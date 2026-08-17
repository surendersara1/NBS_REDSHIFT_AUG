/*
======================================================================================
MODULE 53: ADVANCED DATE & TIMESTAMP FUNCTIONS — 20 ENTERPRISE SCENARIOS
======================================================================================
TARGET AUDIENCE: Application Developers & Senior Data Engineers
BUSINESS SCENARIO: 
Temporal calculations represent 80%+ of analytical reporting: fiscal calendars, 
SLA tracking across business days, UTC/timezone normalization, and session intervals.

THE GOAL:
Provide 20 runnable, production-grade examples of Redshift date/time arithmetic, 
eliminating common porting traps from MySQL/SQL Server.
======================================================================================
*/

-- ===================================================================================
-- DATA GENERATION
-- ===================================================================================
DROP TABLE IF EXISTS demo_orders_dates CASCADE;
CREATE TABLE demo_orders_dates (
    order_id INT,
    order_ts TIMESTAMP,
    ship_ts TIMESTAMP,
    user_tz VARCHAR(50)
);

INSERT INTO demo_orders_dates VALUES 
(1, '2026-08-15 08:30:00', '2026-08-17 14:15:00', 'America/New_York'),
(2, '2026-08-15 22:45:00', '2026-08-18 09:00:00', 'Europe/London'),
(3, '2026-08-16 11:00:00', '2026-08-20 16:30:00', 'Asia/Tokyo');

ANALYZE demo_orders_dates;


-- ===================================================================================
-- 20 ENTERPRISE DATE & TIME FUNCTIONS
-- ===================================================================================

-- 1. SYSDATE vs GETDATE() vs NOW()
-- This is the opposite of what most developers assume, so read it twice:
--   SYSDATE   -> start of the current TRANSACTION (UTC, no parentheses).
--   NOW()     -> start of the current TRANSACTION (same instant as SYSDATE).
--   GETDATE() -> start of the current STATEMENT, even inside a transaction block.
-- CONSEQUENCE: a stored procedure body is ONE transaction, so SYSDATE is frozen for the
-- whole procedure. Timing steps with SYSDATE records every duration as 0. Use GETDATE()
-- for any elapsed-time measurement. See module 20.
SELECT SYSDATE AS stmt_time_utc, GETDATE() AS getdate_utc, NOW() AS txn_start_time;

-- 2. DATEADD (Adding intervals to timestamps)
SELECT order_id, order_ts, DATEADD(day, 7, order_ts) AS due_date FROM demo_orders_dates;

-- 3. DATEDIFF (Calculating elapsed duration between timestamps)
SELECT order_id, DATEDIFF(hour, order_ts, ship_ts) AS fulfillment_hours FROM demo_orders_dates;

-- 4. DATE_TRUNC (Truncating to date boundaries for aggregation)
SELECT order_id, DATE_TRUNC('month', order_ts) AS month_start, DATE_TRUNC('hour', order_ts) AS hour_start FROM demo_orders_dates;

-- 5. EXTRACT / DATE_PART (Pulling specific date parts)
SELECT order_id, EXTRACT(dow FROM order_ts) AS day_of_week_num, EXTRACT(quarter FROM order_ts) AS quarter_num FROM demo_orders_dates;

-- 6. TO_CHAR (Formatting timestamps as display strings)
SELECT order_id, TO_CHAR(order_ts, 'YYYY-MM-DD HH24:MI:SS') AS formatted_iso FROM demo_orders_dates;

-- 7. TO_DATE (Parsing custom date strings into DATE types)
SELECT TO_DATE('15/08/2026', 'DD/MM/YYYY') AS parsed_date;

-- 8. TO_TIMESTAMP (Parsing custom strings into TIMESTAMP types)
SELECT TO_TIMESTAMP('2026-08-15 14:30:00.123', 'YYYY-MM-DD HH24:MI:SS.MS') AS parsed_ts;

-- 9. CONVERT_TIMEZONE (Converting between UTC and local timezones with DST awareness)
SELECT order_id, order_ts AS utc_ts, CONVERT_TIMEZONE('UTC', user_tz, order_ts) AS local_customer_time FROM demo_orders_dates;

-- 10. LAST_DAY (Finding the end date of the month)
SELECT order_id, order_ts, LAST_DAY(order_ts) AS month_end_date FROM demo_orders_dates;

-- 11. ADD_MONTHS (Adding calendar months preserving month-end semantics)
SELECT order_id, ADD_MONTHS(order_ts::DATE, 3) AS next_quarter_date FROM demo_orders_dates;

-- 12. MONTHS_BETWEEN (Exact floating-point difference in months)
SELECT order_id, MONTHS_BETWEEN(ship_ts::DATE, order_ts::DATE) AS months_diff FROM demo_orders_dates;

-- 13. NEXT_DAY (Finding the date of the next named weekday)
SELECT NEXT_DAY('2026-08-15'::DATE, 'Monday') AS next_monday_date;

-- 14. TRUNC on Dates (Removing time component)
SELECT TRUNC('2026-08-15 17:45:10'::TIMESTAMP) AS date_only;

-- 15. Fiscal Calendar Calculation (4-4-5 Retail Calendar starting Feb 1)
SELECT order_id, order_ts,
       CASE WHEN EXTRACT(month FROM order_ts) = 1 THEN EXTRACT(year FROM order_ts) - 1 ELSE EXTRACT(year FROM order_ts) END AS fiscal_year,
       (((EXTRACT(month FROM order_ts)::INT + 10) % 12) / 3 + 1) AS fiscal_quarter
FROM demo_orders_dates;

-- 16. Business Days Difference (Excluding weekends)
SELECT order_id, order_ts, ship_ts,
       (DATEDIFF(day, order_ts::DATE, ship_ts::DATE) + 1)
       - (DATEDIFF(week, order_ts::DATE, ship_ts::DATE) * 2)
       - (CASE WHEN EXTRACT(dow FROM order_ts) = 0 THEN 1 ELSE 0 END)
       - (CASE WHEN EXTRACT(dow FROM ship_ts) = 6 THEN 1 ELSE 0 END) AS business_days_taken
FROM demo_orders_dates;

-- 17. TIME_BUCKET / Epoch Arithmetic (Grouping into 15-minute intervals)
SELECT order_id, order_ts,
       '1970-01-01 00:00:00'::TIMESTAMP + ((EXTRACT(epoch FROM order_ts)::BIGINT / 900) * 900) * INTERVAL '1 SECOND' AS bucket_15min
FROM demo_orders_dates;

-- 18. Age Calculation in Years
SELECT DATEDIFF(year, '1995-04-12'::DATE, CURRENT_DATE) AS approx_age_years;

-- 19. ISO 8601 Week Number
SELECT order_id, EXTRACT(week FROM order_ts) AS iso_week FROM demo_orders_dates;

-- 20. Overlapping Time Interval Detection
SELECT a.order_id AS order_a, b.order_id AS order_b
FROM demo_orders_dates a
JOIN demo_orders_dates b 
  ON a.order_id != b.order_id 
  AND a.order_ts < b.ship_ts 
  AND a.ship_ts > b.order_ts;
