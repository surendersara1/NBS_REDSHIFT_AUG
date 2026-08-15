/*
======================================================================================
MODULE 34: STAGED LOADS AND STATISTICS MANAGEMENT (ANALYZE ON TEMP TABLES)
======================================================================================
MAPPED BEST PRACTICES (from PROCEDURE_OPTIMIZATION_BEST_PRACTICES_MASTER_FILE.md):
- Practice 62: Run ANALYZE (or confirm auto-analyze) after big loads — the planner needs fresh stats.
- Practice 79: Stage into temp tables rather than repeatedly re-scanning base tables, and ANALYZE immediately.
- Practice 32: Watch for nested loop joins in EXPLAIN — usually signals missing statistics.
- Practice 37: Check STL_ALERT_EVENT_LOG for planner-flagged issues (missing stats, broadcast joins).

TARGET AUDIENCE: Application Developers transitioning to Redshift
BUSINESS SCENARIO: 
We have a massive fact table `fct_customer_sales` (10 million rows). 
Inside a daily processing procedure, we populate a temporary table `#stg_daily_sales` with 500,000 rows. 
We then join `#stg_daily_sales` to `fct_customer_sales` to perform an upsert and dimensional lookup.

THE PROBLEM:
When a `#TEMP` table is populated inside a stored procedure session, Redshift **does NOT automatically analyze it**. 
The query optimizer assumes the newly populated `#TEMP` table contains **0 or a default nominal row count**. 
When the optimizer generates a join plan between a 10M row permanent table and an un-analyzed `#TEMP` table, 
it erroneously selects a **Nested Loop Join** or a broadcast inner join (`DS_BCAST_INNER`), 
causing a query that should take 2 seconds to run for **45 minutes or run out of memory**.

THE GOAL:
1. Understand why running `ANALYZE #temp_table` immediately after populating it is mandatory.
2. Inspect the `EXPLAIN` plan and `STL_ALERT_EVENT_LOG` before vs after `ANALYZE`.
3. Eliminate catastrophic nested loop join traps in stored procedure pipelines.
======================================================================================
*/

-- ===================================================================================
-- 1. DATA GENERATION BLOCK (Run this to set up the scenario)
-- ===================================================================================
DROP TABLE IF EXISTS base_large_customers CASCADE;
CREATE TABLE base_large_customers (
    customer_id BIGINT NOT NULL ENCODE az64,
    customer_name VARCHAR(100) NOT NULL ENCODE zstd,
    credit_limit DECIMAL(12,2) NOT NULL ENCODE az64,
    account_mgr_id INT NOT NULL ENCODE az64
)
DISTSTYLE KEY
DISTKEY (customer_id)
COMPOUND SORTKEY (customer_id);

-- Populate 100,000 customers
INSERT INTO base_large_customers (customer_id, customer_name, credit_limit, account_mgr_id)
SELECT 
    s.n AS customer_id,
    'Customer Corp ' || s.n::VARCHAR AS customer_name,
    (10000.00 + (s.n % 50000))::DECIMAL(12,2) AS credit_limit,
    (s.n % 100 + 1)::INT AS account_mgr_id
FROM (
    SELECT ROW_NUMBER() OVER () AS n
    FROM (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) a
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) b
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) c
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) d
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) e
    LIMIT 100000
) s;

ANALYZE base_large_customers;

DROP TABLE IF EXISTS target_enriched_sales CASCADE;
CREATE TABLE target_enriched_sales (
    sale_id BIGINT NOT NULL,
    customer_id BIGINT NOT NULL,
    customer_name VARCHAR(100) NOT NULL,
    sale_amount DECIMAL(12,2) NOT NULL
);


-- ===================================================================================
-- 2. THE "BAD" PROCEDURE (Populate Temp Table Without ANALYZE)
-- ===================================================================================
/*
WHY IT'S DANGEROUS:
- Populates `#stg_sales` with 50,000 rows.
- Skips `ANALYZE #stg_sales`.
- The optimizer assumes `#stg_sales` has 0 rows and picks a catastrophic join order or nested loop.
- Generates `Missing statistics` alerts in `STL_ALERT_EVENT_LOG`.
*/
CREATE OR REPLACE PROCEDURE prc_bad_staged_load_no_stats()
LANGUAGE plpgsql
AS $$
BEGIN
    DROP TABLE IF EXISTS #stg_sales;
    
    CREATE TEMP TABLE #stg_sales (
        sale_id BIGINT NOT NULL,
        customer_id BIGINT NOT NULL,
        sale_amount DECIMAL(12,2) NOT NULL
    )
    DISTSTYLE KEY
    DISTKEY (customer_id)
    ON COMMIT DROP;

    -- Insert 50,000 rows into temp table
    INSERT INTO #stg_sales (sale_id, customer_id, sale_amount)
    SELECT s.n, (s.n % 100000 + 1), (25.00 + (s.n % 500))::DECIMAL(12,2)
    FROM (SELECT ROW_NUMBER() OVER () as n FROM (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) a, (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) b, (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) c, (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) d, (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4) e LIMIT 50000) s;

    -- NO ANALYZE! The optimizer is blind.
    
    TRUNCATE TABLE target_enriched_sales;
    
    INSERT INTO target_enriched_sales (sale_id, customer_id, customer_name, sale_amount)
    SELECT s.sale_id, s.customer_id, c.customer_name, s.sale_amount
    FROM #stg_sales s
    INNER JOIN base_large_customers c ON s.customer_id = c.customer_id;
    
    RAISE INFO 'Bad staged load complete (Optimizer flew blind without statistics).';
END;
$$;


-- ===================================================================================
-- 3. THE "GOOD" PROCEDURE (Explicit ANALYZE on Temp Tables)
-- ===================================================================================
/*
WHY IT'S OPTIMAL:
- Runs `ANALYZE #stg_sales` immediately after the `INSERT` completes.
- Builds an accurate distribution histogram in the catalog.
- The optimizer chooses a lightning-fast collocated Hash Join (`DS_DIST_NONE`).
*/
CREATE OR REPLACE PROCEDURE prc_good_staged_load_with_stats()
LANGUAGE plpgsql
AS $$
DECLARE
    v_rows_inserted BIGINT := 0;
BEGIN
    DROP TABLE IF EXISTS #stg_sales;
    
    CREATE TEMP TABLE #stg_sales (
        sale_id BIGINT NOT NULL,
        customer_id BIGINT NOT NULL,
        sale_amount DECIMAL(12,2) NOT NULL
    )
    DISTSTYLE KEY
    DISTKEY (customer_id)
    ON COMMIT DROP;

    INSERT INTO #stg_sales (sale_id, customer_id, sale_amount)
    SELECT s.n, (s.n % 100000 + 1), (25.00 + (s.n % 500))::DECIMAL(12,2)
    FROM (SELECT ROW_NUMBER() OVER () as n FROM (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) a, (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) b, (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) c, (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) d, (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4) e LIMIT 50000) s;

    -- CRITICAL BEST PRACTICE: Refresh stats on temp table before downstream joins!
    ANALYZE #stg_sales;

    TRUNCATE TABLE target_enriched_sales;
    
    INSERT INTO target_enriched_sales (sale_id, customer_id, customer_name, sale_amount)
    SELECT s.sale_id, s.customer_id, c.customer_name, s.sale_amount
    FROM #stg_sales s
    INNER JOIN base_large_customers c ON s.customer_id = c.customer_id;
    
    GET DIAGNOSTICS v_rows_inserted = ROW_COUNT;
    RAISE INFO 'Good staged load complete: % rows enriched with optimal statistics.', v_rows_inserted;

EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'prc_good_staged_load_with_stats failed: %', SQLERRM;
END;
$$;


-- ===================================================================================
-- 4. USAGE, VERIFICATION & PLAN DIAGNOSTICS
-- ===================================================================================

-- (a) Execute procedures:
-- CALL prc_bad_staged_load_no_stats();
-- CALL prc_good_staged_load_with_stats();

-- (b) Check for Missing Statistics Alerts in system logs (Practice 37):
-- SELECT event, solution, query, event_time
-- FROM stl_alert_event_log
-- WHERE event LIKE '%Missing statistics%'
-- ORDER BY event_time DESC
-- LIMIT 10;
