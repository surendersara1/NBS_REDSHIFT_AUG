/*
======================================================================================
MODULE 21: IDEMPOTENCY AND WATERMARKS
======================================================================================
MAPPED BEST PRACTICES (from PROCEDURE_OPTIMIZATION_BEST_PRACTICES_MASTER_FILE.md):
- Practice 40: Use a reliable watermark — track the last successfully processed batch/timestamp.
- Practice 42: Make loads idempotent — re-running the same range produces the exact same state.
- Practice 43: Avoid duplicate records on retries — use deterministic keys and merge logic.
- Practice 46: Do not advance watermarks/pipeline state until target load has succeeded.
- Practice 47: Keep incremental logic deterministic.

TARGET AUDIENCE: Application Developers transitioning to Redshift
BUSINESS SCENARIO: 
We have a daily pipeline that ingests raw server logs into `fct_web_logs`. 
An external scheduler (e.g. Airflow / EventBridge / Step Functions) triggers the load. 
Due to a transient network timeout, the scheduler retried the job immediately.

THE PROBLEM:
If the pipeline blindly runs `INSERT INTO target SELECT ...`, retries duplicate all rows. 
Downstream dashboards report 200% of actual web traffic and double the revenue. 
In OLTP databases, developers use unique constraints or row-by-row lookups. 
In Redshift, unique constraints are NOT enforced, and row-by-row lookups are catastrophic.

THE GOAL:
1. Make every pipeline idempotent: running it 1 time or 10 times yields the exact same state.
2. Use bounded watermarks (`p_batch_date`) with a localized DELETE-before-INSERT or MERGE.
3. Align the target table's SORTKEY with the watermark to turn the pre-purge into an instant seek.
======================================================================================
*/

-- ===================================================================================
-- 1. DATA GENERATION BLOCK (Run this to set up the scenario)
-- ===================================================================================
DROP TABLE IF EXISTS stg_web_logs CASCADE;
CREATE TABLE stg_web_logs (
    log_id BIGINT NOT NULL ENCODE az64,
    batch_date DATE NOT NULL ENCODE az64,
    url_path VARCHAR(255) NOT NULL ENCODE zstd,
    response_time INT NOT NULL ENCODE az64
)
DISTSTYLE KEY
DISTKEY (log_id);

-- Generate 100,000 log records for today's batch
INSERT INTO stg_web_logs (log_id, batch_date, url_path, response_time)
SELECT 
    s.n AS log_id,
    '2026-08-15'::DATE AS batch_date,
    CASE WHEN (s.n % 4) = 0 THEN '/home'
         WHEN (s.n % 4) = 1 THEN '/products'
         WHEN (s.n % 4) = 2 THEN '/cart'
         ELSE '/checkout' END AS url_path,
    (50 + (s.n % 450))::INT AS response_time
FROM (
    SELECT ROW_NUMBER() OVER () AS n
    FROM (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) a
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) b
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) c
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) d
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) e
    LIMIT 100000
) s;

ANALYZE stg_web_logs;

DROP TABLE IF EXISTS fct_web_logs CASCADE;
CREATE TABLE fct_web_logs (
    log_id BIGINT NOT NULL ENCODE az64,
    batch_date DATE NOT NULL ENCODE az64,
    url_path VARCHAR(255) NOT NULL ENCODE zstd,
    response_time INT NOT NULL ENCODE az64,
    inserted_at TIMESTAMP DEFAULT SYSDATE ENCODE az64
)
DISTSTYLE KEY
DISTKEY (log_id)
COMPOUND SORTKEY (batch_date, log_id);


-- ===================================================================================
-- 2. THE "BAD" PROCEDURE (The App Dev Way / Anti-Pattern)
-- ===================================================================================
/*
WHY IT'S BAD:
- Blind append: It performs an unconstrained `INSERT INTO ... SELECT`.
- Non-idempotent: If Airflow retries after a network blip, all 100,000 rows are duplicated.
- Redshift's optimizer cannot prevent this because PRIMARY KEY / UNIQUE are not enforced.
*/
CREATE OR REPLACE PROCEDURE prc_bad_load_web_logs(p_batch_date DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE INFO 'Executing non-idempotent blind insert...';
    
    INSERT INTO fct_web_logs (log_id, batch_date, url_path, response_time, inserted_at)
    SELECT log_id, batch_date, url_path, response_time, SYSDATE
    FROM stg_web_logs
    WHERE batch_date = p_batch_date;
    
    RAISE INFO 'Load complete.';
END;
$$;


-- ===================================================================================
-- 3. THE "GOOD" PROCEDURE (The Redshift MPP Way / Best Practice)
-- ===================================================================================
/*
WHY IT'S GOOD:
- Enforces strict input validation before executing DML (Practice 11).
- Uses a deterministic watermark (`batch_date = p_batch_date`) to clear prior runs.
- Because `batch_date` is the leading column of `COMPOUND SORTKEY`, the `DELETE` uses
  Zone Map block skipping (is_rrscan = true) and scans ONLY the matching date's blocks.
- The entire operation runs atomically; re-running 10 times produces the exact same row count.
*/
CREATE OR REPLACE PROCEDURE prc_good_load_web_logs(p_batch_date DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_deleted  BIGINT := 0;
    v_inserted BIGINT := 0;
BEGIN
    -- 1. Validate parameter
    IF p_batch_date IS NULL THEN
        RAISE EXCEPTION 'Validation Failed: p_batch_date cannot be NULL.';
    END IF;

    -- 2. Watermark Pre-Purge (Idempotency Guard)
    DELETE FROM fct_web_logs
    WHERE batch_date = p_batch_date;
    GET DIAGNOSTICS v_deleted = ROW_COUNT;

    -- 3. Set-Based Bulk Ingestion
    INSERT INTO fct_web_logs (log_id, batch_date, url_path, response_time, inserted_at)
    SELECT log_id, batch_date, url_path, response_time, SYSDATE
    FROM stg_web_logs
    WHERE batch_date = p_batch_date;
    GET DIAGNOSTICS v_inserted = ROW_COUNT;

    RAISE INFO 'Idempotent load complete for %: % deleted, % inserted.', 
        p_batch_date, v_deleted, v_inserted;

EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'prc_good_load_web_logs failed for batch %: %', p_batch_date, SQLERRM;
END;
$$;


-- ===================================================================================
-- 4. USAGE, VERIFICATION & IDEMPOTENCY PROOF
-- ===================================================================================

-- (a) Test Bad Procedure (Simulate retry failure):
-- TRUNCATE TABLE fct_web_logs;
-- CALL prc_bad_load_web_logs('2026-08-15'::DATE);
-- CALL prc_bad_load_web_logs('2026-08-15'::DATE); -- Retry
-- SELECT COUNT(1) AS bad_row_count FROM fct_web_logs; 
-- --> Yields 200,000 rows (DUPLICATED DATA BUG!)

-- (b) Test Good Procedure (Simulate retry success):
-- TRUNCATE TABLE fct_web_logs;
-- CALL prc_good_load_web_logs('2026-08-15'::DATE);
-- CALL prc_good_load_web_logs('2026-08-15'::DATE); -- Retry
-- SELECT COUNT(1) AS good_row_count FROM fct_web_logs; 
-- --> Yields exactly 100,000 rows (PERFECTLY IDEMPOTENT!)

-- (c) Execution Plan Verification:
-- Notice how the DELETE leverages the Zone Map on batch_date
EXPLAIN
DELETE FROM fct_web_logs WHERE batch_date = '2026-08-15'::DATE;
