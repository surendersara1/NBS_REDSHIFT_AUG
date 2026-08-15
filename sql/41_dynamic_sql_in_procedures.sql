/*
======================================================================================
MODULE 41: DYNAMIC SQL AND PROCEDURE FLEXIBILITY (EXECUTE & QUOTING)
======================================================================================
MAPPED BEST PRACTICES (from PROCEDURE_OPTIMIZATION_BEST_PRACTICES_MASTER_FILE.md):
- Practice 77: Avoid dynamic SQL (EXECUTE) inside hot loops — each call re-plans and re-compiles.
- Practice 15: Fail early — validate dynamic table/column identifiers against the catalog.
- Practice 86: Handle exceptions intentionally with error context.

TARGET AUDIENCE: Application Developers transitioning to Redshift
BUSINESS SCENARIO: 
We have 20 vendor staging tables (`stg_vendor_1`, `stg_vendor_2`, ...). 
We need a reusable stored procedure to dynamically truncate and load any given staging table.

THE PROBLEM:
In application code, developers use string interpolation: `query = "TRUNCATE TABLE " + tableName`.
In database procedures:
1. Naive string concatenation allows **SQL Injection** (`tableName = 'stg_vendor_1; DROP TABLE dim_customer;'`).
2. Overusing `EXECUTE` inside row-by-row loops bypasses the Redshift query compilation cache, 
   forcing the Leader Node to re-parse, re-plan, and re-compile C++ segments on every call.

THE GOAL:
1. Safely construct dynamic SQL using `QUOTE_IDENT()` and catalog validation.
2. Reserve `EXECUTE` for batch DDL and partition operations; never use dynamic SQL in hot loops.
3. Contrast unsafe string concatenation against secure, catalog-validated dynamic execution.
======================================================================================
*/

-- ===================================================================================
-- 1. DATA GENERATION BLOCK (Run this to set up the scenario)
-- ===================================================================================
DROP TABLE IF EXISTS stg_vendor_amer CASCADE;
CREATE TABLE stg_vendor_amer (id INT, val VARCHAR(50));
INSERT INTO stg_vendor_amer VALUES (1, 'Old Data AMER');

DROP TABLE IF EXISTS stg_vendor_emea CASCADE;
CREATE TABLE stg_vendor_emea (id INT, val VARCHAR(50));
INSERT INTO stg_vendor_emea VALUES (1, 'Old Data EMEA');

DROP TABLE IF EXISTS audit_maintenance_runs CASCADE;
CREATE TABLE audit_maintenance_runs (
    run_id BIGINT IDENTITY(1,1),
    table_name VARCHAR(100),
    action_type VARCHAR(50),
    executed_at TIMESTAMP DEFAULT SYSDATE
);


-- ===================================================================================
-- 2. THE "BAD" PROCEDURE (The Unquoted SQL Injection Anti-Pattern)
-- ===================================================================================
/*
WHY IT'S DANGEROUS:
- Directly concatenates raw parameter strings into the `EXECUTE` statement.
- Vulnerable to SQL injection.
- Does not check if the object exists before attempting execution.
*/
CREATE OR REPLACE PROCEDURE prc_bad_unsafe_dynamic_truncate(p_table_name VARCHAR)
LANGUAGE plpgsql
AS $$
DECLARE
    v_sql VARCHAR(MAX);
BEGIN
    -- DANGEROUS: Unsanitized string concatenation!
    v_sql := 'TRUNCATE TABLE ' || p_table_name || ';';
    RAISE INFO 'Executing unsafe SQL: %', v_sql;
    
    EXECUTE v_sql;
END;
$$;


-- ===================================================================================
-- 3. THE "GOOD" PROCEDURE (The Catalog-Validated & Quoted Best Practice)
-- ===================================================================================
/*
WHY IT'S SECURE & ROBUST:
1. CATALOG VALIDATION: Checks `pg_class` and `pg_namespace` to confirm the table exists.
2. QUOTE_IDENT: Properly escapes table identifiers to prevent SQL injection payloads.
3. COMPILE CACHE INTEGRITY: Uses dynamic execution only for DDL metadata statements (TRUNCATE/VACUUM),
   not inside hot row-processing loops.
*/
CREATE OR REPLACE PROCEDURE prc_good_safe_dynamic_truncate(p_schema_name VARCHAR, p_table_name VARCHAR)
LANGUAGE plpgsql
AS $$
DECLARE
    v_sql          VARCHAR(MAX);
    v_table_count  INT := 0;
BEGIN
    -- 1. Fail Early: Validate parameter inputs
    IF p_schema_name IS NULL OR p_table_name IS NULL THEN
        RAISE EXCEPTION 'Schema and Table parameters cannot be NULL.';
    END IF;

    -- 2. Security Check: Validate table existence against system catalog
    SELECT COUNT(1) INTO v_table_count
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = p_schema_name AND c.relname = p_table_name;

    IF v_table_count = 0 THEN
        RAISE EXCEPTION 'Security/Validation Error: Object %.% does not exist.', 
            p_schema_name, p_table_name;
    END IF;

    -- 3. Construct sanitized DDL using QUOTE_IDENT
    v_sql := 'TRUNCATE TABLE ' || QUOTE_IDENT(p_schema_name) || '.' || QUOTE_IDENT(p_table_name) || ';';
    
    RAISE INFO 'Executing verified DDL: %', v_sql;
    EXECUTE v_sql;

    -- 4. Log completion
    INSERT INTO audit_maintenance_runs (table_name, action_type, executed_at)
    VALUES (p_schema_name || '.' || p_table_name, 'TRUNCATE', SYSDATE);
    
    RAISE INFO 'Table %.% truncated successfully.', p_schema_name, p_table_name;

EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'prc_good_safe_dynamic_truncate failed on %.%: %', 
        p_schema_name, p_table_name, SQLERRM;
END;
$$;


-- ===================================================================================
-- 4. USAGE, VERIFICATION & EXPLAIN / CATALOG ANALYSIS
-- ===================================================================================

-- (a) Test Valid Dynamic Truncate:
-- CALL prc_good_safe_dynamic_truncate('public', 'stg_vendor_amer');
-- SELECT COUNT(1) FROM stg_vendor_amer; -- 0 rows (Truncated cleanly!)

-- (b) Test SQL Injection Defense (Injection payload rejected!):
-- CALL prc_good_safe_dynamic_truncate('public', 'stg_vendor_emea; DROP TABLE dim_customer;');
-- --> Throws ERROR: Security/Validation Error: Object does not exist.

-- (c) Explain / Catalog Metadata Inspection:
SELECT n.nspname AS schema_name, c.relname AS table_name, c.reltuples
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relname LIKE 'stg_vendor_%';

-- (d) Audit Execution Trail:
SELECT * FROM audit_maintenance_runs ORDER BY executed_at DESC LIMIT 5;
