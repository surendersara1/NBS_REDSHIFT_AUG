/*
======================================================================================
MODULE 26: CTE (WITH CLAUSE) VS EXPLICIT #TEMP TABLES
======================================================================================
MAPPED BEST PRACTICES (from PROCEDURE_OPTIMIZATION_BEST_PRACTICES_MASTER_FILE.md):
- Practice 20: Avoid recomputing the same expression repeatedly — materialize into #temp table.
- Practice 26: Break complex multi-join, multi-aggregation queries into staged temp tables with explicit dist/sort keys.
- Practice 79: Stage into temp tables rather than repeatedly re-scanning base tables, and ANALYZE immediately.
- Practice 36: Watch for disk spill in SVL_QUERY_SUMMARY — split complex steps to avoid memory overflow.

TARGET AUDIENCE: Application Developers transitioning to Redshift
BUSINESS SCENARIO: 
We are computing an executive Customer Lifetime Value (LTV) report. 
The calculation requires:
1. Summarizing total spend per user.
2. Ranking users within their geographic region.
3. Joining the summary back to user profile data and product category preferences.

THE PROBLEM:
App developers write a single massive query with 5 chained Common Table Expressions (`WITH cte1 AS ..., cte2 AS ...`).
In PostgreSQL / modern engines, CTEs are sometimes optimized or inlined seamlessly.
In Redshift:
1. If a CTE is referenced multiple times in the outer query, Redshift may **re-evaluate and scan the entire base table multiple times**.
2. Complex CTEs can exhaust query workmem, spilling intermediate hash tables to disk.
3. The optimizer cannot gather statistics on intermediate CTE results, leading to flawed join cardinality estimates.

THE GOAL:
1. Know when to use a lightweight CTE (single-use filter) vs. an explicit `#TEMP` table.
2. Use `#TEMP` tables with explicit `DISTKEY` and `ANALYZE` for multi-stage pipelines.
3. Use `ON COMMIT DROP` to prevent temporary schema bloat.
======================================================================================
*/

-- ===================================================================================
-- 1. DATA GENERATION BLOCK (Run this to set up the scenario)
-- ===================================================================================
DROP TABLE IF EXISTS raw_user_orders CASCADE;
CREATE TABLE raw_user_orders (
    order_id BIGINT NOT NULL ENCODE az64,
    user_id BIGINT NOT NULL ENCODE az64,
    region VARCHAR(32) NOT NULL ENCODE bytedict,
    order_amount DECIMAL(12,2) NOT NULL ENCODE az64,
    order_date DATE NOT NULL ENCODE az64
)
DISTSTYLE KEY
DISTKEY (user_id)
COMPOUND SORTKEY (order_date, user_id);

INSERT INTO raw_user_orders (order_id, user_id, region, order_amount, order_date)
SELECT 
    s.n AS order_id,
    (s.n % 10000 + 1) AS user_id,
    CASE WHEN (s.n % 3) = 0 THEN 'AMER' WHEN (s.n % 3) = 1 THEN 'EMEA' ELSE 'APAC' END AS region,
    (20.00 + (s.n % 200))::DECIMAL(12,2) AS order_amount,
    DATEADD(day, -(s.n % 90), '2026-08-15'::DATE) AS order_date
FROM (
    SELECT ROW_NUMBER() OVER () AS n
    FROM (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) a
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) b
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) c
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) d
    CROSS JOIN (SELECT 0 UNION SELECT 1) e
    LIMIT 100000
) s;

ANALYZE raw_user_orders;

DROP TABLE IF EXISTS rpt_regional_top_customers CASCADE;
CREATE TABLE rpt_regional_top_customers (
    region VARCHAR(32) NOT NULL,
    user_id BIGINT NOT NULL,
    total_spend DECIMAL(14,2) NOT NULL,
    regional_rank INT NOT NULL
);


-- ===================================================================================
-- 2. THE "BAD" PROCEDURE (The Monolithic Chained CTE Anti-Pattern)
-- ===================================================================================
/*
WHY IT'S RISKY AT SCALE:
- Chained CTEs (`WITH spend AS (...), ranked AS (...)`) force Redshift to carry large
  intermediate structures in memory.
- If `spend` is joined twice (e.g. to compare user spend against regional averages),
  Redshift re-scans the 100,000 rows repeatedly.
- The planner has no histogram/statistics on CTE output, causing sub-optimal join orders.
*/
CREATE OR REPLACE PROCEDURE prc_bad_cte_pipeline()
LANGUAGE plpgsql
AS $$
BEGIN
    TRUNCATE TABLE rpt_regional_top_customers;
    
    INSERT INTO rpt_regional_top_customers
    WITH user_spend AS (
        SELECT user_id, region, SUM(order_amount) AS total_spend
        FROM raw_user_orders
        GROUP BY user_id, region
    ),
    ranked_users AS (
        SELECT user_id, region, total_spend,
               RANK() OVER (PARTITION BY region ORDER BY total_spend DESC) as rnk
        FROM user_spend
    )
    SELECT region, user_id, total_spend, rnk
    FROM ranked_users
    WHERE rnk <= 10;
END;
$$;


-- ===================================================================================
-- 3. THE "GOOD" PROCEDURE (The Staged #TEMP Table with Statistics)
-- ===================================================================================
/*
WHY IT'S SUPERIOR FOR COMPLEX PIPELINES:
1. EXPLICIT DISTRIBUTION: `#stg_user_spend` is explicitly given `DISTSTYLE KEY DISTKEY (user_id)`,
   guaranteeing zero network redistribution in subsequent joins.
2. STATS VIA ANALYZE: Running `ANALYZE #stg_user_spend` gives the query optimizer exact
   row counts and distinct value statistics before executing the ranking window.
3. ON COMMIT DROP: Automatically drops the temp table when the transaction ends, eliminating catalog bloat.
*/
CREATE OR REPLACE PROCEDURE prc_good_temp_table_pipeline()
LANGUAGE plpgsql
AS $$
DECLARE
    v_rows_inserted BIGINT := 0;
BEGIN
    TRUNCATE TABLE rpt_regional_top_customers;

    -- Stage 1: Aggregate into a localized Temp Table with collocated DISTKEY
    CREATE TEMP TABLE #stg_user_spend (
        user_id BIGINT NOT NULL,
        region VARCHAR(32) NOT NULL,
        total_spend DECIMAL(14,2) NOT NULL
    )
    DISTSTYLE KEY
    DISTKEY (user_id)
    ON COMMIT DROP;

    INSERT INTO #stg_user_spend (user_id, region, total_spend)
    SELECT user_id, region, SUM(order_amount)
    FROM raw_user_orders
    GROUP BY user_id, region;

    -- Stage 2: ANALYZE the temp table immediately (Practice 62, 79)
    ANALYZE #stg_user_spend;

    -- Stage 3: Perform Window Ranking on the compact, pre-analyzed dataset
    INSERT INTO rpt_regional_top_customers (region, user_id, total_spend, regional_rank)
    SELECT region, user_id, total_spend, rnk
    FROM (
        SELECT user_id, region, total_spend,
               RANK() OVER (PARTITION BY region ORDER BY total_spend DESC) AS rnk
        FROM #stg_user_spend
    )
    WHERE rnk <= 10;

    GET DIAGNOSTICS v_rows_inserted = ROW_COUNT;
    RAISE INFO 'Staged pipeline complete. Inserted % top customer records.', v_rows_inserted;

EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'prc_good_temp_table_pipeline failed: %', SQLERRM;
END;
$$;


-- ===================================================================================
-- 4. USAGE, VERIFICATION & MEMORY COMPARISON
-- ===================================================================================

-- (a) Execute both procedures:
-- CALL prc_bad_cte_pipeline();
-- CALL prc_good_temp_table_pipeline();
-- SELECT * FROM rpt_regional_top_customers ORDER BY region, regional_rank;

-- (b) Check for Disk Spills in recent queries (Practice 36):
-- SELECT query_id, step_name, rows, workmem, is_diskbased
-- FROM svl_query_summary
-- WHERE query_id = pg_last_query_id()
-- ORDER BY step_name;
-- (is_diskbased = 't' indicates that memory was exceeded and spilled to disk!)
