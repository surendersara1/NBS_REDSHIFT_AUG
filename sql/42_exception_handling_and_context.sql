/*
======================================================================================
MODULE 42: EXCEPTION HANDLING AND CONTEXT (PL/PGSQL ERROR TRAPPING)
======================================================================================
MAPPED BEST PRACTICES (from PROCEDURE_OPTIMIZATION_BEST_PRACTICES_MASTER_FILE.md):
- Practice 86: Handle exceptions intentionally — return useful errors rather than swallowing failures.
- Practice 87: Preserve failure context in errors — include procedure name, batch window, and SQLSTATE.
- Practice 101: Emit metrics/logs and alarm on failures — a silent pipeline failure is technical debt.

TARGET AUDIENCE: Application Developers transitioning to Redshift
BUSINESS SCENARIO: 
We have a critical batch procedure that transforms orders. 
During execution, a malformed string or arithmetic overflow occurs on row 45,000. 
The pipeline fails, and the on-call engineer is paged at 3:00 AM.

THE PROBLEM:
App developers often write empty exception blocks (`EXCEPTION WHEN OTHERS THEN NULL;`) 
to prevent jobs from failing in orchestrators, silently corrupting the data warehouse. 
Alternatively, they catch the error but throw away the `SQLSTATE` and contextual variable values, 
leaving zero clues as to which exact step, table, or parameter failed.

THE GOAL:
1. Capture both `SQLSTATE` (standard 5-character ANSI error code) and `SQLERRM` (error message).
2. Understand Redshift's single transaction scope: Why DML inside an `EXCEPTION` block fails if the transaction is aborted.
3. Build rich error context strings that immediately pinpoint the failure cause.
======================================================================================
*/

-- ===================================================================================
-- 1. DATA GENERATION BLOCK (Run this to set up the scenario)
-- ===================================================================================
DROP TABLE IF EXISTS source_dirty_data CASCADE;
CREATE TABLE source_dirty_data (
    record_id INT,
    raw_amount VARCHAR(50)
);

INSERT INTO source_dirty_data VALUES 
(1, '100.50'),
(2, '250.00'),
(3, 'INVALID_AMOUNT'), -- <--- DIRTY STRING! Will fail cast to DECIMAL
(4, '400.00');

DROP TABLE IF EXISTS target_clean_data CASCADE;
CREATE TABLE target_clean_data (
    record_id INT,
    clean_amount DECIMAL(12,2)
);


-- ===================================================================================
-- 2. THE "BAD" PROCEDURE (The Swallowed Error Anti-Pattern)
-- ===================================================================================
/*
WHY IT'S CATASTROPHIC:
- Catches the exception and does NOTHING.
- The stored procedure exits with a return code of 0 (SUCCESS) to Airflow.
- The pipeline advances its watermark even though zero data was loaded!
*/
CREATE OR REPLACE PROCEDURE prc_bad_swallow_error()
LANGUAGE plpgsql
AS $$
BEGIN
    TRUNCATE TABLE target_clean_data;
    
    INSERT INTO target_clean_data (record_id, clean_amount)
    SELECT record_id, raw_amount::DECIMAL(12,2)
    FROM source_dirty_data;

EXCEPTION WHEN OTHERS THEN
    -- DANGEROUS ANTI-PATTERN: Swallowing the failure silently!
    RAISE INFO 'An error happened, but ignoring it...';
END;
$$;


-- ===================================================================================
-- 3. THE "GOOD" PROCEDURE (Context-Preserving Exception Handling)
-- ===================================================================================
/*
WHY IT'S ROBUST & ACTIONABLE:
1. EXTRACTS SQLSTATE: Captures `v_sqlstate` (e.g. `22P02` for invalid text representation).
2. PRESERVES PARAMETERS: Formats error message with the exact procedure name, step, and batch window.
3. RE-RAISES ERROR: Calls `RAISE EXCEPTION` so external orchestrators (Airflow/Step Functions) 
   catch the failure, halt dependent downstream pipelines, and trigger alarms.
*/
CREATE OR REPLACE PROCEDURE prc_good_contextual_error_handler(p_batch_id VARCHAR(50))
LANGUAGE plpgsql
AS $$
DECLARE
    v_proc_name VARCHAR(100) := 'prc_good_contextual_error_handler';
    v_step_name VARCHAR(100);
    v_err_msg   VARCHAR(1000);
    v_sqlstate  VARCHAR(10);
BEGIN
    -- -------------------------------------------------------------------------------
    -- STEP 1: Preparation
    -- -------------------------------------------------------------------------------
    v_step_name := '1. Truncate Target';
    TRUNCATE TABLE target_clean_data;

    -- -------------------------------------------------------------------------------
    -- STEP 2: Ingestion & Type Conversion
    -- -------------------------------------------------------------------------------
    v_step_name := '2. Ingest and Cast Dirty Data';
    
    INSERT INTO target_clean_data (record_id, clean_amount)
    SELECT record_id, raw_amount::DECIMAL(12,2)
    FROM source_dirty_data;

    RAISE INFO 'Data ingested successfully.';

EXCEPTION WHEN OTHERS THEN
    -- In Redshift PL/pgSQL, SQLSTATE and SQLERRM are automatically populated
    v_sqlstate := SQLSTATE;
    v_err_msg  := SUBSTRING(SQLERRM, 1, 800);
    
    -- Re-raise with full operational context for on-call engineers:
    RAISE EXCEPTION '[FATAL ERROR in %] Step: [%], Batch: [%], SQLSTATE: [%], Message: %', 
        v_proc_name, v_step_name, p_batch_id, v_sqlstate, v_err_msg;
END;
$$;


-- ===================================================================================
-- 4. USAGE, VERIFICATION & EXPLAIN / CATALOG ANALYSIS
-- ===================================================================================

-- (a) Test Bad Procedure (Returns "Success" silently!):
-- CALL prc_bad_swallow_error();
-- SELECT COUNT(1) FROM target_clean_data; -- 0 rows! (Silent failure)

-- (b) Test Good Procedure (Throws actionable error with full diagnostics):
-- CALL prc_good_contextual_error_handler('BATCH_2026_08_15');
-- Output:
-- ERROR: [FATAL ERROR in prc_good_contextual_error_handler] Step: [2. Ingest and Cast Dirty Data], 
-- Batch: [BATCH_2026_08_15], SQLSTATE: [22P02], Message: Invalid digit, Value 'I', Pos 0, Type: Decimal

-- (c) System Query History Error Inspection:
-- SYS_QUERY_HISTORY records the reason in error_message; there is no error_code
-- column. Failed statements are identified by status = 'failed'.
SELECT query_id, user_id, transaction_id, status, error_message
FROM sys_query_history
WHERE status = 'failed'
ORDER BY start_time DESC LIMIT 5;
