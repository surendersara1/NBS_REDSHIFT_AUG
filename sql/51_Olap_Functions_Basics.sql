/*
======================================================================================
MODULE 51: OLAP / WINDOW FUNCTIONS — THE BASICS, ONE FUNCTION AT A TIME
======================================================================================
TARGET AUDIENCE: Everyone. Start here. Module 51.1 is the advanced version and
                 assumes you already know everything in this file.

HOW TO USE THIS FILE:
The data is TINY and printed in full in Section 0 — ten stores and fourteen days of
sales. That is deliberate. You should be able to check every single answer by eye.
Every example below prints the expected output as a comment. Run the query, compare
it to the comment, and if they differ, work out why before moving on.

Sixteen functions, three buckets:

  BUCKET 1 — RANKING & DISTRIBUTION      "Who is on top? Where does this row sit?"
     1 ROW_NUMBER      2 RANK        3 DENSE_RANK
     4 NTILE           5 PERCENT_RANK  6 CUME_DIST

  BUCKET 2 — OFFSET / NAVIGATION         "What came before or after this row?"
     7 LEAD            8 LAG         9 FIRST_VALUE
    10 LAST_VALUE     11 NTH_VALUE

  BUCKET 3 — WINDOWED AGGREGATES         "Running totals and moving averages"
    12 SUM            13 AVG        14 COUNT
    15 MIN            16 MAX

======================================================================================
WHAT A WINDOW FUNCTION ACTUALLY IS
======================================================================================
A GROUP BY collapses many rows into one. A window function does NOT. It keeps every
row and adds a new column computed from a "window" of surrounding rows.

    GROUP BY                          OVER ()
    ────────────────                  ────────────────
    10 rows in                        10 rows in
     2 rows out                       10 rows out  + a new column

That is the entire idea. Everything else is detail about which rows are in the window.

THE ANATOMY OF THE OVER CLAUSE
──────────────────────────────

    SUM(revenue) OVER (
        PARTITION BY region        <-- 1. split rows into groups. Optional.
        ORDER BY sale_date         <-- 2. order rows inside each group. Optional.
        ROWS BETWEEN 2 PRECEDING   <-- 3. the FRAME: which rows count. Optional.
                 AND CURRENT ROW
    )

    1. PARTITION BY  — like GROUP BY, but the rows survive. Leave it out and the
                       whole result set is one partition.
    2. ORDER BY      — the order INSIDE the window. Required by the ranking and
                       navigation functions; optional for aggregates.
    3. FRAME         — how far the window reaches. This is the part that surprises
                       people, so read the next paragraph twice.

THE DEFAULT FRAME — THE #1 SOURCE OF CONFUSION
──────────────────────────────────────────────
  * With NO ORDER BY   -> the frame is the ENTIRE partition.
  * With an ORDER BY   -> the frame defaults to
                          RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
                          i.e. "everything from the start up to HERE".

That default is why SUM(...) OVER (ORDER BY ...) gives you a RUNNING total rather
than the grand total — which is usually what you wanted. It is also why LAST_VALUE
returns the wrong answer for almost everybody the first time. See Example 10.

NOTE: this file is documentation-verified against the Redshift Database Developer
Guide, and the expected outputs below were computed independently and checked before
being written down. It has not yet been run on a live cluster.
======================================================================================
*/


-- ============================================================================
-- SECTION 0: THE DATA — SMALL ENOUGH TO CHECK BY EYE
-- ============================================================================
-- A small retail chain. Two tables, twenty-four rows in total.

-- ---------------------------------------------------------------------------
-- TABLE 1: store_revenue — one row per store. Used for Bucket 1 (ranking).
-- ---------------------------------------------------------------------------
-- The TIES are deliberate. Three stores tie on 5000 and two pairs tie below it.
-- Without ties you cannot see the difference between RANK and DENSE_RANK, which
-- is the single most common OLAP interview question.
DROP TABLE IF EXISTS store_revenue CASCADE;
CREATE TABLE store_revenue (
    region     VARCHAR(10)   NOT NULL,
    store_name VARCHAR(10)   NOT NULL,
    revenue    DECIMAL(10,2) NOT NULL
)
DISTSTYLE ALL;

INSERT INTO store_revenue (region, store_name, revenue) VALUES
    ('North', 'Alpha',   5000),
    ('North', 'Bravo',   4000),
    ('North', 'Charlie', 4000),   -- ties with Bravo
    ('North', 'Delta',   3000),
    ('North', 'Echo',    2000),
    ('South', 'Foxtrot', 6000),
    ('South', 'Golf',    5000),
    ('South', 'Hotel',   5000),   -- ties with Golf
    ('South', 'India',   3000),
    ('South', 'Juliet',  1000);

-- Look at it before you do anything else:
SELECT * FROM store_revenue ORDER BY revenue DESC, store_name;
/*
 region | store_name | revenue
--------+------------+---------
 South  | Foxtrot    | 6000     <-- 1 store at 6000
 North  | Alpha      | 5000     <-- 3 stores tie at 5000
 South  | Golf       | 5000
 South  | Hotel      | 5000
 North  | Bravo      | 4000     <-- 2 stores tie at 4000
 North  | Charlie    | 4000
 North  | Delta      | 3000     <-- 2 stores tie at 3000
 South  | India      | 3000
 North  | Echo       | 2000
 South  | Juliet     | 1000
*/

-- ---------------------------------------------------------------------------
-- TABLE 2: daily_sales — two stores, seven days each. Buckets 2 and 3.
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS daily_sales CASCADE;
CREATE TABLE daily_sales (
    store_name VARCHAR(10)   NOT NULL,
    sale_date  DATE          NOT NULL,
    revenue    DECIMAL(10,2) NOT NULL
)
DISTSTYLE ALL;

INSERT INTO daily_sales (store_name, sale_date, revenue) VALUES
    ('Downtown', '2026-03-01', 100),
    ('Downtown', '2026-03-02', 120),
    ('Downtown', '2026-03-03',  90),
    ('Downtown', '2026-03-04', 150),
    ('Downtown', '2026-03-05', 130),
    ('Downtown', '2026-03-06', 170),
    ('Downtown', '2026-03-07', 140),
    ('Airport',  '2026-03-01',  80),
    ('Airport',  '2026-03-02',  95),
    ('Airport',  '2026-03-03', 110),
    ('Airport',  '2026-03-04', 105),
    ('Airport',  '2026-03-05', 125),
    ('Airport',  '2026-03-06', 100),
    ('Airport',  '2026-03-07', 160);

SELECT * FROM daily_sales ORDER BY store_name, sale_date;

ANALYZE store_revenue;
ANALYZE daily_sales;


-- ############################################################################
-- BUCKET 1 — RANKING & DISTRIBUTION
-- ############################################################################
-- All six of these need an ORDER BY inside the OVER clause. That is what "rank"
-- means: rank BY something.


-- ============================================================================
-- 1. ROW_NUMBER() — a unique sequential number. Never ties.
-- ============================================================================
-- Assigns 1, 2, 3, ... with no duplicates and no gaps, EVEN WHEN VALUES TIE.
-- Use it when you need exactly one row per group: "the latest record per
-- customer", "the top order per day". Deduplication is its main job.

SELECT
    store_name,
    revenue,
    ROW_NUMBER() OVER (ORDER BY revenue DESC, store_name) AS row_num
FROM store_revenue
ORDER BY row_num;
/*
 store_name | revenue | row_num
------------+---------+---------
 Foxtrot    |    6000 |       1
 Alpha      |    5000 |       2     <-- three stores tie on 5000, but
 Golf       |    5000 |       3         ROW_NUMBER still gives 2, 3, 4
 Hotel      |    5000 |       4
 Bravo      |    4000 |       5
 Charlie    |    4000 |       6
 Delta      |    3000 |       7
 India      |    3000 |       8
 Echo       |    2000 |       9
 Juliet     |    1000 |      10
*/
-- IMPORTANT: notice the tiebreaker ", store_name" in the ORDER BY. Without it,
-- which of Alpha/Golf/Hotel gets number 2 is ARBITRARY and can change between
-- runs. If you deduplicate with ROW_NUMBER and no tiebreaker, your pipeline is
-- not reproducible. Always break ties deliberately.

-- The classic use — top store PER REGION, one row each:
SELECT region, store_name, revenue
FROM (
    SELECT region, store_name, revenue,
           ROW_NUMBER() OVER (PARTITION BY region ORDER BY revenue DESC, store_name) AS rn
    FROM store_revenue
)
WHERE rn = 1;
/*
 region | store_name | revenue
--------+------------+---------
 North  | Alpha      |    5000
 South  | Foxtrot    |    6000
*/


-- ============================================================================
-- 2. RANK() — ties share a rank, and the next rank SKIPS.
-- ============================================================================
-- Think Olympic medals: two silvers means no bronze.
-- 1, 2, 2, 4  — the 3 is skipped because two rows occupy position 2.

SELECT
    store_name,
    revenue,
    RANK() OVER (ORDER BY revenue DESC) AS rnk
FROM store_revenue
ORDER BY rnk, store_name;
/*
 store_name | revenue | rnk
------------+---------+-----
 Foxtrot    |    6000 |   1
 Alpha      |    5000 |   2   <-- three-way tie, all get 2
 Golf       |    5000 |   2
 Hotel      |    5000 |   2
 Bravo      |    4000 |   5   <-- jumps to 5. Ranks 3 and 4 were consumed
 Charlie    |    4000 |   5       by the three stores sitting at rank 2.
 Delta      |    3000 |   7   <-- jumps again: 6 was consumed by Charlie
 India      |    3000 |   7
 Echo       |    2000 |   9
 Juliet     |    1000 |  10
*/
-- Read the gaps: 1, 2,2,2, 5,5, 7,7, 9, 10. The rank number always tells you
-- "how many stores did better than me, plus one".


-- ============================================================================
-- 3. DENSE_RANK() — ties share a rank, and the next rank does NOT skip.
-- ============================================================================
-- 1, 2, 2, 3 — no gaps. Use it when you want "distinct value levels" rather
-- than positions: the 3rd highest PRICE, not the 3rd row.

SELECT
    store_name,
    revenue,
    RANK()       OVER (ORDER BY revenue DESC) AS rnk,
    DENSE_RANK() OVER (ORDER BY revenue DESC) AS dense_rnk
FROM store_revenue
ORDER BY rnk, store_name;
/*
 store_name | revenue | rnk | dense_rnk
------------+---------+-----+-----------
 Foxtrot    |    6000 |   1 |         1
 Alpha      |    5000 |   2 |         2
 Golf       |    5000 |   2 |         2
 Hotel      |    5000 |   2 |         2
 Bravo      |    4000 |   5 |         3    <-- RANK jumps to 5, DENSE_RANK goes to 3
 Charlie    |    4000 |   5 |         3
 Delta      |    3000 |   7 |         4
 India      |    3000 |   7 |         4
 Echo       |    2000 |   9 |         5
 Juliet     |    1000 |  10 |         6
*/
-- SIDE BY SIDE, THE WHOLE LESSON:
--   ROW_NUMBER  1  2 3 4  5 6  7 8   9  10   always unique, ignores ties
--   RANK        1  2 2 2  5 5  7 7   9  10   ties share, next SKIPS
--   DENSE_RANK  1  2 2 2  3 3  4 4   5   6   ties share, next does NOT skip
-- DENSE_RANK's highest value (6) = the number of DISTINCT revenue values.


-- ============================================================================
-- 4. NTILE(n) — split the rows into n roughly equal buckets.
-- ============================================================================
-- NTILE(4) = quartiles. NTILE(10) = deciles. NTILE(100) = percentiles.
-- With 10 rows and 4 buckets, Redshift cannot divide evenly, so the EARLIER
-- buckets get the extra rows: sizes 3, 3, 2, 2.

SELECT
    store_name,
    revenue,
    NTILE(4) OVER (ORDER BY revenue DESC) AS quartile
FROM store_revenue
ORDER BY quartile, revenue DESC, store_name;
/*
 store_name | revenue | quartile
------------+---------+----------
 Foxtrot    |    6000 |        1   bucket 1 = top quartile (3 rows)
 Alpha      |    5000 |        1
 Golf       |    5000 |        1
 Hotel      |    5000 |        2   <-- READ THIS TWICE
 Bravo      |    4000 |        2   bucket 2 (3 rows)
 Charlie    |    4000 |        2
 Delta      |    3000 |        3   bucket 3 (2 rows)
 India      |    3000 |        3
 Echo       |    2000 |        4   bucket 4 (2 rows)
 Juliet     |    1000 |        4
*/
-- THE TRAP: Hotel has revenue 5000, exactly the same as Alpha and Golf, but it
-- landed in bucket 2 while they landed in bucket 1. NTILE DOES NOT RESPECT TIES.
-- It fills buckets by position, not by value. If equal values must land in equal
-- buckets, NTILE is the wrong tool — use PERCENT_RANK or CUME_DIST instead.


-- ============================================================================
-- 5. PERCENT_RANK() — relative standing, from 0.0 to 1.0.
-- ============================================================================
-- FORMULA:  (RANK - 1) / (TOTAL ROWS - 1)
-- The best row is always exactly 0.0; the worst is always exactly 1.0.
-- Here TOTAL ROWS = 10, so the divisor is 9.

SELECT
    store_name,
    revenue,
    RANK() OVER (ORDER BY revenue DESC)                        AS rnk,
    ROUND(PERCENT_RANK() OVER (ORDER BY revenue DESC), 4)      AS pct_rank
FROM store_revenue
ORDER BY rnk, store_name;
/*
 store_name | revenue | rnk | pct_rank
------------+---------+-----+----------
 Foxtrot    |    6000 |   1 |   0.0000   (1-1)/9 = 0
 Alpha      |    5000 |   2 |   0.1111   (2-1)/9 = 0.1111
 Golf       |    5000 |   2 |   0.1111
 Hotel      |    5000 |   2 |   0.1111   ties get the SAME value, unlike NTILE
 Bravo      |    4000 |   5 |   0.4444   (5-1)/9 = 0.4444
 Charlie    |    4000 |   5 |   0.4444
 Delta      |    3000 |   7 |   0.6667   (7-1)/9 = 0.6667
 India      |    3000 |   7 |   0.6667
 Echo       |    2000 |   9 |   0.8889   (9-1)/9 = 0.8889
 Juliet     |    1000 |  10 |   1.0000   (10-1)/9 = 1
*/
-- Because it is built on RANK, ties always share a value. Compare Hotel here
-- (0.1111, same as Alpha and Golf) with Hotel in Example 4 (bucket 2, different
-- from Alpha and Golf). That is the difference between the two tools.
-- "This store is in the top 11% of the chain."


-- ============================================================================
-- 6. CUME_DIST() — cumulative distribution. What fraction is at or above me?
-- ============================================================================
-- FORMULA:  (number of rows at or before this one in the ordering) / (total rows)
-- Always greater than 0; the last row is always exactly 1.0.

SELECT
    store_name,
    revenue,
    ROUND(PERCENT_RANK() OVER (ORDER BY revenue DESC), 4) AS pct_rank,
    ROUND(CUME_DIST()    OVER (ORDER BY revenue DESC), 4) AS cume_dist
FROM store_revenue
ORDER BY revenue DESC, store_name;
/*
 store_name | revenue | pct_rank | cume_dist
------------+---------+----------+-----------
 Foxtrot    |    6000 |   0.0000 |    0.1000   1 of 10 rows are >= 6000
 Alpha      |    5000 |   0.1111 |    0.4000   4 of 10 rows are >= 5000
 Golf       |    5000 |   0.1111 |    0.4000
 Hotel      |    5000 |   0.1111 |    0.4000
 Bravo      |    4000 |   0.4444 |    0.6000   6 of 10 rows are >= 4000
 Charlie    |    4000 |   0.4444 |    0.6000
 Delta      |    3000 |   0.6667 |    0.8000   8 of 10
 India      |    3000 |   0.6667 |    0.8000
 Echo       |    2000 |   0.8889 |    0.9000   9 of 10
 Juliet     |    1000 |   1.0000 |    1.0000  10 of 10
*/
-- PERCENT_RANK vs CUME_DIST, the difference in one line:
--   PERCENT_RANK starts at 0.0  ("how far down the list am I?")
--   CUME_DIST    ends   at 1.0  ("what share of rows have I caught up with?")
-- Use CUME_DIST for "the top 40% of stores"; note the 5000 group lands exactly
-- on 0.40, so "<= 0.40" includes all three of them.


-- ############################################################################
-- BUCKET 2 — OFFSET / NAVIGATION
-- ############################################################################
-- These reach into OTHER rows without a self-join. Before window functions you
-- had to join a table to itself on "date = date - 1", which was slow and wrong
-- at the edges. These replace all of that.


-- ============================================================================
-- 7. LEAD(col, offset) — look FORWARD to a later row.
-- ============================================================================
-- Default offset is 1 (the next row). Returns NULL when there is no next row.

SELECT
    sale_date,
    revenue,
    LEAD(revenue, 1) OVER (ORDER BY sale_date) AS next_day_revenue
FROM daily_sales
WHERE store_name = 'Downtown'
ORDER BY sale_date;
/*
 sale_date  | revenue | next_day_revenue
------------+---------+------------------
 2026-03-01 |     100 |              120
 2026-03-02 |     120 |               90
 2026-03-03 |      90 |              150
 2026-03-04 |     150 |              130
 2026-03-05 |     130 |              170
 2026-03-06 |     170 |              140
 2026-03-07 |     140 |           (null)   <-- no row after the last one
*/


-- ============================================================================
-- 8. LAG(col, offset) — look BACKWARD to an earlier row.
-- ============================================================================
-- The mirror of LEAD, and the more useful of the two: day-over-day change.

SELECT
    sale_date,
    revenue,
    LAG(revenue, 1) OVER (ORDER BY sale_date)              AS prev_day_revenue,
    revenue - LAG(revenue, 1) OVER (ORDER BY sale_date)    AS day_over_day_change
FROM daily_sales
WHERE store_name = 'Downtown'
ORDER BY sale_date;
/*
 sale_date  | revenue | prev_day_revenue | day_over_day_change
------------+---------+------------------+---------------------
 2026-03-01 |     100 |           (null) |              (null)   nothing before day 1
 2026-03-02 |     120 |              100 |                  20
 2026-03-03 |      90 |              120 |                 -30
 2026-03-04 |     150 |               90 |                  60
 2026-03-05 |     130 |              150 |                 -20
 2026-03-06 |     170 |              130 |                  40
 2026-03-07 |     140 |              170 |                 -30
*/
-- Give LAG a third argument to replace the NULL with a default:
--     LAG(revenue, 1, 0) OVER (ORDER BY sale_date)   -- first row gets 0, not NULL
-- PARTITION BY resets the lookback at each store — day 1 of Airport does NOT
-- reach back into Downtown's last day:
SELECT
    store_name, sale_date, revenue,
    LAG(revenue) OVER (PARTITION BY store_name ORDER BY sale_date) AS prev_day
FROM daily_sales
ORDER BY store_name, sale_date;
-- Both stores show (null) on 2026-03-01. That is PARTITION BY doing its job.


-- ============================================================================
-- 9. FIRST_VALUE(col) — the first value in the window frame.
-- ============================================================================
-- With the default frame this is safe: the frame starts at the beginning of the
-- partition, so "the first row" is what you expect.

SELECT
    sale_date,
    revenue,
    FIRST_VALUE(revenue) OVER (ORDER BY sale_date) AS first_day_revenue,
    revenue - FIRST_VALUE(revenue) OVER (ORDER BY sale_date) AS change_since_day_1
FROM daily_sales
WHERE store_name = 'Downtown'
ORDER BY sale_date;
/*
 sale_date  | revenue | first_day_revenue | change_since_day_1
------------+---------+-------------------+--------------------
 2026-03-01 |     100 |               100 |                  0
 2026-03-02 |     120 |               100 |                 20
 2026-03-03 |      90 |               100 |                -10
 2026-03-04 |     150 |               100 |                 50
 2026-03-05 |     130 |               100 |                 30
 2026-03-06 |     170 |               100 |                 70
 2026-03-07 |     140 |               100 |                 40
*/


-- ============================================================================
-- 10. LAST_VALUE(col) — ** THE CLASSIC TRAP. READ THE WHOLE EXAMPLE. **
-- ============================================================================
-- Everyone writes this first, and everyone gets a column that just repeats the
-- current row's own value. It is not a bug. It is the default frame.
--
-- Remember: with an ORDER BY, the frame is
--     RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
-- "The last row in the window" is therefore THE CURRENT ROW. Every time.

-- WRONG — looks reasonable, returns nonsense:
SELECT
    sale_date,
    revenue,
    LAST_VALUE(revenue) OVER (ORDER BY sale_date) AS last_value_WRONG
FROM daily_sales
WHERE store_name = 'Downtown'
ORDER BY sale_date;
/*
 sale_date  | revenue | last_value_WRONG
------------+---------+------------------
 2026-03-01 |     100 |              100   <-- just copies revenue
 2026-03-02 |     120 |              120
 2026-03-03 |      90 |               90
 2026-03-04 |     150 |              150
 2026-03-05 |     130 |              130
 2026-03-06 |     170 |              170
 2026-03-07 |     140 |              140
*/

-- RIGHT — open the frame to the end of the partition:
SELECT
    sale_date,
    revenue,
    LAST_VALUE(revenue) OVER (
        ORDER BY sale_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING   -- <-- the fix
    ) AS last_day_revenue
FROM daily_sales
WHERE store_name = 'Downtown'
ORDER BY sale_date;
/*
 sale_date  | revenue | last_day_revenue
------------+---------+------------------
 2026-03-01 |     100 |              140   <-- day 7's value, on every row
 2026-03-02 |     120 |              140
 2026-03-03 |      90 |              140
 2026-03-04 |     150 |              140
 2026-03-05 |     130 |              140
 2026-03-06 |     170 |              140
 2026-03-07 |     140 |              140
*/
-- THE RULE: FIRST_VALUE is safe with the default frame. LAST_VALUE is not.
-- Any time you write LAST_VALUE, write the frame too.
-- (Sneaky alternative: FIRST_VALUE with the ORDER BY reversed does the same job
--  and needs no frame clause — FIRST_VALUE(revenue) OVER (ORDER BY sale_date DESC).)


-- ============================================================================
-- 11. NTH_VALUE(col, n) — the nth value in the window frame.
-- ============================================================================
-- Same frame trap as LAST_VALUE: with the default frame, row 3 of the window
-- does not exist yet on rows 1 and 2, so you get NULL until the frame is wide
-- enough. Open the frame to make it mean "the 3rd day of the whole period".

SELECT
    sale_date,
    revenue,
    NTH_VALUE(revenue, 3) OVER (
        ORDER BY sale_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
    ) AS third_day_revenue
FROM daily_sales
WHERE store_name = 'Downtown'
ORDER BY sale_date;
/*
 sale_date  | revenue | third_day_revenue
------------+---------+-------------------
 2026-03-01 |     100 |                90   <-- day 3's value (90), on every row
 2026-03-02 |     120 |                90
 2026-03-03 |      90 |                90
 2026-03-04 |     150 |                90
 2026-03-05 |     130 |                90
 2026-03-06 |     170 |                90
 2026-03-07 |     140 |                90
*/
-- Without the frame clause the first two rows would be NULL, because the third
-- row of the window has not been reached yet. Try it and see.


-- ############################################################################
-- BUCKET 3 — WINDOWED AGGREGATES
-- ############################################################################
-- These are the SAME five aggregates you already know. Adding OVER turns them
-- from "collapse the rows" into "keep the rows and add a running column".
--
--   SUM(revenue)                          -> one number, all rows gone
--   SUM(revenue) OVER (ORDER BY date)     -> a running total, every row kept


-- ============================================================================
-- 12. SUM(col) OVER (...) — running total, or subtotal per partition.
-- ============================================================================

-- (a) RUNNING total — the ORDER BY is what makes it "running":
SELECT
    sale_date,
    revenue,
    SUM(revenue) OVER (ORDER BY sale_date) AS running_total
FROM daily_sales
WHERE store_name = 'Downtown'
ORDER BY sale_date;
/*
 sale_date  | revenue | running_total
------------+---------+---------------
 2026-03-01 |     100 |           100
 2026-03-02 |     120 |           220     100+120
 2026-03-03 |      90 |           310     220+90
 2026-03-04 |     150 |           460
 2026-03-05 |     130 |           590
 2026-03-06 |     170 |           760
 2026-03-07 |     140 |           900     the week's total
*/

-- (b) NO ORDER BY -> the frame is the whole partition -> a SUBTOTAL repeated
--     on every row. Extremely useful for "% of total" calculations:
SELECT
    store_name,
    sale_date,
    revenue,
    SUM(revenue) OVER (PARTITION BY store_name)            AS store_week_total,
    ROUND(100.0 * revenue
          / SUM(revenue) OVER (PARTITION BY store_name), 1) AS pct_of_store_week
FROM daily_sales
ORDER BY store_name, sale_date;
/*
 store_name | sale_date  | revenue | store_week_total | pct_of_store_week
------------+------------+---------+------------------+-------------------
 Airport    | 2026-03-01 |      80 |              775 |              10.3
 Airport    | 2026-03-02 |      95 |              775 |              12.3
 ...        |            |         |              775 |
 Downtown   | 2026-03-01 |     100 |              900 |              11.1
 Downtown   | 2026-03-02 |     120 |              900 |              13.3
 ...        |            |         |              900 |
*/
-- Downtown's week = 900, Airport's = 775. The total repeats on every row of its
-- own partition — that is the point. You could not do this with GROUP BY without
-- a second query and a join.


-- ============================================================================
-- 13. AVG(col) OVER (...) — running average, or a MOVING average via the frame.
-- ============================================================================
-- This is where the FRAME clause earns its keep.

SELECT
    sale_date,
    revenue,
    ROUND(AVG(revenue) OVER (ORDER BY sale_date), 2) AS running_avg,
    ROUND(AVG(revenue) OVER (
        ORDER BY sale_date
        ROWS BETWEEN 2 PRECEDING AND CURRENT ROW      -- <-- a 3-day window
    ), 2) AS moving_avg_3day
FROM daily_sales
WHERE store_name = 'Downtown'
ORDER BY sale_date;
/*
 sale_date  | revenue | running_avg | moving_avg_3day
------------+---------+-------------+-----------------
 2026-03-01 |     100 |      100.00 |          100.00   only 1 row available
 2026-03-02 |     120 |      110.00 |          110.00   (100+120)/2
 2026-03-03 |      90 |      103.33 |          103.33   (100+120+90)/3
 2026-03-04 |     150 |      115.00 |          120.00   (120+90+150)/3 <-- differs now
 2026-03-05 |     130 |      118.00 |          123.33   (90+150+130)/3
 2026-03-06 |     170 |      126.67 |          150.00   (150+130+170)/3
 2026-03-07 |     140 |      128.57 |          146.67   (130+170+140)/3
*/
-- The two columns agree for the first three days, then separate: the running
-- average keeps absorbing every earlier day, while the 3-day window forgets.
-- "ROWS BETWEEN 2 PRECEDING AND CURRENT ROW" = this row plus the two before it.


-- ============================================================================
-- 14. COUNT(col) OVER (...) — a running count of rows.
-- ============================================================================
SELECT
    sale_date,
    revenue,
    COUNT(*) OVER (ORDER BY sale_date)             AS days_so_far,
    COUNT(*) OVER (PARTITION BY store_name)        AS days_in_week
FROM daily_sales
WHERE store_name = 'Downtown'
ORDER BY sale_date;
/*
 sale_date  | revenue | days_so_far | days_in_week
------------+---------+-------------+--------------
 2026-03-01 |     100 |           1 |            7
 2026-03-02 |     120 |           2 |            7
 2026-03-03 |      90 |           3 |            7
 2026-03-04 |     150 |           4 |            7
 2026-03-05 |     130 |           5 |            7
 2026-03-06 |     170 |           6 |            7
 2026-03-07 |     140 |           7 |            7
*/
-- One column climbs (it has an ORDER BY), one is constant (it does not).
-- That single difference is the whole default-frame rule, visible side by side.


-- ============================================================================
-- 15. MIN(col) OVER (...) — the lowest value in the frame.
-- ============================================================================
-- ============================================================================
-- 16. MAX(col) OVER (...) — the highest value in the frame.
-- ============================================================================
-- Shown together, because they behave identically and are almost always used
-- as a pair: "worst day so far" and "best day so far".

SELECT
    sale_date,
    revenue,
    MIN(revenue) OVER (ORDER BY sale_date) AS worst_day_so_far,
    MAX(revenue) OVER (ORDER BY sale_date) AS best_day_so_far,
    MIN(revenue) OVER ()                   AS worst_day_overall,
    MAX(revenue) OVER ()                   AS best_day_overall
FROM daily_sales
WHERE store_name = 'Downtown'
ORDER BY sale_date;
/*
 sale_date  | revenue | worst_day_so_far | best_day_so_far | worst_day_overall | best_day_overall
------------+---------+------------------+-----------------+-------------------+------------------
 2026-03-01 |     100 |              100 |             100 |                90 |              170
 2026-03-02 |     120 |              100 |             120 |                90 |              170
 2026-03-03 |      90 |               90 |             120 |                90 |              170
 2026-03-04 |     150 |               90 |             150 |                90 |              170
 2026-03-05 |     130 |               90 |             150 |                90 |              170
 2026-03-06 |     170 |               90 |             170 |                90 |              170
 2026-03-07 |     140 |               90 |             170 |                90 |              170
*/
-- OVER () with nothing inside = the entire result set, one value repeated.
-- "so_far" columns only reach backwards because of the ORDER BY.
-- A running MAX is how you write "has this store beaten its own record today?"


-- ============================================================================
-- PUTTING IT TOGETHER — ONE QUERY, SEVERAL WINDOWS
-- ============================================================================
-- Real reports stack these. Note that each OVER clause is independent — they do
-- not interfere with each other, and none of them collapse any rows.
SELECT
    store_name,
    sale_date,
    revenue,
    RANK()       OVER (PARTITION BY store_name ORDER BY revenue DESC)  AS best_day_rank,
    LAG(revenue) OVER (PARTITION BY store_name ORDER BY sale_date)     AS prev_day,
    SUM(revenue) OVER (PARTITION BY store_name ORDER BY sale_date)     AS running_total,
    ROUND(100.0 * revenue
          / SUM(revenue) OVER (PARTITION BY store_name), 1)            AS pct_of_week
FROM daily_sales
ORDER BY store_name, sale_date;
-- 14 rows in, 14 rows out, four new columns. No GROUP BY anywhere.


-- ============================================================================
-- SUMMARY
-- ============================================================================
/*
┌────┬────────────────┬──────────────────────────────┬────────────────────────────┐
│ #  │ Function       │ Answers                      │ Watch out for              │
├────┼────────────────┼──────────────────────────────┼────────────────────────────┤
│    │ BUCKET 1 — RANKING & DISTRIBUTION                                          │
│  1 │ ROW_NUMBER()   │ unique 1,2,3 — no ties ever  │ add a TIEBREAKER to ORDER  │
│    │                │                              │ BY or it is not repeatable │
│  2 │ RANK()         │ ties share, next SKIPS       │ 1,2,2,4 — gaps are correct │
│  3 │ DENSE_RANK()   │ ties share, next does NOT    │ 1,2,2,3 — no gaps          │
│  4 │ NTILE(n)       │ n equal-sized buckets        │ IGNORES TIES. Equal values │
│    │                │                              │ can land in diff buckets   │
│  5 │ PERCENT_RANK() │ (rank-1)/(rows-1), 0.0→1.0   │ first row is always 0.0    │
│  6 │ CUME_DIST()    │ share of rows at/above me    │ last row is always 1.0     │
├────┼────────────────┼──────────────────────────────┼────────────────────────────┤
│    │ BUCKET 2 — OFFSET / NAVIGATION                                             │
│  7 │ LEAD(c,n)      │ a value from a LATER row     │ NULL at the end            │
│  8 │ LAG(c,n)       │ a value from an EARLIER row  │ NULL at the start; 3rd arg │
│    │                │                              │ supplies a default         │
│  9 │ FIRST_VALUE(c) │ first row of the frame       │ safe with default frame    │
│ 10 │ LAST_VALUE(c)  │ last row of the frame        │ ** BROKEN by default. **   │
│    │                │                              │ Needs ROWS BETWEEN         │
│    │                │                              │ UNBOUNDED PRECEDING AND    │
│    │                │                              │ UNBOUNDED FOLLOWING        │
│ 11 │ NTH_VALUE(c,n) │ nth row of the frame         │ same frame trap as #10     │
├────┼────────────────┼──────────────────────────────┼────────────────────────────┤
│    │ BUCKET 3 — WINDOWED AGGREGATES                                             │
│ 12 │ SUM() OVER     │ running total / subtotal     │ ORDER BY = running,        │
│ 13 │ AVG() OVER     │ running or MOVING average    │ no ORDER BY = whole        │
│ 14 │ COUNT() OVER   │ running count                │ partition repeated         │
│ 15 │ MIN() OVER     │ lowest in the frame          │ use the FRAME clause for   │
│ 16 │ MAX() OVER     │ highest in the frame         │ moving windows             │
└────┴────────────────┴──────────────────────────────┴────────────────────────────┘

THE THREE THINGS THAT CATCH EVERYONE
  1. LAST_VALUE with the default frame returns the current row. Always write the
     frame. (Example 10)
  2. ROW_NUMBER with no tiebreaker is not reproducible between runs. (Example 1)
  3. NTILE splits tied values across buckets. Use PERCENT_RANK or CUME_DIST if
     equal values must be treated equally. (Example 4)

THE DEFAULT FRAME, ONE LAST TIME
  no ORDER BY   -> the entire partition
  with ORDER BY -> RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW

WHERE TO GO NEXT
  51.1  the advanced module — sessionization, attribution, deciling at scale
  37    GROUPING SETS / ROLLUP / CUBE — the other way to get subtotals
  36    deterministic deduplication with ROW_NUMBER, in a real pipeline
  77    why a window function inside a MATERIALIZED VIEW forces a full recompute

  Still to cover elsewhere: MEDIAN, PERCENTILE_CONT, PERCENTILE_DISC,
  RATIO_TO_REPORT and LISTAGG.
*/




-- ############################################################################
-- PART 2 — THREE APPLIED TEACHING MODULES
-- ############################################################################
-- Part 1 taught the sixteen functions one at a time. These three put them to
-- work on questions people actually get asked, and each carries a trap that
-- catches almost every student the first time.

-- ---------------------------------------------------------------------------
-- Extra data for Parts 2 and 3
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS sales_team CASCADE;
CREATE TABLE sales_team (
    emp_id  VARCHAR(4)    NOT NULL,
    region  VARCHAR(10)   NOT NULL,
    revenue DECIMAL(10,2) NOT NULL
)
DISTSTYLE ALL;

INSERT INTO sales_team (emp_id, region, revenue) VALUES
    ('E01','North',9000), ('E02','North',8000), ('E03','North',7000),
    ('E04','North',7000),                             -- TIE for 3rd place
    ('E05','North',5000),
    ('E06','South',9500), ('E07','South',8500), ('E08','South',6000),
    ('E09','South',4000), ('E10','South',3000);

-- revenue is deliberately INTEGER here. Module B depends on that.
DROP TABLE IF EXISTS monthly_sales CASCADE;
CREATE TABLE monthly_sales (
    sale_month CHAR(7) NOT NULL,
    revenue    INTEGER NOT NULL          -- <-- INTEGER. This is the trap.
)
DISTSTYLE ALL;

INSERT INTO monthly_sales (sale_month, revenue) VALUES
    ('2026-01',100000), ('2026-02',110000), ('2026-03', 99000),
    ('2026-04',125000), ('2026-05',130000), ('2026-06',120000);

DROP TABLE IF EXISTS support_tickets CASCADE;
CREATE TABLE support_tickets (
    ticket_date DATE    NOT NULL,
    day_name    CHAR(3) NOT NULL,
    tickets     INTEGER NOT NULL
)
DISTSTYLE ALL;

INSERT INTO support_tickets (ticket_date, day_name, tickets) VALUES
    ('2026-03-02','Mon',120), ('2026-03-03','Tue',135), ('2026-03-04','Wed',128),
    ('2026-03-05','Thu',142), ('2026-03-06','Fri',118), ('2026-03-07','Sat', 45),
    ('2026-03-08','Sun', 38), ('2026-03-09','Mon',130), ('2026-03-10','Tue',140),
    ('2026-03-11','Wed',125), ('2026-03-12','Thu',150), ('2026-03-13','Fri',122),
    ('2026-03-14','Sat', 50), ('2026-03-15','Sun', 42);

ANALYZE sales_team;
ANALYZE monthly_sales;
ANALYZE support_tickets;


-- ============================================================================
-- MODULE A — THE "TOP N" PROBLEM   (0:20 - 0:50 in the agenda)
-- ============================================================================
-- THE SCENARIO: the VP of Sales does not want everyone's revenue. They want the
-- Top 3 salespeople IN EACH REGION.
--
-- THE TEACHING POINT: you cannot put a window function in a WHERE clause.
-- To filter on one you must wrap it in a CTE (or a subquery) first.

-- WRONG — run it and read the error. That error IS the lesson.
SELECT emp_id, region, revenue
FROM sales_team
WHERE DENSE_RANK() OVER (PARTITION BY region ORDER BY revenue DESC) <= 3;
/*
 ERROR: window functions are not allowed in WHERE

 WHY: SQL evaluates WHERE before window functions run. At the moment WHERE is
 applied, the rank does not exist yet. The order is roughly:

   FROM -> WHERE -> GROUP BY -> HAVING -> WINDOW FUNCTIONS -> SELECT -> ORDER BY

 Window functions sit almost last. You cannot filter on something that has not
 been computed. Same reason you cannot use a SELECT alias in WHERE.
*/

-- RIGHT — compute the rank in a CTE, filter in the outer query:
WITH ranked_sales AS (
    SELECT
        emp_id,
        region,
        revenue,
        DENSE_RANK() OVER (PARTITION BY region ORDER BY revenue DESC) AS sales_rank
    FROM sales_team
)
SELECT emp_id, region, revenue, sales_rank
FROM ranked_sales
WHERE sales_rank <= 3
ORDER BY region, sales_rank, emp_id;
/*
 emp_id | region | revenue | sales_rank
--------+--------+---------+------------
 E01    | North  |    9000 |          1
 E02    | North  |    8000 |          2
 E03    | North  |    7000 |          3   <-- FOUR rows from North, because
 E04    | North  |    7000 |          3       E03 and E04 TIE for 3rd place
 E06    | South  |    9500 |          1
 E07    | South  |    8500 |          2
 E08    | South  |    6000 |          3   <-- three rows from South
*/

/*
TEACHER TIP — ASK BEFORE YOU RUN IT
  "What happens if two salespeople tie for 3rd place?"

  Let them guess, then run it. North returns FOUR people, not three.

  That is the correct business answer — you cannot tell E03 they made the cut
  and E04 they did not when they sold exactly the same. But it means "Top 3" can
  return more than 3 rows, and the VP has to be told that up front.

  Now swap DENSE_RANK for ROW_NUMBER and run it again. North returns exactly
  three, and E03 or E04 is dropped AT RANDOM -- whichever the engine read first.
  Run it twice; the survivor can change.

  THE CHOICE
    ROW_NUMBER  exactly N rows, ties broken arbitrarily. Only safe when you
                genuinely need one row AND you added a tiebreaker to ORDER BY.
    RANK        ties share, next rank SKIPS. A 3-way tie at 1st means "top 3"
                returns 3 rows and the next rank is 4.
    DENSE_RANK  ties share, no gaps. Usually what "top N" means in business.
*/


-- ============================================================================
-- MODULE B — TIME-TRAVEL ANALYSIS   (1:00 - 1:30 in the agenda)
-- ============================================================================
-- THE SCENARIO: marketing needs month-over-month growth percentages.
--
-- THE TEACHING POINT: LAG and LEAD eliminate the expensive self-join people
-- write before they know these exist.

-- THE OLD WAY, for contrast — a self-join. It works, it is slow, and it is
-- fiddly at the edges:
-- SELECT a.sale_month, a.revenue, b.revenue AS prev_revenue
-- FROM monthly_sales a
-- LEFT JOIN monthly_sales b
--        ON b.sale_month = TO_CHAR(DATEADD(month, -1, (a.sale_month||'-01')::DATE), 'YYYY-MM');

-- WRONG — the integer division trap. EVERY percentage comes back 0.
SELECT
    sale_month,
    revenue,
    LAG(revenue, 1) OVER (ORDER BY sale_month) AS prev_month_revenue,
    (revenue - LAG(revenue, 1) OVER (ORDER BY sale_month))
        / LAG(revenue, 1) OVER (ORDER BY sale_month) * 100 AS mom_growth_WRONG
FROM monthly_sales
ORDER BY sale_month;
/*
 sale_month | revenue | prev_month_revenue | mom_growth_WRONG
------------+---------+--------------------+------------------
 2026-01    |  100000 |             (null) |           (null)
 2026-02    |  110000 |             100000 |                0    should be  10.00
 2026-03    |   99000 |             110000 |                0    should be -10.00
 2026-04    |  125000 |              99000 |                0    should be  26.26
 2026-05    |  130000 |             125000 |                0    should be   4.00
 2026-06    |  120000 |             130000 |                0    should be  -7.69
*/
-- WHY EVERY ROW IS ZERO: revenue is INTEGER, so INTEGER / INTEGER is integer
-- division and SQL truncates TOWARD ZERO. 10000 / 100000 = 0. Multiplying zero
-- by 100 is still zero. The negative months truncate to zero too -- so you do
-- not even get a sign to tip you off.
-- Nothing errors. You just ship a dashboard where nothing ever grows.

-- RIGHT — cast to decimal BEFORE the division, not after:
SELECT
    sale_month,
    revenue,
    LAG(revenue, 1) OVER (ORDER BY sale_month) AS prev_month_revenue,
    ROUND(
        (revenue - LAG(revenue, 1) OVER (ORDER BY sale_month))::DECIMAL(12,2)
        / LAG(revenue, 1) OVER (ORDER BY sale_month) * 100
    , 2) AS mom_growth_pct
FROM monthly_sales
ORDER BY sale_month;
/*
 sale_month | revenue | prev_month_revenue | mom_growth_pct
------------+---------+--------------------+----------------
 2026-01    |  100000 |             (null) |         (null)   no prior month
 2026-02    |  110000 |             100000 |          10.00
 2026-03    |   99000 |             110000 |         -10.00
 2026-04    |  125000 |              99000 |          26.26
 2026-05    |  130000 |             125000 |           4.00
 2026-06    |  120000 |             130000 |          -7.69
*/

/*
TEACHER TIPS
  1. WATCH FOR INTEGER DIVISION. If both sides are integers, SQL truncates
     toward zero. Cast with ::DECIMAL (or multiply by 100.0 instead of 100)
     BEFORE dividing. The giveaway is a column of clean zeros.
  2. THE FIRST ROW IS ALWAYS NULL. There is no month before the first month.
     That is correct, not a bug. LAG(revenue, 1, 0) supplies a default -- but
     that then divides by zero on row one. NULL is usually the honest answer.
  3. GUARD THE DENOMINATOR. If a prior month can legitimately be 0, wrap it:
     NULLIF(LAG(revenue,1) OVER (...), 0) gives NULL instead of an error.
*/


-- ============================================================================
-- MODULE C — THE FRAME CLAUSE MASTERCLASS   (1:30 - 1:45 in the agenda)
-- ============================================================================
-- THE SCENARIO: operations needs a 7-day rolling average of support tickets to
-- smooth out the weekend dips.
--
-- THE TEACHING POINT: with an ORDER BY and no explicit frame you get a RUNNING
-- total from the start of the partition. For a MOVING window you must write the
-- frame yourself.

SELECT
    ticket_date,
    day_name,
    tickets,
    ROUND(AVG(tickets) OVER (
        ORDER BY ticket_date
        ROWS BETWEEN 6 PRECEDING AND CURRENT ROW     -- 7 days: today + 6 before
    ), 2) AS rolling_7d_avg,
    ROUND(AVG(tickets) OVER (ORDER BY ticket_date), 2) AS running_avg_for_contrast
FROM support_tickets
ORDER BY ticket_date;
/*
 ticket_date | day_name | tickets | rolling_7d_avg | running_avg_for_contrast
-------------+----------+---------+----------------+--------------------------
 2026-03-02  | Mon      |     120 |         120.00 |                   120.00
 2026-03-03  | Tue      |     135 |         127.50 |                   127.50
 2026-03-04  | Wed      |     128 |         127.67 |                   127.67
 2026-03-05  | Thu      |     142 |         131.25 |                   131.25
 2026-03-06  | Fri      |     118 |         128.60 |                   128.60
 2026-03-07  | Sat      |      45 |         114.67 |                   114.67   weekend dip
 2026-03-08  | Sun      |      38 |         103.71 |                   103.71   weekend dip
 2026-03-09  | Mon      |     130 |         105.14 |                   107.00   <-- they SEPARATE
 2026-03-10  | Tue      |     140 |         105.86 |                   110.67
 2026-03-11  | Wed      |     125 |         105.43 |                   112.10
 2026-03-12  | Thu      |     150 |         106.57 |                   115.55
 2026-03-13  | Fri      |     122 |         107.14 |                   116.08
 2026-03-14  | Sat      |      50 |         107.86 |                   111.00
 2026-03-15  | Sun      |      42 |         108.43 |                   106.07
*/
-- READ THE TWO COLUMNS SIDE BY SIDE. Identical for the first seven days --
-- the window has not filled yet, so "the last 7 days" and "everything so far"
-- are the same rows. From day 8 they separate permanently: the rolling column
-- FORGETS day 1, the running column never forgets anything. Once full, the
-- rolling average settles around 105-108. That settling is what "smoothing out
-- the weekend dips" actually means.

/*
WHITEBOARD THIS — THE FRAME ANCHORS

    ROWS BETWEEN  ______________  AND  ______________
                  where it STARTS      where it ENDS

      UNBOUNDED PRECEDING   the very beginning of the partition
      N PRECEDING           N rows back from here
      CURRENT ROW           exactly where you are now
      N FOLLOWING           N rows forward from here
      UNBOUNDED FOLLOWING   the very end of the partition

  READ THEM AS A PAIR:
    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW          running total
    ROWS BETWEEN 6 PRECEDING         AND CURRENT ROW          7-day trailing
    ROWS BETWEEN 3 PRECEDING         AND 3 FOLLOWING          7-day CENTRED
    ROWS BETWEEN CURRENT ROW         AND UNBOUNDED FOLLOWING  everything ahead
    ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING  the whole partition
*/

-- A centred window, for comparison — note that it can see the future:
SELECT
    ticket_date,
    tickets,
    ROUND(AVG(tickets) OVER (
        ORDER BY ticket_date
        ROWS BETWEEN 3 PRECEDING AND 3 FOLLOWING
    ), 2) AS centred_7d_avg
FROM support_tickets
ORDER BY ticket_date;
-- Centred averages look smoother, but you cannot put one on a live dashboard:
-- on today's row it reads rows that have not happened yet.

/*
ONE PRECISION POINT — ROWS vs RANGE

  The DEFAULT frame when you write ORDER BY and nothing else is
      RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
  not ROWS. Usually they behave identically, so it rarely matters.

  They differ when the ORDER BY column has TIES:
      ROWS  counts physical rows.  "current row" means literally this one row.
      RANGE counts by VALUE.       "current row" means every row tying with this
                                    one on the ORDER BY column.

  With two rows sharing a date, a RANGE running total jumps by BOTH values on
  the first of them; a ROWS running total adds them one at a time. Our data has
  one row per date, so both agree here.

  RULE OF THUMB: if you are writing a frame at all, write ROWS. It means what
  you think it means. Use RANGE only when you deliberately want tied rows
  treated as one step.
*/


-- ============================================================================
-- REDSHIFT PERFORMANCE GOTCHA — PARTITION BY AND YOUR DISTKEY
-- ============================================================================
-- Everything above is standard SQL. This part is specific to Redshift, and it
-- is what separates a query that scales from one that does not.
--
-- THE PROBLEM
--   A window function needs every row of a partition physically together, in
--   order, before it can compute anything. Redshift spreads your table across
--   the slices of the cluster. If one partition's rows are scattered over many
--   slices, the cluster must SHUFFLE them across the network first. On a large
--   table that network movement -- not the arithmetic -- is the whole cost.
--
-- THE FIX
--   Align your PARTITION BY column with the table's DISTKEY. Partition by
--   region on a table already distributed by region and every partition is
--   already sitting complete on one slice. Nothing moves.
--
--       PARTITION BY region  +  DISTKEY (region)   -> no shuffle
--       PARTITION BY region  +  DISTSTYLE EVEN     -> full redistribution
--
--   Add a SORTKEY on the ORDER BY column and the per-partition sort can be
--   skipped too.
--
-- HOW TO CHECK: EXPLAIN, and read the line above the Window operator.
--   DS_DIST_NONE  -> partitions were already collocated. Good.
--   DS_DIST_BOTH  -> Redshift redistributed the data to build the windows.
--
-- Our teaching tables are DISTSTYLE ALL (a full copy on every node), which is
-- correct at this size and sidesteps the issue. On a real fact table the
-- alignment is what matters.

EXPLAIN
SELECT region, emp_id, revenue,
       RANK() OVER (PARTITION BY region ORDER BY revenue DESC) AS rnk
FROM sales_team;

-- Modules 28 and 29 cover the distribution side in full;
-- module 52.1 covers what the JOIN does once the rows arrive.


-- ############################################################################
-- PART 3 — ADVANCED PATTERNS   (1:45 - 2:00 in the agenda)
-- ############################################################################
-- The last fifteen minutes. These are the ones that generate discussion.

-- ---------------------------------------------------------------------------
-- Data for the gaps-and-islands module
-- ---------------------------------------------------------------------------
-- Two tickers, eleven CONSECUTIVE CALENDAR DAYS each. A day is "green" when
-- close_price > open_price.
DROP TABLE IF EXISTS market_data CASCADE;
CREATE TABLE market_data (
    ticker      CHAR(3)       NOT NULL,
    trade_date  DATE          NOT NULL,
    open_price  DECIMAL(10,2) NOT NULL,
    close_price DECIMAL(10,2) NOT NULL
)
DISTSTYLE ALL;

INSERT INTO market_data (ticker, trade_date, open_price, close_price) VALUES
    -- AAA: green 2,3 | red 4 | green 5,6,7,8 | red 9 | green 10,11 | red 12
    ('AAA','2026-03-02',100,102), ('AAA','2026-03-03',102,105),
    ('AAA','2026-03-04',105,103),
    ('AAA','2026-03-05',103,106), ('AAA','2026-03-06',106,108),
    ('AAA','2026-03-07',108,109), ('AAA','2026-03-08',109,112),
    ('AAA','2026-03-09',112,110),
    ('AAA','2026-03-10',110,113), ('AAA','2026-03-11',113,115),
    ('AAA','2026-03-12',115,114),
    -- BBB: green 2 | red 3 | green 4,5,6 | red 7 | green 8,9,10,11,12
    ('BBB','2026-03-02', 50, 52), ('BBB','2026-03-03', 52, 51),
    ('BBB','2026-03-04', 51, 53), ('BBB','2026-03-05', 53, 55),
    ('BBB','2026-03-06', 55, 57), ('BBB','2026-03-07', 57, 56),
    ('BBB','2026-03-08', 56, 58), ('BBB','2026-03-09', 58, 60),
    ('BBB','2026-03-10', 60, 62), ('BBB','2026-03-11', 62, 64),
    ('BBB','2026-03-12', 64, 66);

ANALYZE market_data;


-- ============================================================================
-- ADVANCED 1 — THE "GAPS AND ISLANDS" PROBLEM
-- ============================================================================
-- THE SCENARIO: what is the longest STREAK of consecutive days a stock closed
-- green? This is a classic senior-level SQL interview question.
--
-- THE TRICK: subtract ROW_NUMBER() from the date. For any run of consecutive
-- days, the date climbs by 1 and the row number climbs by 1, so the difference
-- STAYS CONSTANT. That constant becomes the group id. The moment a day is
-- missing, the difference jumps and a new group starts.

-- STEP BY STEP — show this middle result first, it is where the penny drops:
WITH green_days AS (
    SELECT ticker, trade_date
    FROM market_data
    WHERE close_price > open_price
)
SELECT
    ticker,
    trade_date,
    ROW_NUMBER() OVER (PARTITION BY ticker ORDER BY trade_date) AS rn,
    trade_date - (ROW_NUMBER() OVER (PARTITION BY ticker ORDER BY trade_date))::INT
        AS streak_group
FROM green_days
ORDER BY ticker, trade_date;
/*
 ticker | trade_date | rn | streak_group
--------+------------+----+--------------
 AAA    | 2026-03-02 |  1 | 2026-03-01      <-- same anchor
 AAA    | 2026-03-03 |  2 | 2026-03-01      <-- same anchor  = one island
 AAA    | 2026-03-05 |  3 | 2026-03-02      <-- ANCHOR MOVED: the 4th was red
 AAA    | 2026-03-06 |  4 | 2026-03-02
 AAA    | 2026-03-07 |  5 | 2026-03-02
 AAA    | 2026-03-08 |  6 | 2026-03-02      <-- four days, one island
 AAA    | 2026-03-10 |  7 | 2026-03-03      <-- moved again: the 9th was red
 AAA    | 2026-03-11 |  8 | 2026-03-03
 BBB    | 2026-03-02 |  1 | 2026-03-01
 BBB    | 2026-03-04 |  2 | 2026-03-02
 BBB    | 2026-03-05 |  3 | 2026-03-02
 BBB    | 2026-03-06 |  4 | 2026-03-02
 BBB    | 2026-03-08 |  5 | 2026-03-03
 BBB    | 2026-03-09 |  6 | 2026-03-03
 BBB    | 2026-03-10 |  7 | 2026-03-03
 BBB    | 2026-03-11 |  8 | 2026-03-03
 BBB    | 2026-03-12 |  9 | 2026-03-03      <-- five days, one island
*/
-- Point at the streak_group column. Every run of consecutive dates collapses to
-- one repeated value. That column is now just a GROUP BY key.

-- THE FULL ANSWER — group by the anchor and count:
WITH green_days AS (
    SELECT ticker, trade_date, close_price
    FROM market_data
    WHERE close_price > open_price
),
streak_groups AS (
    SELECT
        ticker,
        trade_date,
        trade_date - (ROW_NUMBER() OVER (PARTITION BY ticker ORDER BY trade_date))::INT
            AS streak_group
    FROM green_days
)
SELECT
    ticker,
    MIN(trade_date) AS streak_start,
    MAX(trade_date) AS streak_end,
    COUNT(*)        AS consecutive_green_days
FROM streak_groups
GROUP BY ticker, streak_group
ORDER BY consecutive_green_days DESC, ticker, streak_start;
/*
 ticker | streak_start | streak_end | consecutive_green_days
--------+--------------+------------+------------------------
 BBB    | 2026-03-08   | 2026-03-12 |                      5   <-- the winner
 AAA    | 2026-03-05   | 2026-03-08 |                      4
 BBB    | 2026-03-04   | 2026-03-06 |                      3
 AAA    | 2026-03-02   | 2026-03-03 |                      2
 AAA    | 2026-03-10   | 2026-03-11 |                      2
 BBB    | 2026-03-02   | 2026-03-02 |                      1
*/

/*
TEACHER NOTES
  * The PARTITION BY ticker matters. Without it the row numbers run straight
    through from AAA into BBB and every streak is wrong. Ask the class why.
  * This data uses CONSECUTIVE CALENDAR DAYS on purpose. Real market data has
    no weekend rows, so Fri -> Mon is a 3-day date gap and this technique would
    split a genuine streak in two. The fix for real trading data: rank the
    TRADING calendar and subtract two row numbers instead of a date --
    ROW_NUMBER() over all days minus ROW_NUMBER() over green days. Same idea,
    one level up. Worth mentioning; do not derail the lesson with it.
  * The pattern generalises far beyond stocks: consecutive login days, unbroken
    subscription months, sensor uptime runs, "how many days has this been
    failing". Any time somebody says "streak" or "consecutive", this is it.
*/


-- ============================================================================
-- ADVANCED 2 — THE WINDOW CLAUSE (writing clean code)
-- ============================================================================
-- THE SCENARIO: a student needs a running total, a rolling average and a
-- running max, all over the SAME partition and order. The SELECT becomes an
-- unreadable wall of repeated OVER clauses.

-- THE PROBLEM — the same window spelled out three times. Change the ORDER BY
-- and you must remember to change it in all three, or you ship a subtle bug:
SELECT
    store_name,
    sale_date,
    revenue,
    SUM(revenue) OVER (PARTITION BY store_name ORDER BY sale_date ROWS UNBOUNDED PRECEDING) AS running_total,
    ROUND(AVG(revenue) OVER (PARTITION BY store_name ORDER BY sale_date ROWS UNBOUNDED PRECEDING), 2) AS running_avg,
    MAX(revenue) OVER (PARTITION BY store_name ORDER BY sale_date ROWS UNBOUNDED PRECEDING) AS highest_to_date
FROM daily_sales
ORDER BY store_name, sale_date;

-- THE CLEAN VERSION — define the window ONCE, at the bottom, and name it:
SELECT
    store_name,
    sale_date,
    revenue,
    SUM(revenue)        OVER w AS running_total,
    ROUND(AVG(revenue)  OVER w, 2) AS running_avg,
    MAX(revenue)        OVER w AS highest_to_date
FROM daily_sales
WINDOW w AS (PARTITION BY store_name ORDER BY sale_date ROWS UNBOUNDED PRECEDING)
ORDER BY store_name, sale_date;
/*
 store_name | sale_date  | revenue | running_total | running_avg | highest_to_date
------------+------------+---------+---------------+-------------+-----------------
 Downtown   | 2026-03-01 |     100 |           100 |      100.00 |             100
 Downtown   | 2026-03-02 |     120 |           220 |      110.00 |             120
 Downtown   | 2026-03-03 |      90 |           310 |      103.33 |             120
 Downtown   | 2026-03-04 |     150 |           460 |      115.00 |             150
 Downtown   | 2026-03-05 |     130 |           590 |      118.00 |             150
 Downtown   | 2026-03-06 |     170 |           760 |      126.67 |             170
 Downtown   | 2026-03-07 |     140 |           900 |      128.57 |             170
 (Airport follows, its own partition, counters reset)
*/

/*
!! VERIFY THIS ONE ON YOUR OWN CLUSTER BEFORE YOU TEACH IT !!

  The named WINDOW clause is standard SQL and PostgreSQL has had it since 8.4.
  Redshift's SQL dialect derives from PostgreSQL 8.0.2, and several later
  PostgreSQL additions were never carried across. I could not confirm from the
  Redshift documentation that WINDOW is supported, so treat the query above as
  UNVERIFIED until you have run it.

  Run it. If it works, use it -- it is genuinely better code.
  If it errors, the portable fallback is a CTE, which every version supports and
  which achieves the same "define it once" goal:
*/
WITH windowed AS (
    SELECT
        store_name,
        sale_date,
        revenue,
        SUM(revenue) OVER (PARTITION BY store_name ORDER BY sale_date ROWS UNBOUNDED PRECEDING) AS running_total,
        AVG(revenue) OVER (PARTITION BY store_name ORDER BY sale_date ROWS UNBOUNDED PRECEDING) AS running_avg,
        MAX(revenue) OVER (PARTITION BY store_name ORDER BY sale_date ROWS UNBOUNDED PRECEDING) AS highest_to_date
    FROM daily_sales
)
SELECT store_name, sale_date, revenue,
       running_total, ROUND(running_avg, 2) AS running_avg, highest_to_date
FROM windowed
ORDER BY store_name, sale_date;

-- Note: "ROWS UNBOUNDED PRECEDING" is shorthand for
-- "ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW". Same thing, less typing.


-- ============================================================================
-- ADVANCED 3 — CUME_DIST vs PERCENT_RANK, SETTLED
-- ============================================================================
-- THE SCENARIO: you are evaluating performance and want to know whether a row
-- is in the "top 10%". Students confuse these two constantly. Ten minutes here
-- is time well spent.
--
--   PERCENT_RANK()  POSITION.  (rank - 1) / (total rows - 1)
--                   "How far down the list am I?"   First row is ALWAYS 0.0
--
--   CUME_DIST()     VOLUME.    (rows at or before me) / (total rows)
--                   "What share of the data is at or behind me?"
--                   Last row is ALWAYS 1.0, and no row is ever 0.0
--
-- Ordered ASCENDING here so "behind me" reads naturally as "worse than me".

SELECT
    store_name,
    revenue,
    RANK()         OVER (ORDER BY revenue)            AS rank_asc,
    ROUND(PERCENT_RANK() OVER (ORDER BY revenue), 4)  AS percent_rank,
    ROUND(CUME_DIST()    OVER (ORDER BY revenue), 4)  AS cume_dist
FROM store_revenue
ORDER BY revenue, store_name;
/*
 store_name | revenue | rank_asc | percent_rank | cume_dist
------------+---------+----------+--------------+-----------
 Juliet     |    1000 |        1 |       0.0000 |    0.1000   first row: PR is 0, CD is not
 Echo       |    2000 |        2 |       0.1111 |    0.2000
 Delta      |    3000 |        3 |       0.2222 |    0.4000   two rows tie at 3000, so
 India      |    3000 |        3 |       0.2222 |    0.4000   CD jumps 0.2 -> 0.4 in one step
 Bravo      |    4000 |        5 |       0.4444 |    0.6000
 Charlie    |    4000 |        5 |       0.4444 |    0.6000
 Alpha      |    5000 |        7 |       0.6667 |    0.9000   THREE rows tie at 5000, so
 Golf       |    5000 |        7 |       0.6667 |    0.9000   CD jumps 0.6 -> 0.9
 Hotel      |    5000 |        7 |       0.6667 |    0.9000
 Foxtrot    |    6000 |       10 |       1.0000 |    1.0000   last row: both are 1.0
*/
-- WATCH THE TIES. Both functions give tied rows the SAME value -- unlike NTILE.
-- But CUME_DIST jumps by the SIZE of the tie group (0.6 straight to 0.9 across
-- the three stores at 5000), because it counts rows, not positions.

-- "WHO IS IN THE TOP 10%?" — the practical question, and the answer differs:
SELECT
    store_name,
    revenue,
    ROUND(PERCENT_RANK() OVER (ORDER BY revenue DESC), 4) AS pr_desc,
    ROUND(CUME_DIST()    OVER (ORDER BY revenue DESC), 4) AS cd_desc,
    CASE WHEN PERCENT_RANK() OVER (ORDER BY revenue DESC) <= 0.10
         THEN 'yes' ELSE 'no' END AS top10_by_percent_rank,
    CASE WHEN CUME_DIST()    OVER (ORDER BY revenue DESC) <= 0.10
         THEN 'yes' ELSE 'no' END AS top10_by_cume_dist
FROM store_revenue
ORDER BY revenue DESC, store_name;
/*
 store_name | revenue | pr_desc | cd_desc | top10_by_percent_rank | top10_by_cume_dist
------------+---------+---------+---------+-----------------------+--------------------
 Foxtrot    |    6000 |  0.0000 |  0.1000 | yes                   | yes
 Alpha      |    5000 |  0.1111 |  0.4000 | no                    | no
 Golf       |    5000 |  0.1111 |  0.4000 | no                    | no
 Hotel      |    5000 |  0.1111 |  0.4000 | no                    | no
 ...        |         |         |         | no                    | no
*/
-- Both agree here, but for different reasons, and on other data they will not.
-- WHICH TO USE:
--   CUME_DIST    when the question is about VOLUME -- "the top 10% OF ROWS".
--                It answers "how much of the data have I caught up with".
--   PERCENT_RANK when the question is about STANDING -- "in the top 10% of the
--                RANGE of ranks". It always starts at exactly 0.0, so the very
--                best row is always included.
-- If someone says "top decile" and means ten equal buckets, they want neither:
-- they want NTILE(10). See Part 1, Example 4 -- and remember NTILE splits ties.


-- ############################################################################
-- PART 4 — THE TWO-HOUR TEACHING PLAN
-- ############################################################################
/*
┌─────────────┬───────────────────────────┬──────────────────────────────────────┐
│ Time        │ Topic                     │ What to run                          │
├─────────────┼───────────────────────────┼──────────────────────────────────────┤
│ 0:00 - 0:20 │ The core concepts         │ File header + Section 0.             │
│             │ OVER, PARTITION BY,       │ Print both tables. Make the point    │
│             │ ORDER BY                  │ that 10 rows in = 10 rows out.       │
├─────────────┼───────────────────────────┼──────────────────────────────────────┤
│ 0:20 - 0:50 │ Ranking & distribution    │ Part 1, Examples 1-6.                │
│             │ ROW_NUMBER, RANK,         │ LAB: Module A -- Top 3 per region.   │
│             │ DENSE_RANK                │ Ask the tie question BEFORE running. │
├─────────────┼───────────────────────────┼──────────────────────────────────────┤
│ 0:50 - 1:00 │ Break                     │                                      │
├─────────────┼───────────────────────────┼──────────────────────────────────────┤
│ 1:00 - 1:30 │ Offsets & time series     │ Part 1, Examples 7-11.                │
│             │ LEAD, LAG                 │ LAB: Module B -- MoM growth.         │
│             │                           │ Let them hit the integer-division    │
│             │                           │ zeros themselves before you explain. │
├─────────────┼───────────────────────────┼──────────────────────────────────────┤
│ 1:30 - 1:45 │ Frames & aggregates       │ Part 1, Examples 12-16.               │
│             │ SUM, AVG, LAST_VALUE      │ LAB: Module C -- 7-day rolling avg.  │
│             │                           │ Whiteboard the frame anchors.        │
├─────────────┼───────────────────────────┼──────────────────────────────────────┤
│ 1:45 - 2:00 │ Advanced patterns + Q&A   │ Part 3: gaps & islands, the WINDOW   │
│             │                           │ clause, CUME_DIST vs PERCENT_RANK.   │
└─────────────┴───────────────────────────┴──────────────────────────────────────┘

THE FOUR MOMENTS THAT LAND HARDEST — build the session around these
  1. LAST_VALUE returns the current row with the default frame.   (Part 1, #10)
  2. "Top 3" returns four people when two tie for third.          (Module A)
  3. Every growth percentage is 0 because of integer division.    (Module B)
  4. Subtracting a row number from a date groups consecutive runs.(Advanced 1)

RUN IT LIVE. Everyone has their own Redshift cluster and their own account, so
there is nothing to coordinate and nothing to break that is not theirs. Have
them run each query and compare against the expected output printed beside it.
Where a result differs, that is the lesson -- work out why before moving on.

THREE THINGS TO ASK THE ROOM (they generate the best discussion)
  * "Why can't I just put the rank in the WHERE clause?"      -> Module A
  * "Why is my growth percentage zero?"                        -> Module B
  * "Why does my LAST_VALUE column just repeat the revenue?"   -> Part 1, #10
*/


-- ============================================================================
-- CLEANUP — PARTS 2 AND 3
-- ============================================================================
-- DROP TABLE IF EXISTS sales_team CASCADE;
-- DROP TABLE IF EXISTS monthly_sales CASCADE;
-- DROP TABLE IF EXISTS support_tickets CASCADE;
-- DROP TABLE IF EXISTS market_data CASCADE;
-- DROP TABLE IF EXISTS store_revenue CASCADE;
-- DROP TABLE IF EXISTS daily_sales CASCADE;
