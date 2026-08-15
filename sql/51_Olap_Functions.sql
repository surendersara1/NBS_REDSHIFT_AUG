/*
======================================================================================
MODULE 51: THE OLAP MASTERCLASS - DEEP WINDOW FUNCTIONS
======================================================================================
TARGET AUDIENCE: Application Developers & Senior Data Engineers
BUSINESS SCENARIO: 
We are launching a $1 Million, 1-Petabyte analytics initiative. The business requires 
deep behavioral insights that cannot be pre-aggregated in simple daily tables. 
We need to calculate:
1. User Sessionization (Time between clicks).
2. Moving Averages & Running Totals (Financial tracking).
3. First-Touch / Last-Touch Attribution (Marketing).
4. Customer Deciling & Percentile Ranking (Fraud & VIP targeting).

THE PROBLEM:
Application developers will often pull raw data into Spark, Python (Pandas), or Node.js 
to calculate running totals or find the "next event" in a sequence. 
Moving a petabyte of data over the network to a Python script is catastrophic.

THE GOAL:
1. Push 100% of the analytical computation down into the Redshift Compute Nodes.
2. Master the `OVER (PARTITION BY ... ORDER BY ... ROWS BETWEEN ...)` clause.
3. Demonstrate every major OLAP Window Function available in Redshift.
======================================================================================
*/

-- ===================================================================================
-- 1. DATA GENERATION BLOCK (Massive scale simulation)
-- ===================================================================================
DROP TABLE IF EXISTS dim_user;
CREATE TABLE dim_user (
    user_id BIGINT,
    cohort_month DATE,
    country VARCHAR(50)
) DISTSTYLE KEY DISTKEY (user_id);

-- Simulate 1,000 users
INSERT INTO dim_user 
SELECT n, DATE_TRUNC('month', CURRENT_DATE - (n%365)::INT), 'USA'
FROM (SELECT ROW_NUMBER() OVER() as n FROM (SELECT 0 AS n UNION SELECT 1) a, (SELECT 0 AS n UNION SELECT 1) b, (SELECT 0 AS n UNION SELECT 1) c, (SELECT 0 AS n UNION SELECT 1) d, (SELECT 0 AS n UNION SELECT 1) e, (SELECT 0 AS n UNION SELECT 1) f, (SELECT 0 AS n UNION SELECT 1) g, (SELECT 0 AS n UNION SELECT 1) h, (SELECT 0 AS n UNION SELECT 1) i, (SELECT 0 AS n UNION SELECT 1) j limit 1000);

DROP TABLE IF EXISTS fct_web_events;
CREATE TABLE fct_web_events (
    event_id BIGINT IDENTITY(1,1),
    user_id BIGINT,
    event_timestamp TIMESTAMP,
    url_path VARCHAR(255),
    revenue DECIMAL(10,2)
) DISTSTYLE KEY DISTKEY (user_id) SORTKEY (user_id, event_timestamp);

-- Simulate web events (multiple per user)
INSERT INTO fct_web_events (user_id, event_timestamp, url_path, revenue)
SELECT 
    user_id,
    DATEADD(minute, (RANDOM() * 60000)::INT, '2023-01-01'::TIMESTAMP),
    CASE WHEN (RANDOM() * 4)::INT = 0 THEN '/home'
         WHEN (RANDOM() * 4)::INT = 1 THEN '/product'
         WHEN (RANDOM() * 4)::INT = 2 THEN '/cart'
         ELSE '/checkout' END,
    CASE WHEN (RANDOM() * 10)::INT = 0 THEN (RANDOM() * 500)::DECIMAL(10,2) ELSE 0.00 END
FROM dim_user CROSS JOIN (SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5) x;

-- Analyze to ensure optimal query plans
ANALYZE dim_user;
ANALYZE fct_web_events;

-- Target table for our massive analytical view
DROP TABLE IF EXISTS target_olap_insights;
CREATE TABLE target_olap_insights (
    user_id BIGINT,
    event_timestamp TIMESTAMP,
    url_path VARCHAR(255),
    revenue DECIMAL(10,2),
    -- Navigation Metrics
    time_since_last_event_seconds BIGINT,
    next_url_visited VARCHAR(255),
    is_first_touch_of_day BOOLEAN,
    last_touch_of_day VARCHAR(255),
    -- Financial Metrics
    running_total_revenue DECIMAL(15,2),
    moving_avg_revenue_last_3_events DECIMAL(15,2),
    -- Ranking Metrics
    event_sequence_num INT,
    daily_revenue_rank INT,
    daily_revenue_dense_rank INT,
    revenue_decile INT,
    percentile_score DECIMAL(5,4)
) DISTSTYLE KEY DISTKEY (user_id) SORTKEY (user_id, event_timestamp);


-- ===================================================================================
-- 2. THE MASTER OLAP PROCEDURE
-- ===================================================================================
CREATE OR REPLACE PROCEDURE prc_petabyte_olap_engine()
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE INFO 'Engaging Petabyte-Scale OLAP Windowing Engine...';

    TRUNCATE TABLE target_olap_insights;

    INSERT INTO target_olap_insights
    SELECT 
        e.user_id,
        e.event_timestamp,
        e.url_path,
        e.revenue,

        -- ===========================================================================
        -- 1. LAG() and LEAD() : Sessionization & Pathing
        -- ===========================================================================
        -- LAG looks BACKWARDS. We use it to find the time elapsed since the user's PREVIOUS click.
        DATEDIFF(second, 
                 LAG(e.event_timestamp, 1) OVER (
                     PARTITION BY e.user_id 
                     ORDER BY e.event_timestamp
                 ), 
                 e.event_timestamp
        ) AS time_since_last_event_seconds,

        -- LEAD looks FORWARDS. What page did the user go to NEXT?
        LEAD(e.url_path, 1) OVER (
            PARTITION BY e.user_id 
            ORDER BY e.event_timestamp
        ) AS next_url_visited,

        -- ===========================================================================
        -- 2. FIRST_VALUE() and LAST_VALUE() : Attribution
        -- ===========================================================================
        -- Did this click start the day for this user?
        CASE WHEN e.url_path = FIRST_VALUE(e.url_path) OVER (
                 PARTITION BY e.user_id, DATE_TRUNC('day', e.event_timestamp)
                 ORDER BY e.event_timestamp
                 -- Implicit default frame: ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
             ) THEN TRUE ELSE FALSE END AS is_first_touch_of_day,

        -- What was the final page they visited today?
        -- CRITICAL REDSHIFT KNOWLEDGE: LAST_VALUE requires an explicit sliding window frame, 
        -- otherwise it stops at the "CURRENT ROW" and just returns the current url_path!
        LAST_VALUE(e.url_path) OVER (
            PARTITION BY e.user_id, DATE_TRUNC('day', e.event_timestamp)
            ORDER BY e.event_timestamp
            ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
        ) AS last_touch_of_day,

        -- ===========================================================================
        -- 3. AGGREGATE WINDOWS : Running Totals & Moving Averages
        -- ===========================================================================
        -- Running Total (Cumulative Sum) of revenue for this user over time
        SUM(e.revenue) OVER (
            PARTITION BY e.user_id
            ORDER BY e.event_timestamp
            ROWS UNBOUNDED PRECEDING -- Implicitly ends at CURRENT ROW
        ) AS running_total_revenue,

        -- 3-Event Moving Average (Smoothing out spikes)
        -- Looks at the current row AND the 2 rows before it
        AVG(e.revenue) OVER (
            PARTITION BY e.user_id
            ORDER BY e.event_timestamp
            ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
        ) AS moving_avg_revenue_last_3_events,

        -- ===========================================================================
        -- 4. RANKING & PERCENTILES : Deduplication, Leaderboards, deciling
        -- ===========================================================================
        -- ROW_NUMBER: Strictly sequential (1, 2, 3, 4). Guarantees uniqueness.
        ROW_NUMBER() OVER (
            PARTITION BY e.user_id, DATE_TRUNC('day', e.event_timestamp)
            ORDER BY e.event_timestamp
        ) AS event_sequence_num,

        -- RANK: Allows ties, skips numbers (1, 2, 2, 4)
        RANK() OVER (
            PARTITION BY DATE_TRUNC('day', e.event_timestamp)
            ORDER BY e.revenue DESC
        ) AS daily_revenue_rank,

        -- DENSE_RANK: Allows ties, does NOT skip numbers (1, 2, 2, 3)
        DENSE_RANK() OVER (
            PARTITION BY DATE_TRUNC('day', e.event_timestamp)
            ORDER BY e.revenue DESC
        ) AS daily_revenue_dense_rank,

        -- NTILE(10): Decile scoring. Groups users into 10 even buckets based on revenue. 
        -- Bucket 1 is the top 10% highest spenders.
        NTILE(10) OVER (
            PARTITION BY DATE_TRUNC('day', e.event_timestamp)
            ORDER BY e.revenue DESC
        ) AS revenue_decile,

        -- PERCENT_RANK: Returns a relative rank between 0.0 and 1.0 (e.g., 0.99 = top 1%)
        PERCENT_RANK() OVER (
            PARTITION BY DATE_TRUNC('day', e.event_timestamp)
            ORDER BY e.revenue DESC
        ) AS percentile_score

    FROM fct_web_events e
    INNER JOIN dim_user u ON e.user_id = u.user_id;

    RAISE INFO 'OLAP processing complete. All heavy lifting executed natively on Redshift Compute Nodes.';
END;
$$;

-- ===================================================================================
-- 3. USAGE / TESTING & EXECUTION PLAN ANALYSIS
-- ===================================================================================
/*
-- Execute the masterclass procedure
CALL prc_petabyte_olap_engine();

-- View a specific user's behavioral journey
SELECT 
    event_timestamp, 
    url_path, 
    next_url_visited, 
    time_since_last_event_seconds,
    running_total_revenue,
    revenue_decile
FROM target_olap_insights
WHERE user_id = 5
ORDER BY event_timestamp;

--------------------------------------------------------------------------------------
DEEP ARCHITECTURE NOTE FOR SENIOR DEVS:
If you run EXPLAIN on the SELECT query inside the procedure, you will see a massive 
series of `Window` operations stacked on top of each other.
Redshift executes these in memory on the compute nodes. 
Because our tables are distributed by `user_id` (DISTSTYLE KEY), and practically every 
OLAP function above uses `PARTITION BY user_id`, Redshift does not need to shuffle 
any data across the network to compute the window frames. 
This is called "Collocated Windowing" and it is the secret to scaling to petabytes. 
If we partitioned by a column that wasn't the distkey, Redshift would throw a `DS_DIST_BOTH` 
and the query would fail under petabyte loads.
--------------------------------------------------------------------------------------
*/
