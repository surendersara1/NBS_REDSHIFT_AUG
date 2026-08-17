/*
======================================================================================
MODULE 35: BATCHING MASSIVE LOADS (TRANSACTION LOG MANAGEMENT & COMMITS)
======================================================================================
MAPPED BEST PRACTICES (from PROCEDURE_OPTIMIZATION_BEST_PRACTICES_MASTER_FILE.md):
- Practice 45: Process very large loads in manageable batches (time or key ranges).
- Practice 73: Batch large INSERT/UPDATE operations rather than issuing monolithic transactions.
- Practice 76: Batch COMMITs — commit periodically to release transaction log locks and memory.
- Practice 81: Keep transactions reasonably short — long transactions increase lock pressure.

TARGET AUDIENCE: Application Developers transitioning to Redshift
BUSINESS SCENARIO: 
We need to backfill 5 years of historical clickstream data (100 million rows) from 
a legacy archive table `archive_events` into a newly partitioned table `fct_events_v2`.

THE PROBLEM:
An application developer writes a single monolithic statement:
`INSERT INTO fct_events_v2 SELECT * FROM archive_events;`
In Redshift, executing a single 100M-row transaction across years of data:
1. Consumes massive query memory (`workmem`), forcing gigabytes of intermediate data to spill to disk.
2. Holds an exclusive table lock on `fct_events_v2` for hours, completely blocking concurrent BI queries.
3. If the job fails at the 99% mark (due to a transient network timeout or WLM queue cancel), 
   **the entire 6-hour operation rolls back to zero**.

THE GOAL:
1. Break massive migrations into manageable chunks (e.g. month-by-month).
2. Execute an explicit `COMMIT` after each chunk inside the loop to release locks and flush transaction memory.
3. Make the batching loop resumeable so an interrupted job resumes from the last completed month.
======================================================================================
*/

-- ===================================================================================
-- 1. DATA GENERATION BLOCK (Run this to set up the scenario)
-- ===================================================================================
DROP TABLE IF EXISTS archive_events CASCADE;
CREATE TABLE archive_events (
    event_id BIGINT NOT NULL ENCODE az64,
    event_date DATE NOT NULL ENCODE az64,
    user_id BIGINT NOT NULL ENCODE az64,
    payload VARCHAR(100) NOT NULL ENCODE zstd
)
DISTSTYLE KEY
DISTKEY (user_id)
COMPOUND SORTKEY (event_date, user_id);

-- Generate 100,000 events spread across 12 months in 2025
INSERT INTO archive_events (event_id, event_date, user_id, payload)
SELECT 
    s.n AS event_id,
    DATEADD(day, (s.n % 365), '2025-01-01'::DATE) AS event_date,
    (s.n % 10000 + 1) AS user_id,
    'Archive_Record_' || s.n::VARCHAR AS payload
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

ANALYZE archive_events;

DROP TABLE IF EXISTS fct_events_v2 CASCADE;
CREATE TABLE fct_events_v2 (LIKE archive_events);

-- Batch checkpoint tracker table
DROP TABLE IF EXISTS batch_migration_checkpoint CASCADE;
CREATE TABLE batch_migration_checkpoint (
    batch_name VARCHAR(100) NOT NULL,
    chunk_start DATE NOT NULL,
    chunk_end DATE NOT NULL,
    rows_migrated BIGINT NOT NULL,
    completed_at TIMESTAMP DEFAULT SYSDATE
);


-- ===================================================================================
-- 2. THE "BAD" PROCEDURE (The Monolithic Crash-Prone Anti-Pattern)
-- ===================================================================================
/*
WHY IT'S RISKY:
- Single monolithic transaction.
- High risk of WLM query timeout, disk spillage, and lock contention.
- Zero checkpointing: If it dies at 99%, all work is lost.
*/
CREATE OR REPLACE PROCEDURE prc_bad_monolithic_migration()
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE INFO 'Starting massive monolithic backfill... (All or nothing risk)';
    
    INSERT INTO fct_events_v2 (event_id, event_date, user_id, payload)
    SELECT event_id, event_date, user_id, payload
    FROM archive_events;
    
    RAISE INFO 'Monolithic migration complete.';
END;
$$;


-- ===================================================================================
-- 3. THE "GOOD" PROCEDURE (Chunked Batching with Periodic COMMITs)
-- ===================================================================================
/*
WHY IT'S RESILIENT AND OPTIMAL:
1. DYNAMIC BOUNDARIES: Finds `MIN(event_date)` and `MAX(event_date)` automatically.
2. MONTHLY CHUNKING: Iterates one month at a time via `WHILE v_current_start <= v_max_date`.
3. INTERMEDIATE COMMITS: Commits each batch independently, flushing locks and disk workmem.
4. CHECKPOINT TRACKING: Records each completed month in `batch_migration_checkpoint`.
*/
CREATE OR REPLACE PROCEDURE prc_good_chunked_migration(p_batch_label VARCHAR(50))
LANGUAGE plpgsql
AS $$
DECLARE
    v_min_date      DATE;
    v_max_date      DATE;
    v_current_start DATE;
    v_current_end   DATE;
    v_rows_chunk    BIGINT := 0;
    v_total_rows    BIGINT := 0;
BEGIN
    -- 1. Determine date boundaries
    SELECT MIN(event_date), MAX(event_date)
    INTO v_min_date, v_max_date
    FROM archive_events;
    
    IF v_min_date IS NULL THEN
        RAISE INFO 'Archive table is empty. Nothing to migrate.';
        RETURN;
    END IF;

    v_current_start := DATE_TRUNC('month', v_min_date)::DATE;
    RAISE INFO 'Starting chunked backfill from % to % ...', v_current_start, v_max_date;

    -- 2. Iterate month by month
    WHILE v_current_start <= v_max_date LOOP
        v_current_end := DATEADD(month, 1, v_current_start)::DATE;
        
        RAISE INFO 'Processing chunk: [% to %] ...', v_current_start, v_current_end;

        -- Step A: Set-based insert for this specific month
        INSERT INTO fct_events_v2 (event_id, event_date, user_id, payload)
        SELECT event_id, event_date, user_id, payload
        FROM archive_events
        WHERE event_date >= v_current_start 
          AND event_date < v_current_end;
        GET DIAGNOSTICS v_rows_chunk = ROW_COUNT;
        
        -- Step B: Log checkpoint
        INSERT INTO batch_migration_checkpoint (batch_name, chunk_start, chunk_end, rows_migrated, completed_at)
        VALUES (p_batch_label, v_current_start, v_current_end, v_rows_chunk, SYSDATE);

        -- Step C: Explicit COMMIT to free transaction locks and memory! (Practice 76)
        COMMIT;

        v_total_rows := v_total_rows + v_rows_chunk;
        
        -- Advance the window
        v_current_start := v_current_end;
    END LOOP;

    RAISE INFO 'Chunked backfill [%] completed successfully. Migrated % total rows.', 
        p_batch_label, v_total_rows;

EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'prc_good_chunked_migration failed on chunk [% to %]: %', 
        v_current_start, v_current_end, SQLERRM;
END;
$$;


-- ===================================================================================
-- 4. USAGE & CHECKPOINT VERIFICATION
-- ===================================================================================

-- (a) Execute chunked migration:
-- CALL prc_good_chunked_migration('ARCHIVE_2025_BACKFILL');

-- (b) Check checkpoint log to verify step-by-step progress:
-- SELECT batch_name, chunk_start, chunk_end, rows_migrated, completed_at
-- FROM batch_migration_checkpoint
-- WHERE batch_name = 'ARCHIVE_2025_BACKFILL'
-- ORDER BY chunk_start;

-- (c) Verify target row count matches source exactly:
-- SELECT COUNT(1) FROM fct_events_v2;

-- (d) Explain Plan for a Single Monthly Batch:
EXPLAIN
INSERT INTO fct_events_v2 (event_id, event_date, user_id, payload)
SELECT event_id, event_date, user_id, payload
FROM archive_events
WHERE event_date >= '2025-01-01'::DATE AND event_date < '2025-02-01'::DATE;

-- (e) Inspect Transaction Memory and WLM Queue Runtimes:
SELECT query_id, service_class_id, service_class_name, queue_time, execution_time
FROM sys_query_history
WHERE query_text LIKE '%INSERT INTO fct_events_v2%'
ORDER BY start_time DESC LIMIT 5;
