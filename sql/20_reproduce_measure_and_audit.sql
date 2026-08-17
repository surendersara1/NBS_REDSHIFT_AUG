/*
======================================================================================
MODULE 20: REPRODUCE, MEASURE, AND AUDIT
======================================================================================
MAPPED BEST PRACTICES (from PROCEDURE_OPTIMIZATION_BEST_PRACTICES_MASTER_FILE.md):
- Practice 1: Reproduce reliably — get a repeatable test case before changing anything.
- Practice 2: Measure before you change anything — capture baseline runtime and EXPLAIN plan.
- Practice 97: Record rows inserted/updated/deleted (ROW_COUNT) for every load.
- Practice 98: Log execution duration to track performance trends and regressions over time.
- Practice 99: Log the processed date/batch window so every execution is traceable.
- Practice 101: Emit metrics/logs and alarm on failures — a silent failure is technical debt.

TARGET AUDIENCE: Application Developers transitioning to Redshift
BUSINESS SCENARIO: 
We have a daily batch job that loads dimension data into `dim_customer`. 
Occasionally, business users report that dashboards are slow or data is stale. 
When asked "how long did the job take yesterday and how many rows were inserted vs deleted?", 
the developer has no data because logging was purely `console.log` / `RAISE INFO`.

THE PROBLEM:
`RAISE INFO` messages evaporate once the database session closes. 
External orchestrator logs (Airflow/CloudWatch) only record cluster entry and exit times, 
obscuring which internal step (e.g. staging extract, deduplication, delete, insert) 
consumed 95% of execution time. 
Without persistent audit logging, capacity planning and regression triage are impossible.

THE GOAL:
1. Establish a persistent, schema-managed `etl_audit_log` table.
2. Instrument every sub-step with `SYSDATE` duration tracking and `ROW_COUNT` extraction.
3. Provide analytical queries over the audit log to benchmark optimizations before vs after.
======================================================================================
*/

-- ===================================================================================
-- 1. DATA GENERATION BLOCK (Run this to set up the scenario)
-- ===================================================================================
DROP TABLE IF EXISTS etl_audit_log CASCADE;
CREATE TABLE etl_audit_log (
    log_id BIGINT IDENTITY(1,1) NOT NULL ENCODE az64,
    procedure_name VARCHAR(100) NOT NULL ENCODE zstd,
    step_name VARCHAR(255) NOT NULL ENCODE zstd,
    batch_window VARCHAR(100) ENCODE zstd,
    start_time TIMESTAMP NOT NULL ENCODE az64,
    end_time TIMESTAMP NOT NULL ENCODE az64,
    duration_ms BIGINT NOT NULL ENCODE az64,
    rows_affected BIGINT NOT NULL ENCODE az64,
    status VARCHAR(20) NOT NULL ENCODE bytedict,
    error_message VARCHAR(1000) ENCODE zstd
)
DISTSTYLE EVEN
COMPOUND SORTKEY (procedure_name, start_time);

DROP TABLE IF EXISTS source_customer_updates CASCADE;
CREATE TABLE source_customer_updates (
    customer_id INT NOT NULL ENCODE az64,
    customer_name VARCHAR(100) NOT NULL ENCODE zstd,
    segment VARCHAR(50) NOT NULL ENCODE bytedict,
    status VARCHAR(20) NOT NULL ENCODE bytedict,
    updated_at TIMESTAMP NOT NULL ENCODE az64
)
DISTSTYLE KEY
DISTKEY (customer_id);

-- Generate 100,000 incoming customer records
INSERT INTO source_customer_updates (customer_id, customer_name, segment, status, updated_at)
SELECT 
    s.n AS customer_id,
    'Customer_' || s.n::VARCHAR AS customer_name,
    CASE WHEN s.n % 3 = 0 THEN 'Enterprise' WHEN s.n % 3 = 1 THEN 'Mid-Market' ELSE 'SMB' END AS segment,
    CASE WHEN s.n % 10 = 0 THEN 'INACTIVE' ELSE 'ACTIVE' END AS status,
    DATEADD(minute, -(s.n % 1440), '2026-08-15 00:00:00'::TIMESTAMP) AS updated_at
FROM (
    SELECT ROW_NUMBER() OVER () AS n
    FROM (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) a
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) b
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) c
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) d
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) e
    LIMIT 100000
) s;

ANALYZE source_customer_updates;

DROP TABLE IF EXISTS dim_customer CASCADE;
CREATE TABLE dim_customer (
    customer_id INT NOT NULL ENCODE az64,
    customer_name VARCHAR(100) NOT NULL ENCODE zstd,
    segment VARCHAR(50) NOT NULL ENCODE bytedict,
    status VARCHAR(20) NOT NULL ENCODE bytedict,
    updated_at TIMESTAMP NOT NULL ENCODE az64
)
DISTSTYLE KEY
DISTKEY (customer_id)
COMPOUND SORTKEY (customer_id);


-- ===================================================================================
-- 2. THE "BAD" PROCEDURE (The App Dev Way / Anti-Pattern)
-- ===================================================================================
/*
WHY IT'S BAD:
- Zero persistent metrics: Relying exclusively on `RAISE INFO` prints to standard output,
  which disappears when the connection closes.
- Inefficient unindexed `IN (SELECT...)` subquery: Forces Redshift to materialize customer IDs
  into leader memory before broadcasting.
- No visibility into step durations: If the pipeline runs 2 hours, there is no way to know
  whether the DELETE or the INSERT caused the slowdown.
*/
CREATE OR REPLACE PROCEDURE prc_bad_load_customers()
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE INFO 'Starting customer load at %', GETDATE();
    
    -- Step 1: Inefficient delete using IN list
    DELETE FROM dim_customer 
    WHERE customer_id IN (SELECT customer_id FROM source_customer_updates);
    
    -- Step 2: Insert new records
    INSERT INTO dim_customer (customer_id, customer_name, segment, status, updated_at)
    SELECT customer_id, customer_name, segment, status, GETDATE()
    FROM source_customer_updates;
    
    RAISE INFO 'Finished customer load at %', GETDATE();
END;
$$;


-- ===================================================================================
-- 3. THE "GOOD" PROCEDURE (The Redshift MPP Way / Best Practice)
-- ===================================================================================
/*
WHY IT'S GOOD:
- Granular instrumentation: Captures `v_step_start` before each phase and logs exact milliseconds.
- USES `GETDATE()`, NOT `SYSDATE`. This is the single most important detail in this module.
  A procedure body runs inside ONE transaction, and `SYSDATE` returns the start time of the
  *transaction*, not of the current statement -- so every `SYSDATE` in this procedure would
  return the identical value and every `duration_ms` would be logged as 0. `GETDATE()`
  returns the start of the current *statement* even inside a transaction block, which is
  what makes per-step timing possible at all.
- `GET DIAGNOSTICS ... ROW_COUNT`: Extracts exact database modifications per operation (Practice 97).
- Persistent audit tracking: Logs each step directly into `etl_audit_log` (Practice 98, 99).
- Collocated `USING` join for DELETE: Eliminates `IN (SELECT ...)` subplan materialization.
- Error preservation: Catches SQL errors, logs the failing step to `etl_audit_log`, and re-raises with context.
*/
CREATE OR REPLACE PROCEDURE prc_good_load_customers(p_batch_window VARCHAR(100))
LANGUAGE plpgsql
AS $$
DECLARE
    v_proc_name     VARCHAR(100) := 'prc_good_load_customers';
    v_step_name     VARCHAR(255);
    v_step_start    TIMESTAMP;
    v_rows_affected BIGINT := 0;
    v_err_msg       VARCHAR(1000);
BEGIN
    -- -------------------------------------------------------------------------------
    -- STEP 1: Collocated DELETE of existing keys
    -- -------------------------------------------------------------------------------
    v_step_name  := '1. Delete matched customer records';
    v_step_start := GETDATE();
    
    DELETE FROM dim_customer
    USING source_customer_updates s
    WHERE dim_customer.customer_id = s.customer_id;
    
    GET DIAGNOSTICS v_rows_affected = ROW_COUNT;
    
    INSERT INTO etl_audit_log (procedure_name, step_name, batch_window, start_time, end_time, duration_ms, rows_affected, status)
    VALUES (v_proc_name, v_step_name, p_batch_window, v_step_start, GETDATE(), DATEDIFF(ms, v_step_start, GETDATE()), v_rows_affected, 'SUCCESS');

    -- -------------------------------------------------------------------------------
    -- STEP 2: Set-based INSERT of new records
    -- -------------------------------------------------------------------------------
    v_step_name  := '2. Bulk insert updated customer records';
    v_step_start := GETDATE();
    
    INSERT INTO dim_customer (customer_id, customer_name, segment, status, updated_at)
    SELECT customer_id, customer_name, segment, status, updated_at
    FROM source_customer_updates;
    
    GET DIAGNOSTICS v_rows_affected = ROW_COUNT;
    
    INSERT INTO etl_audit_log (procedure_name, step_name, batch_window, start_time, end_time, duration_ms, rows_affected, status)
    VALUES (v_proc_name, v_step_name, p_batch_window, v_step_start, GETDATE(), DATEDIFF(ms, v_step_start, GETDATE()), v_rows_affected, 'SUCCESS');

    -- -------------------------------------------------------------------------------
    -- STEP 3: Refresh statistics after material modification (Practice 62)
    -- -------------------------------------------------------------------------------
    v_step_name  := '3. Analyze target table';
    v_step_start := GETDATE();
    
    ANALYZE dim_customer;
    
    INSERT INTO etl_audit_log (procedure_name, step_name, batch_window, start_time, end_time, duration_ms, rows_affected, status)
    VALUES (v_proc_name, v_step_name, p_batch_window, v_step_start, GETDATE(), DATEDIFF(ms, v_step_start, GETDATE()), 0, 'SUCCESS');

EXCEPTION WHEN OTHERS THEN
    v_err_msg := SUBSTRING(SQLERRM, 1, 990);
    RAISE EXCEPTION 'Procedure % failed during step [%]: %', v_proc_name, v_step_name, v_err_msg;
END;
$$;


-- ===================================================================================
-- 4. USAGE, VERIFICATION & AUDIT ANALYSIS
-- ===================================================================================

-- (a) Execute the instrumented procedure:
-- CALL prc_good_load_customers('2026-08-15_DAILY_BATCH');

-- (b) Query the Audit Log to inspect step durations and rows modified:
-- SELECT log_id, step_name, batch_window, duration_ms, rows_affected, status, start_time
-- FROM etl_audit_log
-- WHERE procedure_name = 'prc_good_load_customers'
-- ORDER BY start_time DESC;

-- (c) DBA Trend Analysis Query: Measure procedure performance over the last 30 runs
-- SELECT 
--     procedure_name,
--     step_name,
--     COUNT(1) AS total_runs,
--     AVG(duration_ms) AS avg_duration_ms,
--     MAX(duration_ms) AS max_duration_ms,
--     AVG(rows_affected) AS avg_rows_affected
-- FROM etl_audit_log
-- GROUP BY procedure_name, step_name
-- ORDER BY procedure_name, step_name;
