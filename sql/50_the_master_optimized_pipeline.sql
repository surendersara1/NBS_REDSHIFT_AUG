/*
======================================================================================
MODULE 50: THE GRAND FINALE — THE MASTER OPTIMIZED ENTERPRISE PIPELINE
======================================================================================
MAPPED BEST PRACTICES (from PROCEDURE_OPTIMIZATION_BEST_PRACTICES_MASTER_FILE.md):
- Practice 11-15: Strict Input Validation & Failing Early.
- Practice 16: Never SELECT * — select explicit typed columns.
- Practice 18-19: Sargable half-open timestamp range filtering (preserving Zone Maps).
- Practice 26, 79: Staging in collocated #TEMP tables with ON COMMIT DROP and explicit ANALYZE.
- Practice 29: Collocated Distribution Keys (DISTKEY account_id).
- Practice 42: Complete Idempotency (Watermark purge before load).
- Practice 62: Refreshing target statistics (ANALYZE).
- Practice 80-87: Atomic Transaction boundaries, ROW_COUNT extraction, and rich error propagation.
- Practice 97-99: End-to-end Audit Logging.

TARGET AUDIENCE: Application Developers transitioning to Redshift
BUSINESS SCENARIO: 
You are tasked with engineering the single most critical, mission-critical data warehouse pipeline: 
the Billing Settlement Fact Ingestion (`fct_billing_settlement`). 
Millions of dollars in revenue reporting depend on this pipeline being 100% accurate, idempotent, 
and blindingly fast.

THE GOAL:
Combine all 112 best practices into a single, flawless, production-grade template that serves 
as the reference implementation for every data engineering pipeline across the enterprise.
======================================================================================
*/

-- ===================================================================================
-- 1. DATA GENERATION BLOCK (Landing and Fact Tables)
-- ===================================================================================
DROP TABLE IF EXISTS raw_billing_landing CASCADE;
CREATE TABLE raw_billing_landing (
    invoice_id BIGINT NOT NULL ENCODE az64,
    account_id BIGINT NOT NULL ENCODE az64,
    billing_date DATE NOT NULL ENCODE az64,
    amount DECIMAL(14,2) NOT NULL ENCODE az64,
    currency CHAR(3) NOT NULL ENCODE bytedict,
    payment_status VARCHAR(20) NOT NULL ENCODE bytedict
)
DISTSTYLE KEY
DISTKEY (account_id)
COMPOUND SORTKEY (billing_date, account_id);

-- Populate 100,000 billing records for today
INSERT INTO raw_billing_landing (invoice_id, account_id, billing_date, amount, currency, payment_status)
SELECT 
    s.n AS invoice_id,
    (s.n % 10000 + 1) AS account_id,
    '2026-08-15'::DATE AS billing_date,
    (25.00 + (s.n % 1500))::DECIMAL(14,2) AS amount,
    'USD' AS currency,
    CASE WHEN (s.n % 20) = 0 THEN 'PENDING' ELSE 'SETTLED' END AS payment_status
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

ANALYZE raw_billing_landing;

DROP TABLE IF EXISTS fct_billing_settlement CASCADE;
CREATE TABLE fct_billing_settlement (
    invoice_id BIGINT NOT NULL ENCODE az64,
    account_id BIGINT NOT NULL ENCODE az64,
    billing_date DATE NOT NULL ENCODE raw, -- Sort key: raw for fastest range pruning
    amount DECIMAL(14,2) NOT NULL ENCODE az64,
    currency CHAR(3) NOT NULL ENCODE bytedict,
    payment_status VARCHAR(20) NOT NULL ENCODE bytedict,
    loaded_at TIMESTAMP DEFAULT SYSDATE ENCODE az64,
    PRIMARY KEY (invoice_id)
)
DISTSTYLE KEY
DISTKEY (account_id)
COMPOUND SORTKEY (billing_date, account_id);

DROP TABLE IF EXISTS master_pipeline_audit CASCADE;
CREATE TABLE master_pipeline_audit (
    audit_id BIGINT IDENTITY(1,1),
    procedure_name VARCHAR(100) NOT NULL,
    batch_date DATE NOT NULL,
    start_time TIMESTAMP NOT NULL,
    end_time TIMESTAMP NOT NULL,
    duration_ms BIGINT NOT NULL,
    rows_deleted BIGINT NOT NULL,
    rows_inserted BIGINT NOT NULL,
    status VARCHAR(20) NOT NULL
);


-- ===================================================================================
-- 2. THE MASTER PRODUCTION-GRADE STORED PROCEDURE
-- ===================================================================================
CREATE OR REPLACE PROCEDURE prc_master_optimized_billing_pipeline(p_process_date DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_proc_name     VARCHAR(100) := 'prc_master_optimized_billing_pipeline';
    v_proc_start    TIMESTAMP;
    v_step_start    TIMESTAMP;
    v_rows_deleted  BIGINT := 0;
    v_rows_inserted BIGINT := 0;
    v_err_msg       VARCHAR(1000);
BEGIN
    v_proc_start := SYSDATE;
    RAISE INFO '[%] Starting master billing pipeline for batch date: % ...', v_proc_name, p_process_date;

    -- ===============================================================================
    -- PHASE 1: FAIL-EARLY INPUT VALIDATION (Practices 11, 12, 13, 15)
    -- ===============================================================================
    IF p_process_date IS NULL THEN
        RAISE EXCEPTION 'Validation Error: p_process_date cannot be NULL.';
    END IF;

    IF p_process_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'Validation Error: Cannot process future date (%).', p_process_date;
    END IF;

    -- ===============================================================================
    -- PHASE 2: PRIVATE STAGING WITH COLLOCATED DISTKEY & STATS (Practices 26, 29, 79)
    -- ===============================================================================
    v_step_start := SYSDATE;
    
    CREATE TEMP TABLE #stg_billing_validated (
        invoice_id BIGINT NOT NULL,
        account_id BIGINT NOT NULL,
        billing_date DATE NOT NULL,
        amount DECIMAL(14,2) NOT NULL,
        currency CHAR(3) NOT NULL,
        payment_status VARCHAR(20) NOT NULL
    )
    DISTSTYLE KEY
    DISTKEY (account_id) -- Collocated with target table to ensure DS_DIST_NONE!
    ON COMMIT DROP;      -- Automatic lifecycle cleanup (Practice 26, 45)

    -- Sargable filter extraction:
    INSERT INTO #stg_billing_validated (invoice_id, account_id, billing_date, amount, currency, payment_status)
    SELECT invoice_id, account_id, billing_date, amount, currency, payment_status
    FROM raw_billing_landing
    WHERE billing_date = p_process_date;

    -- Refresh statistics on temp table immediately before join/merge (Practice 62, 79):
    ANALYZE #stg_billing_validated;
    RAISE INFO 'Staging complete in % ms.', DATEDIFF(ms, v_step_start, SYSDATE);

    -- ===============================================================================
    -- PHASE 3: IDEMPOTENCY & SET-BASED LOAD (Practices 27, 42, 44)
    -- ===============================================================================
    v_step_start := SYSDATE;

    -- Step A: Range-restricted watermark purge (Zone Maps skip non-matching blocks)
    DELETE FROM fct_billing_settlement
    WHERE billing_date = p_process_date;
    GET DIAGNOSTICS v_rows_deleted = ROW_COUNT;

    -- Step B: Collocated set-based bulk insert (DS_DIST_NONE)
    INSERT INTO fct_billing_settlement (
        invoice_id, account_id, billing_date, amount, currency, payment_status, loaded_at
    )
    SELECT invoice_id, account_id, billing_date, amount, currency, payment_status, SYSDATE
    FROM #stg_billing_validated;
    GET DIAGNOSTICS v_rows_inserted = ROW_COUNT;

    RAISE INFO 'DML complete in % ms: % deleted, % inserted.', 
        DATEDIFF(ms, v_step_start, SYSDATE), v_rows_deleted, v_rows_inserted;

    -- ===============================================================================
    -- PHASE 4: TARGET STATISTICS REFRESH (Practice 62)
    -- ===============================================================================
    ANALYZE fct_billing_settlement;

    -- ===============================================================================
    -- PHASE 5: PERSISTENT AUDIT LOGGING (Practices 97, 98, 99)
    -- ===============================================================================
    INSERT INTO master_pipeline_audit (
        procedure_name, batch_date, start_time, end_time, duration_ms, rows_deleted, rows_inserted, status
    ) VALUES (
        v_proc_name, p_process_date, v_proc_start, SYSDATE, DATEDIFF(ms, v_proc_start, SYSDATE), 
        v_rows_deleted, v_rows_inserted, 'SUCCESS'
    );

    RAISE INFO '[%] Finished successfully in % ms.', v_proc_name, DATEDIFF(ms, v_proc_start, SYSDATE);

EXCEPTION WHEN OTHERS THEN
    v_err_msg := SUBSTRING(SQLERRM, 1, 950);
    RAISE EXCEPTION '[FATAL ERROR in %] Batch Date [%]: %', v_proc_name, p_process_date, v_err_msg;
END;
$$;


-- ===================================================================================
-- 3. USAGE & AUDIT VERIFICATION
-- ===================================================================================

-- (a) Execute master pipeline:
-- CALL prc_master_optimized_billing_pipeline('2026-08-15'::DATE);

-- (b) Check audit metrics:
-- SELECT * FROM master_pipeline_audit ORDER BY start_time DESC LIMIT 5;

-- (c) Verify fact table row count and distribution:
-- SELECT COUNT(1) FROM fct_billing_settlement WHERE billing_date = '2026-08-15'::DATE;

-- (d) Explain Plan: Collocated Insert with Zero Network Movement (DS_DIST_NONE):
EXPLAIN
INSERT INTO fct_billing_settlement (invoice_id, account_id, billing_date, amount, currency, payment_status, loaded_at)
SELECT invoice_id, account_id, billing_date, amount, currency, payment_status, SYSDATE
FROM raw_billing_landing
WHERE billing_date = '2026-08-15'::DATE;

-- (e) Inspect Slice-Level Parallel Execution in SYS_QUERY_DETAIL:
SELECT query_id, slice, step_name, is_rrscan, is_diskbased, input_rows, output_rows
FROM sys_query_detail
WHERE query_id = pg_last_query_id()
ORDER BY slice, step_name;
