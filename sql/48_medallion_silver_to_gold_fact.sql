/*
======================================================================================
MODULE 48: MEDALLION ARCHITECTURE (SILVER TO GOLD FACT WITH SURROGATE LOOKUPS)
======================================================================================
MAPPED BEST PRACTICES (from PROCEDURE_OPTIMIZATION_BEST_PRACTICES_MASTER_FILE.md):
- Practice 89: Use a star schema for analytics — facts (measures) plus dimensions (context).
- Practice 59: Design keys intentionally — handle surrogate key lookups and unknown defaults (-1).
- Practice 29: Align distribution keys across fact and core dimensions.
- Practice 42: Make fact loads idempotent.

TARGET AUDIENCE: Application Developers transitioning to Redshift
BUSINESS SCENARIO: 
We are building the core Gold business fact table `fct_sales_gold`. 
The Silver layer provides clean orders with natural business keys (`customer_id`, `product_sku`, `store_id`). 
The Gold layer requires resolving these business keys into integer **Surrogate Keys** (`customer_sk`, `product_sk`, `store_sk`) 
and looking up SCD Type 2 point-in-time dimension records based on `order_date`.

THE PROBLEM:
If an incoming order has a `customer_id` that does not yet exist in `dim_customer` (a late-arriving dimension), 
an `INNER JOIN` silently drops the order, losing revenue metrics. 
Conversely, a `LEFT JOIN` without surrogate key defaults inserts `NULL` into primary foreign keys, breaking BI star schemas.

THE GOAL:
1. Implement point-in-time SCD2 surrogate key joins: `order_date BETWEEN valid_from AND valid_to`.
2. Default missing / late-arriving dimension foreign keys to `-1` ('Unknown Customer').
3. Ensure the fact load is 100% idempotent and collocated on the primary join key.
======================================================================================
*/

-- ===================================================================================
-- 1. DATA GENERATION BLOCK (Run this to set up the scenario)
-- ===================================================================================
DROP TABLE IF EXISTS dim_customer_gold CASCADE;
CREATE TABLE dim_customer_gold (
    customer_sk BIGINT NOT NULL ENCODE az64,
    customer_id BIGINT NOT NULL ENCODE az64,
    valid_from DATE NOT NULL ENCODE az64,
    valid_to DATE NOT NULL ENCODE az64,
    PRIMARY KEY (customer_sk)
)
DISTSTYLE ALL; -- Small dimension replicated to all nodes (Practice 31, 49)

-- Seed with known customers + Default Unknown Record (-1)
INSERT INTO dim_customer_gold VALUES 
(-1, -1, '1900-01-01', '9999-12-31'), -- DEFAULT UNKNOWN RECORD
(1001, 101, '2024-01-01', '2026-07-31'), -- Customer 101 version 1
(1002, 101, '2026-08-01', '9999-12-31'), -- Customer 101 version 2
(1003, 102, '2024-01-01', '9999-12-31');

DROP TABLE IF EXISTS silver_orders CASCADE;
CREATE TABLE silver_orders (
    order_id BIGINT NOT NULL ENCODE az64,
    customer_id BIGINT NOT NULL ENCODE az64,
    order_date DATE NOT NULL ENCODE az64,
    gross_amount DECIMAL(12,2) NOT NULL ENCODE az64
)
DISTSTYLE KEY
DISTKEY (customer_id);

-- Incoming Silver Orders:
-- Order 1: Matches Customer 101 on Aug 15 -> should resolve to customer_sk = 1002
-- Order 2: Matches Customer 101 on June 1 -> should resolve to customer_sk = 1001
-- Order 3: Customer 999 does not exist in dimension -> should resolve to customer_sk = -1 (Unknown)
INSERT INTO silver_orders VALUES 
(501, 101, '2026-08-15', 350.00),
(502, 101, '2026-06-01', 120.00),
(503, 999, '2026-08-15', 75.00);

DROP TABLE IF EXISTS fct_sales_gold CASCADE;
CREATE TABLE fct_sales_gold (
    order_id BIGINT NOT NULL ENCODE az64,
    customer_sk BIGINT NOT NULL ENCODE az64, -- Resolved surrogate key
    order_date DATE NOT NULL ENCODE az64,
    gross_amount DECIMAL(12,2) NOT NULL ENCODE az64,
    loaded_at TIMESTAMP DEFAULT SYSDATE ENCODE az64
)
DISTSTYLE KEY
DISTKEY (customer_sk)
COMPOUND SORTKEY (order_date, customer_sk);


-- ===================================================================================
-- 2. THE PROCEDURE (Point-in-Time SCD2 Fact Loader with Unknown Default)
-- ===================================================================================
CREATE OR REPLACE PROCEDURE prc_pipeline_silver_to_gold_fact(p_batch_date DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_rows_inserted BIGINT := 0;
    v_deleted_count BIGINT := 0;
BEGIN
    RAISE INFO 'Starting Gold Fact Ingestion for % ...', p_batch_date;

    -- Step 1: Idempotent pre-purge for the batch date
    DELETE FROM fct_sales_gold WHERE order_date = p_batch_date;
    GET DIAGNOSTICS v_deleted_count = ROW_COUNT;

    -- Step 2: Set-based surrogate key resolution with SCD2 point-in-time join
    INSERT INTO fct_sales_gold (order_id, customer_sk, order_date, gross_amount, loaded_at)
    SELECT 
        o.order_id,
        NVL(c.customer_sk, -1) AS customer_sk, -- Default missing / late dimensions to -1!
        o.order_date,
        o.gross_amount,
        SYSDATE
    FROM silver_orders o
    LEFT JOIN dim_customer_gold c 
        ON o.customer_id = c.customer_id
        AND o.order_date >= c.valid_from 
        AND o.order_date <= c.valid_to
    WHERE o.order_date = p_batch_date;

    GET DIAGNOSTICS v_rows_inserted = ROW_COUNT;
    RAISE INFO 'Gold Fact Load complete: % rows inserted for batch %.', v_rows_inserted, p_batch_date;

EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'prc_pipeline_silver_to_gold_fact failed for %: %', p_batch_date, SQLERRM;
END;
$$;


-- ===================================================================================
-- 3. USAGE & VERIFICATION
-- ===================================================================================

-- (a) Execute fact pipeline for 2026-08-15:
-- CALL prc_pipeline_silver_to_gold_fact('2026-08-15'::DATE);

-- (b) Check fact rows (Notice point-in-time SK resolution and -1 fallback!):
-- SELECT order_id, customer_sk, order_date, gross_amount FROM fct_sales_gold;
-- Result:
-- 501 | 1002 | 2026-08-15 | 350.00 (Customer 101 current version!)
-- 503 |   -1 | 2026-08-15 |  75.00 (Customer 999 gracefully resolved to Unknown!)

-- (c) Explain Plan: Collocated SK Dimension Lookup (DS_DIST_ALL_NONE)
EXPLAIN
SELECT 
    o.order_id,
    NVL(c.customer_sk, -1) AS customer_sk,
    o.order_date,
    o.gross_amount
FROM silver_orders o
LEFT JOIN dim_customer_gold c 
  ON o.customer_id = c.customer_id
  AND o.order_date >= c.valid_from 
  AND o.order_date <= c.valid_to
WHERE o.order_date = '2026-08-15'::DATE;
