/*
======================================================================================
MODULE 37: MULTI-LEVEL GROUPING (GROUPING SETS, ROLLUP, CUBE)
======================================================================================
MAPPED BEST PRACTICES (from PROCEDURE_OPTIMIZATION_BEST_PRACTICES_MASTER_FILE.md):
- Practice 20: Avoid recomputing the same expression repeatedly — compute multi-level totals in 1 pass.
- Practice 24: Use UNION ALL instead of UNION unless de-duplication is genuinely required.
- Practice 16: Never SELECT * — list only the necessary aggregate metrics.
- Practice 90: Denormalize for analytical reads.

TARGET AUDIENCE: Application Developers transitioning to Redshift
BUSINESS SCENARIO: 
We are generating an executive financial dashboard that requires:
1. Sales by `(Region, Country, Product_Category)`
2. Sub-totals by `(Region, Country)`
3. Regional Sub-totals by `(Region)`
4. Grand Total across the entire company.

THE PROBLEM:
Application developers write 4 separate aggregate queries and stitch them together using `UNION ALL`:
`SELECT r, c, p, sum(x) ... UNION ALL SELECT r, c, NULL, sum(x) ... UNION ALL SELECT r, NULL, NULL, sum(x) ...`
In Redshift, this forces the cluster to execute **4 separate full table scans and 4 separate hash aggregations**!
For a 100-million row table, `UNION ALL` burns $4\times$ the I/O and takes $4\times$ longer.

THE GOAL:
1. Master `GROUPING SETS`, `ROLLUP`, and `CUBE` to compute all sub-totals in a **single table scan**.
2. Use the `GROUPING()` function to identify and label sub-total rows dynamically.
3. Compare execution plans: Single HashAggregate pass vs. 4-way `UNION ALL` scan.
======================================================================================
*/

-- ===================================================================================
-- 1. DATA GENERATION BLOCK (Run this to set up the scenario)
-- ===================================================================================
DROP TABLE IF EXISTS fct_cube_sales CASCADE;
CREATE TABLE fct_cube_sales (
    sale_id BIGINT NOT NULL ENCODE az64,
    region VARCHAR(32) NOT NULL ENCODE bytedict,
    country VARCHAR(32) NOT NULL ENCODE bytedict,
    category VARCHAR(50) NOT NULL ENCODE bytedict,
    sale_amount DECIMAL(12,2) NOT NULL ENCODE az64
)
DISTSTYLE EVEN;

-- Insert 100,000 sales transactions
INSERT INTO fct_cube_sales (sale_id, region, country, category, sale_amount)
SELECT 
    s.n AS sale_id,
    CASE WHEN (s.n % 3) = 0 THEN 'AMER' WHEN (s.n % 3) = 1 THEN 'EMEA' ELSE 'APAC' END AS region,
    CASE WHEN (s.n % 6) = 0 THEN 'USA' WHEN (s.n % 6) = 1 THEN 'Canada'
         WHEN (s.n % 6) = 2 THEN 'UK'  WHEN (s.n % 6) = 3 THEN 'Germany'
         WHEN (s.n % 6) = 4 THEN 'Japan' ELSE 'Australia' END AS country,
    CASE WHEN (s.n % 4) = 0 THEN 'Electronics' WHEN (s.n % 4) = 1 THEN 'Furniture'
         WHEN (s.n % 4) = 2 THEN 'Clothing'    ELSE 'Groceries' END AS category,
    (15.00 + (s.n % 200))::DECIMAL(12,2) AS sale_amount
FROM (
    SELECT ROW_NUMBER() OVER () AS n
    FROM (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) a
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) b
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) c
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) d
    CROSS JOIN (SELECT 0 UNION SELECT 1) e
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) f
    LIMIT 100000
) s;

ANALYZE fct_cube_sales;

DROP TABLE IF EXISTS rpt_sales_multilevel_summary CASCADE;
CREATE TABLE rpt_sales_multilevel_summary (
    region VARCHAR(32),
    country VARCHAR(32),
    category VARCHAR(50),
    total_sales DECIMAL(16,2) NOT NULL,
    aggregation_level VARCHAR(50) NOT NULL
);


-- ===================================================================================
-- 2. THE "BAD" PROCEDURE (The 4-Scan UNION ALL Anti-Pattern)
-- ===================================================================================
/*
WHY IT'S SLOW:
- Scans `fct_cube_sales` 4 times.
- Executes 4 independent hash aggregations.
- Wastes cluster memory and quadruples I/O throughput.
*/
CREATE OR REPLACE PROCEDURE prc_bad_multilevel_union()
LANGUAGE plpgsql
AS $$
BEGIN
    TRUNCATE TABLE rpt_sales_multilevel_summary;
    
    INSERT INTO rpt_sales_multilevel_summary
    -- Level 1: Full grain (Region, Country, Category)
    SELECT region, country, category, SUM(sale_amount), 'DETAILED'
    FROM fct_cube_sales GROUP BY region, country, category
    UNION ALL
    -- Level 2: Country Sub-total
    SELECT region, country, 'ALL_CATEGORIES', SUM(sale_amount), 'SUBTOTAL_COUNTRY'
    FROM fct_cube_sales GROUP BY region, country
    UNION ALL
    -- Level 3: Regional Sub-total
    SELECT region, 'ALL_COUNTRIES', 'ALL_CATEGORIES', SUM(sale_amount), 'SUBTOTAL_REGION'
    FROM fct_cube_sales GROUP BY region
    UNION ALL
    -- Level 4: Grand Total
    SELECT 'ALL_REGIONS', 'ALL_COUNTRIES', 'ALL_CATEGORIES', SUM(sale_amount), 'GRAND_TOTAL'
    FROM fct_cube_sales;
    
    RAISE INFO 'UNION ALL multi-pass summary complete.';
END;
$$;


-- ===================================================================================
-- 3. THE "GOOD" PROCEDURE (The Single-Pass GROUPING SETS / ROLLUP Best Practice)
-- ===================================================================================
/*
WHY IT'S 4x FASTER:
1. SINGLE DISK SCAN: Reads `fct_cube_sales` exactly ONCE.
2. NATIVE MPP ROLLUP: Computes hierarchical aggregations in a single pipelined execution step.
3. GROUPING() BITMASK: Dynamically labels sub-totals using `GROUPING(column_name)`.
*/
CREATE OR REPLACE PROCEDURE prc_good_multilevel_rollup()
LANGUAGE plpgsql
AS $$
DECLARE
    v_rows BIGINT := 0;
BEGIN
    TRUNCATE TABLE rpt_sales_multilevel_summary;

    INSERT INTO rpt_sales_multilevel_summary (region, country, category, total_sales, aggregation_level)
    SELECT 
        NVL(region, 'ALL_REGIONS') AS region,
        NVL(country, 'ALL_COUNTRIES') AS country,
        NVL(category, 'ALL_CATEGORIES') AS category,
        SUM(sale_amount) AS total_sales,
        CASE 
            WHEN GROUPING(region) = 1 THEN 'GRAND_TOTAL'
            WHEN GROUPING(country) = 1 THEN 'SUBTOTAL_REGION'
            WHEN GROUPING(category) = 1 THEN 'SUBTOTAL_COUNTRY'
            ELSE 'DETAILED'
        END AS aggregation_level
    FROM fct_cube_sales
    GROUP BY ROLLUP(region, country, category);

    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RAISE INFO 'Single-pass ROLLUP summary complete: % aggregated rows produced.', v_rows;

EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'prc_good_multilevel_rollup failed: %', SQLERRM;
END;
$$;


-- ===================================================================================
-- 4. USAGE, VERIFICATION & EXPLAIN COMPARISON
-- ===================================================================================

-- (a) Execute and compare row counts:
-- CALL prc_bad_multilevel_union();
-- CALL prc_good_multilevel_rollup();
-- SELECT * FROM rpt_sales_multilevel_summary ORDER BY region, country, category;

-- (b) Execution Plan Comparison (EXPLAIN):
-- Notice single Sequential Scan in ROLLUP vs 4 Sequential Scans in UNION ALL!
EXPLAIN
SELECT region, country, category, SUM(sale_amount)
FROM fct_cube_sales
GROUP BY ROLLUP(region, country, category);
