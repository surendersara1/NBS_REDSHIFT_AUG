/*
======================================================================================
MODULE 47: MEDALLION ARCHITECTURE (SILVER TO GOLD SCD TYPE 2 WITH ROW HASHING)
======================================================================================
MAPPED BEST PRACTICES (from PROCEDURE_OPTIMIZATION_BEST_PRACTICES_MASTER_FILE.md):
- Practice 94: Decide slowly-changing-dimension (SCD) handling per dimension — track history intentionally.
- Practice 20: Avoid recomputing the same expression repeatedly — use MD5 row hashes for change detection.
- Practice 29: Align distribution keys across dimension and delta tables (DISTKEY customer_id).
- Practice 80: Use transactions to keep SCD history consistent.

TARGET AUDIENCE: Application Developers transitioning to Redshift
BUSINESS SCENARIO: 
We are maintaining a gold-layer Customer Dimension `dim_customer_scd2` (SCD Type 2). 
When a customer's address, tier, or region changes, we must **expire the active record** 
(`is_current = FALSE`, `valid_to = change_date`) and **insert a new active record** (`is_current = TRUE`, `valid_to = '9999-12-31'`).

THE PROBLEM:
In wide dimensions (50+ columns), writing `WHERE target.col1 != source.col1 OR target.col2 != source.col2 ...` 
is error-prone and generates massive SQL predicate trees. 
Furthermore, no-op updates (where the source sends unchanged data) must NOT generate new SCD versions.

THE GOAL:
1. Master SCD Type 2 implementation in Redshift using set-based SQL.
2. Use deterministic row hashing (`MD5(col1 || '|' || col2 || ...)`) to detect attribute changes in one comparison.
3. Guarantee that history is queryable by timestamp (`WHERE '2025-06-01' BETWEEN valid_from AND valid_to`).
======================================================================================
*/

-- ===================================================================================
-- 1. DATA GENERATION BLOCK (Run this to set up the scenario)
-- ===================================================================================
DROP TABLE IF EXISTS dim_customer_scd2 CASCADE;
CREATE TABLE dim_customer_scd2 (
    customer_sk BIGINT IDENTITY(1,1) NOT NULL ENCODE az64, -- Surrogate Key
    customer_id BIGINT NOT NULL ENCODE az64,               -- Natural Business Key
    customer_name VARCHAR(100) NOT NULL ENCODE zstd,
    address VARCHAR(150) NOT NULL ENCODE zstd,
    tier VARCHAR(20) NOT NULL ENCODE bytedict,
    row_hash VARCHAR(32) NOT NULL ENCODE zstd,             -- MD5 Hash of tracked attributes
    valid_from DATE NOT NULL ENCODE az64,
    valid_to DATE NOT NULL ENCODE az64,
    is_current BOOLEAN NOT NULL ENCODE raw,
    PRIMARY KEY (customer_sk)
)
DISTSTYLE KEY
DISTKEY (customer_id)
COMPOUND SORTKEY (customer_id, valid_from);

-- Initial State: Customer 101 and 102
INSERT INTO dim_customer_scd2 (customer_id, customer_name, address, tier, row_hash, valid_from, valid_to, is_current)
VALUES 
(101, 'Alice Smith', '123 Pine St', 'STANDARD', MD5('Alice Smith|123 Pine St|STANDARD'), '2024-01-01', '9999-12-31', TRUE),
(102, 'Bob Jones',   '456 Elm St',  'GOLD',     MD5('Bob Jones|456 Elm St|GOLD'),         '2024-01-01', '9999-12-31', TRUE);

-- Incoming Silver Delta Table:
DROP TABLE IF EXISTS silver_customer_delta CASCADE;
CREATE TABLE silver_customer_delta (
    customer_id BIGINT NOT NULL,
    customer_name VARCHAR(100) NOT NULL,
    address VARCHAR(150) NOT NULL,
    tier VARCHAR(20) NOT NULL,
    effective_date DATE NOT NULL
)
DISTSTYLE KEY
DISTKEY (customer_id);

-- Delta scenarios:
-- Customer 101: Changed address to '789 Oak Ave' and tier to 'VIP' (Needs new SCD2 version!)
-- Customer 102: Exactly same data (No-op update! Must NOT create new version)
-- Customer 103: Brand new customer (Needs new active version)
INSERT INTO silver_customer_delta VALUES 
(101, 'Alice Smith', '789 Oak Ave', 'VIP',  '2026-08-15'),
(102, 'Bob Jones',   '456 Elm St',  'GOLD', '2026-08-15'),
(103, 'Charlie Ray', '999 Maple Dr','SILVER','2026-08-15');


-- ===================================================================================
-- 2. THE PROCEDURE (Set-Based SCD Type 2 Pipeline with Row Hashing)
-- ===================================================================================
CREATE OR REPLACE PROCEDURE prc_pipeline_silver_to_gold_scd2(p_batch_date DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_expired_count  BIGINT := 0;
    v_inserted_count BIGINT := 0;
BEGIN
    RAISE INFO 'Starting SCD Type 2 Gold Pipeline for % ...', p_batch_date;

    -- Stage 1: Compute MD5 row hash on incoming silver delta
    DROP TABLE IF EXISTS #stg_scd2_delta;
    CREATE TEMP TABLE #stg_scd2_delta (
        customer_id BIGINT NOT NULL,
        customer_name VARCHAR(100) NOT NULL,
        address VARCHAR(150) NOT NULL,
        tier VARCHAR(20) NOT NULL,
        row_hash VARCHAR(32) NOT NULL,
        effective_date DATE NOT NULL
    )
    DISTSTYLE KEY
    DISTKEY (customer_id)
    ON COMMIT DROP;

    INSERT INTO #stg_scd2_delta
    SELECT 
        customer_id,
        customer_name,
        address,
        tier,
        MD5(customer_name || '|' || address || '|' || tier) AS row_hash,
        effective_date
    FROM silver_customer_delta;

    ANALYZE #stg_scd2_delta;

    -- Step 1: EXPIRE active records whose attributes have changed
    UPDATE dim_customer_scd2
    SET valid_to   = s.effective_date - 1,
        is_current = FALSE
    FROM #stg_scd2_delta s
    WHERE dim_customer_scd2.customer_id = s.customer_id
      AND dim_customer_scd2.is_current  = TRUE
      AND dim_customer_scd2.row_hash   != s.row_hash; -- Changed attributes detected instantly!
    GET DIAGNOSTICS v_expired_count = ROW_COUNT;

    -- Step 2: INSERT new versions (both brand new customers and new versions of changed customers)
    INSERT INTO dim_customer_scd2 (
        customer_id, customer_name, address, tier, row_hash, valid_from, valid_to, is_current
    )
    SELECT 
        s.customer_id,
        s.customer_name,
        s.address,
        s.tier,
        s.row_hash,
        s.effective_date AS valid_from,
        '9999-12-31'::DATE AS valid_to,
        TRUE AS is_current
    FROM #stg_scd2_delta s
    LEFT JOIN dim_customer_scd2 target 
        ON s.customer_id = target.customer_id 
        AND target.is_current = TRUE 
        AND s.row_hash = target.row_hash -- Unchanged active record match
    WHERE target.customer_id IS NULL; -- Only insert if no identical active row exists!
    GET DIAGNOSTICS v_inserted_count = ROW_COUNT;

    RAISE INFO 'SCD Type 2 Load Complete: % versions expired, % new versions inserted.', 
        v_expired_count, v_inserted_count;

EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'prc_pipeline_silver_to_gold_scd2 failed: %', SQLERRM;
END;
$$;


-- ===================================================================================
-- 3. USAGE, VERIFICATION & HISTORICAL TIME-TRAVEL QUERY
-- ===================================================================================

-- (a) Execute SCD2 procedure:
-- CALL prc_pipeline_silver_to_gold_scd2('2026-08-15'::DATE);

-- (b) Check dim_customer_scd2:
-- SELECT customer_sk, customer_id, customer_name, address, tier, valid_from, valid_to, is_current
-- FROM dim_customer_scd2
-- ORDER BY customer_id, valid_from;
-- Result:
-- 101 v1: 2024-01-01 to 2026-08-14 | is_current = FALSE (Expired!)
-- 101 v2: 2026-08-15 to 9999-12-31 | is_current = TRUE  (New address/tier!)
-- 102 v1: 2024-01-01 to 9999-12-31 | is_current = TRUE  (Unchanged, no extra row!)
-- 103 v1: 2026-08-15 to 9999-12-31 | is_current = TRUE  (Brand new customer!)

-- (c) Point-in-time Historical Query (How did Customer 101 look on 2025-06-01?):
-- SELECT customer_id, address, tier
-- FROM dim_customer_scd2
-- WHERE customer_id = 101
--   AND '2025-06-01'::DATE BETWEEN valid_from AND valid_to;
-- (Returns '123 Pine St', STANDARD tier!)

-- (d) Explain Plan for SCD2 Expiration Step:
EXPLAIN
UPDATE dim_customer_scd2
SET valid_to = '2026-08-14'::DATE, is_current = FALSE
FROM silver_customer_delta s
WHERE dim_customer_scd2.customer_id = s.customer_id
  AND dim_customer_scd2.is_current = TRUE;
