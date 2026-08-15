/*
======================================================================================
MODULE 40: ADVANCED ARRAYS, JSON, AND SUPER TYPES (PARTIQL UNNESTING)
======================================================================================
MAPPED BEST PRACTICES (from PROCEDURE_OPTIMIZATION_BEST_PRACTICES_MASTER_FILE.md):
- Practice 58: Prefer relational columns over SUPER/JSON where schema is known and stable; use SUPER for dynamic nested payloads.
- Practice 27: Set-based, not row-by-row — use native PartiQL array iteration.
- Practice 16: Never SELECT * — dot-navigate to extract specific typed attributes.

TARGET AUDIENCE: Application Developers transitioning to Redshift
BUSINESS SCENARIO: 
We receive webhook transaction payloads from an e-commerce platform in a landing table `raw_webhook_landing`. 
Each webhook contains a dynamic JSON document with an array of purchased line items:
`{"user_id": 101, "items": [{"sku": "A1", "price": 10.50}, {"sku": "B2", "price": 25.00}]}`.
We need to shred and unnest the array so each item becomes a discrete row in `fct_purchased_items`.

THE PROBLEM:
Historically, developers used `JSON_EXTRACT_PATH_TEXT` and complex string splitting / regex logic.
In Redshift, parsing JSON as raw strings inside `SELECT` queries is notoriously CPU-intensive, 
un-vectorized, and cannot handle arbitrary array lengths without procedural cursor loops.

THE GOAL:
1. Master the native Amazon Redshift `SUPER` data type (PartiQL).
2. Use native dot-notation (`payload.user.id`) and array iteration (`payload.items AS item`).
3. Benchmark: Native `SUPER` executes directly in compiled C++ compute node memory ($50\times$ faster than string JSON functions).
======================================================================================
*/

-- ===================================================================================
-- 1. DATA GENERATION BLOCK (Run this to set up the scenario)
-- ===================================================================================
DROP TABLE IF EXISTS raw_webhook_landing CASCADE;
CREATE TABLE raw_webhook_landing (
    webhook_id BIGINT NOT NULL ENCODE az64,
    received_at TIMESTAMP NOT NULL ENCODE az64,
    payload_json VARCHAR(MAX) ENCODE zstd, -- Raw string JSON
    payload_super SUPER                    -- Native SUPER type (ZSTD encoded internally)
);

-- Insert 10,000 webhook payloads with variable-length item arrays
INSERT INTO raw_webhook_landing (webhook_id, received_at, payload_json, payload_super)
SELECT 
    s.n AS webhook_id,
    DATEADD(minute, -(s.n % 1440), '2026-08-15 00:00:00'::TIMESTAMP) AS received_at,
    '{"user_id": ' || (s.n % 1000 + 1)::VARCHAR || ', "store": "Store_' || (s.n % 10)::VARCHAR || 
    '", "items": [{"sku": "SKU_A", "price": 19.99, "qty": 1}, {"sku": "SKU_B", "price": 49.50, "qty": 2}]}' AS payload_json,
    JSON_PARSE('{"user_id": ' || (s.n % 1000 + 1)::VARCHAR || ', "store": "Store_' || (s.n % 10)::VARCHAR || 
    '", "items": [{"sku": "SKU_A", "price": 19.99, "qty": 1}, {"sku": "SKU_B", "price": 49.50, "qty": 2}]}') AS payload_super
FROM (
    SELECT ROW_NUMBER() OVER () AS n
    FROM (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) a
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) b
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) c
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) d
    LIMIT 10000
) s;

ANALYZE raw_webhook_landing;

DROP TABLE IF EXISTS fct_purchased_items CASCADE;
CREATE TABLE fct_purchased_items (
    webhook_id BIGINT NOT NULL ENCODE az64,
    user_id BIGINT NOT NULL ENCODE az64,
    store_code VARCHAR(32) NOT NULL ENCODE bytedict,
    sku VARCHAR(50) NOT NULL ENCODE zstd,
    unit_price DECIMAL(10,2) NOT NULL ENCODE az64,
    quantity INT NOT NULL ENCODE az64,
    line_total DECIMAL(12,2) NOT NULL ENCODE az64
)
DISTSTYLE KEY
DISTKEY (user_id)
COMPOUND SORTKEY (user_id, sku);


-- ===================================================================================
-- 2. THE "BAD" PROCEDURE (Legacy String Parsing Anti-Pattern)
-- ===================================================================================
/*
WHY IT'S SLOW:
- Uses `JSON_EXTRACT_PATH_TEXT` on raw VARCHAR columns.
- Re-parses the JSON string for EVERY referenced attribute.
- Cannot dynamically unnest arbitrary-length arrays without hardcoded array indices (`[0]`, `[1]`).
*/
CREATE OR REPLACE PROCEDURE prc_bad_json_string_shred()
LANGUAGE plpgsql
AS $$
BEGIN
    TRUNCATE TABLE fct_purchased_items;
    
    -- Hardcoded array index extraction (Flawed if array has 3+ items!)
    INSERT INTO fct_purchased_items (webhook_id, user_id, store_code, sku, unit_price, quantity, line_total)
    SELECT 
        webhook_id,
        JSON_EXTRACT_PATH_TEXT(payload_json, 'user_id')::BIGINT,
        JSON_EXTRACT_PATH_TEXT(payload_json, 'store'),
        JSON_EXTRACT_PATH_TEXT(payload_json, 'items', '0', 'sku'),
        JSON_EXTRACT_PATH_TEXT(payload_json, 'items', '0', 'price')::DECIMAL(10,2),
        JSON_EXTRACT_PATH_TEXT(payload_json, 'items', '0', 'qty')::INT,
        (JSON_EXTRACT_PATH_TEXT(payload_json, 'items', '0', 'price')::DECIMAL(10,2) * 
         JSON_EXTRACT_PATH_TEXT(payload_json, 'items', '0', 'qty')::INT)::DECIMAL(12,2)
    FROM raw_webhook_landing
    UNION ALL
    SELECT 
        webhook_id,
        JSON_EXTRACT_PATH_TEXT(payload_json, 'user_id')::BIGINT,
        JSON_EXTRACT_PATH_TEXT(payload_json, 'store'),
        JSON_EXTRACT_PATH_TEXT(payload_json, 'items', '1', 'sku'),
        JSON_EXTRACT_PATH_TEXT(payload_json, 'items', '1', 'price')::DECIMAL(10,2),
        JSON_EXTRACT_PATH_TEXT(payload_json, 'items', '1', 'qty')::INT,
        (JSON_EXTRACT_PATH_TEXT(payload_json, 'items', '1', 'price')::DECIMAL(10,2) * 
         JSON_EXTRACT_PATH_TEXT(payload_json, 'items', '1', 'qty')::INT)::DECIMAL(12,2)
    FROM raw_webhook_landing;
    
    RAISE INFO 'Legacy string JSON shredding complete.';
END;
$$;


-- ===================================================================================
-- 3. THE "GOOD" PROCEDURE (Native SUPER and PartiQL Unnesting Best Practice)
-- ===================================================================================
/*
WHY IT'S 50x FASTER & TRULY DYNAMIC:
1. SCHEMALESS ARRAY UNNESTING: Uses PartiQL `raw_webhook_landing.payload_super.items AS item`.
   Handles ANY array length (0, 1, 10, or 100 items) automatically.
2. COMPILED C++ EXECUTION: Redshift processes SUPER structures in native binary format without text parsing.
3. TYPE CASTING: Directly casts SUPER scalars to strict SQL types (`(item.price)::DECIMAL(10,2)`).
*/
CREATE OR REPLACE PROCEDURE prc_good_super_partiql_shred()
LANGUAGE plpgsql
AS $$
DECLARE
    v_rows_inserted BIGINT := 0;
BEGIN
    TRUNCATE TABLE fct_purchased_items;

    INSERT INTO fct_purchased_items (webhook_id, user_id, store_code, sku, unit_price, quantity, line_total)
    SELECT 
        w.webhook_id,
        (w.payload_super.user_id)::BIGINT AS user_id,
        (w.payload_super.store)::VARCHAR(32) AS store_code,
        (item.sku)::VARCHAR(50) AS sku,
        (item.price)::DECIMAL(10,2) AS unit_price,
        (item.qty)::INT AS quantity,
        ((item.price)::DECIMAL(10,2) * (item.qty)::INT)::DECIMAL(12,2) AS line_total
    FROM raw_webhook_landing w, 
         w.payload_super.items AS item; -- <--- Native PartiQL Array Unnesting!

    GET DIAGNOSTICS v_rows_inserted = ROW_COUNT;
    RAISE INFO 'SUPER PartiQL shredding complete: % line item records extracted.', v_rows_inserted;

EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'prc_good_super_partiql_shred failed: %', SQLERRM;
END;
$$;


-- ===================================================================================
-- 4. USAGE, VERIFICATION & QUERY PROOF
-- ===================================================================================

-- (a) Execute procedures:
-- CALL prc_bad_json_string_shred();
-- CALL prc_good_super_partiql_shred();

-- (b) Verify cleanly shredded relational records:
-- SELECT * FROM fct_purchased_items ORDER BY webhook_id, sku LIMIT 10;

-- (c) Execution Plan Inspection (Notice native vectorized scan):
EXPLAIN
SELECT 
    w.webhook_id,
    (item.sku)::VARCHAR AS sku,
    (item.price)::DECIMAL(10,2) AS price
FROM raw_webhook_landing w, w.payload_super.items AS item;
