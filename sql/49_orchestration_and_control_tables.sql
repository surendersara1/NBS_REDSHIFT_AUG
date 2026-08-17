/*
======================================================================================
MODULE 49: ORCHESTRATION, CONTROL TABLES, AND AUDIT DRIVERS
======================================================================================
MAPPED BEST PRACTICES (from PROCEDURE_OPTIMIZATION_BEST_PRACTICES_MASTER_FILE.md):
- Practice 95: Orchestrate dependencies, schedules, and retries with a workflow tool.
- Practice 98: Log execution duration to track performance trends and regressions over time.
- Practice 101: Emit metrics/logs and alarm on failures — a silent pipeline failure is technical debt.
- Practice 75: Avoid nested cursor loops (Redshift 1-cursor estate-wide limit).

TARGET AUDIENCE: Application Developers transitioning to Redshift
BUSINESS SCENARIO: 
We have a complex warehouse load consisting of 4 distinct pipeline stages:
1. `prc_pipeline_bronze_to_silver` (Cleansing)
2. `prc_pipeline_silver_to_gold_scd2` (Dimensions)
3. `prc_pipeline_silver_to_gold_fact` (Facts)
4. `prc_refresh_gold_materialized_views` (MVs)
We want a metadata-driven control framework (`ctrl_pipeline_orchestration`) to run 
each stage sequentially, track runtimes in `audit_pipeline_executions`, and abort on failure.

THE PROBLEM:
Hardcoding long monolithic procedures makes debugging impossible. 
Conversely, running cursor loops over procedures that contain other cursor loops triggers 
Redshift's **1 concurrent cursor estate-wide limit** (`ERROR: cursor ... already in use`).

THE GOAL:
1. Build a robust, metadata-driven control table structure.
2. Execute child stages dynamically with execution time tracking.
3. Propagate child exceptions to halt downstream dependencies cleanly.
======================================================================================
*/

-- ===================================================================================
-- 1. DATA GENERATION BLOCK (Control & Audit Tables)
-- ===================================================================================
DROP TABLE IF EXISTS ctrl_pipeline_orchestration CASCADE;
CREATE TABLE ctrl_pipeline_orchestration (
    job_id INT NOT NULL,
    stage_name VARCHAR(100) NOT NULL,
    procedure_call VARCHAR(255) NOT NULL,
    run_order INT NOT NULL,
    is_active BOOLEAN NOT NULL,
    PRIMARY KEY (job_id)
)
DISTSTYLE ALL;

-- Seed pipeline execution sequence
INSERT INTO ctrl_pipeline_orchestration VALUES 
(1, 'Bronze to Silver Cleansing', 'CALL prc_pipeline_bronze_to_silver()', 10, TRUE),
(2, 'Silver to Gold Dimensions',  'CALL prc_pipeline_silver_to_gold_scd2(''2026-08-15''::DATE)', 20, TRUE),
(3, 'Silver to Gold Facts',       'CALL prc_pipeline_silver_to_gold_fact(''2026-08-15''::DATE)', 30, TRUE);

DROP TABLE IF EXISTS audit_pipeline_executions CASCADE;
CREATE TABLE audit_pipeline_executions (
    execution_id BIGINT IDENTITY(1,1),
    pipeline_name VARCHAR(100) NOT NULL,
    stage_name VARCHAR(100) NOT NULL,
    start_time TIMESTAMP NOT NULL,
    end_time TIMESTAMP NOT NULL,
    duration_seconds INT NOT NULL,
    status VARCHAR(20) NOT NULL,
    error_message VARCHAR(1000)
)
DISTSTYLE EVEN
COMPOUND SORTKEY (start_time);


-- ===================================================================================
-- 2. THE PROCEDURE (Metadata-Driven Pipeline Orchestrator)
-- ===================================================================================
CREATE OR REPLACE PROCEDURE prc_master_pipeline_orchestrator(p_pipeline_name VARCHAR(100))
LANGUAGE plpgsql
AS $$
DECLARE
    rec              RECORD;
    v_stage_start    TIMESTAMP;
    v_stage_duration INT;
    v_err_msg        VARCHAR(1000);
BEGIN
    RAISE INFO '===================================================================';
    RAISE INFO 'Starting Metadata-Driven Pipeline: % ...', p_pipeline_name;
    RAISE INFO '===================================================================';

    -- Loop through active stages in sequence
    -- NOTE: Child procedures must NOT open explicit cursors to avoid cursor limits!
    FOR rec IN (
        SELECT job_id, stage_name, procedure_call 
        FROM ctrl_pipeline_orchestration 
        WHERE is_active = TRUE 
        ORDER BY run_order ASC
    ) LOOP
        v_stage_start := GETDATE();
        RAISE INFO 'Executing Stage [%]: % ...', rec.stage_name, rec.procedure_call;

        BEGIN
            -- Dynamically invoke the child procedure
            EXECUTE rec.procedure_call;
            
            v_stage_duration := DATEDIFF(second, v_stage_start, GETDATE());
            
            INSERT INTO audit_pipeline_executions (
                pipeline_name, stage_name, start_time, end_time, duration_seconds, status
            ) VALUES (
                p_pipeline_name, rec.stage_name, v_stage_start, GETDATE(), v_stage_duration, 'SUCCESS'
            );
            
            RAISE INFO 'Stage [%] completed in % seconds.', rec.stage_name, v_stage_duration;

        EXCEPTION WHEN OTHERS THEN
            v_err_msg := SUBSTRING(SQLERRM, 1, 950);
            v_stage_duration := DATEDIFF(second, v_stage_start, GETDATE());

            -- Actually record the failure. On entering an exception block Redshift rolls
            -- back the current transaction and starts a NEW one for the handler, commits
            -- it, and only then re-throws -- so this FAILED row survives the abort.
            -- Without it, the status and error_message columns are never populated for
            -- the one case they exist to record.
            INSERT INTO audit_pipeline_executions (
                pipeline_name, stage_name, start_time, end_time, duration_seconds, status, error_message
            ) VALUES (
                p_pipeline_name, rec.stage_name, v_stage_start, GETDATE(), v_stage_duration, 'FAILED', v_err_msg
            );

            -- Abort the orchestrator immediately to protect downstream data:
            RAISE EXCEPTION '[ORCHESTRATOR FATAL] Pipeline [%] halted at Stage [%]: %',
                p_pipeline_name, rec.stage_name, v_err_msg;
        END;

    END LOOP;

    RAISE INFO 'Master Pipeline [%] completed all stages successfully.', p_pipeline_name;

EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION '%', SQLERRM;
END;
$$;


-- ===================================================================================
-- 4. USAGE, VERIFICATION & EXPLAIN / CATALOG ANALYSIS
-- ===================================================================================

-- (a) Execute master orchestrator:
-- CALL prc_master_pipeline_orchestrator('NIGHTLY_MEDALLION_ETL');

-- (b) Check pipeline execution audit log:
SELECT execution_id, stage_name, start_time, duration_seconds, status
FROM audit_pipeline_executions
WHERE pipeline_name = 'NIGHTLY_MEDALLION_ETL'
ORDER BY start_time ASC;

-- (c) Performance SLA Trend Analysis (Practice 98):
SELECT stage_name, 
       COUNT(1) AS runs,
       ROUND(AVG(duration_seconds), 2) AS avg_duration_sec,
       MAX(duration_seconds) AS max_duration_sec
FROM audit_pipeline_executions
GROUP BY stage_name;
