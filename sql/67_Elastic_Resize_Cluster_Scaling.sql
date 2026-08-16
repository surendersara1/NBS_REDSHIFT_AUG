/*
======================================================================================
MODULE 67: ELASTIC RESIZE, CLUSTER SCALING & SERVERLESS RPU MANAGEMENT
======================================================================================
MAPPED BEST PRACTICES (from PROCEDURE_OPTIMIZATION_BEST_PRACTICES_MASTER_FILE.md):
- Practice 106: "Right-size compute (RPUs / cluster / node type) to the workload."
- Practice 107: "Use elastic resize or RA3 node scaling ahead of known heavy batch windows."
- Practice 103: "Use Auto WLM instead of manual queues."
- Practice 104: "Separate ETL/batch workloads from BI/dashboard queues."

TARGET AUDIENCE: Cloud Infrastructure Engineers, FinOps Leads, Platform Architects
BUSINESS SCENARIO:
A retail data warehouse runs two distinct workloads:
  • Nightly ETL (1:00–5:00 AM): Heavy COPY + MERGE across 200 tables. Needs 12 nodes.
  • Daytime BI (8:00 AM–8:00 PM): 3,000 Tableau users. Needs 6 nodes + concurrency scaling.
  • Weekends: Near-zero usage. Could run on 2 nodes or pause entirely.

Without scaling, the company pays for 12 nodes 24/7 = $350K/year wasted compute.
With elastic resize + scheduled actions, they pay for what they use = $140K/year.

ARCHITECTURE:
┌──────────────────────────────────────────────────────────────────────────────┐
│                   COMPUTE SCALING OPTIONS IN REDSHIFT                        │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌─────────────────────────────────────────────────┐                        │
│  │  PROVISIONED CLUSTERS (RA3 / DC2)               │                        │
│  │  ├── Classic Resize: Add/remove nodes            │                        │
│  │  │   (minutes, cluster restart, brief downtime)  │                        │
│  │  ├── Elastic Resize: Add/remove SAME node type   │                        │
│  │  │   (seconds, no restart, near-zero downtime)   │                        │
│  │  ├── Concurrency Scaling: Burst BI queues         │                        │
│  │  │   (auto-add transient clusters for read)      │                        │
│  │  └── Scheduled Actions: Cron-based resize         │                        │
│  │      (scale up before ETL, scale down after)     │                        │
│  └─────────────────────────────────────────────────┘                        │
│                                                                              │
│  ┌─────────────────────────────────────────────────┐                        │
│  │  SERVERLESS WORKGROUPS                          │                        │
│  │  ├── Base RPU: Minimum always-on capacity        │                        │
│  │  │   (8–512 RPUs, in increments of 8)           │                        │
│  │  ├── Max RPU: Ceiling for auto-scaling            │                        │
│  │  │   (auto-scales between base and max)          │                        │
│  │  ├── Auto Pause: Zero cost when idle              │                        │
│  │  │   (resumes in ~30 seconds on first query)     │                        │
│  │  └── Usage Limits: Daily/weekly RPU-hour caps     │                        │
│  │      (prevents runaway costs)                    │                        │
│  └─────────────────────────────────────────────────┘                        │
│                                                                              │
│  TIMELINE EXAMPLE (24-HOUR CYCLE):                                          │
│  ┌────┬────┬────┬────┬────┬────┬────┬────┬────┬────┬────┬────┐             │
│  │12AM│2AM │4AM │6AM │8AM │10AM│12PM│2PM │4PM │6PM │8PM │10PM│             │
│  ├────┼────┼────┼────┼────┼────┼────┼────┼────┼────┼────┼────┤             │
│  │ 12 nodes (ETL) │ 6 nodes (BI) + concurrency scaling │ 2  │             │
│  │████████████████│░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░│▒▒▒▒│             │
│  └────┴────┴────┴────┴────┴────┴────┴────┴────┴────┴────┴────┘             │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘

======================================================================================
*/

-- ============================================================================
-- SECTION 1: ELASTIC RESIZE (PROVISIONED CLUSTERS)
-- ============================================================================
-- IMPLEMENTS: Best Practice #107

-- Elastic resize changes the number of nodes WITHOUT a full cluster restart.
-- Data is redistributed in the background. Queries continue with brief pauses.
--
-- CONSTRAINTS:
--   • Can only add/remove nodes of the SAME type (e.g., ra3.4xlarge)
--   • Must stay within supported node count range (1–128 for RA3)
--   • Cannot change node type (that requires classic resize)

-- Scale UP before the nightly ETL window:
-- (Run this via AWS CLI, SDK, or Redshift Scheduler — not SQL)
-- aws redshift resize-cluster \
--     --cluster-identifier <CLUSTER_ID> \
--     --cluster-type multi-node \
--     --number-of-nodes 12 \
--     --classic false

-- Scale DOWN after ETL completes:
-- aws redshift resize-cluster \
--     --cluster-identifier <CLUSTER_ID> \
--     --number-of-nodes 6 \
--     --classic false

-- Check resize status from within Redshift:
SELECT
    cluster_identifier,
    node_type,
    number_of_nodes,
    cluster_status,               -- 'available', 'resizing', 'modifying'
    resize_type,                  -- 'ElasticResize', 'ClassicResize'
    estimated_time_to_completion
FROM SVV_CLUSTER_INFO;            -- Redshift system view


-- ============================================================================
-- SECTION 2: SCHEDULED ACTIONS (CRON-BASED AUTO-SCALING)
-- ============================================================================
-- IMPLEMENTS: Best Practice #107

-- Scheduled actions automatically resize your cluster on a cron schedule.
-- This eliminates the need for external Lambda functions or Airflow DAGs.

-- Example: Scale to 12 nodes every night at 1:00 AM UTC for ETL
-- aws redshift create-scheduled-action \
--     --scheduled-action-name "nightly-scale-up" \
--     --target-action '{"ResizeCluster":{"ClusterIdentifier":"<CLUSTER_ID>","NumberOfNodes":12}}' \
--     --schedule "cron(0 1 * * ? *)" \
--     --iam-role "<SCHEDULER_ROLE_ARN>" \
--     --scheduled-action-description "Scale up for nightly ETL"

-- Scale back to 6 nodes at 6:00 AM UTC after ETL completes
-- aws redshift create-scheduled-action \
--     --scheduled-action-name "morning-scale-down" \
--     --target-action '{"ResizeCluster":{"ClusterIdentifier":"<CLUSTER_ID>","NumberOfNodes":6}}' \
--     --schedule "cron(0 6 * * ? *)" \
--     --iam-role "<SCHEDULER_ROLE_ARN>"

-- Weekend pause (Friday 10 PM → Monday 6 AM)
-- aws redshift create-scheduled-action \
--     --scheduled-action-name "weekend-pause" \
--     --target-action '{"PauseCluster":{"ClusterIdentifier":"<CLUSTER_ID>"}}' \
--     --schedule "cron(0 22 ? * FRI *)"

-- aws redshift create-scheduled-action \
--     --scheduled-action-name "monday-resume" \
--     --target-action '{"ResumeCluster":{"ClusterIdentifier":"<CLUSTER_ID>"}}' \
--     --schedule "cron(0 6 ? * MON *)"


-- ============================================================================
-- SECTION 3: SERVERLESS RPU SCALING
-- ============================================================================
-- IMPLEMENTS: Best Practice #106

-- Redshift Serverless auto-scales between base and max RPU.
-- 1 RPU ≈ 1 Redshift Provisioned compute unit.
-- Billing is per-RPU-second, billed in 1-second increments.

-- Set base and max RPU for a workgroup:
-- aws redshift-serverless update-workgroup \
--     --workgroup-name "analytics-workgroup" \
--     --base-capacity 32 \
--     --max-capacity 256

-- Monitor RPU consumption:
SELECT
    start_time,
    end_time,
    compute_seconds,
    data_scanned_bytes / (1024*1024*1024) AS data_scanned_gb,
    charged_seconds
FROM SYS_SERVERLESS_USAGE
WHERE start_time >= DATEADD(day, -7, SYSDATE)
ORDER BY start_time DESC
LIMIT 50;

-- Daily RPU consumption trend:
SELECT
    DATE_TRUNC('day', start_time)::DATE AS usage_date,
    SUM(compute_seconds) / 3600.0       AS compute_hours,
    SUM(charged_seconds) / 3600.0       AS charged_hours,
    SUM(data_scanned_bytes) / (1024.0^4) AS data_scanned_tb
FROM SYS_SERVERLESS_USAGE
WHERE start_time >= DATEADD(day, -30, SYSDATE)
GROUP BY 1
ORDER BY 1;


-- ============================================================================
-- SECTION 4: CONCURRENCY SCALING (BURST BI CAPACITY)
-- ============================================================================
-- IMPLEMENTS: Best Practice #105

-- Concurrency Scaling automatically adds transient cluster capacity when
-- your WLM queues are full. It handles burst BI workloads without permanent
-- node additions.
--
-- HOW IT WORKS:
--   1. User query enters WLM queue
--   2. If queue wait > threshold, Redshift spins up a transient cluster
--   3. Query executes on the transient cluster
--   4. Transient cluster auto-terminates after idle timeout
--
-- COST: You get 1 hour/day of free concurrency scaling per active node.
--   A 6-node cluster gets 6 free hours/day. Beyond that: on-demand pricing.

-- Enable concurrency scaling for a WLM queue:
-- (Set via Parameter Group or Redshift console)
-- max_concurrency_scaling_clusters = 5  (up to 10)

-- Check if queries used concurrency scaling:
SELECT
    query_id,
    query_text,
    concurrency_scaling_status,     -- 0=main cluster, 1=scaling cluster
    elapsed_time / 1000000.0 AS elapsed_sec,
    queue_time / 1000000.0 AS queue_sec
FROM SYS_QUERY_HISTORY
WHERE start_time >= DATEADD(hour, -24, SYSDATE)
  AND concurrency_scaling_status = 1
ORDER BY start_time DESC
LIMIT 20;

-- Calculate concurrency scaling usage and free-tier consumption:
SELECT
    DATE_TRUNC('day', start_time)::DATE AS usage_date,
    SUM(CASE WHEN concurrency_scaling_status = 1 THEN elapsed_time ELSE 0 END)
        / 1000000.0 / 3600.0 AS concurrency_scaling_hours
FROM SYS_QUERY_HISTORY
WHERE start_time >= DATEADD(day, -30, SYSDATE)
GROUP BY 1
ORDER BY 1;


-- ============================================================================
-- SECTION 5: ANTI-PATTERN — OVER-PROVISIONED "SET AND FORGET"
-- ============================================================================

-- ❌ BAD: Running 12 RA3.4xlarge nodes 24/7 because "ETL needs them"
-- Cost: 12 × $3.26/hr × 24h × 365d = $342,696/year
--
-- ✅ GOOD: Elastic resize schedule:
-- • ETL window (5 hours): 12 nodes = 12 × $3.26 × 5h = $195.60/day
-- • BI window (12 hours): 6 nodes  = 6 × $3.26 × 12h = $234.72/day
-- • Off-peak (7 hours):   2 nodes  = 2 × $3.26 × 7h  = $45.64/day
-- Total: $475.96/day × 365 = $173,725/year — SAVING $168,971/year (49%)
--
-- Even better: Serverless with auto-pause:
-- • Only billed for actual compute-seconds consumed
-- • Zero cost during weekends if no queries run


-- ============================================================================
-- SECTION 6: MONITORING CLUSTER HEALTH & RIGHT-SIZING
-- ============================================================================
-- IMPLEMENTS: Best Practice #106

-- Check current cluster utilization:
SELECT
    service_class,
    num_queued_queries,
    num_executing_queries,
    query_cpu_usage_percent,
    query_memory_usage_percent
FROM STV_WLM_SERVICE_CLASS_STATE
WHERE service_class > 4;    -- User-defined queues only

-- Historical CPU and disk usage (right-sizing signal):
SELECT
    DATE_TRUNC('hour', recorded_time)::TIMESTAMP AS hour,
    AVG(avg_cpu_utilization) AS avg_cpu_pct,
    AVG(avg_disk_space_used_percent) AS avg_disk_pct,
    MAX(avg_cpu_utilization) AS peak_cpu_pct
FROM SYS_CLUSTER_PERFORMANCE
WHERE recorded_time >= DATEADD(day, -7, SYSDATE)
GROUP BY 1
ORDER BY 1;

-- RIGHT-SIZING RULE OF THUMB:
-- • Avg CPU < 20% sustained → you're over-provisioned, scale down
-- • Avg CPU > 80% sustained → you're under-provisioned, scale up
-- • Peak CPU hitting 100% during ETL only → use scheduled elastic resize
-- • Disk > 80% on DC2 → migrate to RA3 (managed storage auto-scales)


-- ============================================================================
-- SECTION 7: PROVISIONED vs. SERVERLESS DECISION MATRIX
-- ============================================================================
/*
┌────────────────────────┬──────────────────────────┬──────────────────────────┐
│ Criteria               │ Provisioned (RA3/DC2)    │ Serverless               │
├────────────────────────┼──────────────────────────┼──────────────────────────┤
│ Workload Pattern       │ Predictable, steady      │ Spiky, unpredictable     │
│ Cost Model             │ Per-node-hour (always on)│ Per-RPU-second (pay-use) │
│ Scaling Speed          │ Minutes (elastic resize) │ Seconds (auto-scale RPU) │
│ Minimum Cost           │ ~$2,500/month (2 nodes)  │ $0 (auto-pause)          │
│ Max Performance        │ 128 nodes × 48 slices    │ 512 RPU                  │
│ Concurrency Scaling    │ Yes (free tier + paid)   │ Built-in (auto-scale)    │
│ Snapshot/Backup        │ Manual + automated       │ Automated (recovery pts) │
│ WLM Queues             │ Up to 8 queues           │ Priority-based           │
│ Best For               │ Large, 24/7 warehouses   │ Dev/test, analytics, BI  │
└────────────────────────┴──────────────────────────┴──────────────────────────┘
*/
