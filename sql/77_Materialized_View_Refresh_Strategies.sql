/*
======================================================================================
MODULE 77: MATERIALIZED VIEW REFRESH — AUTO vs MANUAL, INCREMENTAL vs FULL
======================================================================================
MAPPED BEST PRACTICES (from PROCEDURE_OPTIMIZATION_BEST_PRACTICES_MASTER_FILE.md):
- Practice 20: "Avoid recomputing the same expression repeatedly" — that is what an
  MV is for. It is also what a badly-written MV fails to achieve.
- Practice 35: "Read the plan before and after every change" — here the equivalent is
  reading STV_MV_INFO.state before you trust an MV.
- Practice 108: "Lean on caching for repeat queries."
- Practice 106: "Right-size compute" — a full-recompute MV on a large fact table can
  cost more than the query it was meant to replace.

TARGET AUDIENCE: Analytics Engineers, BI Developers, anyone who has ever typed
                 AUTO REFRESH YES and assumed that was the end of it.

THE PROBLEM:
Redshift NEVER asks you to choose a refresh method. It reads your SELECT and decides
for you, silently. Two MVs that look almost identical can differ by 100x in refresh
cost, and nothing in the DDL tells you which one you got.

Worse: `AUTO REFRESH YES` is not always accepted, and when it IS accepted the MV can
still be permanently stale. Both failures are quiet.

THE GOAL:
Ten runnable examples, simple to complex, each with the anti-pattern and the fix.
After each one you read the SAME two views and watch the answer change:

  STV_MV_INFO.state         0 = FULL RECOMPUTE      1 = INCREMENTAL
  SVL_MV_REFRESH_STATUS     "...recomputed MV from scratch"
                            "...updated MV incrementally"     <-- read this literally

That status string is the whole lesson. You are not inferring anything; Redshift
tells you in English which path it took.

THE THREE MECHANISMS (§13 has the decision table):
  MANUAL     REFRESH MATERIALIZED VIEW mv;        deterministic, ETL-ordered
  AUTO       AUTO REFRESH YES                     as-soon-as-possible, best effort
  SCHEDULED  Redshift scheduler / console         fixed cadence, predictable cost

NOTE ON VERIFICATION: every rule in this file is taken from the Redshift Database
Developer Guide (Refreshing a materialized view; CREATE MATERIALIZED VIEW;
STV_MV_INFO; SVL_MV_REFRESH_STATUS). It has NOT been executed on a live cluster.
Where a behaviour is worth measuring rather than trusting, the file says so and
gives you the query. Example 7 is deliberately one of those.
======================================================================================
*/


-- ============================================================================
-- SECTION 0: DATA SIMULATION — 100,000 ORDERS, 5,000 CUSTOMERS
-- ============================================================================
-- Deterministic generator: the cross-join product must be >= the LIMIT or the
-- LIMIT never binds and you silently get fewer rows than you think.
--   orders:    10^5            = 100,000  -> LIMIT 100000 binds exactly
--   customers: 10^4 =  10,000 >=   5,000  -> LIMIT 5000 binds

DROP TABLE IF EXISTS mv77_orders CASCADE;
CREATE TABLE mv77_orders (
    order_id        BIGINT      NOT NULL ENCODE az64,
    customer_id     INT         NOT NULL ENCODE az64,
    region          VARCHAR(16) NOT NULL ENCODE bytedict,
    product_category VARCHAR(32) NOT NULL ENCODE bytedict,
    order_date      DATE        NOT NULL ENCODE az64,
    order_amount    DECIMAL(12,2) NOT NULL ENCODE az64,
    quantity        INT         NOT NULL ENCODE az64,
    order_status    VARCHAR(16) NOT NULL ENCODE bytedict
)
DISTSTYLE KEY
DISTKEY (customer_id)
COMPOUND SORTKEY (order_date);

INSERT INTO mv77_orders (order_id, customer_id, region, product_category,
                         order_date, order_amount, quantity, order_status)
SELECT
    s.n                                       AS order_id,
    (s.n % 5000 + 1)                          AS customer_id,
    CASE WHEN s.n % 4 = 0 THEN 'AMER' WHEN s.n % 4 = 1 THEN 'EMEA'
         WHEN s.n % 4 = 2 THEN 'APAC' ELSE 'LATAM' END AS region,
    CASE WHEN s.n % 5 = 0 THEN 'Electronics' WHEN s.n % 5 = 1 THEN 'Apparel'
         WHEN s.n % 5 = 2 THEN 'Home'        WHEN s.n % 5 = 3 THEN 'Grocery'
         ELSE 'Toys' END                      AS product_category,
    DATEADD(day, -(s.n % 180), '2026-08-15'::DATE) AS order_date,
    (12.50 + (s.n % 400))::DECIMAL(12,2)      AS order_amount,
    (1 + (s.n % 8))                           AS quantity,
    -- Order matters: every multiple of 20 is also a multiple of 10, so the rarer
    -- status must be tested FIRST or it is never produced.
    CASE WHEN s.n % 20 = 0 THEN 'CANCELLED'
         WHEN s.n % 10 = 0 THEN 'RETURNED'
         WHEN s.n % 5  = 0 THEN 'PENDING'
         ELSE 'COMPLETED' END                 AS order_status
FROM (
    SELECT ROW_NUMBER() OVER () AS n
    FROM (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) a
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) b
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) c
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) d
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) e
    LIMIT 100000
) s;

DROP TABLE IF EXISTS mv77_customers CASCADE;
CREATE TABLE mv77_customers (
    customer_id   INT          NOT NULL ENCODE az64,
    customer_name VARCHAR(64)  NOT NULL ENCODE zstd,
    segment       VARCHAR(16)  NOT NULL ENCODE bytedict,
    country       CHAR(2)      NOT NULL ENCODE bytedict
)
DISTSTYLE KEY
DISTKEY (customer_id);

INSERT INTO mv77_customers (customer_id, customer_name, segment, country)
SELECT
    s.n,
    'Customer ' || s.n::VARCHAR,
    CASE WHEN s.n % 3 = 0 THEN 'ENTERPRISE' WHEN s.n % 3 = 1 THEN 'MIDMARKET'
         ELSE 'SMB' END,
    CASE WHEN s.n % 4 = 0 THEN 'US' WHEN s.n % 4 = 1 THEN 'GB'
         WHEN s.n % 4 = 2 THEN 'DE' ELSE 'JP' END
FROM (
    SELECT ROW_NUMBER() OVER () AS n
    FROM (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) a
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) b
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) c
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) d
    LIMIT 5000
) s;

ANALYZE mv77_orders;
ANALYZE mv77_customers;

-- Sanity check the simulation before you trust any result below:
SELECT 'orders'    AS tbl, COUNT(*) AS rows, COUNT(DISTINCT order_status) AS statuses
FROM mv77_orders
UNION ALL
SELECT 'customers', COUNT(*), COUNT(DISTINCT segment) FROM mv77_customers;
-- Expect: orders 100000 / 4 statuses, customers 5000 / 3 segments.


-- ============================================================================
-- SECTION 1: THE TWO QUERIES YOU WILL RUN AFTER EVERY EXAMPLE
-- ============================================================================
-- Bookmark these. Everything in this file is read through them.

-- (A) WHICH REFRESH METHOD DID REDSHIFT PICK, AND IS AUTO EVEN ALLOWED?
--     Run this immediately after any CREATE MATERIALIZED VIEW.
--     Note: "schema" is the literal column name; it is quoted to be safe.
SELECT
    "schema",
    name,
    state,                    -- 0 = FULL RECOMPUTE, 1 = INCREMENTAL,
                              -- 101 dropped col, 102 changed col type,
                              -- 103 renamed table, 104 renamed col, 105 renamed schema
    CASE state
        WHEN 0   THEN 'FULL RECOMPUTE  <-- reruns the whole query'
        WHEN 1   THEN 'INCREMENTAL     <-- only the delta'
        WHEN 101 THEN 'BROKEN: a base column was dropped'
        WHEN 102 THEN 'BROKEN: a base column type changed'
        WHEN 103 THEN 'BROKEN: a base table was renamed'
        WHEN 104 THEN 'BROKEN: a base column was renamed'
        WHEN 105 THEN 'BROKEN: a schema was renamed'
        ELSE 'other'
    END                     AS what_it_means,
    autorefresh,              -- t = auto refresh is on and permitted
    autorewrite,              -- t = eligible for automatic query rewriting
    is_stale                  -- t = base tables changed since last refresh
FROM stv_mv_info
WHERE name LIKE 'mv77%'
ORDER BY name;

-- (B) WHAT ACTUALLY HAPPENED ON THE LAST REFRESH?
--     The status column is plain English. Read it literally.
SELECT
    mv_name,
    starttime,
    DATEDIFF(ms, starttime, endtime) AS refresh_ms,
    status
FROM svl_mv_refresh_status
WHERE mv_name LIKE 'mv77%'
ORDER BY starttime DESC
LIMIT 25;
-- You are looking for one of:
--   "Refresh successfully updated MV incrementally"     <-- cheap, what you want
--   "Refresh successfully recomputed MV from scratch"   <-- expensive
--   "MV was already updated"                            <-- nothing to do
-- (SYS_MV_REFRESH_HISTORY is the newer SYS equivalent and is what AWS recommends
--  for dashboards; SVL_MV_REFRESH_STATUS is used here because its status text is
--  the most explicit teaching signal.)


-- ============================================================================
-- EXAMPLE 1 — THE BASELINE THAT WORKS  (simplest case, everything green)
-- ============================================================================
-- Plain SELECT / WHERE / GROUP BY with SUM, COUNT, AVG.
-- This is the shape you should be aiming at. Everything after this example is a
-- deviation from it, and every deviation costs you something.

DROP MATERIALIZED VIEW IF EXISTS mv77_01_good;
CREATE MATERIALIZED VIEW mv77_01_good
DISTSTYLE KEY DISTKEY (region_key)
AUTO REFRESH YES
AS
SELECT
    region                        AS region_key,
    order_date,
    product_category,
    SUM(order_amount)             AS total_amount,
    SUM(quantity)                 AS total_units,
    COUNT(*)                      AS order_count,
    AVG(order_amount)             AS avg_order_value
FROM mv77_orders
WHERE order_status = 'COMPLETED'
GROUP BY region, order_date, product_category;

-- OBSERVE: state = 1 (INCREMENTAL), autorefresh = t.
-- SUM / COUNT / AVG / MIN / MAX are all incremental-safe. WHERE and GROUP BY are fine.
-- This MV only ever processes the rows that changed.


-- ============================================================================
-- EXAMPLE 2 — ORDER BY / LIMIT  (the MV will not be created at all)
-- ============================================================================
-- Not a refresh problem. A "this object cannot exist" problem.
-- People add ORDER BY out of habit from writing SELECTs. An MV has no inherent
-- row order to preserve, so Redshift rejects it outright.

-- BAD: run this and read the error. It fails at CREATE time.
DROP MATERIALIZED VIEW IF EXISTS mv77_02_bad;
CREATE MATERIALIZED VIEW mv77_02_bad AS
SELECT region, SUM(order_amount) AS total_amount
FROM mv77_orders
GROUP BY region
ORDER BY total_amount DESC        -- <-- ORDER BY is not allowed in an MV
LIMIT 10;                         -- <-- neither is LIMIT (nor OFFSET)

-- GOOD: materialise the aggregate; sort and limit at QUERY time, where it belongs.
DROP MATERIALIZED VIEW IF EXISTS mv77_02_good;
CREATE MATERIALIZED VIEW mv77_02_good
AUTO REFRESH YES
AS
SELECT region, SUM(order_amount) AS total_amount
FROM mv77_orders
GROUP BY region;

-- The "top 10" you actually wanted:
SELECT region, total_amount
FROM mv77_02_good
ORDER BY total_amount DESC
LIMIT 10;

-- Also rejected at CREATE time, for the same "cannot exist" reason:
--   standard views, system tables/views, temp tables, UDFs,
--   late-binding references, leader-node-only functions
--   (CURRENT_SCHEMA, CURRENT_SCHEMAS, HAS_*_PRIVILEGE),
--   and RLS-protected or DDM-protected base tables.


-- ============================================================================
-- EXAMPLE 3 — OLAP / WINDOW FUNCTIONS  ** THE HEADLINE CASE **
-- ============================================================================
-- This is the single most common way a well-intentioned MV becomes expensive.
-- Window functions are ALLOWED in an MV. They just silently disable incremental
-- refresh, so every refresh reruns the entire query over the whole fact table.
--
-- The MV looks fine. It returns correct data. It costs 100x more to maintain,
-- and the DDL gives you no hint.

-- BAD: RANK() inside the MV -> state 0, full recompute forever.
DROP MATERIALIZED VIEW IF EXISTS mv77_03_bad;
CREATE MATERIALIZED VIEW mv77_03_bad
AUTO REFRESH YES
AS
SELECT
    region,
    product_category,
    SUM(order_amount) AS total_amount,
    RANK() OVER (PARTITION BY region ORDER BY SUM(order_amount) DESC) AS rank_in_region
FROM mv77_orders
GROUP BY region, product_category;

-- GOOD: materialise ONLY the aggregate (incremental), apply the window at read time.
-- The ranking is trivial CPU over a few hundred pre-aggregated rows. The expensive
-- part -- the SUM over 100,000 rows -- is what gets incrementally maintained.
DROP MATERIALIZED VIEW IF EXISTS mv77_03_good;
CREATE MATERIALIZED VIEW mv77_03_good
AUTO REFRESH YES
AS
SELECT
    region,
    product_category,
    SUM(order_amount) AS total_amount
FROM mv77_orders
GROUP BY region, product_category;

-- The ranked result, identical output, cheap maintenance:
SELECT
    region,
    product_category,
    total_amount,
    RANK() OVER (PARTITION BY region ORDER BY total_amount DESC) AS rank_in_region
FROM mv77_03_good
ORDER BY region, rank_in_region;

-- OBSERVE: mv77_03_bad state = 0, mv77_03_good state = 1.
-- THE RULE: aggregate in the MV, window over the MV.
-- This applies to every OLAP function -- RANK, DENSE_RANK, ROW_NUMBER, NTILE,
-- LAG, LEAD, FIRST_VALUE, LAST_VALUE, PERCENT_RANK, and any SUM/AVG used as an
-- OVER() window rather than a GROUP BY aggregate.


-- ============================================================================
-- EXAMPLE 4 — DISTINCT AGGREGATES  (COUNT(DISTINCT ...) blocks incremental)
-- ============================================================================
-- Redshift cannot maintain a distinct count from a delta: to know whether an
-- arriving customer_id is new, it would need the whole set. So it gives up and
-- recomputes.

-- BAD: distinct count inside the MV -> state 0.
DROP MATERIALIZED VIEW IF EXISTS mv77_04_bad;
CREATE MATERIALIZED VIEW mv77_04_bad
AUTO REFRESH YES
AS
SELECT
    region,
    order_date,
    COUNT(DISTINCT customer_id) AS unique_customers,   -- <-- blocks incremental
    SUM(order_amount)           AS total_amount
FROM mv77_orders
GROUP BY region, order_date;

-- GOOD: materialise at the grain that makes the distinct unnecessary.
-- One row per (region, date, customer) is incrementally maintainable, and the
-- distinct count becomes a plain COUNT(*) at read time.
DROP MATERIALIZED VIEW IF EXISTS mv77_04_good;
CREATE MATERIALIZED VIEW mv77_04_good
DISTSTYLE KEY DISTKEY (customer_id)
AUTO REFRESH YES
AS
SELECT
    region,
    order_date,
    customer_id,
    SUM(order_amount) AS customer_amount,
    COUNT(*)          AS customer_orders
FROM mv77_orders
GROUP BY region, order_date, customer_id;

-- The distinct count, derived:
SELECT region, order_date,
       COUNT(*)               AS unique_customers,
       SUM(customer_amount)   AS total_amount
FROM mv77_04_good
GROUP BY region, order_date
ORDER BY order_date DESC, region
LIMIT 20;

-- TRADE-OFF, STATED HONESTLY: the good MV holds more rows (one per customer per
-- day per region) than the bad one. You are buying cheap incremental maintenance
-- with storage. On a large fact table that is almost always the right trade --
-- but it IS a trade, and you should measure it rather than assume.


-- ============================================================================
-- EXAMPLE 5 — APPROXIMATE COUNT(DISTINCT)  (the trap: "approximate" != "cheap")
-- ============================================================================
-- Everybody reaches for APPROXIMATE COUNT(DISTINCT) to make the previous example
-- fast. In a plain query it genuinely is fast. Inside an MV it is on the SAME
-- no-incremental-refresh list as the exact version.
--
-- So you get: approximate answers AND full recompute. The worst of both.

-- BAD: approximate, and still state 0.
DROP MATERIALIZED VIEW IF EXISTS mv77_05_bad;
CREATE MATERIALIZED VIEW mv77_05_bad
AUTO REFRESH YES
AS
SELECT
    region,
    APPROXIMATE COUNT(DISTINCT customer_id) AS approx_customers
FROM mv77_orders
GROUP BY region;

-- GOOD: same grain trick as Example 4 -- or, if you truly want HLL, keep the
-- SKETCH in a plain table maintained by your ETL, not in an MV. Sketches merge;
-- that is the whole point of them, and it gives you incremental behaviour that
-- an MV refuses to.
DROP MATERIALIZED VIEW IF EXISTS mv77_05_good;
CREATE MATERIALIZED VIEW mv77_05_good
DISTSTYLE KEY DISTKEY (customer_id)
AUTO REFRESH YES
AS
SELECT region, customer_id, COUNT(*) AS orders
FROM mv77_orders
GROUP BY region, customer_id;

SELECT region, COUNT(*) AS exact_customers FROM mv77_05_good GROUP BY region;

-- Full no-incremental aggregate list, worth memorising:
--   MEDIAN, PERCENTILE_CONT, LISTAGG, STDDEV_SAMP, STDDEV_POP,
--   APPROXIMATE COUNT, APPROXIMATE PERCENTILE, bitwise aggregates,
--   and ANY DISTINCT aggregate.
-- Safe: SUM, COUNT, AVG, MIN, MAX.


-- ============================================================================
-- EXAMPLE 6 — OUTER JOIN  (INNER is incremental, OUTER is not)
-- ============================================================================
-- LEFT/RIGHT/FULL OUTER JOIN blocks incremental refresh. INNER JOIN does not.

-- BAD: LEFT JOIN to keep orders whose customer row is missing -> state 0.
DROP MATERIALIZED VIEW IF EXISTS mv77_06_bad;
CREATE MATERIALIZED VIEW mv77_06_bad
AUTO REFRESH YES
AS
SELECT
    NVL(c.segment, 'UNKNOWN') AS segment,
    o.region,
    SUM(o.order_amount)       AS total_amount
FROM mv77_orders o
LEFT JOIN mv77_customers c ON o.customer_id = c.customer_id   -- <-- blocks incremental
GROUP BY NVL(c.segment, 'UNKNOWN'), o.region;

-- GOOD: fix the DIMENSION so the outer join is unnecessary. Add an explicit
-- "unknown" member (the -1 pattern from module 48) and INNER JOIN to it.
-- This is better modelling anyway: it makes the unknown case a real, countable
-- row rather than a NULL you have to remember to coalesce everywhere.
INSERT INTO mv77_customers (customer_id, customer_name, segment, country)
SELECT -1, 'UNKNOWN CUSTOMER', 'UNKNOWN', 'ZZ'
WHERE NOT EXISTS (SELECT 1 FROM mv77_customers WHERE customer_id = -1);

DROP MATERIALIZED VIEW IF EXISTS mv77_06_good;
CREATE MATERIALIZED VIEW mv77_06_good
AUTO REFRESH YES
AS
SELECT
    c.segment,
    o.region,
    SUM(o.order_amount) AS total_amount
FROM mv77_orders o
INNER JOIN mv77_customers c ON o.customer_id = c.customer_id  -- <-- incremental-safe
GROUP BY c.segment, o.region;

-- OBSERVE: bad state = 0, good state = 1, and the good one is also a better model.
-- (In this simulation every order already has a matching customer, so both return
--  the same numbers. Delete a customer row and re-run to see the difference the
--  UNKNOWN member makes.)


-- ============================================================================
-- EXAMPLE 7 — SET OPERATIONS  (UNION blocks; measure UNION ALL yourself)
-- ============================================================================
-- The docs list UNION, INTERSECT, EXCEPT and MINUS as incremental blockers.
-- UNION ALL is NOT named in that list. That is a meaningful distinction and it is
-- exactly the kind of thing you should measure rather than take on faith --
-- including from this file.

-- BAD: UNION (dedup) -> documented blocker.
DROP MATERIALIZED VIEW IF EXISTS mv77_07_bad;
CREATE MATERIALIZED VIEW mv77_07_bad
AUTO REFRESH YES
AS
SELECT region, 'COMPLETED' AS bucket, SUM(order_amount) AS total_amount
FROM mv77_orders WHERE order_status = 'COMPLETED' GROUP BY region
UNION
SELECT region, 'OTHER', SUM(order_amount)
FROM mv77_orders WHERE order_status <> 'COMPLETED' GROUP BY region;

-- CANDIDATE: same shape with UNION ALL. Create it, then READ state and decide.
DROP MATERIALIZED VIEW IF EXISTS mv77_07_test;
CREATE MATERIALIZED VIEW mv77_07_test
AUTO REFRESH YES
AS
SELECT region, 'COMPLETED' AS bucket, SUM(order_amount) AS total_amount
FROM mv77_orders WHERE order_status = 'COMPLETED' GROUP BY region
UNION ALL
SELECT region, 'OTHER', SUM(order_amount)
FROM mv77_orders WHERE order_status <> 'COMPLETED' GROUP BY region;

-- GOOD: no set operation at all. Conditional aggregation collapses both branches
-- into one pass (module 38's lesson), and it is unambiguously incremental.
DROP MATERIALIZED VIEW IF EXISTS mv77_07_good;
CREATE MATERIALIZED VIEW mv77_07_good
AUTO REFRESH YES
AS
SELECT
    region,
    SUM(CASE WHEN order_status =  'COMPLETED' THEN order_amount ELSE 0 END) AS completed_amount,
    SUM(CASE WHEN order_status <> 'COMPLETED' THEN order_amount ELSE 0 END) AS other_amount
FROM mv77_orders
GROUP BY region;

-- Now read state for all three and see which of your assumptions survived:
SELECT name, state,
       CASE state WHEN 1 THEN 'INCREMENTAL' WHEN 0 THEN 'FULL RECOMPUTE' ELSE 'other' END AS method
FROM stv_mv_info
WHERE name IN ('mv77_07_bad', 'mv77_07_test', 'mv77_07_good')
ORDER BY name;


-- ============================================================================
-- EXAMPLE 8 — SUBQUERIES  (any subquery in the definition blocks incremental)
-- ============================================================================

-- BAD: a correlated-style filter subquery -> state 0.
DROP MATERIALIZED VIEW IF EXISTS mv77_08_bad;
CREATE MATERIALIZED VIEW mv77_08_bad
AUTO REFRESH YES
AS
SELECT region, SUM(order_amount) AS total_amount
FROM mv77_orders o
WHERE o.customer_id IN (
    SELECT customer_id FROM mv77_customers WHERE segment = 'ENTERPRISE'   -- <-- subquery
)
GROUP BY region;

-- GOOD: express the same restriction as a join. Joins are incremental-safe;
-- subqueries are not. (This is also module 25's lesson arriving from a different
-- direction: the join is both faster to run AND cheaper to maintain.)
DROP MATERIALIZED VIEW IF EXISTS mv77_08_good;
CREATE MATERIALIZED VIEW mv77_08_good
AUTO REFRESH YES
AS
SELECT o.region, SUM(o.order_amount) AS total_amount
FROM mv77_orders o
INNER JOIN mv77_customers c
        ON o.customer_id = c.customer_id
       AND c.segment = 'ENTERPRISE'
GROUP BY o.region;

-- Prove they agree before you trust the rewrite (Practice 5, correctness is the gate):
SELECT b.region, b.total_amount AS bad_amount, g.total_amount AS good_amount,
       CASE WHEN b.total_amount = g.total_amount THEN 'MATCH' ELSE 'DIFFERS' END AS check
FROM mv77_08_bad b JOIN mv77_08_good g ON b.region = g.region
ORDER BY b.region;


-- ============================================================================
-- EXAMPLE 9 — MUTABLE FUNCTIONS  (AUTO REFRESH is REJECTED, and it is never fresh)
-- ============================================================================
-- Two separate failures, and this is the first example where AUTO REFRESH YES is
-- not merely degraded but refused.
--
--   1. CREATE ... AUTO REFRESH YES fails outright when the definition contains a
--      mutable function. Most date/time functions are mutable: GETDATE(), SYSDATE,
--      CURRENT_DATE, and anything derived from them.
--   2. Even with AUTO REFRESH NO it still creates -- but STV_MV_INFO.is_stale is
--      pinned to 't' FOREVER, because Redshift cannot know when "last 30 days"
--      stopped meaning what it meant yesterday.

-- BAD: rolling window baked into the MV. Run it and read the error.
DROP MATERIALIZED VIEW IF EXISTS mv77_09_bad;
CREATE MATERIALIZED VIEW mv77_09_bad
AUTO REFRESH YES                    -- <-- rejected: definition uses a mutable function
AS
SELECT region, SUM(order_amount) AS total_amount
FROM mv77_orders
WHERE order_date >= DATEADD(day, -30, CURRENT_DATE)
GROUP BY region;

-- STILL BAD, just differently: it creates, but is permanently stale.
DROP MATERIALIZED VIEW IF EXISTS mv77_09_stale;
CREATE MATERIALIZED VIEW mv77_09_stale
AUTO REFRESH NO
AS
SELECT region, SUM(order_amount) AS total_amount
FROM mv77_orders
WHERE order_date >= DATEADD(day, -30, CURRENT_DATE)
GROUP BY region;

-- GOOD: materialise ALL of history at day grain, with no time filter at all.
-- The MV becomes immutable and incremental; the rolling window moves to the query,
-- where it costs nothing because it is filtering a few hundred pre-aggregated rows.
DROP MATERIALIZED VIEW IF EXISTS mv77_09_good;
CREATE MATERIALIZED VIEW mv77_09_good
AUTO REFRESH YES
AS
SELECT region, order_date, SUM(order_amount) AS total_amount
FROM mv77_orders
GROUP BY region, order_date;

-- The rolling 30 days, evaluated fresh on every call:
SELECT region, SUM(total_amount) AS last_30d_amount
FROM mv77_09_good
WHERE order_date >= DATEADD(day, -30, CURRENT_DATE)
GROUP BY region
ORDER BY last_30d_amount DESC;

-- OBSERVE: mv77_09_stale has is_stale = 't' and it will never change.
-- THE RULE: an MV must be a pure function of its base tables. The moment "now"
-- appears in the definition, that stops being true.


-- ============================================================================
-- EXAMPLE 10 — NESTED MVs  (AUTO REFRESH rejected; CASCADE required)
-- ============================================================================
-- An MV built on another MV is legal and sometimes the right design. But:
--   * AUTO REFRESH YES is rejected on the dependent MV.
--   * A plain REFRESH runs in RESTRICT mode and refreshes ONLY that view, even if
--     its parent is out of date. You get an INFO message, not an error, and stale
--     numbers if you are not reading messages.

-- Base layer -- this one can autorefresh normally:
DROP MATERIALIZED VIEW IF EXISTS mv77_10_child CASCADE;
DROP MATERIALIZED VIEW IF EXISTS mv77_10_base  CASCADE;
CREATE MATERIALIZED VIEW mv77_10_base
AUTO REFRESH YES
AS
SELECT region, order_date, product_category, SUM(order_amount) AS total_amount
FROM mv77_orders
GROUP BY region, order_date, product_category;

-- BAD: dependent MV asking for AUTO REFRESH -> rejected at CREATE time.
CREATE MATERIALIZED VIEW mv77_10_child
AUTO REFRESH YES                    -- <-- rejected: MV defined on another MV
AS
SELECT region, SUM(total_amount) AS total_amount
FROM mv77_10_base
GROUP BY region;

-- WORKS: same MV without AUTO REFRESH. You now own the refresh order.
CREATE MATERIALIZED VIEW mv77_10_child
AUTO REFRESH NO
AS
SELECT region, SUM(total_amount) AS total_amount
FROM mv77_10_base
GROUP BY region;

-- Change the base data, then compare the two refresh modes:
INSERT INTO mv77_orders VALUES
 (900001, 42, 'AMER', 'Electronics', '2026-08-15', 9999.00, 1, 'COMPLETED');

-- WRONG: RESTRICT mode. Refreshes the child against a STALE parent.
--   INFO: Materialized view mv77_10_child is already up to date. However, it
--         depends on another materialized view that is not up to date.
REFRESH MATERIALIZED VIEW mv77_10_child;

-- RIGHT: CASCADE. Refreshes parent then child, in one transaction.
REFRESH MATERIALIZED VIEW mv77_10_child CASCADE;

-- Map your MV dependency graph before designing a refresh order:
WITH RECURSIVE deps (mv_tgt, lvl, mv_dep) AS (
    SELECT TRIM(name) AS mv_tgt, 0 AS lvl, TRIM(ref_name) AS mv_dep
    FROM stv_mv_deps
    UNION ALL
    SELECT r.mv_tgt, r.lvl + 1, TRIM(s.ref_name)
    FROM stv_mv_deps s, deps r
    WHERE r.mv_dep = s.name
)
SELECT mv_tgt, lvl, mv_dep FROM deps ORDER BY mv_tgt, lvl DESC;


-- ============================================================================
-- SECTION 11: THE EXPERIMENT — ONE DELTA, REFRESH EVERYTHING, COMPARE
-- ============================================================================
-- This is where the file pays off. Insert a small batch, refresh every MV, then
-- read the status text. An incremental MV touches ~1,000 rows. A full-recompute
-- MV reruns over all 100,001+.

-- 1,000 new orders on the most recent date:
INSERT INTO mv77_orders (order_id, customer_id, region, product_category,
                         order_date, order_amount, quantity, order_status)
SELECT
    500000 + s.n,
    (s.n % 5000 + 1),
    CASE WHEN s.n % 4 = 0 THEN 'AMER' WHEN s.n % 4 = 1 THEN 'EMEA'
         WHEN s.n % 4 = 2 THEN 'APAC' ELSE 'LATAM' END,
    CASE WHEN s.n % 5 = 0 THEN 'Electronics' WHEN s.n % 5 = 1 THEN 'Apparel'
         WHEN s.n % 5 = 2 THEN 'Home' WHEN s.n % 5 = 3 THEN 'Grocery' ELSE 'Toys' END,
    '2026-08-15'::DATE,
    (12.50 + (s.n % 400))::DECIMAL(12,2),
    (1 + (s.n % 8)),
    'COMPLETED'
FROM (
    SELECT ROW_NUMBER() OVER () AS n
    FROM (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) a
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) b
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) c
    LIMIT 1000
) s;

-- Refresh them all manually so the comparison is apples-to-apples
-- (auto refresh is best-effort and may not have fired yet):
REFRESH MATERIALIZED VIEW mv77_01_good;
REFRESH MATERIALIZED VIEW mv77_03_bad;
REFRESH MATERIALIZED VIEW mv77_03_good;
REFRESH MATERIALIZED VIEW mv77_04_bad;
REFRESH MATERIALIZED VIEW mv77_04_good;
REFRESH MATERIALIZED VIEW mv77_05_bad;
REFRESH MATERIALIZED VIEW mv77_05_good;
REFRESH MATERIALIZED VIEW mv77_06_bad;
REFRESH MATERIALIZED VIEW mv77_06_good;
REFRESH MATERIALIZED VIEW mv77_07_bad;
REFRESH MATERIALIZED VIEW mv77_07_test;
REFRESH MATERIALIZED VIEW mv77_07_good;
REFRESH MATERIALIZED VIEW mv77_08_bad;
REFRESH MATERIALIZED VIEW mv77_08_good;
REFRESH MATERIALIZED VIEW mv77_09_good;
REFRESH MATERIALIZED VIEW mv77_10_child CASCADE;

-- THE SCOREBOARD. This one query is the summary of the whole module:
SELECT
    r.mv_name,
    i.state,
    CASE i.state WHEN 1 THEN 'INCREMENTAL' WHEN 0 THEN 'FULL RECOMPUTE' ELSE 'BROKEN' END AS method,
    i.autorefresh,
    DATEDIFF(ms, r.starttime, r.endtime) AS refresh_ms,
    r.status
FROM svl_mv_refresh_status r
LEFT JOIN stv_mv_info i ON TRIM(i.name) = TRIM(r.mv_name)
WHERE r.mv_name LIKE 'mv77%'
  AND r.starttime >= DATEADD(hour, -1, GETDATE())
ORDER BY refresh_ms DESC;

-- Read the status column top to bottom. Every "recomputed MV from scratch" is a
-- design decision you made without realising it.


-- ============================================================================
-- SECTION 12: HOW A WORKING MV SILENTLY BECOMES UNREFRESHABLE
-- ============================================================================
-- Nothing above breaks an MV permanently. DDL on the BASE TABLE does -- and it
-- does so even when the changed column is not used by the MV at all.

-- mv77_01_good does not reference order_status. Drop it anyway:
--   ALTER TABLE mv77_orders DROP COLUMN order_status;
-- Then STV_MV_INFO.state becomes 101 and the MV can be QUERIED but never REFRESHED.
--
--   state 101  a base column was dropped
--   state 102  a base column type changed
--   state 103  a base table was renamed
--   state 104  a base column was renamed
--   state 105  a schema was renamed
--
-- There is no repair. You cannot ALTER an MV's definition and you cannot rename an
-- MV. The only fix is DROP and CREATE.
--
-- PRACTICAL CONSEQUENCE: put an MV health check in your deployment pipeline. A
-- schema migration that "only renamed an unused column" will take your dashboards
-- stale and nothing will raise an error.

-- The health check worth scheduling:
SELECT "schema", name, state, is_stale, autorefresh
FROM stv_mv_info
WHERE state >= 100                       -- anything >= 100 is unrefreshable
   OR (is_stale = 't' AND autorefresh = 't');   -- auto is on but not keeping up


-- ============================================================================
-- SECTION 13: DECISION TABLE
-- ============================================================================
/*
┌────────────────────────────────┬───────────────┬──────────────┬─────────────────┐
│ Your MV definition contains…   │ Incremental?  │ AUTO REFRESH │ What to do      │
├────────────────────────────────┼───────────────┼──────────────┼─────────────────┤
│ SELECT/WHERE/GROUP BY/HAVING   │ YES           │ allowed      │ nothing, ideal  │
│ SUM COUNT AVG MIN MAX          │ YES           │ allowed      │ nothing, ideal  │
│ INNER JOIN                     │ YES           │ allowed      │ nothing, ideal  │
├────────────────────────────────┼───────────────┼──────────────┼─────────────────┤
│ Window / OLAP function         │ no → FULL     │ allowed      │ window at read  │
│ COUNT(DISTINCT …)              │ no → FULL     │ allowed      │ lower the grain │
│ APPROXIMATE COUNT(DISTINCT)    │ no → FULL     │ allowed      │ lower the grain │
│ MEDIAN PERCENTILE LISTAGG      │ no → FULL     │ allowed      │ compute at read │
│ STDDEV_* / bitwise aggregates  │ no → FULL     │ allowed      │ compute at read │
│ OUTER JOIN                     │ no → FULL     │ allowed      │ UNKNOWN member  │
│ UNION INTERSECT EXCEPT MINUS   │ no → FULL     │ allowed      │ conditional agg │
│ Subquery                       │ no → FULL     │ allowed      │ rewrite as join │
│ Delta Lake / Hudi external tbl │ no → FULL     │ see below    │ —               │
├────────────────────────────────┼───────────────┼──────────────┼─────────────────┤
│ Mutable function (CURRENT_DATE)│ n/a           │ REJECTED     │ filter at read  │
│ External schema (Spectrum/fed) │ n/a           │ REJECTED     │ manual/schedule │
│ Defined on another MV          │ n/a           │ REJECTED     │ REFRESH CASCADE │
├────────────────────────────────┼───────────────┼──────────────┼─────────────────┤
│ ORDER BY / LIMIT / OFFSET      │ MV WILL NOT BE CREATED       │ sort at read    │
│ Temp table, UDF, standard view │ MV WILL NOT BE CREATED       │ —               │
│ RLS- or DDM-protected table    │ MV WILL NOT BE CREATED       │ —               │
└────────────────────────────────┴───────────────┴──────────────┴─────────────────┘

CHOOSING A MECHANISM
  MANUAL     you need determinism — refresh right after the load that feeds it,
             inside your ETL sequence. Works even when AUTO REFRESH is off.
  AUTO       dashboards where "reasonably fresh" beats "exactly when". Redshift
             deprioritises it under load, so it is best-effort, never a guarantee.
  SCHEDULED  fixed cadence and predictable cost — the middle ground when AUTO is
             too vague and MANUAL is too manual.
  CASCADE    mandatory for nested MVs. Without it you refresh a child against a
             stale parent and get an INFO message rather than an error.

ONE PLATFORM NOTE: since 27 Feb 2026 auto-refresh runs as a USER query at user
priority rather than a background process — which makes it markedly fresher. That
change is Provisioned CURRENT track patch P198+ only; it is disabled on Serverless.
This cluster is provisioned ra3.large, so it applies here.
*/


-- ============================================================================
-- CLEANUP
-- ============================================================================
-- DROP MATERIALIZED VIEW IF EXISTS mv77_10_child;
-- DROP MATERIALIZED VIEW IF EXISTS mv77_10_base CASCADE;
-- DROP MATERIALIZED VIEW IF EXISTS mv77_09_good;
-- DROP MATERIALIZED VIEW IF EXISTS mv77_09_stale;
-- DROP MATERIALIZED VIEW IF EXISTS mv77_08_good;
-- DROP MATERIALIZED VIEW IF EXISTS mv77_08_bad;
-- DROP MATERIALIZED VIEW IF EXISTS mv77_07_good;
-- DROP MATERIALIZED VIEW IF EXISTS mv77_07_test;
-- DROP MATERIALIZED VIEW IF EXISTS mv77_07_bad;
-- DROP MATERIALIZED VIEW IF EXISTS mv77_06_good;
-- DROP MATERIALIZED VIEW IF EXISTS mv77_06_bad;
-- DROP MATERIALIZED VIEW IF EXISTS mv77_05_good;
-- DROP MATERIALIZED VIEW IF EXISTS mv77_05_bad;
-- DROP MATERIALIZED VIEW IF EXISTS mv77_04_good;
-- DROP MATERIALIZED VIEW IF EXISTS mv77_04_bad;
-- DROP MATERIALIZED VIEW IF EXISTS mv77_03_good;
-- DROP MATERIALIZED VIEW IF EXISTS mv77_03_bad;
-- DROP MATERIALIZED VIEW IF EXISTS mv77_02_good;
-- DROP MATERIALIZED VIEW IF EXISTS mv77_01_good;
-- DROP TABLE IF EXISTS mv77_orders CASCADE;
-- DROP TABLE IF EXISTS mv77_customers CASCADE;
