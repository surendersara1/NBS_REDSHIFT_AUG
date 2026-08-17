/*
======================================================================================
MODULE 65: RESULT CACHE, QUERY ACCELERATION & SHORT-QUERY OPTIMIZATION
======================================================================================
MAPPED BEST PRACTICES (from PROCEDURE_OPTIMIZATION_BEST_PRACTICES_MASTER_FILE.md):
- Practice 108: "Lean on result caching for identical repeat queries — avoid volatile
  SQL (e.g., now()) that defeats it."
- Practice 20: "Avoid recomputing the same expression repeatedly."
- Practice 106: "Right-size compute to the workload."
- Practice 103: "Use Auto WLM instead of manual queues."

TARGET AUDIENCE: BI Engineers, Dashboard Developers, Performance Engineers
BUSINESS SCENARIO:
A retail analytics team has 200 Tableau dashboards used by 3,000 users. During the
morning "coffee rush" (8:00-9:30 AM), 2,800 users open dashboards simultaneously.
80% of these queries are IDENTICAL (same filters, same date range).

Without result caching, Redshift executes 2,800 full table scans of a 500GB fact table.
With result caching, it executes 1 scan and serves 2,799 responses from cache in <10ms.

ARCHITECTURE:
┌──────────────────────────────────────────────────────────────────────────────┐
│                      QUERY EXECUTION PIPELINE                               │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  User Query ──► Parser ──► Planner ──┬──► RESULT CACHE HIT?                │
│                                      │    ├── YES → Return cached result    │
│                                      │    │         (< 10ms, zero compute)  │
│                                      │    │                                 │
│                                      │    └── NO → Continue to execution    │
│                                      │              │                       │
│                                      │              ▼                       │
│                                      │    ┌────────────────────┐            │
│                                      │    │ SHORT QUERY?       │            │
│                                      │    │ (< 5 seconds est.) │            │
│                                      │    ├────────────────────┤            │
│                                      │    │ YES → QA Accel.    │            │
│                                      │    │   (burst slices)   │            │
│                                      │    │ NO  → Normal exec  │            │
│                                      │    └────────────────────┘            │
│                                      │              │                       │
│                                      │              ▼                       │
│                                      │    Execute on compute slices         │
│                                      │    Store result in cache             │
│                                      │    Return to user                    │
│                                      │                                      │
└──────────────────────────────────────────────────────────────────────────────┘
│                                                                              │
│  CACHE INVALIDATION TRIGGERS:                                               │
│  • Underlying table receives INSERT/UPDATE/DELETE/COPY                      │
│  • DDL on underlying table (ALTER TABLE, DROP, etc.)                        │
│  • Session parameter changes (search_path, timezone, etc.)                  │
│  • Cache entry exceeds TTL (default ~1 hour for unchanged tables)           │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘

======================================================================================
*/

-- These schemas are referenced throughout this module but are not created by
-- sql/01 (staging, analytics, admin) or sql/07 (rpt). Without these lines every
-- qualified reference below fails with 'schema does not exist'.
CREATE SCHEMA IF NOT EXISTS gold;
CREATE SCHEMA IF NOT EXISTS bi;

-- ============================================================================
-- SECTION 1: UNDERSTANDING RESULT CACHING (THE FREE PERFORMANCE TIER)
-- ============================================================================
-- IMPLEMENTS: Best Practice #108
--
-- Result caching is ENABLED BY DEFAULT in Redshift. When a query:
--   1. Has been executed before with identical SQL text
--   2. The underlying tables have NOT been modified since the last execution
--   3. The query does NOT contain volatile functions
-- → Redshift returns the cached result in <10ms, using ZERO compute.
--
-- This is the #1 easiest performance win you can get. It costs nothing.

-- Check if result caching is enabled for your session:
SHOW enable_result_cache_for_session;
-- Default: on

-- Explicitly enable/disable per session:
SET enable_result_cache_for_session = ON;   -- Enable (default)
SET enable_result_cache_for_session = OFF;  -- Disable (for benchmarking)


-- ============================================================================
-- SECTION 2: CACHE-FRIENDLY vs. CACHE-BUSTING QUERIES
-- ============================================================================
-- IMPLEMENTS: Best Practice #108

-- ❌ ANTI-PATTERN: Cache-busting queries (these NEVER hit cache)
-- These use volatile functions that return different values on each call.

-- BAD: GETDATE() / SYSDATE / CURRENT_TIMESTAMP are volatile
SELECT
    product_category,
    SUM(revenue) AS total_revenue
FROM gold.fact_sales
WHERE sale_date >= DATEADD(day, -30, GETDATE())   -- ← CACHE BUSTER!
GROUP BY product_category;
-- Every execution generates a DIFFERENT SQL text because GETDATE() evaluates
-- to a different microsecond. Redshift sees it as a brand-new query.

-- BAD: RANDOM() is volatile
SELECT * FROM gold.dim_products ORDER BY RANDOM() LIMIT 10;

-- BAD: Non-deterministic UDFs marked as VOLATILE
-- CREATE FUNCTION my_volatile_func() RETURNS INT VOLATILE AS $$ ... $$;


-- ✅ GOOD PATTERN: Cache-friendly queries

-- GOOD: Use a fixed date boundary (the BI tool can compute this)
SELECT
    product_category,
    SUM(revenue) AS total_revenue
FROM gold.fact_sales
WHERE sale_date >= '2026-07-16'   -- ← Fixed literal, cache-friendly!
  AND sale_date <  '2026-08-15'
GROUP BY product_category;
-- All 2,800 users submitting this exact query → 1 execution, 2,799 cache hits.

-- GOOD: Use DATE_TRUNC to snap to a boundary
SELECT
    product_category,
    SUM(revenue) AS total_revenue
FROM gold.fact_sales
WHERE sale_date >= DATE_TRUNC('month', CURRENT_DATE)  -- ← Stable within the month
  AND sale_date <  CURRENT_DATE                        -- ← Stable within the day
GROUP BY product_category;
-- CURRENT_DATE (without time component) changes only once per day at midnight.
-- All queries within the same day generate identical SQL → cache hits all day.

-- GOOD: Parameterized views that dashboard tools call with fixed values
CREATE OR REPLACE VIEW bi.vw_monthly_revenue AS
SELECT
    DATE_TRUNC('month', sale_date)::DATE AS sale_month,
    product_category,
    SUM(revenue)        AS total_revenue,
    COUNT(*)            AS transaction_count,
    AVG(revenue)        AS avg_revenue
FROM gold.fact_sales
WHERE sale_date >= DATEADD(month, -12, DATE_TRUNC('month', CURRENT_DATE))
GROUP BY 1, 2;
-- This view's SQL is identical for all users on the same day → cache hit.


-- ============================================================================
-- SECTION 3: VERIFYING CACHE HITS IN QUERY HISTORY
-- ============================================================================
-- IMPLEMENTS: Best Practice #38 (Benchmark via SYS_QUERY_HISTORY)

-- Find queries that hit the result cache:
SELECT
    query_id,
    user_id,
    query_text,
    result_cache_hit,           -- TRUE = served from cache
    elapsed_time / 1000000.0 AS elapsed_seconds,
    start_time
FROM SYS_QUERY_HISTORY
WHERE start_time >= DATEADD(hour, -1, SYSDATE)
  AND query_type = 'SELECT'
ORDER BY start_time DESC
LIMIT 50;

-- Calculate your cache hit ratio (target: >60% for BI workloads):
SELECT
    COUNT(*) AS total_queries,
    SUM(CASE WHEN result_cache_hit THEN 1 ELSE 0 END) AS cache_hits,
    SUM(CASE WHEN NOT result_cache_hit THEN 1 ELSE 0 END) AS cache_misses,
    ROUND(
        SUM(CASE WHEN result_cache_hit THEN 1 ELSE 0 END) * 100.0 / COUNT(*),
        2
    ) AS cache_hit_rate_pct
FROM SYS_QUERY_HISTORY
WHERE start_time >= DATEADD(hour, -24, SYSDATE)
  AND query_type = 'SELECT'
  AND query_text NOT LIKE '%SYS_%';   -- Exclude system catalog queries

-- Identify the TOP cache-busting queries (optimize these first):
SELECT
    MD5(query_text) AS query_fingerprint,
    LEFT(query_text, 200) AS query_preview,
    COUNT(*) AS execution_count,
    SUM(CASE WHEN result_cache_hit THEN 1 ELSE 0 END) AS cache_hits,
    SUM(CASE WHEN NOT result_cache_hit THEN 1 ELSE 0 END) AS cache_misses,
    AVG(elapsed_time) / 1000000.0 AS avg_elapsed_sec
FROM SYS_QUERY_HISTORY
WHERE start_time >= DATEADD(hour, -24, SYSDATE)
  AND query_type = 'SELECT'
  AND result_cache_hit = FALSE
GROUP BY 1, 2
HAVING COUNT(*) > 10        -- Only frequently-executed queries
ORDER BY cache_misses DESC
LIMIT 20;


-- ============================================================================
-- SECTION 4: QUERY ACCELERATION (QA) — TURBO FOR SHORT QUERIES
-- ============================================================================
-- IMPLEMENTS: Best Practice #106 (Right-size compute)
--
-- Query Acceleration (QA) automatically detects short-running queries (typically
-- <5 seconds) and routes them to dedicated "accelerator" compute pools — separate
-- from your main WLM queues. This prevents dashboard queries from queueing behind
-- long-running ETL jobs.
--
-- QA is like a fast lane at the airport: short queries get priority processing.

-- Enable QA for your workgroup (Serverless):
-- ALTER WORKGROUP my_workgroup SET QA_ACCELERATOR_ENABLED = TRUE;

-- For Provisioned clusters, QA is controlled via the Redshift console under
-- Workload Management → Query Acceleration settings.

-- Verify QA status:
-- COLUMN NAME AND TYPE BOTH MATTER: the column is short_query_accelerated, not
-- is_accelerated, and it is CHARACTER(10) holding 'true' / 'false' / NULL -- not a
-- boolean. Comparing it to TRUE fails; compare to the string 'true'.
-- It is also populated only on provisioned clusters; on Serverless it is empty.
SELECT
    query_id,
    query_text,
    short_query_accelerated,     -- 'true' = ran on SQA slices
    elapsed_time / 1000.0 AS elapsed_ms,
    queue_time / 1000.0 AS queue_ms
FROM SYS_QUERY_HISTORY
WHERE start_time >= DATEADD(hour, -1, SYSDATE)
  AND short_query_accelerated = 'true'
ORDER BY start_time DESC
LIMIT 20;

-- Calculate QA savings (how much queue time QA saved):
SELECT
    SUM(CASE WHEN short_query_accelerated = 'true' THEN 1 ELSE 0 END) AS accelerated_queries,
    COUNT(*) AS total_queries,
    ROUND(
        SUM(CASE WHEN short_query_accelerated = 'true' THEN 1 ELSE 0 END) * 100.0 / COUNT(*),
        2
    ) AS pct_accelerated,
    SUM(CASE WHEN short_query_accelerated = 'true' THEN elapsed_time ELSE 0 END) / 1000000.0
        AS total_accelerated_seconds
FROM SYS_QUERY_HISTORY
WHERE start_time >= DATEADD(hour, -24, SYSDATE)
  AND query_type = 'SELECT';


-- ============================================================================
-- SECTION 5: COMBINING RESULT CACHE + MV + QA (THE TRIPLE OPTIMIZATION)
-- ============================================================================
-- The ultimate BI performance stack:
--   1. Materialized View pre-computes heavy aggregations
--   2. Result Cache serves identical repeated queries from memory
--   3. QA fast-lanes short queries past long ETL jobs

-- Step 1: Pre-compute the heavy aggregation in an MV
CREATE MATERIALIZED VIEW gold.mv_sales_dashboard
AUTO REFRESH YES
AS
SELECT
    DATE_TRUNC('day', s.sale_date)::DATE   AS sale_day,
    d.region,
    d.product_category,
    COUNT(*)                                AS transaction_count,
    SUM(s.revenue)                          AS total_revenue,
    SUM(s.quantity)                         AS total_units,
    AVG(s.revenue)                          AS avg_order_value,
    APPROXIMATE COUNT(DISTINCT s.customer_id) AS approx_unique_customers
FROM gold.fact_sales s
JOIN gold.dim_product d ON s.product_key = d.product_key
GROUP BY 1, 2, 3;

-- Step 2: Dashboard queries hit the MV (much smaller than the fact table)
-- → First execution: full MV scan (fast, because MV is pre-aggregated)
-- → Second identical execution: result cache hit (<10ms)
-- → All 2,800 morning users: 1 MV scan + 2,799 cache hits = near-zero cost

SELECT
    sale_day,
    region,
    SUM(total_revenue) AS revenue,
    SUM(approx_unique_customers) AS unique_customers
FROM gold.mv_sales_dashboard
WHERE sale_day >= DATE_TRUNC('month', CURRENT_DATE)
GROUP BY 1, 2
ORDER BY sale_day, region;


-- ============================================================================
-- SECTION 6: CACHE MANAGEMENT & INVALIDATION
-- ============================================================================

-- Force cache invalidation (useful during testing):
SET enable_result_cache_for_session = OFF;
-- Run your query...
SET enable_result_cache_for_session = ON;

-- IMPORTANT: These operations AUTOMATICALLY invalidate the cache:
-- • INSERT, UPDATE, DELETE, COPY into any table referenced by the cached query
-- • ALTER TABLE on any referenced table
-- • VACUUM on any referenced table
-- • GRANT/REVOKE on any referenced table
--
-- This means: after your ETL pipeline runs, the first BI query will be a cache miss
-- (because the tables changed), but all subsequent identical queries will be cache hits.


-- ============================================================================
-- SECTION 7: ANTI-PATTERN CHEAT SHEET
-- ============================================================================
/*
┌───────────────────────────────────────────────────────────────────────────────┐
│                    CACHE-FRIENDLY vs. CACHE-BUSTING                          │
├────────────────────────────────┬──────────────────────────────────────────────┤
│ ❌ BUSTS CACHE                │ ✅ CACHE-FRIENDLY ALTERNATIVE               │
├────────────────────────────────┼──────────────────────────────────────────────┤
│ GETDATE() / SYSDATE           │ CURRENT_DATE (stable within day)            │
│ NOW()                         │ DATE_TRUNC('hour', CURRENT_TIMESTAMP)       │
│ RANDOM()                      │ Remove or use a fixed seed                  │
│ VOLATILE UDF                  │ Mark UDF as STABLE or IMMUTABLE             │
│ Dynamic session variables     │ Fixed literals in SQL                       │
│ String concatenation of dates │ Parameterized with date literals            │
│ COUNT(*) with SYSDATE filter  │ COUNT(*) with CURRENT_DATE filter           │
│ Different SQL formatting      │ Standardize SQL text from BI tool           │
│ Mixed case in SQL text        │ Consistent casing (cache is text-sensitive) │
└────────────────────────────────┴──────────────────────────────────────────────┘

KEY INSIGHT: The result cache compares the EXACT SQL text (byte-for-byte).
'SELECT * FROM t' and 'select * from t' are DIFFERENT cache entries.
Standardize your BI tool's SQL generation for maximum cache hits.
*/
