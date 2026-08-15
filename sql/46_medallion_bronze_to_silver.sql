/*
======================================================================================
MODULE 46: MEDALLION ARCHITECTURE (BRONZE TO SILVER CLEANSING & QUARANTINE)
======================================================================================
MAPPED BEST PRACTICES (from PROCEDURE_OPTIMIZATION_BEST_PRACTICES_MASTER_FILE.md):
- Practice 91: Follow medallion layering: Bronze (raw) -> Silver (cleansed) -> Gold (business).
- Practice 84: Use staging tables for complex loads — transform and validate before publishing.
- Practice 85: Validate staged data before publishing — check row counts, nulls, and business rules.
- Practice 100: Add data-quality checks and quarantine malformed records.

TARGET AUDIENCE: Application Developers transitioning to Redshift
BUSINESS SCENARIO: 
We have raw JSON customer event payloads in a Bronze landing table `bronze_raw_events`. 
The data contains malformed records (e.g. invalid emails, negative ages, non-numeric amounts, corrupted JSON). 
We need a production-grade stored procedure to cleanse and promote valid records to `silver_customers` 
while redirecting corrupted records to `silver_quarantine_records` for data-steward triage.

THE PROBLEM:
If a single dirty row crashes the pipeline with a type conversion error, the entire batch halts. 
Conversely, if developers use `NULLIF` without tracking, bad data silently poisons analytics.

THE GOAL:
1. Parse Bronze JSON into typed Silver relational columns.
2. Isolate invalid records into a dedicated `silver_quarantine_records` table with explicit error codes.
3. Cleanse, deduplicate, and promote 100% clean records to `silver_customers`.
======================================================================================
*/

-- ===================================================================================
-- 1. DATA GENERATION BLOCK (Run this to set up the scenario)
-- ===================================================================================
DROP TABLE IF EXISTS bronze_raw_events CASCADE;
CREATE TABLE bronze_raw_events (
    raw_event_id BIGINT IDENTITY(1,1),
    payload_json VARCHAR(MAX),
    ingested_at TIMESTAMP DEFAULT SYSDATE
);

-- Seed with clean, edge-case, and corrupted records:
INSERT INTO bronze_raw_events (payload_json) VALUES 
('{"user_id": 101, "name": "Alice Smith", "email": "alice@company.com", "age": 29, "country": "US"}'),
('{"user_id": 102, "name": "Bob Jones",   "email": "invalid_email_format", "age": 34, "country": "GB"}'), -- Bad email!
('{"user_id": 103, "name": "Charlie",     "email": "charlie@test.com", "age": -5, "country": "DE"}'),     -- Invalid negative age!
('{"user_id": 104, "name": "Dana White",  "email": "dana@test.com",    "age": 42, "country": "FR"}');

DROP TABLE IF EXISTS silver_customers CASCADE;
CREATE TABLE silver_customers (
    user_id BIGINT NOT NULL ENCODE az64,
    customer_name VARCHAR(100) NOT NULL ENCODE zstd,
    email VARCHAR(100) NOT NULL ENCODE zstd,
    age INT NOT NULL ENCODE az64,
    country CHAR(2) NOT NULL ENCODE bytedict,
    promoted_at TIMESTAMP NOT NULL ENCODE az64,
    PRIMARY KEY (user_id)
)
DISTSTYLE KEY
DISTKEY (user_id)
COMPOUND SORTKEY (user_id);

DROP TABLE IF EXISTS silver_quarantine_records CASCADE;
CREATE TABLE silver_quarantine_records (
    quarantine_id BIGINT IDENTITY(1,1),
    raw_event_id BIGINT,
    payload_json VARCHAR(MAX),
    quarantine_reason VARCHAR(255),
    quarantined_at TIMESTAMP DEFAULT SYSDATE
);


-- ===================================================================================
-- 2. THE PROCEDURE (Bronze -> Silver Cleansing with Quarantine Routing)
-- ===================================================================================
CREATE OR REPLACE PROCEDURE prc_pipeline_bronze_to_silver()
LANGUAGE plpgsql
AS $$
DECLARE
    v_clean_count      BIGINT := 0;
    v_quarantine_count BIGINT := 0;
BEGIN
    RAISE INFO 'Starting Bronze-to-Silver Cleansing Pipeline...';

    -- Step 1: Stage parsed records into a temporary table with validation flags
    DROP TABLE IF EXISTS #stg_parsed_events;
    CREATE TEMP TABLE #stg_parsed_events (
        raw_event_id BIGINT,
        user_id BIGINT,
        customer_name VARCHAR(100),
        email VARCHAR(100),
        age INT,
        country VARCHAR(10),
        payload_json VARCHAR(MAX),
        is_valid BOOLEAN,
        validation_error VARCHAR(255)
    )
    DISTSTYLE KEY
    DISTKEY (user_id)
    ON COMMIT DROP;

    INSERT INTO #stg_parsed_events
    SELECT 
        raw_event_id,
        JSON_EXTRACT_PATH_TEXT(payload_json, 'user_id')::BIGINT,
        JSON_EXTRACT_PATH_TEXT(payload_json, 'name'),
        JSON_EXTRACT_PATH_TEXT(payload_json, 'email'),
        NULLIF(JSON_EXTRACT_PATH_TEXT(payload_json, 'age'), '')::INT,
        JSON_EXTRACT_PATH_TEXT(payload_json, 'country'),
        payload_json,
        -- Validation logic:
        CASE 
            WHEN JSON_EXTRACT_PATH_TEXT(payload_json, 'email') NOT LIKE '%@%.%' THEN FALSE
            WHEN NULLIF(JSON_EXTRACT_PATH_TEXT(payload_json, 'age'), '')::INT <= 0 THEN FALSE
            ELSE TRUE
        END AS is_valid,
        CASE 
            WHEN JSON_EXTRACT_PATH_TEXT(payload_json, 'email') NOT LIKE '%@%.%' THEN 'MALFORMED_EMAIL'
            WHEN NULLIF(JSON_EXTRACT_PATH_TEXT(payload_json, 'age'), '')::INT <= 0 THEN 'INVALID_AGE'
            ELSE 'CLEAN'
        END AS validation_error
    FROM bronze_raw_events;

    ANALYZE #stg_parsed_events;

    -- Step 2: Route dirty records to the Quarantine table
    INSERT INTO silver_quarantine_records (raw_event_id, payload_json, quarantine_reason, quarantined_at)
    SELECT raw_event_id, payload_json, validation_error, SYSDATE
    FROM #stg_parsed_events
    WHERE is_valid = FALSE;
    GET DIAGNOSTICS v_quarantine_count = ROW_COUNT;

    -- Step 3: Promote clean, deduplicated records to Silver Layer (Idempotent MERGE)
    MERGE INTO silver_customers
    USING (
        SELECT user_id, customer_name, email, age, country::CHAR(2) AS country
        FROM #stg_parsed_events
        WHERE is_valid = TRUE
    ) s
    ON silver_customers.user_id = s.user_id
    WHEN MATCHED THEN
        UPDATE SET 
            customer_name = s.customer_name,
            email         = s.email,
            age           = s.age,
            country       = s.country,
            promoted_at   = SYSDATE
    WHEN NOT MATCHED THEN
        INSERT (user_id, customer_name, email, age, country, promoted_at)
        VALUES (s.user_id, s.customer_name, s.email, s.age, s.country, SYSDATE);
    GET DIAGNOSTICS v_clean_count = ROW_COUNT;

    RAISE INFO 'Bronze-to-Silver Pipeline finished: % promoted clean, % quarantined.', 
        v_clean_count, v_quarantine_count;

EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'prc_pipeline_bronze_to_silver failed: %', SQLERRM;
END;
$$;


-- ===================================================================================
-- 3. USAGE & MEDALLION VERIFICATION
-- ===================================================================================

-- (a) Execute cleansing pipeline:
-- CALL prc_pipeline_bronze_to_silver();

-- (b) Check Silver Clean Customers (Only 101 and 104 promoted):
-- SELECT * FROM silver_customers ORDER BY user_id;

-- (c) Check Quarantine Table (102 and 103 quarantined with exact error reasons):
-- SELECT * FROM silver_quarantine_records ORDER BY quarantine_id;

-- (d) Explain Plan for Silver Promotion MERGE:
EXPLAIN
MERGE INTO silver_customers
USING (SELECT 101::BIGINT AS user_id, 'Alice' AS customer_name, 'a@a.com' AS email, 30 AS age, 'US'::CHAR(2) AS country) s
ON silver_customers.user_id = s.user_id
WHEN MATCHED THEN UPDATE SET customer_name = s.customer_name
WHEN NOT MATCHED THEN INSERT (user_id, customer_name, email, age, country, promoted_at)
VALUES (s.user_id, s.customer_name, s.email, s.age, s.country, SYSDATE);
