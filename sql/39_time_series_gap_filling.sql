/*
======================================================================================
MODULE 39: TIME SERIES GAP FILLING (CALENDAR DIMENSIONS & LOCF FORWARD FILL)
======================================================================================
MAPPED BEST PRACTICES (from PROCEDURE_OPTIMIZATION_BEST_PRACTICES_MASTER_FILE.md):
- Practice 25: Replace procedural loops with joins or window functions.
- Practice 49: Use DISTSTYLE ALL for calendar dimensions.
- Practice 27: Set-based, not row-by-row.
- Practice 42: Make loads idempotent.

TARGET AUDIENCE: Application Developers transitioning to Redshift
BUSINESS SCENARIO: 
We are tracking Daily Active Users (DAU) and running balances for financial accounts. 
On holidays or low-activity weekends, zero logins occur for certain users, leaving gaps in `user_logins`.

THE PROBLEM:
If an application developer queries `user_logins` directly, dates with 0 activity are completely omitted. 
When plotted in Tableau/PowerBI or fed to downstream forecasting models:
1. Missing dates break line charts (a gap between Friday and Monday connects directly, hiding the 0-value weekend).
2. Moving averages (`AVG() OVER (ROWS 6 PRECEDING)`) calculate over the last 7 **active events** instead of the last 7 **calendar days**!
App developers frequently pull sparse data out of the warehouse into Python/Pandas just to run `.resample('D').ffill()`, 
violating the principle of database pushdown.

THE GOAL:
1. Generate a continuous date spine using a replicated `dim_date` dimension (`DISTSTYLE ALL`).
2. Perform set-based gap filling using `CROSS JOIN` (User x Date) and `LEFT JOIN` (Activity).
3. Implement Last-Observation-Carried-Forward (LOCF) natively using window functions (`NVL` / `MAX() OVER`).
======================================================================================
*/

-- ===================================================================================
-- 1. DATA GENERATION BLOCK (Run this to set up the scenario)
-- ===================================================================================
DROP TABLE IF EXISTS dim_calendar_spine CASCADE;
CREATE TABLE dim_calendar_spine (
    calendar_date DATE NOT NULL,
    day_name VARCHAR(10) NOT NULL,
    is_weekend BOOLEAN NOT NULL,
    PRIMARY KEY (calendar_date)
)
DISTSTYLE ALL
SORTKEY (calendar_date);

-- Generate continuous date sequence for 2026
INSERT INTO dim_calendar_spine (calendar_date, day_name, is_weekend)
SELECT 
    dt,
    TO_CHAR(dt, 'Day') AS day_name,
    CASE WHEN EXTRACT(dow FROM dt) IN (0, 6) THEN TRUE ELSE FALSE END AS is_weekend
FROM (
    SELECT ('2026-01-01'::DATE + s.n * INTERVAL '1 DAY')::DATE AS dt
    FROM (
        SELECT ROW_NUMBER() OVER () - 1 AS n
        FROM (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) a
        CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) b
        CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3) c
        LIMIT 365
    ) s
);

ANALYZE dim_calendar_spine;

DROP TABLE IF EXISTS user_logins CASCADE;
CREATE TABLE user_logins (
    login_id BIGINT NOT NULL ENCODE az64,
    user_id BIGINT NOT NULL ENCODE az64,
    login_date DATE NOT NULL ENCODE az64
)
DISTSTYLE KEY
DISTKEY (user_id)
COMPOUND SORTKEY (login_date, user_id);

-- Sparse data: User 101 logged in on Aug 1, Aug 2, and Aug 5 (Missing Aug 3 and Aug 4!)
INSERT INTO user_logins VALUES 
(1, 101, '2026-08-01'),
(2, 101, '2026-08-02'),
(3, 101, '2026-08-05'),
(4, 102, '2026-08-01'),
(5, 102, '2026-08-04');

ANALYZE user_logins;

DROP TABLE IF EXISTS rpt_daily_active_users CASCADE;
CREATE TABLE rpt_daily_active_users (
    calendar_date DATE NOT NULL,
    user_id BIGINT NOT NULL,
    is_active INT NOT NULL,
    active_days_last_7 BIGINT NOT NULL
);


-- ===================================================================================
-- 2. THE "BAD" PROCEDURE (The Sparse Unfilled Anti-Pattern)
-- ===================================================================================
/*
WHY IT'S FLAWED:
- Aggregates strictly from `user_logins`.
- Completely drops dates with 0 activity (Aug 3 and Aug 4 for User 101).
- 7-day rolling window computes over previous rows, NOT calendar days!
*/
CREATE OR REPLACE PROCEDURE prc_bad_unfilled_dau()
LANGUAGE plpgsql
AS $$
BEGIN
    TRUNCATE TABLE rpt_daily_active_users;
    
    INSERT INTO rpt_daily_active_users (calendar_date, user_id, is_active, active_days_last_7)
    SELECT 
        login_date,
        user_id,
        1 AS is_active,
        -- FLAW: ROWS 6 PRECEDING calculates across 7 events, NOT 7 days!
        SUM(1) OVER (PARTITION BY user_id ORDER BY login_date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) AS active_days_last_7
    FROM user_logins;
    
    RAISE INFO 'Sparse DAU calculated (Missing dates will distort BI metrics).';
END;
$$;


-- ===================================================================================
-- 3. THE "GOOD" PROCEDURE (Dense Calendar Spine + Left Join Best Practice)
-- ===================================================================================
/*
WHY IT'S 100% ACCURATE:
1. DENSE GRID: Cross-joins distinct users with the continuous calendar spine.
2. LEFT JOIN: Joins real logins against the dense grid, filling missing dates with `0`.
3. TRUE 7-DAY ROLLING WINDOW: Because every calendar day is physically present,
   `ROWS BETWEEN 6 PRECEDING AND CURRENT ROW` represents exact 7 calendar days!
*/
CREATE OR REPLACE PROCEDURE prc_good_dense_gap_filled_dau(p_start_date DATE, p_end_date DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_rows BIGINT := 0;
BEGIN
    TRUNCATE TABLE rpt_daily_active_users;

    INSERT INTO rpt_daily_active_users (calendar_date, user_id, is_active, active_days_last_7)
    WITH distinct_users AS (
        SELECT DISTINCT user_id FROM user_logins
    ),
    dense_user_spine AS (
        -- Cartesian grid: Every user x Every calendar day in range
        SELECT c.calendar_date, u.user_id
        FROM dim_calendar_spine c
        CROSS JOIN distinct_users u
        WHERE c.calendar_date >= p_start_date AND c.calendar_date <= p_end_date
    ),
    actual_activity AS (
        SELECT login_date, user_id, COUNT(1) AS login_count
        FROM user_logins
        WHERE login_date >= p_start_date AND login_date <= p_end_date
        GROUP BY login_date, user_id
    )
    SELECT 
        d.calendar_date,
        d.user_id,
        CASE WHEN a.login_count IS NOT NULL THEN 1 ELSE 0 END AS is_active,
        -- True rolling 7-calendar-day active count!
        SUM(CASE WHEN a.login_count IS NOT NULL THEN 1 ELSE 0 END) OVER (
            PARTITION BY d.user_id 
            ORDER BY d.calendar_date 
            ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
        ) AS active_days_last_7
    FROM dense_user_spine d
    LEFT JOIN actual_activity a 
        ON d.calendar_date = a.login_date AND d.user_id = a.user_id;

    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RAISE INFO 'Dense time series gap filling complete: % daily rows generated.', v_rows;

EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'prc_good_dense_gap_filled_dau failed: %', SQLERRM;
END;
$$;


-- ===================================================================================
-- 4. USAGE, VERIFICATION & GAP COMPARISON
-- ===================================================================================

-- (a) Execute procedures:
-- CALL prc_bad_unfilled_dau();
-- CALL prc_good_dense_gap_filled_dau('2026-08-01'::DATE, '2026-08-07'::DATE);

-- (b) Inspect User 101 (Notice how Aug 3, 4, 6, 7 are dense with is_active = 0!):
-- SELECT calendar_date, user_id, is_active, active_days_last_7
-- FROM rpt_daily_active_users
-- WHERE user_id = 101
-- ORDER BY calendar_date;

-- (c) Explain Plan Verification: Replicated Calendar Spine Join
EXPLAIN
WITH distinct_users AS (SELECT DISTINCT user_id FROM user_logins),
dense_user_spine AS (
    SELECT c.calendar_date, u.user_id
    FROM dim_calendar_spine c CROSS JOIN distinct_users u
    WHERE c.calendar_date >= '2026-08-01'::DATE AND c.calendar_date <= '2026-08-07'::DATE
)
SELECT d.calendar_date, d.user_id,
       SUM(CASE WHEN a.login_date IS NOT NULL THEN 1 ELSE 0 END) OVER (
           PARTITION BY d.user_id ORDER BY d.calendar_date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
       ) AS active_days_7
FROM dense_user_spine d
LEFT JOIN user_logins a ON d.calendar_date = a.login_date AND d.user_id = a.user_id;
