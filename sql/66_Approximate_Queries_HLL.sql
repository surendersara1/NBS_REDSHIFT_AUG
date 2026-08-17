/*
======================================================================================
MODULE 66: APPROXIMATE QUERIES, HLL SKETCHES & PROBABILISTIC COUNTING
======================================================================================
MAPPED BEST PRACTICES (from PROCEDURE_OPTIMIZATION_BEST_PRACTICES_MASTER_FILE.md):
- Practice 20: "Avoid recomputing the same expression repeatedly" — HLL sketches
  pre-compute cardinality and can be merged without re-scanning raw data.
- Practice 23: "Drop unneeded DISTINCT" — APPROXIMATE COUNT(DISTINCT) eliminates
  the full sort+dedup that exact DISTINCT requires.
- Practice 106: "Right-size compute" — approximate queries use 10-100x less compute.

TARGET AUDIENCE: Analytics Engineers, BI Developers, Data Scientists
BUSINESS SCENARIO:
An ad-tech platform needs to report unique visitors per campaign per day across
2 billion impression records. Exact COUNT(DISTINCT user_id) takes 45 minutes
and spills 200GB to disk. The business accepts ±2% accuracy for real-time dashboards.

APPROXIMATE COUNT(DISTINCT) returns in 8 seconds with 1.6% average error.
HLL sketches allow pre-aggregating daily sketches and merging them into weekly/monthly
reports WITHOUT re-scanning the 2-billion-row fact table.

ARCHITECTURE:
┌──────────────────────────────────────────────────────────────────────────────┐
│                    EXACT vs. APPROXIMATE CARDINALITY                         │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  EXACT COUNT(DISTINCT user_id):                                             │
│  ┌─────────────────────────────────────────────────────────┐                │
│  │ Scan 2B rows → Hash all user_ids → Sort → Dedup → Count│                │
│  │ Memory: ~50GB  │  Disk Spill: 200GB  │  Time: 45 min   │                │
│  └─────────────────────────────────────────────────────────┘                │
│                                                                              │
│  APPROXIMATE COUNT(DISTINCT user_id):                                       │
│  ┌─────────────────────────────────────────────────────────┐                │
│  │ Scan 2B rows → Hash → HyperLogLog sketch (12KB)        │                │
│  │ Memory: 12KB   │  Disk Spill: 0       │  Time: 8 sec   │                │
│  │ Error: ±1.6%  (e.g., 45.2M ± 720K)                     │                │
│  └─────────────────────────────────────────────────────────┘                │
│                                                                              │
│  HLL SKETCH PRE-AGGREGATION:                                                │
│  ┌───────────┐  ┌───────────┐  ┌───────────┐                               │
│  │ Day 1     │  │ Day 2     │  │ Day 3     │  ← Daily sketches (12KB each) │
│  │ HLL(users)│  │ HLL(users)│  │ HLL(users)│                               │
│  └─────┬─────┘  └─────┬─────┘  └─────┬─────┘                               │
│        └──────────────┼──────────────┘                                      │
│                       ▼                                                      │
│            HLL_COMBINE(daily_sketches)                                       │
│            → Weekly unique users (±1.6%)                                    │
│            → WITHOUT re-scanning raw data!                                  │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘

======================================================================================
*/

-- These schemas are referenced throughout this module but are not created by
-- sql/01 (staging, analytics, admin) or sql/07 (rpt). Without these lines every
-- qualified reference below fails with 'schema does not exist'.
CREATE SCHEMA IF NOT EXISTS lab;
CREATE SCHEMA IF NOT EXISTS etl;


-- ============================================================================
-- SECTION 1: DATA GENERATION — 50 MILLION IMPRESSION RECORDS
-- ============================================================================
-- IMPLEMENTS: applied_redshift.md §2 (Data generation comes first)

CREATE TABLE IF NOT EXISTS lab.fact_impressions (
    impression_id       BIGINT IDENTITY(1,1),
    event_date          DATE        NOT NULL,
    campaign_id         INT         NOT NULL,
    user_id             VARCHAR(64) NOT NULL,
    page_url            VARCHAR(256),
    device_type         VARCHAR(20),
    country_code        CHAR(2),
    impression_cost     DECIMAL(10,4)
)
DISTSTYLE KEY DISTKEY (user_id)
SORTKEY (event_date);

-- Seed 50M rows (4 campaigns, 5M unique users, 90 days):
INSERT INTO lab.fact_impressions (
    event_date, campaign_id, user_id, page_url,
    device_type, country_code, impression_cost
)
SELECT
    DATEADD(day, -(seq % 90), CURRENT_DATE)         AS event_date,
    (seq % 4) + 1                                    AS campaign_id,
    'usr_' || LPAD((seq % 5000000)::VARCHAR, 8, '0') AS user_id,
    '/page/' || (seq % 1000)                         AS page_url,
    CASE seq % 3 WHEN 0 THEN 'mobile' WHEN 1 THEN 'desktop' ELSE 'tablet' END,
    CASE seq % 5 WHEN 0 THEN 'US' WHEN 1 THEN 'GB' WHEN 2 THEN 'DE'
                 WHEN 3 THEN 'FR' ELSE 'JP' END,
    ROUND((RANDOM() * 0.05)::DECIMAL(10,4), 4)       AS impression_cost
-- Deterministic row generator. The original read from stl_scan, a system LOG table --
-- it is not "a large system table", it holds however many scan-step records the
-- cluster happens to have logged. On a freshly deployed cluster that is often a few
-- hundred rows, so LIMIT 50000000 never binds, every learner gets a different and much
-- smaller dataset, and the exact-vs-approximate contrast this module exists to
-- demonstrate disappears along with the row count.
--
-- NOTE ON RUNTIME: 50 million rows is the volume the module is written around, but it
-- takes several minutes and a few GB on a single-node ra3.large. If you are short on
-- time, drop the LIMIT to 5000000 -- the HLL contrast is still clearly visible, and
-- every query below works unchanged.
FROM (
    SELECT ROW_NUMBER() OVER () AS seq
    FROM (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) a
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) b
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) c
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) d
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) e
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) f
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) g
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4) h
    LIMIT 50000000
) gen;

ANALYZE lab.fact_impressions;


-- ============================================================================
-- SECTION 2: THE "BAD" WAY — EXACT COUNT(DISTINCT) AT SCALE
-- ============================================================================
-- IMPLEMENTS: applied_redshift.md §2 (The "Bad" Procedure — The App Dev Way)

-- The app developer writes what looks correct but is catastrophically slow:
-- "How many unique users saw each campaign in the last 30 days?"

-- BAD: Exact COUNT(DISTINCT) on 50M rows
SELECT
    campaign_id,
    COUNT(DISTINCT user_id) AS exact_unique_users,    -- ← FULL HASH + SORT + DEDUP
    SUM(impression_cost)    AS total_cost
FROM lab.fact_impressions
WHERE event_date >= DATEADD(day, -30, CURRENT_DATE)
GROUP BY campaign_id
ORDER BY campaign_id;
-- EXPLAIN will show: HashAggregate with estimated memory >> available per-slice memory
-- → Spills to disk → 45+ minutes on large clusters

-- Check the execution plan for disk spill:
-- EXPLAIN SELECT campaign_id, COUNT(DISTINCT user_id) ...
-- Look for: "Disk Used: ..." in SVL_QUERY_METRICS_SUMMARY


-- ============================================================================
-- SECTION 3: THE "GOOD" WAY — APPROXIMATE COUNT(DISTINCT)
-- ============================================================================
-- IMPLEMENTS: Best Practice #20 (Avoid recomputing), #23 (Drop unneeded DISTINCT)

-- GOOD: APPROXIMATE COUNT(DISTINCT) uses HyperLogLog internally
SELECT
    campaign_id,
    APPROXIMATE COUNT(DISTINCT user_id) AS approx_unique_users,  -- ← HLL sketch
    SUM(impression_cost)                AS total_cost
FROM lab.fact_impressions
WHERE event_date >= DATEADD(day, -30, CURRENT_DATE)
GROUP BY campaign_id
ORDER BY campaign_id;
-- Returns in seconds. Error is typically ±1.6%.
-- EXPLAIN will show: HLL HashAggregate (no disk spill, constant memory per slice)


-- ============================================================================
-- SECTION 4: HLL FUNCTIONS — PRE-AGGREGATION & MERGING
-- ============================================================================
-- IMPLEMENTS: Best Practice #20 (Avoid recomputing the same expression)
--
-- The real power of HLL: create daily sketches, then MERGE them for weekly/monthly
-- reports without touching the raw fact table again.

-- Step 1: Create a daily sketch summary table
CREATE TABLE IF NOT EXISTS lab.daily_campaign_sketches (
    report_date     DATE    NOT NULL,
    campaign_id     INT     NOT NULL,
    user_hll        HLLSKETCH,              -- The HLL sketch (binary, ~12KB)
    impression_count BIGINT NOT NULL,
    total_cost      DECIMAL(18,4)
)
DISTSTYLE KEY DISTKEY (campaign_id)
SORTKEY (report_date);

-- Step 2: Populate daily sketches (run once per day as part of ETL)
INSERT INTO lab.daily_campaign_sketches
SELECT
    event_date                        AS report_date,
    campaign_id,
    HLL(user_id)                      AS user_hll,        -- Create sketch
    COUNT(*)                          AS impression_count,
    SUM(impression_cost)              AS total_cost
FROM lab.fact_impressions
WHERE event_date = CURRENT_DATE - 1   -- Yesterday's data
GROUP BY event_date, campaign_id;

-- Step 3: Merge daily sketches into a weekly report (NO raw table scan!)
SELECT
    campaign_id,
    HLL_CARDINALITY(HLL_COMBINE(user_hll)) AS weekly_unique_users,
    SUM(impression_count)                   AS weekly_impressions,
    SUM(total_cost)                         AS weekly_cost
FROM lab.daily_campaign_sketches
WHERE report_date >= DATEADD(day, -7, CURRENT_DATE)
GROUP BY campaign_id
ORDER BY campaign_id;
-- HLL_COMBINE merges 7 daily sketches into one weekly sketch.
-- HLL_CARDINALITY extracts the estimated cardinality from the merged sketch.
-- This query reads 7 rows × 4 campaigns = 28 rows instead of 50M.

-- Step 4: Monthly report (same pattern, 30 daily sketches):
SELECT
    campaign_id,
    HLL_CARDINALITY(HLL_COMBINE(user_hll)) AS monthly_unique_users,
    SUM(impression_count)                   AS monthly_impressions,
    SUM(total_cost)                         AS monthly_cost
FROM lab.daily_campaign_sketches
WHERE report_date >= DATEADD(day, -30, CURRENT_DATE)
GROUP BY campaign_id;


-- ============================================================================
-- SECTION 5: HLL SKETCH FUNCTIONS REFERENCE
-- ============================================================================
/*
┌──────────────────────────┬───────────────────────────────────────────────────┐
│ Function                 │ Description                                       │
├──────────────────────────┼───────────────────────────────────────────────────┤
│ HLL(column)              │ Creates an HLL sketch from a column of values.   │
│                          │ Use in GROUP BY aggregations.                    │
├──────────────────────────┼───────────────────────────────────────────────────┤
│ HLL_COMBINE(sketch_col)  │ Merges multiple HLL sketches into one.           │
│                          │ Use to roll up daily→weekly→monthly.             │
├──────────────────────────┼───────────────────────────────────────────────────┤
│ HLL_CARDINALITY(sketch)  │ Returns the estimated distinct count from a      │
│                          │ sketch. Error: ±1.6% standard.                   │
├──────────────────────────┼───────────────────────────────────────────────────┤
│ HLL_CREATE_SKETCH(value) │ Creates a sketch from a single scalar value.     │
│                          │ Useful for streaming/incremental sketch building. │
├──────────────────────────┼───────────────────────────────────────────────────┤
│ APPROXIMATE COUNT(       │ Syntactic sugar for HLL. Redshift internally     │
│   DISTINCT col)          │ creates an HLL sketch. Use in ad-hoc queries.    │
└──────────────────────────┴───────────────────────────────────────────────────┘
*/

-- Example: Create a sketch from a single value (useful in streaming):
SELECT HLL_CARDINALITY(
    HLL_COMBINE(
        HLL_CREATE_SKETCH(user_id)
    )
) AS unique_users
FROM lab.fact_impressions
WHERE event_date = CURRENT_DATE - 1;


-- ============================================================================
-- SECTION 6: ACCURACY VALIDATION — EXACT vs. APPROXIMATE
-- ============================================================================
-- Always validate on a sample before deploying approximate queries in production.

-- Side-by-side comparison:
SELECT
    campaign_id,
    COUNT(DISTINCT user_id)             AS exact_count,
    APPROXIMATE COUNT(DISTINCT user_id) AS approx_count,
    ABS(COUNT(DISTINCT user_id) - APPROXIMATE COUNT(DISTINCT user_id))
        * 100.0 / COUNT(DISTINCT user_id) AS error_pct
FROM lab.fact_impressions
WHERE event_date >= DATEADD(day, -7, CURRENT_DATE)
GROUP BY campaign_id
ORDER BY campaign_id;
-- Typical results: error_pct between 0.5% and 2.5%


-- ============================================================================
-- SECTION 7: WHEN TO USE APPROXIMATE vs. EXACT
-- ============================================================================
/*
USE APPROXIMATE WHEN:                      USE EXACT WHEN:
─────────────────────                       ────────────────
• Dashboard unique user counts              • Financial reconciliation
• Real-time conversion funnels              • Regulatory reporting
• Ad-tech impression deduplication          • Row-level audit trails
• IoT device fleet cardinality              • Billing/invoicing
• A/B test audience sizing                  • Compliance data
• Error tolerance: ±2% is acceptable        • Zero error tolerance required
• Cardinality > 100K (biggest ROI)          • Cardinality < 10K (exact is fast)
*/


-- ============================================================================
-- SECTION 8: ETL PROCEDURE — DAILY SKETCH BUILDER
-- ============================================================================
-- IMPLEMENTS: Best Practices #42 (Idempotent), #97 (ROW_COUNT)

CREATE OR REPLACE PROCEDURE etl.sp_build_daily_hll_sketches(
    p_report_date DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_rows_deleted INT;
    v_rows_inserted INT;
BEGIN
    -- Idempotent: delete existing sketches for this date
    DELETE FROM lab.daily_campaign_sketches
    WHERE report_date = p_report_date;
    GET DIAGNOSTICS v_rows_deleted = ROW_COUNT;

    -- Build fresh sketches
    INSERT INTO lab.daily_campaign_sketches
    SELECT
        p_report_date,
        campaign_id,
        HLL(user_id),
        COUNT(*),
        SUM(impression_cost)
    FROM lab.fact_impressions
    WHERE event_date = p_report_date
    GROUP BY campaign_id;
    GET DIAGNOSTICS v_rows_inserted = ROW_COUNT;

    RAISE INFO 'sp_build_daily_hll_sketches [%]: Deleted %, Inserted % sketches.',
               p_report_date, v_rows_deleted, v_rows_inserted;
END;
$$;

-- Usage:
-- CALL etl.sp_build_daily_hll_sketches('2026-08-14');
