/*
======================================================================================
MODULE 31: COMPOUND VS INTERLEAVED SORT KEYS (AND AUTO SORT KEYS)
======================================================================================
MAPPED BEST PRACTICES (from PROCEDURE_OPTIMIZATION_BEST_PRACTICES_MASTER_FILE.md):
- Practice 8: SORT KEY -> ZONE MAPS skips blocks.
- Practice 52: Set sort keys on columns used in WHERE/JOIN/GROUP BY, typically date/timestamp.
- Practice 53: Use compound sort keys for a consistent leading filter column; reserve interleaved sort keys for multiple, equally-important filter columns (costly to maintain).
- Practice 64: Run VACUUM (or confirm auto-vacuum) to reclaim space and re-sort rows.
- Practice 65: Use targeted VACUUM SORT ONLY / VACUUM REINDEX when applicable.

TARGET AUDIENCE: Application Developers transitioning to Redshift
BUSINESS SCENARIO: 
We have a massive user activity tracking table `fct_user_activity` (1 billion events). 
Analysts execute two distinct types of queries:
- Query Type 1 (90% of traffic): `WHERE event_date = '2026-08-15' AND user_id = 4550` (Date + User)
- Query Type 2 (10% of traffic): `WHERE user_id = 4550` (User lookup across all historical time)

THE PROBLEM:
App developers coming from Postgres/SQL Server expect secondary B-Tree indexes (`CREATE INDEX idx_user ON ...`).
Redshift has NO secondary indexes. Physical sorting on disk is controlled exclusively by SORT KEYS:
1. **COMPOUND SORTKEY (col1, col2)**: Sorts hierarchical prefix order (col1 first, then col2). 
   Filtering on `col1` or `(col1, col2)` is blindingly fast. 
   Filtering on `col2` alone performs a 100% full table scan!
2. **INTERLEAVED SORTKEY (col1, col2)**: Gives equal weight to both columns using Z-order multidimensional curves.
   Filtering on `col2` alone is fast, BUT:
   - Ingesting new data scatters blocks across disk.
   - Restoring sort order requires `VACUUM REINDEX`, which takes **10x to 50x longer and consumes massive cluster I/O**.

THE GOAL:
1. Build identical datasets with `COMPOUND`, `INTERLEAVED`, and `AUTO` sort keys.
2. Benchmark query performance when filtering on leading vs secondary sort columns.
3. Measure `VACUUM REINDEX` maintenance overhead.
======================================================================================
*/

-- ===================================================================================
-- 1. DATA GENERATION BLOCK (Run this to set up the scenario)
-- ===================================================================================

-- Table 1: Compound Sort Key (Default & Best Practice for time-series)
DROP TABLE IF EXISTS events_compound CASCADE;
CREATE TABLE events_compound (
    event_id BIGINT NOT NULL ENCODE az64,
    event_date DATE NOT NULL ENCODE raw, -- Sort key column 1
    user_id BIGINT NOT NULL ENCODE az64, -- Sort key column 2
    event_type VARCHAR(32) NOT NULL ENCODE bytedict,
    payload VARCHAR(100) NOT NULL ENCODE zstd
)
DISTSTYLE KEY
DISTKEY (user_id)
COMPOUND SORTKEY (event_date, user_id);

-- Table 2: Interleaved Sort Key (Multidimensional Z-Order)
DROP TABLE IF EXISTS events_interleaved CASCADE;
CREATE TABLE events_interleaved (
    event_id BIGINT NOT NULL ENCODE az64,
    event_date DATE NOT NULL ENCODE raw,
    user_id BIGINT NOT NULL ENCODE az64,
    event_type VARCHAR(32) NOT NULL ENCODE bytedict,
    payload VARCHAR(100) NOT NULL ENCODE zstd
)
DISTSTYLE KEY
DISTKEY (user_id)
INTERLEAVED SORTKEY (event_date, user_id);

-- Table 3: Unsorted Baseline (For benchmark contrast)
DROP TABLE IF EXISTS events_none CASCADE;
CREATE TABLE events_none (
    event_id BIGINT NOT NULL ENCODE az64,
    event_date DATE NOT NULL ENCODE az64,
    user_id BIGINT NOT NULL ENCODE az64,
    event_type VARCHAR(32) NOT NULL ENCODE bytedict,
    payload VARCHAR(100) NOT NULL ENCODE zstd
)
DISTSTYLE KEY
DISTKEY (user_id);

-- Populate 300,000 events across 365 days and 5,000 users
INSERT INTO events_compound (event_id, event_date, user_id, event_type, payload)
SELECT 
    s.n AS event_id,
    DATEADD(day, -(s.n % 365), '2026-08-15'::DATE) AS event_date,
    (s.n % 5000 + 1) AS user_id,
    CASE WHEN (s.n % 3) = 0 THEN 'CLICK' WHEN (s.n % 3) = 1 THEN 'VIEW' ELSE 'PURCHASE' END AS event_type,
    'Session_Payload_' || s.n::VARCHAR AS payload
FROM (
    SELECT ROW_NUMBER() OVER () AS n
    FROM (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) a
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) b
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) c
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) d
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2) e
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) f
    LIMIT 300000
) s;

INSERT INTO events_interleaved SELECT * FROM events_compound;
INSERT INTO events_none SELECT * FROM events_compound;

ANALYZE events_compound;
ANALYZE events_interleaved;
ANALYZE events_none;


-- ===================================================================================
-- 2. BENCHMARK QUERIES: LEADING VS SECONDARY COLUMN FILTERING
-- ===================================================================================

-- QUERY TEST 1: Filter on Leading Column (event_date)
-- COMPOUND: Lightning fast seek using Zone Maps.
-- INTERLEAVED: Fast seek using multidimensional bounding boxes.
-- NONE: Slow full table scan.

SELECT 'Compound - Date Filter' AS test, COUNT(*), MAX(payload) 
FROM events_compound WHERE event_date = '2026-08-01'::DATE;

SELECT 'Interleaved - Date Filter' AS test, COUNT(*), MAX(payload) 
FROM events_interleaved WHERE event_date = '2026-08-01'::DATE;

SELECT 'None - Date Filter' AS test, COUNT(*), MAX(payload) 
FROM events_none WHERE event_date = '2026-08-01'::DATE;


-- QUERY TEST 2: Filter on Secondary Column ALONE (user_id)
-- COMPOUND: Full table scan! Because user_id is second in the compound key, it is scattered across every date block.
-- INTERLEAVED: Fast range-restricted seek! Z-ordering allows block skipping on secondary columns.
-- NONE: Full table scan.

SELECT 'Compound - User Filter Alone' AS test, COUNT(*), MAX(payload) 
FROM events_compound WHERE user_id = 2500;

SELECT 'Interleaved - User Filter Alone' AS test, COUNT(*), MAX(payload) 
FROM events_interleaved WHERE user_id = 2500;


-- ===================================================================================
-- 2. THE "BAD" PROCEDURE (The Unsorted / Interleaved Maintenance Anti-Pattern)
-- ===================================================================================
/*
WHY YOU ALMOST ALWAYS WANT COMPOUND SORT KEYS:
- Append-only time-series data naturally lands at the end of a COMPOUND sort key table.
  `VACUUM SORT ONLY` completes in seconds.
- An INTERLEAVED sort key requires Redshift to mathematically reorganize the entire multidimensional
  space on EVERY batch load via `VACUUM REINDEX`.
*/
CREATE OR REPLACE PROCEDURE prc_bad_interleaved_maintenance_trap()
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE INFO 'WARNING: Avoid Interleaved Sort Keys unless multi-column range queries are equal and vacuum overhead is acceptable.';
END;
$$;


-- ===================================================================================
-- 3. THE "GOOD" PROCEDURE (Compound & Auto Sort Key Best Practice)
-- ===================================================================================
/*
SORT KEY DECISION MATRIX:
1. Use COMPOUND SORTKEY (Leading = Timestamp) for 95% of fact tables.
2. Put the most frequently filtered range column (e.g. date) FIRST.
3. Use AUTO if you want Redshift Automated Table Optimization (ATO) to manage keys.
*/
CREATE OR REPLACE PROCEDURE prc_good_sortkey_decision_matrix()
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE INFO 'Compound Sort Keys provide optimal range pruning with minimal vacuum maintenance overhead.';
END;
$$;


-- ===================================================================================
-- 4. USAGE, VERIFICATION & EXPLAIN / CATALOG ANALYSIS
-- ===================================================================================

-- (a) Check Zone Map range-restricted scans in EXPLAIN:
EXPLAIN SELECT COUNT(*) FROM events_compound WHERE event_date = '2026-08-01'::DATE;
EXPLAIN SELECT COUNT(*) FROM events_compound WHERE user_id = 2500;

-- (b) Inspect sort key health in system catalog:
SELECT "table", diststyle, sortkey1, sortkey_num, unsorted, size AS mb, tbl_rows
FROM svv_table_info
WHERE "table" IN ('events_compound', 'events_interleaved', 'events_none')
ORDER BY "table";

-- (c) Inspect interleaved column skew (only populated for interleaved tables):
SELECT * FROM svv_interleaved_columns WHERE tbl = 'events_interleaved'::regclass;
