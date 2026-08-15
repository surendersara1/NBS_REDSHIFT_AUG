/*
======================================================================================
MODULE 19: INPUT VALIDATION & FAILING EARLY
======================================================================================
MAPPED BEST PRACTICES (from PROCEDURE_OPTIMIZATION_BEST_PRACTICES_MASTER_FILE.md):
- Practice 11: Validate required parameters — reject NULL for required inputs.
- Practice 12: Validate date ranges — ensure p_from_date <= p_to_date.
- Practice 13: Limit excessively large ranges — prevent accidental full-history scans.
- Practice 15: Fail early — validate before expensive scans, deletes, joins, or inserts.
- Practice 18: Never wrap filtered/sort-key columns in functions or casts.
- Practice 19: Use half-open timestamp ranges (>= start AND < end).

TARGET AUDIENCE: Application Developers (Node.js, Java, Python) transitioning to Redshift
BUSINESS SCENARIO: 
We have a massive raw clickstream table with billions of rows. We need a procedure 
to aggregate this data into a daily summary table (`agg_daily_clicks`). 
The procedure accepts a start date and an end date parameter.

THE PROBLEM:
App developers often trust the caller (e.g., an Airflow job or an API) to provide 
sane parameters. In a transactional DB (Postgres/MySQL), a bad query with a wide date 
range might take a few seconds. In Redshift, an accidental 5-year date range scan on a 
10-billion row table will saturate the I/O bus, consume cluster workmem, queue other 
users, and take hours to fail or complete.

THE GOAL:
1. Never trust the caller.
2. Fail fast and early before scanning ANY data.
3. Enforce maximum processing windows (e.g., max 31 days per run).
4. Use sargable half-open timestamp intervals to preserve Zone Map pruning.
======================================================================================
*/

-- ===================================================================================
-- 1. DATA GENERATION BLOCK (Run this to set up the scenario)
-- ===================================================================================
DROP TABLE IF EXISTS raw_clickstream CASCADE;
CREATE TABLE raw_clickstream (
    event_id VARCHAR(50) NOT NULL ENCODE zstd,
    user_id INT NOT NULL ENCODE az64,
    event_name VARCHAR(50) NOT NULL ENCODE bytedict,
    event_timestamp TIMESTAMP NOT NULL ENCODE az64
)
DISTSTYLE KEY
DISTKEY (user_id)
COMPOUND SORTKEY (event_timestamp);

-- Generate 500,000 rows of mock clickstream data spread over the last 365 days
INSERT INTO raw_clickstream (event_id, user_id, event_name, event_timestamp)
SELECT 
    MD5(s.n::TEXT || RANDOM()::TEXT) AS event_id,
    (RANDOM() * 50000)::INT AS user_id,
    CASE WHEN (s.n % 3) = 0 THEN 'login'
         WHEN (s.n % 3) = 1 THEN 'view_item'
         ELSE 'checkout' END AS event_name,
    DATEADD(minute, -(s.n % 525600), '2026-08-15 00:00:00'::TIMESTAMP) AS event_timestamp
FROM (
    SELECT ROW_NUMBER() OVER () AS n
    FROM (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) a
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) b
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) c
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) d
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4) e
    LIMIT 500000
) s;

ANALYZE raw_clickstream;

DROP TABLE IF EXISTS agg_daily_clicks CASCADE;
CREATE TABLE agg_daily_clicks (
    event_date DATE NOT NULL ENCODE az64,
    event_name VARCHAR(50) NOT NULL ENCODE bytedict,
    total_events BIGINT NOT NULL ENCODE az64
)
DISTSTYLE EVEN
COMPOUND SORTKEY (event_date);


-- ===================================================================================
-- 2. THE "BAD" PROCEDURE (The App Dev Way / Anti-Pattern)
-- ===================================================================================
/*
WHY IT'S BAD:
- No parameter validation: If `p_start_date` is NULL, the WHERE clause evaluates to UNKNOWN.
- No blast radius protection: If someone passes '2020-01-01' to '2026-01-01', the cluster
  attempts a multi-year scan, exhausting cluster memory and spilling to disk.
- Non-sargable predicate: `DATE_TRUNC('day', event_timestamp)::DATE >= p_start_date` wraps
  the SORT KEY column in a function. This completely disables Zone Map block skipping!
  Redshift must read 100% of 1MB blocks from disk even if only 1 day of data was requested.
*/
CREATE OR REPLACE PROCEDURE prc_bad_aggregate_clicks(p_start_date DATE, p_end_date DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE INFO 'Starting aggregation (BAD WAY)...';
    
    -- Blindly execute the insert without checking inputs or range limits
    INSERT INTO agg_daily_clicks (event_date, event_name, total_events)
    SELECT 
        DATE_TRUNC('day', event_timestamp)::DATE AS event_date,
        event_name,
        COUNT(1) AS total_events
    FROM raw_clickstream
    WHERE DATE_TRUNC('day', event_timestamp)::DATE >= p_start_date 
      AND DATE_TRUNC('day', event_timestamp)::DATE <= p_end_date
    GROUP BY 1, 2;
    
    RAISE INFO 'Aggregation complete.';
END;
$$;


-- ===================================================================================
-- 3. THE "GOOD" PROCEDURE (The Redshift MPP Way / Best Practice)
-- ===================================================================================
/*
WHY IT'S GOOD:
- Explicit NULL checks fail immediately with meaningful context (Practice 11).
- Logical sequence validation prevents inverted date ranges (Practice 12).
- Blast radius protection enforces a maximum processing window (e.g., 31 days) (Practice 13).
- Sargable predicates: Filters on `event_timestamp >= p_start_date::TIMESTAMP` and
  `event_timestamp < (p_end_date + 1)::TIMESTAMP` without functions on the column (Practice 18, 19).
  This allows Redshift to evaluate block-level Zone Maps and skip reading 95%+ of disk blocks!
*/
CREATE OR REPLACE PROCEDURE prc_good_aggregate_clicks(p_start_date DATE, p_end_date DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_days_diff INT;
    v_rows_inserted BIGINT := 0;
BEGIN
    -- 1. VALIDATION: Check for NULLs (Fail Early)
    IF p_start_date IS NULL OR p_end_date IS NULL THEN
        RAISE EXCEPTION 'Validation Failed: p_start_date and p_end_date cannot be NULL.';
    END IF;

    -- 2. VALIDATION: Check logical sequence
    IF p_start_date > p_end_date THEN
        RAISE EXCEPTION 'Validation Failed: p_start_date (%) cannot be greater than p_end_date (%).', 
            p_start_date, p_end_date;
    END IF;

    -- 3. VALIDATION: Blast Radius Protection (Max 31 days per run)
    v_days_diff := DATEDIFF(day, p_start_date, p_end_date);
    IF v_days_diff > 31 THEN
        RAISE EXCEPTION 'Validation Failed: Date range exceeds 31 days (Requested: % days). Please batch your loads.', 
            v_days_diff;
    END IF;

    RAISE INFO 'Validation passed. Aggregating data for % to %...', p_start_date, p_end_date;

    -- 4. IDEMPOTENT PURGE: Clear target slice before inserting
    DELETE FROM agg_daily_clicks
    WHERE event_date >= p_start_date AND event_date <= p_end_date;

    -- 5. SARGABLE INSERT: Half-open interval preserves Zone Map pruning
    INSERT INTO agg_daily_clicks (event_date, event_name, total_events)
    SELECT 
        event_timestamp::DATE AS event_date,
        event_name,
        COUNT(1) AS total_events
    FROM raw_clickstream
    WHERE event_timestamp >= p_start_date::TIMESTAMP 
      AND event_timestamp < (p_end_date + 1)::TIMESTAMP
    GROUP BY 1, 2;

    GET DIAGNOSTICS v_rows_inserted = ROW_COUNT;
    RAISE INFO 'Aggregation complete. Inserted % rows.', v_rows_inserted;

EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'prc_good_aggregate_clicks failed for window % to %: %', 
        p_start_date, p_end_date, SQLERRM;
END;
$$;


-- ===================================================================================
-- 4. USAGE, VERIFICATION & EXECUTION PLAN PROOF
-- ===================================================================================

-- (a) Test Validation Guardrails:
-- CALL prc_good_aggregate_clicks(NULL, '2026-08-15');        --> Throws NULL validation error
-- CALL prc_good_aggregate_clicks('2026-08-15', '2026-08-01'); --> Throws date sequence error
-- CALL prc_good_aggregate_clicks('2025-01-01', '2026-08-15'); --> Throws blast radius (>31 days) error

-- (b) Test Valid Execution:
-- CALL prc_good_aggregate_clicks('2026-08-01'::DATE, '2026-08-15'::DATE);
-- SELECT * FROM agg_daily_clicks ORDER BY event_date DESC, total_events DESC;

-- (c) Execution Plan Comparison (EXPLAIN):
-- NON-SARGABLE (Bad): Full table scan on raw_clickstream (Zone map disabled by DATE_TRUNC)
EXPLAIN
SELECT event_name, COUNT(1)
FROM raw_clickstream
WHERE DATE_TRUNC('day', event_timestamp)::DATE >= '2026-08-01'::DATE
  AND DATE_TRUNC('day', event_timestamp)::DATE <= '2026-08-15'::DATE
GROUP BY event_name;

-- SARGABLE (Good): Range-restricted scan (Zone maps skip all blocks outside the 15-day range)
EXPLAIN
SELECT event_name, COUNT(1)
FROM raw_clickstream
WHERE event_timestamp >= '2026-08-01 00:00:00'::TIMESTAMP
  AND event_timestamp < '2026-08-16 00:00:00'::TIMESTAMP
GROUP BY event_name;

-- (d) Check actual block skips in system views:
-- SELECT query_id, step_name, table_name, is_rrscan, input_rows, output_rows
-- FROM sys_query_detail
-- WHERE query_id = pg_last_query_id()
-- ORDER BY step_name;
