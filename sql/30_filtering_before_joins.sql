/*
======================================================================================
MODULE 30: FILTERING BEFORE JOINS (PREDICATE PUSHDOWN)
======================================================================================
MAPPED BEST PRACTICES (from PROCEDURE_OPTIMIZATION_BEST_PRACTICES_MASTER_FILE.md):
- Practice 17: Filter as early as possible — push WHERE predicates before joins/aggregations.
- Practice 30: Filter both sides of a join before joining, not after — reduces rows shuffled.
- Practice 34: Check EXPLAIN for data movement volume.

TARGET AUDIENCE: Application Developers transitioning to Redshift
BUSINESS SCENARIO: 
We have a 500-million row fact table `fct_web_clicks` and a 10-million row dimension `dim_users`. 
We need to generate a marketing report for active users in **Germany (DE)** during the last **7 days**.

THE PROBLEM:
App developers often join the two massive tables first, and then place the filter at the very bottom:
`FROM fct_web_clicks c JOIN dim_users u ON ... WHERE c.click_date >= ... AND u.country = 'DE'`
While modern optimizers attempt predicate pushdown, complex views, nested CTEs, and late-binding 
views can block pushdown. 
Result: Redshift joins 500M rows to 10M rows (shuffling gigabytes of unneeded data), only to 
discard 99% of the joined rows at the final filter step.

THE GOAL:
1. Filter both fact and dimension datasets down to their minimal subsets BEFORE joining.
2. Drastically reduce hash table build time in RAM and eliminate network shuffle.
3. Compare `EXPLAIN` join input row counts before and after pushdown.
======================================================================================
*/

-- ===================================================================================
-- 1. DATA GENERATION BLOCK (Run this to set up the scenario)
-- ===================================================================================
DROP TABLE IF EXISTS filter_users CASCADE;
CREATE TABLE filter_users (
    user_id BIGINT NOT NULL ENCODE az64,
    user_name VARCHAR(100) NOT NULL ENCODE zstd,
    country CHAR(2) NOT NULL ENCODE bytedict,
    is_active BOOLEAN NOT NULL ENCODE raw
)
DISTSTYLE KEY
DISTKEY (user_id);

INSERT INTO filter_users (user_id, user_name, country, is_active)
SELECT 
    s.n AS user_id,
    'User_' || s.n::VARCHAR AS user_name,
    CASE WHEN (s.n % 10) = 0 THEN 'DE'
         WHEN (s.n % 10) = 1 THEN 'FR'
         WHEN (s.n % 10) = 2 THEN 'GB'
         ELSE 'US' END AS country,
    CASE WHEN (s.n % 5) = 0 THEN TRUE ELSE FALSE END AS is_active
FROM (
    SELECT ROW_NUMBER() OVER () AS n
    FROM (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) a
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) b
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) c
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) d
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) e
    LIMIT 50000
) s;

DROP TABLE IF EXISTS filter_clicks CASCADE;
CREATE TABLE filter_clicks (
    click_id BIGINT NOT NULL ENCODE az64,
    user_id BIGINT NOT NULL ENCODE az64,
    click_date DATE NOT NULL ENCODE az64,
    revenue DECIMAL(10,2) NOT NULL ENCODE az64
)
DISTSTYLE KEY
DISTKEY (user_id)
COMPOUND SORTKEY (click_date, user_id);

INSERT INTO filter_clicks (click_id, user_id, click_date, revenue)
SELECT 
    s.n AS click_id,
    (s.n % 50000 + 1) AS user_id,
    DATEADD(day, -(s.n % 365), '2026-08-15'::DATE) AS click_date,
    (1.00 + (s.n % 50))::DECIMAL(10,2) AS revenue
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

ANALYZE filter_users;
ANALYZE filter_clicks;

DROP TABLE IF EXISTS rpt_german_active_revenue CASCADE;
CREATE TABLE rpt_german_active_revenue (
    report_date DATE NOT NULL,
    total_revenue DECIMAL(14,2) NOT NULL,
    click_count BIGINT NOT NULL
);


-- ===================================================================================
-- 2. THE "BAD" PROCEDURE (Join First, Filter Last Anti-Pattern)
-- ===================================================================================
/*
WHY IT'S SLOW:
- Joins the entire user table to the entire clickstream table.
- Builds an in-memory hash table for 50,000 users and probes 100,000 click rows.
- Discards 98% of the calculated rows at the outer WHERE clause.
*/
CREATE OR REPLACE PROCEDURE prc_bad_join_then_filter()
LANGUAGE plpgsql
AS $$
BEGIN
    TRUNCATE TABLE rpt_german_active_revenue;
    
    INSERT INTO rpt_german_active_revenue (report_date, total_revenue, click_count)
    SELECT 
        c.click_date,
        SUM(c.revenue) AS total_revenue,
        COUNT(1) AS click_count
    FROM filter_clicks c
    INNER JOIN filter_users u ON c.user_id = u.user_id
    WHERE c.click_date >= '2026-08-08'::DATE -- Filtered at end
      AND u.country = 'DE'                   -- Filtered at end
      AND u.is_active = TRUE                 -- Filtered at end
    GROUP BY c.click_date;
END;
$$;


-- ===================================================================================
-- 3. THE "GOOD" PROCEDURE (Pushdown Filtered Subqueries Best Practice)
-- ===================================================================================
/*
WHY IT'S 10x FASTER:
- Filters `filter_users` down to active DE users FIRST (reducing 50,000 rows to 5,000).
- Filters `filter_clicks` to the 7-day range FIRST (skipping 98% of disk blocks via Zone Maps).
- The join operates on tiny, highly compact in-memory datasets.
*/
CREATE OR REPLACE PROCEDURE prc_good_filter_before_join(p_start_date DATE, p_end_date DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_rows BIGINT := 0;
BEGIN
    TRUNCATE TABLE rpt_german_active_revenue;
    
    INSERT INTO rpt_german_active_revenue (report_date, total_revenue, click_count)
    WITH filtered_users AS (
        SELECT user_id 
        FROM filter_users 
        WHERE country = 'DE' AND is_active = TRUE
    ),
    filtered_clicks AS (
        SELECT user_id, click_date, revenue
        FROM filter_clicks
        WHERE click_date >= p_start_date AND click_date <= p_end_date
    )
    SELECT 
        c.click_date,
        SUM(c.revenue) AS total_revenue,
        COUNT(1) AS click_count
    FROM filtered_clicks c
    INNER JOIN filtered_users u ON c.user_id = u.user_id
    GROUP BY c.click_date;
    
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RAISE INFO 'Filter pushdown complete: % daily summaries aggregated.', v_rows;

EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'prc_good_filter_before_join failed: %', SQLERRM;
END;
$$;


-- ===================================================================================
-- 4. USAGE, VERIFICATION & EXPLAIN PLAN COMPARISON
-- ===================================================================================

-- (a) Execution Plan Analysis:
EXPLAIN
WITH filtered_users AS (
    SELECT user_id FROM filter_users WHERE country = 'DE' AND is_active = TRUE
),
filtered_clicks AS (
    SELECT user_id, click_date, revenue FROM filter_clicks WHERE click_date >= '2026-08-08'::DATE
)
SELECT c.click_date, SUM(c.revenue)
FROM filtered_clicks c
INNER JOIN filtered_users u ON c.user_id = u.user_id
GROUP BY c.click_date;

-- (b) Run procedure:
-- CALL prc_good_filter_before_join('2026-08-08'::DATE, '2026-08-15'::DATE);
-- SELECT * FROM rpt_german_active_revenue ORDER BY report_date;
