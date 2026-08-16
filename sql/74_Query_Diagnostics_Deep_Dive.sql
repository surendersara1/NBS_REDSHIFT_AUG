/*
======================================================================================
MODULE 74: QUERY DIAGNOSTICS DEEP DIVE — SYSTEMATIC PERFORMANCE TRIAGE
======================================================================================
MAPPED BEST PRACTICES (from PROCEDURE_OPTIMIZATION_BEST_PRACTICES_MASTER_FILE.md):
- Practice 35: "Read the EXPLAIN plan before and after every change."
- Practice 36: "Watch for disk spill."
- Practice 37: "Check STL_ALERT_EVENT_LOG for planner-flagged issues."
- Practice 38: "Benchmark via SYS_QUERY_HISTORY/SVL_QUERY_METRICS."
- Practice 4: "Chase the 80/20 — fix only the 2-3 slowest steps."
- Practice 6: "Change one thing at a time — edit, re-measure, keep or revert."

TARGET AUDIENCE: Performance Engineers, Senior Data Engineers, DBAs
BUSINESS SCENARIO:
A production stored procedure that builds the Gold-layer fact_orders table
degraded from 8 minutes to 2.5 hours after a table grew past 5 billion rows.
The on-call engineer needs a systematic approach to:
  1. Identify WHICH step is slow (not guess)
  2. Understand WHY it's slow (EXPLAIN plan + system views)
  3. Fix it with evidence (not cargo-cult optimization)
  4. Verify the fix is correct (diff row counts)

DIAGNOSTIC DECISION TREE:
┌──────────────────────────────────────────────────────────────────────────────┐
│                    QUERY PERFORMANCE TRIAGE FLOWCHART                        │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  Query is slow                                                              │
│  │                                                                           │
│  ├─▶ Step 1: Is it QUEUED or EXECUTING?                                     │
│  │   ├─ Queued too long → WLM contention (Module 18)                        │
│  │   └─ Executing too long → Continue below                                 │
│  │                                                                           │
│  ├─▶ Step 2: Check STL_ALERT_EVENT_LOG                                      │
│  │   ├─ "Missing statistics" → ANALYZE the table                            │
│  │   ├─ "Nested Loop" → Missing join predicate or cross join                │
│  │   ├─ "Very selective filter" → Sort key mismatch                         │
│  │   ├─ "Broadcast" → Distribution key misalignment                        │
│  │   └─ "Serial execution" → Query runs on Leader Node only                │
│  │                                                                           │
│  ├─▶ Step 3: Check EXPLAIN plan                                             │
│  │   ├─ DS_DIST_BOTH → Both tables redistributed (bad dist keys)           │
│  │   ├─ DS_BCAST_INNER → Inner table broadcast (big table = bad)           │
│  │   ├─ DS_DIST_NONE → Co-located join (good!)                             │
│  │   ├─ Hash Join vs. Nested Loop → Nested loop is almost always bad       │
│  │   └─ Sort step + Disk spill → Data too large for memory                 │
│  │                                                                           │
│  ├─▶ Step 4: Check SVL_QUERY_METRICS_SUMMARY                               │
│  │   ├─ segment_execution_time → Which segment took the most time?          │
│  │   ├─ query_temp_blocks_to_disk → Disk spill detected?                   │
│  │   └─ scan_row_count vs returned_rows → How selective is the filter?     │
│  │                                                                           │
│  └─▶ Step 5: Check SVV_TABLE_INFO                                           │
│      ├─ stats_off > 10% → Run ANALYZE                                      │
│      ├─ unsorted > 20% → Run VACUUM SORT ONLY                              │
│      ├─ skew_rows > 4.0 → Bad distribution key → data imbalance            │
│      └─ empty > 20% → Run VACUUM DELETE ONLY                               │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘

======================================================================================
*/

-- ============================================================================
-- SECTION 1: STEP 1 — IS IT QUEUED OR EXECUTING?
-- ============================================================================
-- IMPLEMENTS: Best Practice #38

-- Separate queue wait time from actual execution time:
SELECT
    query_id,
    user_id,
    LEFT(query_text, 150)                       AS query_preview,
    queue_time / 1000000.0                       AS queue_seconds,
    execution_time / 1000000.0                   AS exec_seconds,
    elapsed_time / 1000000.0                     AS total_seconds,
    ROUND(queue_time * 100.0 / NULLIF(elapsed_time, 0), 1) AS pct_in_queue,
    status
FROM SYS_QUERY_HISTORY
WHERE start_time >= DATEADD(hour, -4, SYSDATE)
  AND elapsed_time > 60000000                    -- Longer than 60 seconds
ORDER BY elapsed_time DESC
LIMIT 20;

-- If pct_in_queue > 50%: The problem is WLM contention, not the query itself.
-- Fix: Adjust WLM queues, enable concurrency scaling, or schedule better.

-- If pct_in_queue < 10%: The query itself is slow. Continue with Step 2.


-- ============================================================================
-- SECTION 2: STEP 2 — CHECK STL_ALERT_EVENT_LOG (PLANNER RED FLAGS)
-- ============================================================================
-- IMPLEMENTS: Best Practice #37

-- The query planner logs warnings when it detects known anti-patterns:
SELECT
    query,
    event,                      -- The alert type
    solution,                   -- Redshift's suggested fix!
    event_time,
    LEFT(s.query_text, 150) AS query_preview
FROM STL_ALERT_EVENT_LOG a
JOIN SYS_QUERY_HISTORY s ON a.query = s.query_id
WHERE a.event_time >= DATEADD(hour, -4, SYSDATE)
ORDER BY a.event_time DESC
LIMIT 30;

-- COMMON ALERTS AND THEIR FIXES:
/*
┌─────────────────────────────┬──────────────────────────────────────────────────┐
│ Alert Event                 │ What It Means & How to Fix                       │
├─────────────────────────────┼──────────────────────────────────────────────────┤
│ "Missing query plan stats"  │ Table stats are stale. Run ANALYZE on the table.│
│                             │ The planner is guessing row counts → bad plan.  │
├─────────────────────────────┼──────────────────────────────────────────────────┤
│ "Nested Loop Join"          │ Join predicate is missing or non-equi.          │
│                             │ Check for missing ON clause or implicit cross.  │
├─────────────────────────────┼──────────────────────────────────────────────────┤
│ "Very selective filter"     │ A filter eliminates >99.5% of rows AFTER scan. │
│                             │ The sort key doesn't match the filter column.   │
│                             │ Fix: Change sort key or add as compound sort.   │
├─────────────────────────────┼──────────────────────────────────────────────────┤
│ "Broadcasting large table"  │ A large inner table is being broadcast to all   │
│                             │ slices. Fix: Align distribution keys.           │
├─────────────────────────────┼──────────────────────────────────────────────────┤
│ "Serial execution"          │ Query runs only on Leader Node (not parallel).  │
│                             │ Usually: function-only queries, system views.   │
├─────────────────────────────┼──────────────────────────────────────────────────┤
│ "Rows returned exceeds      │ Too many rows being returned to the client.     │
│  threshold"                 │ Add LIMIT or filter, or use UNLOAD to S3.       │
└─────────────────────────────┴──────────────────────────────────────────────────┘
*/


-- ============================================================================
-- SECTION 3: STEP 3 — READ THE EXPLAIN PLAN
-- ============================================================================
-- IMPLEMENTS: Best Practice #35

-- Run EXPLAIN on the slow query (don't execute it — just plan it):
-- EXPLAIN
-- SELECT f.order_date, d.customer_name, SUM(f.total_amount)
-- FROM gold.fact_orders f
-- JOIN gold.dim_customer d ON f.customer_id = d.customer_id
-- WHERE f.order_date >= '2026-01-01'
-- GROUP BY 1, 2;

-- KEY THINGS TO LOOK FOR IN THE PLAN:

-- 1. DISTRIBUTION FLAGS (data movement between nodes):
/*
  DS_DIST_NONE     → ✅ Perfect! Tables are co-located. No data movement.
  DS_DIST_ALL_NONE → ✅ Good. Small table is DISTSTYLE ALL, no movement.
  DS_DIST_INNER    → ⚠️ Inner table is redistributed. Moderate cost.
  DS_BCAST_INNER   → ⚠️ Inner table is broadcast to all slices. OK if small.
  DS_DIST_BOTH     → ❌ BOTH tables redistributed! Very expensive. Fix dist keys.
  DS_DIST_ALL_INNER→ ❌ ALL table is on inner side — unusual, check plan.
*/

-- 2. JOIN TYPES:
/*
  Hash Join        → ✅ Normal equi-join. Parallel, efficient.
  Merge Join       → ✅ Both inputs are pre-sorted. Very efficient.
  Nested Loop      → ❌ Red flag! Usually means missing join key or cross join.
*/

-- 3. SCAN TYPES:
/*
  Seq Scan         → Full table scan. Check if sort key could help.
  Sort             → Data must be sorted. Check if pre-sorted by sort key.
  HashAggregate    → GROUP BY. Check if it spills to disk.
*/


-- ============================================================================
-- SECTION 4: STEP 4 — DETAILED QUERY METRICS
-- ============================================================================
-- IMPLEMENTS: Best Practice #38

-- Get per-segment execution breakdown for a specific query:
SELECT
    query,
    segment,
    step_type,
    rows,
    bytes,
    elapsed_time / 1000000.0            AS segment_seconds,
    is_diskbased                        AS disk_spill,
    workmem / (1024*1024)               AS workmem_mb
FROM SVL_QUERY_METRICS_SUMMARY
WHERE query = 12345678                   -- Replace with your query_id
ORDER BY elapsed_time DESC;

-- The SLOWEST segment is your optimization target.
-- If disk_spill = TRUE → that step ran out of memory and wrote to disk.
--   Fix: Break the query into smaller temp-table steps (Module 26)
--        or increase WLM memory allocation.

-- Get the total bytes scanned vs. returned:
SELECT
    query_id,
    returned_rows,
    returned_bytes / (1024*1024*1024)   AS returned_gb,
    elapsed_time / 1000000.0            AS elapsed_sec
FROM SYS_QUERY_HISTORY
WHERE query_id = 12345678;

-- If returned_gb >> expected: You're scanning way too much data.
--   Fix: Add better filters (Practice #17) or check sort key alignment.


-- ============================================================================
-- SECTION 5: STEP 5 — TABLE HEALTH CHECK
-- ============================================================================
-- IMPLEMENTS: Best Practices #62-67 (Statistics & Maintenance)

-- Comprehensive table health report:
SELECT
    schema AS schema_name,
    "table" AS table_name,
    size AS size_mb,
    tbl_rows,
    sortkey1,
    diststyle,
    stats_off,                          -- % stats are stale (>10% = bad)
    unsorted,                           -- % unsorted rows (>20% = needs VACUUM SORT)
    skew_rows,                          -- Row distribution skew (>4.0 = bad distkey)
    empty AS pct_empty_blocks           -- % empty blocks from deletes (needs VACUUM DELETE)
FROM SVV_TABLE_INFO
WHERE schema IN ('gold', 'silver', 'staging')
  AND tbl_rows > 0
ORDER BY
    CASE
        WHEN stats_off > 10 THEN 1      -- Stale stats = priority 1
        WHEN skew_rows > 4.0 THEN 2     -- Skewed data = priority 2
        WHEN unsorted > 20 THEN 3       -- Unsorted = priority 3
        ELSE 4
    END,
    tbl_rows DESC;

-- Action items from this query:
-- • stats_off > 10% → ANALYZE schema.table;
-- • unsorted > 20%  → VACUUM SORT ONLY schema.table;
-- • skew_rows > 4.0 → Consider changing DISTKEY
-- • pct_empty > 20% → VACUUM DELETE ONLY schema.table;


-- ============================================================================
-- SECTION 6: THE COMPLETE DIAGNOSTIC PROCEDURE
-- ============================================================================
-- IMPLEMENTS: Best Practices #97-101 (Observability)

CREATE OR REPLACE PROCEDURE admin.sp_diagnose_slow_query(
    p_query_id BIGINT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_elapsed_sec   DECIMAL(10,2);
    v_queue_sec     DECIMAL(10,2);
    v_exec_sec      DECIMAL(10,2);
    v_returned_rows BIGINT;
    v_cache_hit     BOOLEAN;
    v_alert_count   INT;
    v_spill_count   INT;
BEGIN
    -- 1. Basic query info
    SELECT
        elapsed_time / 1000000.0,
        queue_time / 1000000.0,
        execution_time / 1000000.0,
        returned_rows,
        result_cache_hit
    INTO v_elapsed_sec, v_queue_sec, v_exec_sec, v_returned_rows, v_cache_hit
    FROM SYS_QUERY_HISTORY
    WHERE query_id = p_query_id;

    RAISE INFO '=== DIAGNOSTIC REPORT FOR QUERY % ===', p_query_id;
    RAISE INFO 'Total: %s | Queue: %s | Exec: %s | Rows: % | Cache: %',
               v_elapsed_sec, v_queue_sec, v_exec_sec, v_returned_rows, v_cache_hit;

    -- Queue analysis
    IF v_queue_sec > v_exec_sec THEN
        RAISE WARNING '⚠️ Query spent MORE time in queue than executing! Check WLM.';
    END IF;

    -- 2. Check for planner alerts
    SELECT COUNT(*) INTO v_alert_count
    FROM STL_ALERT_EVENT_LOG
    WHERE query = p_query_id;

    IF v_alert_count > 0 THEN
        RAISE WARNING '⚠️ % planner alerts found! Check STL_ALERT_EVENT_LOG.', v_alert_count;
    ELSE
        RAISE INFO '✅ No planner alerts.';
    END IF;

    -- 3. Check for disk spill
    SELECT COUNT(*) INTO v_spill_count
    FROM SVL_QUERY_METRICS_SUMMARY
    WHERE query = p_query_id
      AND is_diskbased = 't';

    IF v_spill_count > 0 THEN
        RAISE WARNING '❌ DISK SPILL detected in % segments! Query ran out of memory.', v_spill_count;
        RAISE INFO 'FIX: Break into smaller temp tables or increase WLM memory.';
    ELSE
        RAISE INFO '✅ No disk spill.';
    END IF;

    RAISE INFO '=== END DIAGNOSTIC REPORT ===';
END;
$$;

-- Usage: CALL admin.sp_diagnose_slow_query(12345678);


-- ============================================================================
-- SECTION 7: BEFORE/AFTER OPTIMIZATION TEMPLATE
-- ============================================================================
-- IMPLEMENTS: Best Practices #5 (Correctness gate), #6 (One change at a time),
--             #111 (Diff checksums)

-- Step 1: Capture baseline BEFORE any change
CREATE TEMP TABLE baseline_metrics AS
SELECT
    COUNT(*)        AS row_count,
    SUM(CHECKSUM(order_id::VARCHAR || total_amount::VARCHAR)) AS checksum,
    SYSDATE         AS captured_at
FROM gold.fact_orders
WHERE order_date >= '2026-01-01';

-- Step 2: Make ONE optimization change (e.g., add a sort key, rewrite a join)

-- Step 3: Re-run and capture AFTER metrics
CREATE TEMP TABLE after_metrics AS
SELECT
    COUNT(*)        AS row_count,
    SUM(CHECKSUM(order_id::VARCHAR || total_amount::VARCHAR)) AS checksum,
    SYSDATE         AS captured_at
FROM gold.fact_orders
WHERE order_date >= '2026-01-01';

-- Step 4: DIFF — verify correctness
SELECT
    b.row_count     AS before_rows,
    a.row_count     AS after_rows,
    b.checksum      AS before_checksum,
    a.checksum      AS after_checksum,
    CASE WHEN b.row_count = a.row_count AND b.checksum = a.checksum
         THEN '✅ PASS — Identical output'
         ELSE '❌ FAIL — Output changed!'
    END AS verification
FROM baseline_metrics b, after_metrics a;
