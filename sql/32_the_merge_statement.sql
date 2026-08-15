/*
======================================================================================
MODULE 32: THE MERGE STATEMENT VS DELETE/INSERT VS ALTER TABLE APPEND
======================================================================================
MAPPED BEST PRACTICES (from PROCEDURE_OPTIMIZATION_BEST_PRACTICES_MASTER_FILE.md):
- Practice 44: Prefer MERGE / upsert over DELETE+INSERT where supported — reduces ghost rows.
- Practice 43: Avoid duplicate records on retries — staging table MUST be unique.
- Practice 78: Avoid excessive logging in hot loops.
- Practice 72: Use TRUNCATE instead of DELETE when clearing staging tables.

TARGET AUDIENCE: Application Developers transitioning to Redshift
BUSINESS SCENARIO: 
We have a product dimension `dim_product` (1 million SKUs). 
Every night, an upstream inventory catalog sends a delta file (`stg_product_delta`) 
containing 50,000 modified prices and new product additions. 
We need to perform a high-performance "Upsert" into Redshift.

THE PROBLEM:
Historically, Redshift lacked an ANSI `MERGE` statement, forcing developers to use a 3-step dance:
1. Load into temp table.
2. `DELETE FROM target USING temp WHERE target.id = temp.id`.
3. `INSERT INTO target SELECT * FROM temp`.
This caused 2 massive table scans, created millions of "ghost row" tombstones, and required 
nightly `VACUUM DELETE ONLY`.

THE GOAL:
1. Master the native Amazon Redshift `MERGE` statement.
2. Learn the critical MERGE prerequisites (Target join column must be unique/PK; Source must be deduplicated).
3. Know when `ALTER TABLE APPEND` (instant metadata pointer swap) is even faster for append-only partitions.
======================================================================================
*/

-- ===================================================================================
-- 1. DATA GENERATION BLOCK (Run this to set up the scenario)
-- ===================================================================================
DROP TABLE IF EXISTS dim_product CASCADE;
CREATE TABLE dim_product (
    product_id BIGINT NOT NULL ENCODE az64,
    product_sku VARCHAR(50) NOT NULL ENCODE zstd,
    product_name VARCHAR(100) NOT NULL ENCODE zstd,
    category VARCHAR(50) NOT NULL ENCODE bytedict,
    unit_price DECIMAL(10,2) NOT NULL ENCODE az64,
    updated_at TIMESTAMP NOT NULL ENCODE az64,
    PRIMARY KEY (product_id) -- Declared for MERGE optimizer hint
)
DISTSTYLE KEY
DISTKEY (product_id)
COMPOUND SORTKEY (product_id);

-- Seed initial dimension data (100,000 products)
INSERT INTO dim_product (product_id, product_sku, product_name, category, unit_price, updated_at)
SELECT 
    s.n AS product_id,
    'SKU-' || LPAD(s.n::VARCHAR, 6, '0') AS product_sku,
    'Product ' || s.n::VARCHAR AS product_name,
    CASE WHEN s.n % 4 = 0 THEN 'Electronics' WHEN s.n % 4 = 1 THEN 'Apparel' WHEN s.n % 4 = 2 THEN 'Home' ELSE 'Toys' END AS category,
    (10.00 + (s.n % 100))::DECIMAL(10,2) AS unit_price,
    '2026-01-01 00:00:00'::TIMESTAMP AS updated_at
FROM (
    SELECT ROW_NUMBER() OVER () AS n
    FROM (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) a
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) b
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) c
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) d
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) e
    LIMIT 100000
) s;

ANALYZE dim_product;

-- Incoming Nightly Delta: 10,000 price updates + 2,000 new products
DROP TABLE IF EXISTS stg_product_delta CASCADE;
CREATE TABLE stg_product_delta (
    product_id BIGINT NOT NULL ENCODE az64,
    product_sku VARCHAR(50) NOT NULL ENCODE zstd,
    product_name VARCHAR(100) NOT NULL ENCODE zstd,
    category VARCHAR(50) NOT NULL ENCODE bytedict,
    unit_price DECIMAL(10,2) NOT NULL ENCODE az64
)
DISTSTYLE KEY
DISTKEY (product_id); -- Aligned with target for collocated merge!

-- 10,000 existing products with new prices:
INSERT INTO stg_product_delta (product_id, product_sku, product_name, category, unit_price)
SELECT product_id, product_sku, product_name, category, (unit_price * 1.15)::DECIMAL(10,2)
FROM dim_product WHERE product_id <= 10000;

-- 2,000 brand new products:
INSERT INTO stg_product_delta (product_id, product_sku, product_name, category, unit_price)
SELECT (100000 + s.n), 'SKU-' || (100000 + s.n)::VARCHAR, 'New Product ' || s.n::VARCHAR, 'Electronics', 99.99
FROM (SELECT ROW_NUMBER() OVER () as n FROM (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) a, (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) b, (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) c, (SELECT 0 UNION SELECT 1) d LIMIT 2000) s;

ANALYZE stg_product_delta;


-- ===================================================================================
-- 2. THE "BAD" PROCEDURE (The Legacy Two-Pass DELETE+INSERT Pattern)
-- ===================================================================================
/*
WHY IT'S SUB-OPTIMAL TODAY:
- Executes 2 full passes over the base table (one DELETE, one INSERT).
- Every DELETE creates physical tombstones (ghost rows). 
- Over 6 months of daily updates, table scan performance degrades by 50%+ without constant VACUUMs.
*/
CREATE OR REPLACE PROCEDURE prc_bad_legacy_upsert()
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE INFO 'Running legacy DELETE + INSERT upsert...';
    
    -- Pass 1: Delete matching rows (creates tombstones)
    DELETE FROM dim_product
    USING stg_product_delta s
    WHERE dim_product.product_id = s.product_id;
    
    -- Pass 2: Insert both new and updated rows
    INSERT INTO dim_product (product_id, product_sku, product_name, category, unit_price, updated_at)
    SELECT product_id, product_sku, product_name, category, unit_price, SYSDATE
    FROM stg_product_delta;
    
    RAISE INFO 'Legacy upsert complete.';
END;
$$;


-- ===================================================================================
-- 3. THE "GOOD" PROCEDURE (The Native Redshift MERGE Statement)
-- ===================================================================================
/*
WHY IT'S SUPERIOR:
- Single declarative statement optimized internally by the query engine.
- Minimizes transaction log overhead and significantly reduces tombstone fragmentation.
- CRITICAL MERGE RULES IN REDSHIFT:
  1. The ON join condition MUST be an equality match on the target table's primary key or unique columns.
  2. The source (staging) table MUST NOT contain duplicate keys (or the MERGE statement fails at runtime).
  3. Redshift MERGE does not support multiple `WHEN MATCHED AND <extra_cond>` clauses.
*/
CREATE OR REPLACE PROCEDURE prc_good_native_merge_upsert()
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE INFO 'Executing native Redshift MERGE...';
    
    MERGE INTO dim_product
    USING stg_product_delta s
    ON dim_product.product_id = s.product_id
    WHEN MATCHED THEN
        UPDATE SET 
            product_sku  = s.product_sku,
            product_name = s.product_name,
            category     = s.category,
            unit_price   = s.unit_price,
            updated_at   = SYSDATE
    WHEN NOT MATCHED THEN
        INSERT (product_id, product_sku, product_name, category, unit_price, updated_at)
        VALUES (s.product_id, s.product_sku, s.product_name, s.category, s.unit_price, SYSDATE);
        
    RAISE INFO 'Native MERGE completed successfully.';

EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'prc_good_native_merge_upsert failed: %', SQLERRM;
END;
$$;


-- ===================================================================================
-- 4. USAGE, VERIFICATION & MERGE EXPLAIN PLAN
-- ===================================================================================

-- (a) Execute native MERGE:
-- CALL prc_good_native_merge_upsert();

-- (b) Verify row count:
-- SELECT COUNT(1) FROM dim_product; -- Yields exactly 102,000 rows (100k original + 2k new)

-- (c) Inspect price updates:
-- SELECT product_id, unit_price, updated_at FROM dim_product WHERE product_id <= 5;

-- (d) Check Execution Plan of MERGE:
EXPLAIN
MERGE INTO dim_product
USING stg_product_delta s ON dim_product.product_id = s.product_id
WHEN MATCHED THEN UPDATE SET unit_price = s.unit_price
WHEN NOT MATCHED THEN INSERT (product_id, product_sku, product_name, category, unit_price, updated_at)
VALUES (s.product_id, s.product_sku, s.product_name, s.category, s.unit_price, SYSDATE);
