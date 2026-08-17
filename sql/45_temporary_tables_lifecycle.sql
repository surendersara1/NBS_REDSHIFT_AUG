/*
======================================================================================
MODULE 45: TEMPORARY TABLES LIFECYCLE & CATALOG BLOAT MANAGEMENT
======================================================================================
MAPPED BEST PRACTICES (from PROCEDURE_OPTIMIZATION_BEST_PRACTICES_MASTER_FILE.md):
- Practice 79: Stage into temp tables, and ANALYZE immediately before downstream joins.
- Practice 26: Drop temp tables explicitly before returning to prevent catalog leaks.
- Practice 81: Keep temporary session footprints lightweight.

TARGET AUDIENCE: Application Developers transitioning to Redshift
BUSINESS SCENARIO: 
An application uses a connection pool (e.g. HikariCP / generic JDBC pool with 20 persistent connections). 
Every minute, a microservice invokes a stored procedure that creates a temporary table `CREATE TEMP TABLE temp_batch (...)`.

THE PROBLEM:
App developers assume temporary tables evaporate when the stored procedure exits. 
**THEY DO NOT.** 
In Redshift, temporary tables persist until the **database connection is closed**. 
In connection-pooled microservice environments:
1. Connections stay open for weeks.
2. Thousands of lingering `#temp` tables accumulate in session temporary schemas (`pg_temp_*`).
3. The cluster catalog (`pg_class`, `pg_attribute`) bloats severely, slowing down query planning for all users.
4. Storage space consumed by forgotten temp tables triggers disk full alarms.

THE GOAL:
1. Understand the exact lifecycle of `#TEMP` tables in Redshift.
2. Make an explicit `DROP TABLE` before the procedure returns the mandatory standard.
   Redshift's CREATE TABLE grammar accepts NO `ON COMMIT` clause -- unlike PostgreSQL --
   so an explicit drop is the only mechanism available to bound the lifetime.
3. Query `pg_class` to audit lingering temporary tables and detect catalog bloat.
======================================================================================
*/

-- ===================================================================================
-- 1. DATA GENERATION & CATALOG INSPECTION (Run this to set up the scenario)
-- ===================================================================================

-- QUERY: How many temporary tables exist right now across all active sessions?
SELECT 
    n.nspname AS temp_schema_name,
    c.relname AS temp_table_name,
    c.relowner,
    c.reltuples AS estimated_rows
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname LIKE 'pg_temp_%'
ORDER BY n.nspname, c.relname;


-- ===================================================================================
-- 2. THE "BAD" PROCEDURE (Lingering Connection-Pool Leak Anti-Pattern)
-- ===================================================================================
/*
WHY IT CAUSES CATALOG BLOAT:
- Creates the temp table and simply returns, leaving it behind for the whole session.
- In a persistent connection pool, this table remains alive indefinitely in `pg_temp`.
- Over 10,000 executions, the cluster slows down due to catalog table fragmentation.
*/
CREATE OR REPLACE PROCEDURE prc_bad_temp_table_leak()
LANGUAGE plpgsql
AS $$
BEGIN
    -- DANGEROUS: Lingers in session until connection disconnects!
    DROP TABLE IF EXISTS #temp_leaky_table;
    CREATE TEMP TABLE #temp_leaky_table (
        id INT,
        data_val VARCHAR(100)
    );

    INSERT INTO #temp_leaky_table VALUES (1, 'Leaked memory in connection pool');
    RAISE INFO 'Bad temp table created without transaction-scoped lifecycle.';
END;
$$;


-- ===================================================================================
-- 3. THE "GOOD" PROCEDURE (Explicit Drop-Before-Return Best Practice)
-- ===================================================================================
/*
WHY IT'S 100% CLEAN & LEAK-PROOF:
1. THERE IS NO `ON COMMIT` IN REDSHIFT. Neither CREATE TABLE nor CREATE TABLE AS accepts
   an ON COMMIT clause. PostgreSQL has it; Redshift never inherited it. Writing
   `ON COMMIT DROP` is a syntax error, not a harmless no-op -- the procedure will not
   even be created. AWS states plainly that a Redshift temp table "is automatically
   dropped at the end of the session in which it was created", and the session is
   exactly what outlives you in a connection pool. That is the whole problem above.
2. EXPLICIT DROP ON THE WAY OUT: This is the only mechanism that actually bounds the
   lifetime and keeps `pg_temp_*` clean between connection-pool requests.
3. DROP ON THE WAY IN TOO: makes the procedure re-runnable on a pooled connection that
   may still be holding the previous call's table.
4. EXPLICIT ANALYZE: Analyzes the temp table so intermediate joins execute with optimal plans.
*/
CREATE OR REPLACE PROCEDURE prc_good_temp_table_lifecycle()
LANGUAGE plpgsql
AS $$
DECLARE
    v_count BIGINT := 0;
BEGIN
    -- Drop on the way IN: the pooled connection may still hold a previous call's table
    DROP TABLE IF EXISTS #temp_safe_lifecycle;

    CREATE TEMP TABLE #temp_safe_lifecycle (
        id INT NOT NULL,
        data_val VARCHAR(100) NOT NULL
    )
    DISTSTYLE EVEN;

    INSERT INTO #temp_safe_lifecycle (id, data_val)
    SELECT n, 'Clean Value ' || n::VARCHAR
    FROM (SELECT 1 AS n UNION SELECT 2 UNION SELECT 3) x;

    -- Refresh stats immediately
    ANALYZE #temp_safe_lifecycle;

    SELECT COUNT(1) INTO v_count FROM #temp_safe_lifecycle;

    -- BEST PRACTICE: drop on the way OUT. This is the step that actually bounds the
    -- lifetime. Without it the table survives until the connection closes, which in a
    -- pool may be weeks.
    DROP TABLE IF EXISTS #temp_safe_lifecycle;

    RAISE INFO 'Safe temp table processed % rows and was dropped before returning.', v_count;

EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'prc_good_temp_table_lifecycle failed: %', SQLERRM;
END;
$$;


-- ===================================================================================
-- 4. USAGE, VERIFICATION & EXPLAIN / CATALOG ANALYSIS
-- ===================================================================================

-- (a) Run Good Procedure:
-- CALL prc_good_temp_table_lifecycle();

-- (b) Check for lingering tables in pg_temp:
-- SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
-- WHERE n.nspname LIKE 'pg_temp_%';
