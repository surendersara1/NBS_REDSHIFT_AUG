/*
======================================================================================
MODULE 70: COST CONTROL, RPU BUDGETS & FINOPS FOR REDSHIFT
======================================================================================
MAPPED BEST PRACTICES (from PROCEDURE_OPTIMIZATION_BEST_PRACTICES_MASTER_FILE.md):
- Practice 106: "Right-size compute (RPUs / cluster / node type) to the workload."
- Practice 16: "Never SELECT *" — scans all columns = higher compute cost.
- Practice 17: "Filter as early as possible" — reduces data scanned = lower cost.
- Practice 107: "Use elastic resize ahead of known heavy batch windows."
- Practice 67: "Schedule VACUUM/ANALYZE during low-traffic windows."

TARGET AUDIENCE: FinOps Engineers, Data Platform Leads, Engineering Managers
BUSINESS SCENARIO:
A media company's Redshift Serverless bill jumped from $8K/month to $47K/month after
a new team onboarded 50 ad-hoc analysts. Root cause:
  • 12 runaway queries scanning 100TB+ daily (SELECT * FROM fact_events)
  • No usage limits — a single analyst's accidental cross-join consumed $3,200 in one hour
  • No cost attribution — no way to identify which team or query drove the cost

ARCHITECTURE:
┌──────────────────────────────────────────────────────────────────────────────┐
│                      REDSHIFT COST CONTROL STACK                             │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  Layer 1: QUERY-LEVEL CONTROLS                                              │
│  ├── Query Monitoring Rules (QMR): Kill queries exceeding thresholds        │
│  ├── Result Cache: Avoid re-executing identical queries (Module 65)         │
│  └── EXPLAIN + Filter Pushdown: Reduce data scanned per query              │
│                                                                              │
│  Layer 2: WORKGROUP-LEVEL CONTROLS                                          │
│  ├── Usage Limits: Daily/weekly RPU-hour caps                               │
│  ├── Max RPU: Ceiling on auto-scaling                                       │
│  └── Auto-Pause: Zero cost when idle                                        │
│                                                                              │
│  Layer 3: ORGANIZATIONAL CONTROLS                                           │
│  ├── Cost Attribution: Tag queries by team/user/application                 │
│  ├── Chargeback Reports: Per-team cost breakdown                            │
│  └── AWS Budgets: Alerts at 50%, 80%, 100% of monthly target               │
│                                                                              │
│  Layer 4: ARCHITECTURAL CONTROLS                                            │
│  ├── Spectrum for cold data: $5/TB scanned vs. $0.36/RPU-hour compute     │
│  ├── Materialized Views: Pre-compute expensive aggregations once           │
│  ├── Concurrency Scaling: Free tier first (1 hr/node/day)                  │
│  └── Scheduled resize: Scale down during off-peak                          │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘

======================================================================================
*/

-- ============================================================================
-- SECTION 1: UNDERSTANDING REDSHIFT COST DRIVERS
-- ============================================================================
/*
PROVISIONED CLUSTER COSTS:
  • Compute: Per-node-hour (always on). RA3.4xlarge = ~$3.26/hr per node.
  • Storage: RA3 managed storage = $0.024/GB/month.
  • Spectrum: $5/TB of data scanned from S3.
  • Concurrency Scaling: Same rate as base compute, 1 free hr/node/day.
  • Snapshots: Free up to cluster size; cross-region = $0.02/GB/month.

SERVERLESS COSTS:
  • Compute: Per-RPU-second. ~$0.375/RPU-hour.
  • Storage: $0.024/GB/month (same as RA3).
  • Spectrum: $5/TB scanned.
  • No concurrency scaling charges (built into auto-scaling).
  • Recovery points: Included.

THE #1 COST DRIVER: COMPUTE (not storage). Optimizing queries and right-sizing
compute has 10-100x more impact than storage optimization.
*/


-- ============================================================================
-- SECTION 2: SERVERLESS USAGE LIMITS (THE BUDGET GUARDRAIL)
-- ============================================================================
-- IMPLEMENTS: Best Practice #106

-- Set a daily RPU-hour limit to prevent runaway costs:
-- aws redshift-serverless update-usage-limit \
--     --usage-limit-id "ul-abc123" \
--     --amount 100 \
--     --usage-type "ServerlessCompute" \
--     --period "daily" \
--     --breach-action "deactivate"  -- Options: log, deactivate, emit-metric

-- What happens when the limit is breached:
-- • log: Query still runs, but a CloudWatch alarm fires
-- • emit-metric: Emits a metric; use with SNS for alerts
-- • deactivate: ALL queries are blocked until the next period resets

-- RECOMMENDATION: Use 'emit-metric' for production + SNS alerts.
-- Reserve 'deactivate' for non-critical dev/test workgroups.


-- ============================================================================
-- SECTION 3: FINDING THE MOST EXPENSIVE QUERIES
-- ============================================================================
-- IMPLEMENTS: Best Practices #16 (Never SELECT *), #17 (Filter early)

-- Top 20 most expensive queries (by compute time):
SELECT
    query_id,
    user_id,
    LEFT(query_text, 200)                       AS query_preview,
    elapsed_time / 1000000.0                     AS elapsed_seconds,
    queue_time / 1000000.0                       AS queue_seconds,
    execution_time / 1000000.0                   AS exec_seconds,
    result_cache_hit,
    returned_rows,
    returned_bytes / (1024*1024*1024)             AS returned_gb
FROM SYS_QUERY_HISTORY
WHERE start_time >= DATEADD(day, -1, SYSDATE)
  AND query_type = 'SELECT'
  AND result_cache_hit = FALSE                   -- Exclude cached (free) queries
ORDER BY elapsed_time DESC
LIMIT 20;

-- Top cost-driving users (who's burning the most compute?):
SELECT
    user_id,
    COUNT(*)                                     AS query_count,
    SUM(elapsed_time) / 1000000.0 / 3600.0       AS total_compute_hours,
    AVG(elapsed_time) / 1000000.0                AS avg_query_seconds,
    SUM(returned_bytes) / (1024.0^4)              AS total_returned_tb
FROM SYS_QUERY_HISTORY
WHERE start_time >= DATEADD(day, -7, SYSDATE)
  AND query_type IN ('SELECT', 'CTAS', 'UNLOAD')
GROUP BY user_id
ORDER BY total_compute_hours DESC
LIMIT 20;


-- ============================================================================
-- SECTION 4: SERVERLESS COMPUTE CONSUMPTION ANALYSIS
-- ============================================================================

-- Daily RPU consumption trend:
SELECT
    DATE_TRUNC('day', start_time)::DATE         AS usage_date,
    SUM(compute_seconds) / 3600.0                AS compute_hours,
    SUM(charged_seconds) / 3600.0                AS charged_hours,
    SUM(data_scanned_bytes) / (1024.0^4)          AS data_scanned_tb,
    ROUND(SUM(charged_seconds) / 3600.0 * 0.375, 2) AS estimated_cost_usd
FROM SYS_SERVERLESS_USAGE
WHERE start_time >= DATEADD(day, -30, SYSDATE)
GROUP BY 1
ORDER BY 1;

-- Hourly cost pattern (find your peak hours):
SELECT
    EXTRACT(hour FROM start_time)                AS hour_of_day,
    ROUND(AVG(charged_seconds) / 3600.0 * 0.375, 2) AS avg_hourly_cost_usd,
    COUNT(*)                                     AS query_count
FROM SYS_SERVERLESS_USAGE
WHERE start_time >= DATEADD(day, -7, SYSDATE)
GROUP BY 1
ORDER BY 1;


-- ============================================================================
-- SECTION 5: QUERY MONITORING RULES (QMR) — AUTO-KILL RUNAWAY QUERIES
-- ============================================================================
-- IMPLEMENTS: Best Practice #106

-- QMR automatically aborts or logs queries exceeding predefined thresholds.
-- This prevents a single bad query from consuming your entire budget.

-- Create a QMR via parameter group (JSON config):
/*
{
  "rules": [
    {
      "rule_name": "kill_long_queries",
      "predicate": [
        {"metric_name": "query_execution_time", "operator": ">", "value": 600}
      ],
      "action": "abort"
    },
    {
      "rule_name": "log_full_table_scans",
      "predicate": [
        {"metric_name": "scan_row_count", "operator": ">", "value": 1000000000}
      ],
      "action": "log"
    },
    {
      "rule_name": "kill_disk_spill",
      "predicate": [
        {"metric_name": "query_temp_blocks_to_disk", "operator": ">", "value": 1000000}
      ],
      "action": "abort"
    }
  ]
}
*/

-- Check QMR violations:
SELECT
    query_id,
    rule_name,
    action,                   -- 'abort', 'log', 'hop' (move to another queue)
    metric_name,
    metric_value,
    threshold,
    start_time
FROM STL_WLM_RULE_ACTION
WHERE start_time >= DATEADD(day, -7, SYSDATE)
ORDER BY start_time DESC;


-- ============================================================================
-- SECTION 6: SPECTRUM COST OPTIMIZATION ($5/TB SCANNED)
-- ============================================================================
-- IMPLEMENTS: Best Practice #17 (Filter early), #60 (Columnar formats)

-- Spectrum charges $5/TB of data scanned from S3.
-- Two levers to reduce cost:
--   1. Columnar formats (Parquet/ORC): scan only needed columns
--   2. Partition pruning: scan only needed partitions

-- ❌ BAD: CSV on S3 (scans all columns, no partition pruning)
-- SELECT user_id, event_type
-- FROM spectrum.raw_events_csv          -- 100TB CSV, ALL columns scanned
-- WHERE event_date = '2026-08-14';      -- No partition pruning
-- COST: $500 per query (100TB × $5/TB)

-- ✅ GOOD: Partitioned Parquet on S3 (scan 2 columns, 1 partition)
-- SELECT user_id, event_type
-- FROM spectrum.raw_events_parquet      -- Parquet, only 2 columns scanned
-- WHERE event_date = '2026-08-14';      -- Partition pruning → ~1TB scanned
-- COST: $5 per query (1TB × $5/TB) — 100x cheaper!

-- Monitor Spectrum scan costs:
SELECT
    query_id,
    segment,
    s3_scanned_rows,
    s3_scanned_bytes / (1024.0^4)     AS s3_scanned_tb,
    ROUND(s3_scanned_bytes / (1024.0^4) * 5.0, 2) AS estimated_spectrum_cost_usd
FROM SVL_S3QUERY_SUMMARY
WHERE start_time >= DATEADD(day, -1, SYSDATE)
ORDER BY s3_scanned_bytes DESC
LIMIT 20;


-- ============================================================================
-- SECTION 7: COST ATTRIBUTION BY TEAM / APPLICATION
-- ============================================================================

-- Use query_group or query labels to tag queries by team:
-- SET query_group TO 'team=marketing';
-- SELECT ... FROM gold.fact_campaigns ...;
-- RESET query_group;

-- Then aggregate costs by team:
SELECT
    COALESCE(
        REGEXP_SUBSTR(query_text, 'team=([a-z_]+)', 1, 1, 'e'),
        'untagged'
    ) AS team_tag,
    COUNT(*)                                     AS query_count,
    SUM(elapsed_time) / 1000000.0 / 3600.0       AS compute_hours,
    ROUND(SUM(elapsed_time) / 1000000.0 / 3600.0 * 0.375, 2)
                                                  AS estimated_cost_usd
FROM SYS_QUERY_HISTORY
WHERE start_time >= DATEADD(day, -30, SYSDATE)
  AND query_type IN ('SELECT', 'CTAS', 'UNLOAD')
GROUP BY 1
ORDER BY estimated_cost_usd DESC;


-- ============================================================================
-- SECTION 8: COST OPTIMIZATION CHECKLIST
-- ============================================================================
/*
┌──────────────────────────────────────────────────────────────────────────────┐
│                    COST OPTIMIZATION CHECKLIST                                │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  IMMEDIATE WINS (< 1 hour of work):                                        │
│  ☐ Enable result caching (usually already on — verify)                     │
│  ☐ Set Serverless usage limits (daily RPU-hour cap)                        │
│  ☐ Create QMR to abort queries > 10 minutes                                │
│  ☐ Convert S3 data from CSV → Parquet                                      │
│  ☐ Add partition pruning to Spectrum queries                               │
│                                                                              │
│  MEDIUM EFFORT (1 day of work):                                            │
│  ☐ Identify and optimize top 10 most expensive queries                     │
│  ☐ Replace SELECT * with specific column lists                             │
│  ☐ Create Materialized Views for repeated dashboard queries                │
│  ☐ Schedule elastic resize (scale down off-peak)                           │
│  ☐ Enable auto-pause for Serverless dev/test workgroups                    │
│                                                                              │
│  STRATEGIC (1 week of work):                                                │
│  ☐ Implement cost attribution (query_group tags by team)                   │
│  ☐ Move cold data to Spectrum (>90 days → S3 Parquet)                     │
│  ☐ Set up AWS Budgets with SNS alerts at 50%, 80%, 100%                   │
│  ☐ Evaluate Provisioned vs. Serverless for each workload                   │
│  ☐ Implement chargeback reporting for business stakeholders                │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘
*/


-- ============================================================================
-- SECTION 9: AUTOMATED COST MONITORING PROCEDURE
-- ============================================================================
-- IMPLEMENTS: Best Practices #97-101 (Observability)

CREATE OR REPLACE PROCEDURE admin.sp_daily_cost_report()
LANGUAGE plpgsql
AS $$
DECLARE
    v_total_hours   DECIMAL(10,2);
    v_total_cost    DECIMAL(10,2);
    v_top_user      VARCHAR(128);
    v_top_user_cost DECIMAL(10,2);
BEGIN
    -- Calculate yesterday's total compute cost
    SELECT
        ROUND(SUM(charged_seconds) / 3600.0, 2),
        ROUND(SUM(charged_seconds) / 3600.0 * 0.375, 2)
    INTO v_total_hours, v_total_cost
    FROM SYS_SERVERLESS_USAGE
    WHERE start_time >= DATEADD(day, -1, CURRENT_DATE)
      AND start_time <  CURRENT_DATE;

    -- Find the most expensive user
    SELECT user_id, ROUND(SUM(elapsed_time) / 1000000.0 / 3600.0 * 0.375, 2)
    INTO v_top_user, v_top_user_cost
    FROM SYS_QUERY_HISTORY
    WHERE start_time >= DATEADD(day, -1, CURRENT_DATE)
      AND start_time <  CURRENT_DATE
    GROUP BY user_id
    ORDER BY 2 DESC
    LIMIT 1;

    RAISE INFO '=== DAILY COST REPORT ===';
    RAISE INFO 'Date: %', CURRENT_DATE - 1;
    RAISE INFO 'Total Compute Hours: %', v_total_hours;
    RAISE INFO 'Estimated Cost: $%', v_total_cost;
    RAISE INFO 'Top User: % ($%)', v_top_user, v_top_user_cost;

    -- Alert if cost exceeds daily budget:
    IF v_total_cost > 500.00 THEN
        RAISE WARNING '⚠️ DAILY COST EXCEEDED $500 BUDGET: $%', v_total_cost;
    END IF;
END;
$$;

-- CALL admin.sp_daily_cost_report();
