/*
======================================================================================
MODULE 29: BROADCAST DIMENSIONS (DISTSTYLE ALL FOR SMALL LOOKUPS)
======================================================================================
MAPPED BEST PRACTICES (from PROCEDURE_OPTIMIZATION_BEST_PRACTICES_MASTER_FILE.md):
- Practice 31: Use ALL/broadcast distribution for small lookup/dimension tables (roughly <3M rows).
- Practice 49: Use DISTSTYLE ALL for small, frequently-joined dimension tables.
- Practice 34: Check EXPLAIN for DS_DIST_ALL_NONE (optimal) vs DS_BCAST_INNER (runtime shuffle).

TARGET AUDIENCE: Application Developers transitioning to Redshift
BUSINESS SCENARIO: 
We have a massive fact table `fct_transactions` (100 million rows) distributed by `user_id`. 
We need to join it to a small reference table `dim_country` (250 country codes) to get 
the region name for international compliance reporting.

THE PROBLEM:
The fact table is distributed by `user_id`. 
If `dim_country` is distributed with `DISTSTYLE EVEN` or `DISTSTYLE AUTO(EVEN)`, its 250 rows 
are split across the slices. 
To join on `country_code`, Redshift is forced to issue a runtime broadcast (`DS_BCAST_INNER`), 
broadcasting country records to all slices during query execution.

THE GOAL:
1. Explain `DISTSTYLE ALL` (replicate a complete copy of the dimension to every compute node).
2. Eliminate runtime network broadcasts, achieving `DS_DIST_ALL_NONE` execution plans.
3. Establish the rule of thumb: Small lookup tables (< 2-3 million rows) should always be `DISTSTYLE ALL`.
======================================================================================
*/

-- ===================================================================================
-- 1. DATA GENERATION BLOCK (Run this to set up the scenario)
-- ===================================================================================
DROP TABLE IF EXISTS bad_dim_country CASCADE;
CREATE TABLE bad_dim_country (
    country_code CHAR(2) NOT NULL ENCODE raw,
    country_name VARCHAR(64) NOT NULL ENCODE zstd,
    region_name VARCHAR(32) NOT NULL ENCODE bytedict
)
DISTSTYLE EVEN; -- Scatter small table across slices (ANTI-PATTERN for small lookups!)

DROP TABLE IF EXISTS good_dim_country CASCADE;
CREATE TABLE good_dim_country (
    country_code CHAR(2) NOT NULL ENCODE raw,
    country_name VARCHAR(64) NOT NULL ENCODE zstd,
    region_name VARCHAR(32) NOT NULL ENCODE bytedict
)
DISTSTYLE ALL; -- Complete copy on slice 0 of every compute node (BEST PRACTICE!)

-- Insert 250 country codes
INSERT INTO bad_dim_country VALUES 
('US', 'United States', 'AMER'), ('CA', 'Canada', 'AMER'), ('MX', 'Mexico', 'AMER'),
('GB', 'United Kingdom', 'EMEA'), ('DE', 'Germany', 'EMEA'), ('FR', 'France', 'EMEA'),
('JP', 'Japan', 'APAC'), ('AU', 'Australia', 'APAC'), ('IN', 'India', 'APAC'),
('BR', 'Brazil', 'AMER'), ('ZA', 'South Africa', 'EMEA'), ('SG', 'Singapore', 'APAC');

INSERT INTO good_dim_country SELECT * FROM bad_dim_country;

DROP TABLE IF EXISTS fct_txns CASCADE;
CREATE TABLE fct_txns (
    txn_id BIGINT NOT NULL ENCODE az64,
    user_id BIGINT NOT NULL ENCODE az64,
    country_code CHAR(2) NOT NULL ENCODE bytedict,
    amount DECIMAL(12,2) NOT NULL ENCODE az64
)
DISTSTYLE KEY
DISTKEY (user_id);

-- Generate 100,000 transactions
INSERT INTO fct_txns (txn_id, user_id, country_code, amount)
SELECT 
    s.n AS txn_id,
    (s.n % 10000 + 1) AS user_id,
    CASE WHEN (s.n % 6) = 0 THEN 'US'
         WHEN (s.n % 6) = 1 THEN 'GB'
         WHEN (s.n % 6) = 2 THEN 'DE'
         WHEN (s.n % 6) = 3 THEN 'JP'
         WHEN (s.n % 6) = 4 THEN 'IN'
         ELSE 'BR' END AS country_code,
    (5.00 + (s.n % 250))::DECIMAL(12,2) AS amount
FROM (
    SELECT ROW_NUMBER() OVER () AS n
    FROM (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) a
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) b
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) c
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) d
    CROSS JOIN (SELECT 0 UNION SELECT 1) e
    LIMIT 100000
) s;

ANALYZE bad_dim_country;
ANALYZE good_dim_country;
ANALYZE fct_txns;

DROP TABLE IF EXISTS rpt_regional_sales CASCADE;
CREATE TABLE rpt_regional_sales (
    region_name VARCHAR(32) NOT NULL,
    total_sales DECIMAL(16,2) NOT NULL,
    txn_count BIGINT NOT NULL
);


-- ===================================================================================
-- 2. THE "BAD" PROCEDURE (The Runtime Broadcast Anti-Pattern)
-- ===================================================================================
/*
WHY IT'S SUB-OPTIMAL:
- `bad_dim_country` is DISTSTYLE EVEN.
- Joining on `country_code` forces the optimizer to dynamically broadcast the dimension 
  table across the network at query time (`DS_BCAST_INNER`).
- Under high concurrency (dozens of BI dashboards running simultaneously), dynamic 
  broadcasting saturates the internal cluster network.
*/
CREATE OR REPLACE PROCEDURE prc_bad_broadcast_report()
LANGUAGE plpgsql
AS $$
BEGIN
    TRUNCATE TABLE rpt_regional_sales;
    
    INSERT INTO rpt_regional_sales (region_name, total_sales, txn_count)
    SELECT 
        c.region_name,
        SUM(t.amount) AS total_sales,
        COUNT(1) AS txn_count
    FROM fct_txns t
    INNER JOIN bad_dim_country c ON t.country_code = c.country_code
    GROUP BY c.region_name;
END;
$$;


-- ===================================================================================
-- 3. THE "GOOD" PROCEDURE (The DISTSTYLE ALL Zero-Broadcast Best Practice)
-- ===================================================================================
/*
WHY IT'S OPTIMAL:
- `good_dim_country` was created with `DISTSTYLE ALL`.
- A complete copy is already pre-replicated and stored locally on every compute node.
- At query time: ZERO NETWORK BROADCAST! Every slice reads its local copy of the country table.
- Execution plan achieves `DS_DIST_ALL_NONE`.
*/
CREATE OR REPLACE PROCEDURE prc_good_broadcast_report()
LANGUAGE plpgsql
AS $$
DECLARE
    v_rows BIGINT := 0;
BEGIN
    TRUNCATE TABLE rpt_regional_sales;
    
    INSERT INTO rpt_regional_sales (region_name, total_sales, txn_count)
    SELECT 
        c.region_name,
        SUM(t.amount) AS total_sales,
        COUNT(1) AS txn_count
    FROM fct_txns t
    INNER JOIN good_dim_country c ON t.country_code = c.country_code
    GROUP BY c.region_name;
    
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RAISE INFO 'Regional report complete: % regional groups aggregated with DS_DIST_ALL_NONE.', v_rows;

EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'prc_good_broadcast_report failed: %', SQLERRM;
END;
$$;


-- ===================================================================================
-- 4. USAGE, VERIFICATION & EXPLAIN PLAN PROOF
-- ===================================================================================

-- (a) Plan with EVEN Dimension (Bad): Notice `DS_BCAST_INNER` in the plan!
EXPLAIN
SELECT c.region_name, SUM(t.amount)
FROM fct_txns t
INNER JOIN bad_dim_country c ON t.country_code = c.country_code
GROUP BY c.region_name;

-- (b) Plan with ALL Dimension (Good): Notice `DS_DIST_ALL_NONE` (Zero Network Movement!)
EXPLAIN
SELECT c.region_name, SUM(t.amount)
FROM fct_txns t
INNER JOIN good_dim_country c ON t.country_code = c.country_code
GROUP BY c.region_name;

-- (c) Run and verify:
-- CALL prc_good_broadcast_report();
-- SELECT * FROM rpt_regional_sales ORDER BY total_sales DESC;
