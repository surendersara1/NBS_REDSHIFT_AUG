/*
======================================================================================
MODULE 43: VACUUM AND MAINTENANCE AUTOMATION
======================================================================================
MAPPED BEST PRACTICES (from PROCEDURE_OPTIMIZATION_BEST_PRACTICES_MASTER_FILE.md):
- Practice 64: Run VACUUM (or confirm auto-vacuum) to reclaim space and re-sort rows.
- Practice 65: Use targeted VACUUM DELETE ONLY / VACUUM SORT ONLY instead of a full VACUUM.
- Practice 66: Monitor SVV_TABLE_INFO for stats_off, unsorted %, size, and skew_rows.
- Practice 67: Schedule VACUUM/ANALYZE during low-traffic windows.
- Practice 18: Redshift PL/pgSQL limits: VACUUM CANNOT be run inside a stored procedure transaction.

TARGET AUDIENCE: Application Developers transitioning to Redshift
BUSINESS SCENARIO: 
We have a high-velocity fact table `fct_daily_events` where 100,000 rows are deleted 
(archived) and 100,000 new rows are appended every night. 
Over 3 months, table physical storage doubled from 10 GB to 20 GB even though the row count 
stayed identical, and query runtimes degraded from 1.5 seconds to 12 seconds.

THE PROBLEM:
1. In Redshift, `DELETE` does NOT release disk space — it creates "tombstones" (ghost rows). 
   The cluster continues reading deleted rows from disk during every subsequent query!
2. New inserts append to the end of the physical file, breaking the `SORTKEY` ordering.
3. App developers try to embed `VACUUM` inside a stored procedure, which **fails with a syntax error**:
   `ERROR: VACUUM cannot run inside a multi-command transaction or stored procedure`.

THE GOAL:
1. Understand the 4 types of VACUUM: `DELETE ONLY`, `SORT ONLY`, `FULL`, and `REINDEX`.
2. Inspect table fragmentation in `SVV_TABLE_INFO` (`unsorted`, `vacuum_sort_benefit`, `pct_used`).
3. Build external automation patterns (e.g. EventBridge + Lambda / Airflow / Data API) to trigger maintenance.
======================================================================================
*/

-- ===================================================================================
-- 1. DATA GENERATION BLOCK (Run this to set up the scenario)
-- ===================================================================================
DROP TABLE IF EXISTS fct_maintenance_demo CASCADE;
CREATE TABLE fct_maintenance_demo (
    event_id BIGINT NOT NULL ENCODE az64,
    event_date DATE NOT NULL ENCODE raw, -- Leading sort key
    user_id BIGINT NOT NULL ENCODE az64,
    payload VARCHAR(200) NOT NULL ENCODE zstd
)
DISTSTYLE KEY
DISTKEY (user_id)
COMPOUND SORTKEY (event_date);

-- Insert 100,000 sorted records
INSERT INTO fct_maintenance_demo (event_id, event_date, user_id, payload)
SELECT 
    s.n AS event_id,
    DATEADD(day, -(s.n % 30), '2026-08-15'::DATE) AS event_date,
    (s.n % 5000 + 1) AS user_id,
    'Event_Payload_Data_' || s.n::VARCHAR AS payload
FROM (
    SELECT ROW_NUMBER() OVER () AS n
    FROM (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) a
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) b
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) c
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) d
    CROSS JOIN (SELECT 0 UNION SELECT 1) e
    LIMIT 100000
) s;

ANALYZE fct_maintenance_demo;

-- SIMULATE FRAGMENTATION & TOMBSTONES:
-- 1. Delete 40,000 rows (creates tombstones)
DELETE FROM fct_maintenance_demo WHERE (event_id % 2) = 0;

-- 2. Insert 20,000 unsorted older dates at the physical end of the file
INSERT INTO fct_maintenance_demo (event_id, event_date, user_id, payload)
SELECT 
    (200000 + s.n),
    DATEADD(day, -(s.n % 180), '2026-01-01'::DATE), -- Out of order dates!
    (s.n % 5000 + 1),
    'Unsorted_Payload_' || s.n::VARCHAR
FROM (
    SELECT ROW_NUMBER() OVER () AS n
    FROM (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) a
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) b
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) c
    CROSS JOIN (SELECT 0 UNION SELECT 1) d
    LIMIT 20000
) s;


-- ===================================================================================
-- 2. DIAGNOSTIC CATALOG INSPECTION (SVV_TABLE_INFO)
-- ===================================================================================

-- Inspect fragmentation, unsorted %, and tombstone bloat:
SELECT 
    "schema",
    "table",
    size AS size_mb,
    tbl_rows,
    unsorted,              -- % of rows out of sort order (If > 10% -> VACUUM SORT)
    stats_off,             -- % staleness of stats (If > 10% -> ANALYZE)
    vacuum_sort_benefit,   -- Benefit score from running VACUUM SORT
    skew_rows              -- Slice skew ratio
FROM svv_table_info
WHERE "table" = 'fct_maintenance_demo';


-- ===================================================================================
-- 2. THE "BAD" PROCEDURE (The In-Transaction VACUUM Anti-Pattern)
-- ===================================================================================
/*
WHY IT FAILS:
- App developers try to embed `VACUUM` inside a PL/pgSQL stored procedure.
- Redshift throws `ERROR: VACUUM cannot run inside a multi-command transaction or stored procedure`.
*/
CREATE OR REPLACE PROCEDURE prc_bad_vacuum_inside_procedure()
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE INFO 'ERROR: VACUUM cannot run inside a stored procedure transaction. Trigger from external orchestrator!';
END;
$$;


-- ===================================================================================
-- 3. THE "GOOD" PROCEDURE (The Targeted Maintenance Best Practice)
-- ===================================================================================
/*
WHY TARGETED VACUUM IS 10x FASTER:
- Use `VACUUM DELETE ONLY` after large purges (sweeps tombstones without sorting).
- Use `VACUUM SORT ONLY` after large appends (sorts append region without vacuuming deletes).
- Execute from Airflow / Python Data API outside transaction blocks.
*/
CREATE OR REPLACE PROCEDURE prc_good_maintenance_guidance()
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE INFO 'Targeted maintenance: Run VACUUM DELETE ONLY or VACUUM SORT ONLY externally.';
END;
$$;


-- ===================================================================================
-- 4. USAGE, VERIFICATION & EXPLAIN / CATALOG ANALYSIS
-- ===================================================================================
/*
-- Python Automation Pattern (AWS Lambda / Airflow PythonOperator):
import boto3

client = boto3.client('redshift-data')

def run_redshift_maintenance(table_name):
    # VACUUM must run in its own statement outside an explicit transaction block
    response = client.execute_statement(
        ClusterIdentifier='nbs-coaching-dev',
        Database='coaching',
        SecretArn='arn:aws:secretsmanager:us-east-1:123456789012:secret:master',
        Sql=f'VACUUM DELETE ONLY {table_name};'
    )
    print(f"Triggered maintenance statement: {response['Id']}")
*/
