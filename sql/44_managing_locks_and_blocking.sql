/*
======================================================================================
MODULE 44: MANAGING LOCKS, BLOCKING, AND CONCURRENCY CONFLICTS
======================================================================================
MAPPED BEST PRACTICES (from PROCEDURE_OPTIMIZATION_BEST_PRACTICES_MASTER_FILE.md):
- Practice 81: Keep transactions reasonably short — long transactions increase locking pressure.
- Practice 80: Understand Redshift SERIALIZABLE isolation and table-level locks.
- Practice 104: Separate ETL/batch workloads from BI/dashboard queues.

TARGET AUDIENCE: Application Developers transitioning to Redshift
BUSINESS SCENARIO: 
An overnight ETL job runs a long transaction updating `fct_daily_sales`. 
Simultaneously, executive BI dashboards refresh their charts every 30 seconds. 
The ETL job hangs, BI queries time out with 504 Gateway errors, and the DBA sees 
**Transaction Serialization Conflicts (Error 1023)**.

THE PROBLEM:
In MySQL/Postgres, locking is row-level (RowShare / RowExclusive). 
In Redshift:
1. All transactions run under **SERIALIZABLE isolation**.
2. DML operations acquire **table-level locks** (`AccessExclusiveLock` or `WriteLock`).
3. An open transaction holding a lock blocks all concurrent writers and DDL statements.
4. If two concurrent transactions read and write to the same table in an overlapping window, 
   Redshift automatically aborts the second transaction with:
   `ERROR: 1023 DETAIL: Serializable isolation violation on table ...`

THE GOAL:
1. Query `SVV_TRANSACTIONS` to identify blocking PIDs and what they are waiting on.
2. Terminate hung backend sessions safely (`pg_terminate_backend`).
3. Implement short transaction boundaries and `SET statement_timeout` guardrails.
======================================================================================
*/

-- ===================================================================================
-- 1. DATA GENERATION & LOCK SIMULATION BLOCK
-- ===================================================================================
DROP TABLE IF EXISTS target_locked_table CASCADE;
CREATE TABLE target_locked_table (
    id INT NOT NULL,
    val VARCHAR(50) NOT NULL
)
DISTSTYLE EVEN;

INSERT INTO target_locked_table VALUES (1, 'Initial Data');

DROP TABLE IF EXISTS lock_incident_log CASCADE;
CREATE TABLE lock_incident_log (
    incident_id BIGINT IDENTITY(1,1),
    blocked_pid INT,
    blocking_pid INT,
    table_name VARCHAR(100),
    detected_at TIMESTAMP DEFAULT SYSDATE
);


-- ===================================================================================
-- 2. THE DBA LOCK TRIAGE TOOLKIT (System Queries)
-- ===================================================================================

-- NOTE ON WHICH VIEW TO USE:
-- SVV_TRANSACTIONS is the view AWS directs you to for lock contention, and it is
-- the only one carrying lock_mode / txn_start / relation / granted. STV_LOCKS has
-- just table_id, lock_owner, lock_owner_pid and lock_status -- and it is visible
-- to superusers only, so it is the wrong tool in a shared classroom cluster.

-- QUERY 1: Who is holding or waiting for a lock THIS INSTANT?
SELECT
    t.pid              AS blocking_pid,
    t.txn_owner        AS owner_user,
    t.txn_db           AS db_name,
    t.granted          AS lock_granted,     -- f = this transaction is WAITING
    t.lock_mode        AS lock_type,        -- 'AccessShareLock', 'ExclusiveLock', ...
    c.relname          AS table_name,
    DATEDIFF(second, t.txn_start, GETDATE()) AS txn_age_seconds
FROM svv_transactions t
-- LEFT JOIN: relation is NULL when lockable_object_type = 'transactionid'
LEFT JOIN pg_class c ON c.oid = t.relation
ORDER BY t.txn_start ASC;

-- QUERY 2: Find long-lived open transactions still holding their locks:
SELECT
    t.pid,
    t.txn_owner AS user_name,
    t.txn_start,
    DATEDIFF(minute, t.txn_start, GETDATE()) AS txn_age_minutes,
    t.lock_mode,
    t.lockable_object_type,
    c.relname AS table_name
FROM svv_transactions t
LEFT JOIN pg_class c ON c.oid = t.relation
WHERE t.granted = TRUE
ORDER BY t.txn_start ASC;

-- QUERY 3: Terminate a runaway blocking session (DBA Emergency Action):
-- SELECT pg_terminate_backend(<blocking_pid>);


-- ===================================================================================
-- 2. THE "BAD" PROCEDURE (The Unbounded Table Lock Anti-Pattern)
-- ===================================================================================
/*
WHY IT BLOCKS THE CLUSTER:
- Runs an unbounded long transaction with heavy transformations directly on target table.
- Holds AccessExclusiveLock for minutes, causing 504 Gateway Timeouts across BI dashboards.
*/
CREATE OR REPLACE PROCEDURE prc_bad_long_locking_load()
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE INFO 'Holding table lock for extended duration... (BI queries blocked!)';
END;
$$;


-- ===================================================================================
-- 3. THE "GOOD" PROCEDURE (The Staged Lock-Minimizing Best Practice)
-- ===================================================================================
/*
WHY IT MINIMIZES LOCK CONTENTION:
1. SET STATEMENT TIMEOUT: Aborts the query if it cannot acquire locks within 30 seconds,
   preventing the procedure from queueing behind long-running BI queries.
2. STAGED PREPARATION: All heavy calculations, transforms, and lookups occur in private `#TEMP` tables
   WITHOUT locking the target table.
3. MINIMAL LOCK WINDOW: The final `INSERT INTO target ...` takes milliseconds, holding the table lock
   for the shortest possible duration.
*/
CREATE OR REPLACE PROCEDURE prc_good_lock_optimized_load()
LANGUAGE plpgsql
AS $$
BEGIN
    -- 1. Guardrail: Never let a procedure hang indefinitely on a lock
    SET statement_timeout = 30000; -- 30 seconds

    RAISE INFO 'Preparing data in un-locked private temp table...';

    -- Heavy computation happens in temp space with zero table locks on permanent objects:
    DROP TABLE IF EXISTS #temp_lock_prep;
    CREATE TEMP TABLE #temp_lock_prep (id INT, val VARCHAR(50));

    INSERT INTO #temp_lock_prep (id, val)
    SELECT n, 'Calculated Value ' || n::VARCHAR
    FROM (SELECT 1 AS n UNION SELECT 2 UNION SELECT 3) x;

    -- Minimal Lock Window: The table lock is held for < 0.05 seconds!
    TRUNCATE TABLE target_locked_table;
    
    INSERT INTO target_locked_table (id, val)
    SELECT id, val FROM #temp_lock_prep;

    RAISE INFO 'Lock-optimized load complete.';

EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'prc_good_lock_optimized_load failed or timed out: %', SQLERRM;
END;
$$;


-- ===================================================================================
-- 4. USAGE, VERIFICATION & EXPLAIN / CATALOG ANALYSIS
-- ===================================================================================

-- (a) Execute procedure safely:
-- CALL prc_good_lock_optimized_load();
-- SELECT * FROM target_locked_table;
