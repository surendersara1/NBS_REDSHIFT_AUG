/*
======================================================================================
MODULE 52.1: JOIN ALGORITHMS — MERGE vs HASH vs NESTED LOOP
======================================================================================
MAPPED BEST PRACTICES (from PROCEDURE_OPTIMIZATION_BEST_PRACTICES_MASTER_FILE.md):
- Practice 32: "Watch for nested loop joins in EXPLAIN — usually signals missing stats."
- Practice 34: "Check EXPLAIN for DS_DIST_BOTH / DS_BCAST_INNER data movement."
- Practice 29: "Align distribution keys across frequently-joined tables."
- Practice 31/49: "Use DISTSTYLE ALL for small lookup/dimension tables."
- Practice 62: "Run ANALYZE after big loads — the planner needs fresh stats."
- Practice 35: "Read the EXPLAIN plan before and after every change."

TARGET AUDIENCE: Everyone. This is core 101.
                 Read this straight after module 52 (All Table Types).

WHY THIS MODULE EXISTS:
Modules 28 and 29 teach where the DATA goes — DS_DIST_NONE, DS_BCAST_INNER, and how
distribution keys move rows across the network. This module teaches what the JOIN
actually DOES once the rows arrive. They are two different questions and you need
both. A perfectly collocated join running a nested loop is still a disaster.

Redshift has exactly three physical join algorithms. It picks one for you, based on
your table design and your statistics. You never request one directly — you create
the conditions and read back what you got.

======================================================================================
THE THREE ALGORITHMS
======================================================================================

┌──────────────────────────────────────────────────────────────────────────────┐
│  1. MERGE JOIN — the fastest. Rare, and worth engineering for.               │
├──────────────────────────────────────────────────────────────────────────────┤
│  Requires BOTH tables distributed AND sorted on the join column.             │
│  Then it is a single pass down two already-ordered streams. No hash table is  │
│  built, no memory is allocated for one, nothing can spill.                   │
│                                                                              │
│    left  (sorted)   1 2 3 4 5 6 7 8 9                                        │
│                     │ │ │ │ │ │ │ │ │      one pass, two pointers,           │
│    right (sorted)   1 2 3 4 5 6 7 8 9      O(n + m)                          │
│                                                                              │
│  You have to EARN this: DISTKEY = SORTKEY = the join column, on both sides,   │
│  and the table must actually BE sorted (VACUUM), not merely declared sorted.  │
├──────────────────────────────────────────────────────────────────────────────┤
│  2. HASH JOIN — the normal one. What you will usually see.                   │
├──────────────────────────────────────────────────────────────────────────────┤
│  Builds a hash table from the SMALLER side (the "build" side), then streams   │
│  the larger side past it (the "probe" side).                                 │
│                                                                              │
│    build side  ──▶ [ hash table in memory ]                                  │
│    probe side  ──────────▶ probe ─────────▶ matches                          │
│                                                                              │
│  Perfectly good — UNLESS the build side is too big for the memory the query   │
│  was granted. Then the hash table spills to disk and the join collapses.      │
│  Two things make it go wrong: the build side is genuinely huge, or the        │
│  optimizer picked the WRONG side to build from because the stats lied.        │
├──────────────────────────────────────────────────────────────────────────────┤
│  3. NESTED LOOP — almost always a bug. Check your ON clause.                 │
├──────────────────────────────────────────────────────────────────────────────┤
│  For every row on the left, scan the entire right side.                      │
│                                                                              │
│    for each left row:            200,000 x 5,000                             │
│        for each right row:       = 1,000,000,000 comparisons                 │
│            test the condition                                                │
│                                                                              │
│  Usually means a missing or non-equality join condition — an accidental cross │
│  join. Rows multiply and the query never finishes. It is legitimate only for  │
│  a deliberate cross join against something tiny (a calendar spine, a small    │
│  parameter grid). If you see it anywhere else, read your ON clause again.     │
└──────────────────────────────────────────────────────────────────────────────┘

======================================================================================
THE FIX HIERARCHY — DO THESE IN THIS ORDER
======================================================================================

  1 · ANALYZE for fresh statistics.
      Cheapest fix, most common cause. A planner working from stale or missing
      stats guesses row counts, and a wrong guess is what produces a nested loop
      or a hash table built from the wrong side. Always rule this out FIRST,
      before you touch the table design or the SQL.

  2 · Make the small side DISTSTYLE ALL.
      One statement. Replicates the dimension to every node, so there is nothing
      to redistribute and the build side is always local. This alone fixes most
      dimension joins.

  3 · Align the DISTKEYs on the join column.
      Bigger change — it is the physical layout of a fact table. Do it when both
      sides are large and step 2 does not apply. This is what buys DS_DIST_NONE,
      and it is the precondition for a merge join.

  4 · Only then rewrite the SQL.
      Last, not first. Most "slow join" tickets are solved by steps 1 to 3
      without touching a line of SQL. Rewriting first means you will never learn
      which of the four actually mattered.

Section 5 walks a single bad query through all four steps, measuring after each.

NOTE: verified against the Redshift Database Developer Guide (SYS_QUERY_DETAIL
step_name values; SVL_QUERY_SUMMARY; SVV_TABLE_INFO). Not yet executed on a
live cluster.
======================================================================================
*/


-- ============================================================================
-- SECTION 0: DATA SIMULATION
-- ============================================================================
-- One fact table and one dimension, then deliberately-designed copies of each so
-- we can force a different algorithm out of the same logical join.
--
-- Deterministic generators: the cross-join product must be >= the LIMIT, or the
-- LIMIT never binds and you silently get fewer rows than you think.
--   customers 10^4     =  10,000 >=   5,000
--   orders    10^5 x 3 = 300,000 >= 200,000
--   nl pair   10^3     =   1,000  =   1,000

-- ---------------------------------------------------------------------------
-- (A) The source data, loaded once
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS jt_src_customers CASCADE;
CREATE TABLE jt_src_customers (
    customer_id   INT           NOT NULL,
    customer_name VARCHAR(64)   NOT NULL,
    segment       VARCHAR(16)   NOT NULL,
    country       CHAR(2)       NOT NULL,
    credit_limit  DECIMAL(12,2) NOT NULL
);

INSERT INTO jt_src_customers
SELECT
    s.n,
    'Customer ' || s.n::VARCHAR,
    CASE WHEN s.n % 3 = 0 THEN 'ENTERPRISE' WHEN s.n % 3 = 1 THEN 'MIDMARKET' ELSE 'SMB' END,
    CASE WHEN s.n % 4 = 0 THEN 'US' WHEN s.n % 4 = 1 THEN 'GB'
         WHEN s.n % 4 = 2 THEN 'DE' ELSE 'JP' END,
    (5000 + (s.n % 45000))::DECIMAL(12,2)
FROM (
    SELECT ROW_NUMBER() OVER () AS n
    FROM (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) a
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) b
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) c
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) d
    LIMIT 5000
) s;

DROP TABLE IF EXISTS jt_src_orders CASCADE;
CREATE TABLE jt_src_orders (
    order_id     BIGINT        NOT NULL,
    customer_id  INT           NOT NULL,
    order_date   DATE          NOT NULL,
    region       VARCHAR(16)   NOT NULL,
    order_amount DECIMAL(12,2) NOT NULL,
    order_status VARCHAR(16)   NOT NULL
);

INSERT INTO jt_src_orders
SELECT
    s.n,
    (s.n % 5000 + 1),
    DATEADD(day, -(s.n % 365), '2026-08-15'::DATE),
    CASE WHEN s.n % 4 = 0 THEN 'AMER' WHEN s.n % 4 = 1 THEN 'EMEA'
         WHEN s.n % 4 = 2 THEN 'APAC' ELSE 'LATAM' END,
    (12.50 + (s.n % 400))::DECIMAL(12,2),
    -- Rarer status tested FIRST: every multiple of 20 is also a multiple of 10,
    -- so the other order would make CANCELLED unreachable.
    CASE WHEN s.n % 20 = 0 THEN 'CANCELLED'
         WHEN s.n % 10 = 0 THEN 'RETURNED'
         ELSE 'COMPLETED' END
FROM (
    SELECT ROW_NUMBER() OVER () AS n
    FROM (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) a
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) b
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) c
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) d
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) e
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2) f
    LIMIT 200000
) s;

-- ---------------------------------------------------------------------------
-- (B) MERGE-JOIN CANDIDATES — distributed AND sorted on the join column
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS jt_orders_merge CASCADE;
CREATE TABLE jt_orders_merge (
    order_id     BIGINT        NOT NULL,
    customer_id  INT           NOT NULL,
    order_date   DATE          NOT NULL,
    region       VARCHAR(16)   NOT NULL,
    order_amount DECIMAL(12,2) NOT NULL,
    order_status VARCHAR(16)   NOT NULL
)
DISTSTYLE KEY DISTKEY (customer_id)      -- distributed on the join column
COMPOUND SORTKEY (customer_id);          -- AND sorted on the join column

DROP TABLE IF EXISTS jt_customers_merge CASCADE;
CREATE TABLE jt_customers_merge (
    customer_id   INT           NOT NULL,
    customer_name VARCHAR(64)   NOT NULL,
    segment       VARCHAR(16)   NOT NULL,
    country       CHAR(2)       NOT NULL,
    credit_limit  DECIMAL(12,2) NOT NULL
)
DISTSTYLE KEY DISTKEY (customer_id)      -- same column
COMPOUND SORTKEY (customer_id);          -- same column

INSERT INTO jt_orders_merge    SELECT * FROM jt_src_orders;
INSERT INTO jt_customers_merge SELECT * FROM jt_src_customers;

-- ---------------------------------------------------------------------------
-- (C) MISALIGNED COPIES — the anti-pattern
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS jt_orders_bad CASCADE;
CREATE TABLE jt_orders_bad (
    order_id     BIGINT        NOT NULL,
    customer_id  INT           NOT NULL,
    order_date   DATE          NOT NULL,
    region       VARCHAR(16)   NOT NULL,
    order_amount DECIMAL(12,2) NOT NULL,
    order_status VARCHAR(16)   NOT NULL
)
DISTSTYLE EVEN                           -- scattered: nothing aligns
COMPOUND SORTKEY (order_date);           -- sorted on the WRONG column for this join

DROP TABLE IF EXISTS jt_customers_bad CASCADE;
CREATE TABLE jt_customers_bad (
    customer_id   INT           NOT NULL,
    customer_name VARCHAR(64)   NOT NULL,
    segment       VARCHAR(16)   NOT NULL,
    country       CHAR(2)       NOT NULL,
    credit_limit  DECIMAL(12,2) NOT NULL
)
DISTSTYLE EVEN
COMPOUND SORTKEY (customer_name);        -- sorted, but not on the join column

INSERT INTO jt_orders_bad    SELECT * FROM jt_src_orders;
INSERT INTO jt_customers_bad SELECT * FROM jt_src_customers;

-- ---------------------------------------------------------------------------
-- (D) THE HASH-JOIN IDEAL — small side replicated to every node
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS jt_customers_all CASCADE;
CREATE TABLE jt_customers_all (
    customer_id   INT           NOT NULL,
    customer_name VARCHAR(64)   NOT NULL,
    segment       VARCHAR(16)   NOT NULL,
    country       CHAR(2)       NOT NULL,
    credit_limit  DECIMAL(12,2) NOT NULL
)
DISTSTYLE ALL;                           -- a full copy on every node

INSERT INTO jt_customers_all SELECT * FROM jt_src_customers;

-- ---------------------------------------------------------------------------
-- (E) NESTED-LOOP SANDBOX — deliberately TINY, so the demo cannot hurt you
-- ---------------------------------------------------------------------------
-- 1,000 x 1,000 = 1,000,000 rows. Big enough to see the explosion, small enough
-- to finish. NEVER point a cross join at jt_src_orders: 200,000 x 5,000 is a
-- billion comparisons and it will not come back.
DROP TABLE IF EXISTS jt_nl_left CASCADE;
CREATE TABLE jt_nl_left  (id INT NOT NULL, grp INT NOT NULL, lo INT NOT NULL, hi INT NOT NULL);
DROP TABLE IF EXISTS jt_nl_right CASCADE;
CREATE TABLE jt_nl_right (id INT NOT NULL, grp INT NOT NULL, val INT NOT NULL);

INSERT INTO jt_nl_left
SELECT s.n, (s.n % 10), (s.n % 100), (s.n % 100) + 50
FROM (
    SELECT ROW_NUMBER() OVER () AS n
    FROM (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) a
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) b
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) c
    LIMIT 1000
) s;

INSERT INTO jt_nl_right
SELECT s.n, (s.n % 10), (s.n % 120)
FROM (
    SELECT ROW_NUMBER() OVER () AS n
    FROM (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) a
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) b
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) c
    LIMIT 1000
) s;

-- ---------------------------------------------------------------------------
-- (F) SORT THE MERGE CANDIDATES, THEN COLLECT STATISTICS
-- ---------------------------------------------------------------------------
-- THIS STEP IS THE WHOLE POINT OF THE MERGE-JOIN SECTION.
-- Declaring a SORTKEY does not sort anything. Rows arriving from an INSERT land
-- in the table's UNSORTED region. Until that region is merged into the sorted
-- region, Redshift cannot walk the table as an ordered stream and will not
-- choose a merge join no matter how perfect your DDL looks.
--
-- VACUUM cannot run inside a stored procedure. These are standalone statements.
VACUUM SORT ONLY jt_orders_merge;
VACUUM SORT ONLY jt_customers_merge;

ANALYZE jt_orders_merge;
ANALYZE jt_customers_merge;
ANALYZE jt_orders_bad;
ANALYZE jt_customers_bad;
ANALYZE jt_customers_all;
ANALYZE jt_nl_left;
ANALYZE jt_nl_right;

-- Confirm the simulation before trusting anything below:
SELECT 'orders'    AS tbl, COUNT(*) AS rows FROM jt_src_orders
UNION ALL SELECT 'customers', COUNT(*) FROM jt_src_customers
UNION ALL SELECT 'nl_left',   COUNT(*) FROM jt_nl_left
UNION ALL SELECT 'nl_right',  COUNT(*) FROM jt_nl_right;
-- Expect 200000 / 5000 / 1000 / 1000.

-- Confirm the merge candidates really ARE sorted (unsorted should be 0 or near it):
SELECT "table", diststyle, sortkey1, unsorted, tbl_rows
FROM svv_table_info
WHERE "table" IN ('jt_orders_merge','jt_customers_merge','jt_orders_bad',
                  'jt_customers_bad','jt_customers_all')
ORDER BY "table";


-- ============================================================================
-- SECTION 1: HOW TO READ WHICH JOIN YOU GOT
-- ============================================================================
-- Two instruments. Use both — they answer different questions.

-- (A) EXPLAIN — what the planner INTENDS. Costs nothing, runs nothing.
--     Look for the operator name and the DS_ annotation on the same line:
--
--       XN Merge Join  DS_DIST_NONE       <-- best case
--       XN Hash Join   DS_DIST_ALL_NONE   <-- very good (small side is ALL)
--       XN Hash Join   DS_DIST_NONE       <-- good (aligned DISTKEYs)
--       XN Hash Join   DS_BCAST_INNER     <-- acceptable if the inner is small
--       XN Hash Join   DS_DIST_BOTH       <-- both sides redistributed. Bad.
--       XN Nested Loop DS_BCAST_INNER     <-- almost always a bug
--
--     Two INDEPENDENT things on one line: the ALGORITHM (Merge/Hash/Nested Loop)
--     and the DATA MOVEMENT (the DS_ code, which is modules 28 and 29).

-- (B) SYS_QUERY_DETAIL — what actually RAN. Run the query first, then this.
--     step_name is a documented enumeration; the join steps appear as
--     'merge' (merge join), 'hashjoin', and 'nestloop'.
--
-- SELECT query_id, segment_id, step_id, step_name, table_name,
--        input_rows, output_rows, data_skewness,
--        spilled_block_local_disk        -- > 0 means the hash table spilled
-- FROM sys_query_detail
-- WHERE query_id = pg_last_query_id()
--   AND step_name IN ('merge','hashjoin','nestloop','hash','broadcast','distribute')
-- ORDER BY segment_id, step_id;

-- (C) Spill detection, the other way. NOTE SVL_QUERY_SUMMARY uses "query" and
--     "label" -- NOT query_id and step_name:
-- SELECT query, step, rows, workmem, label, is_diskbased
-- FROM svl_query_summary
-- WHERE query = pg_last_query_id()
-- ORDER BY workmem DESC;
--     is_diskbased = 't' on a hash step is the spill you are hunting.


-- ============================================================================
-- SECTION 2: MERGE JOIN — THE FASTEST, AND YOU HAVE TO EARN IT
-- ============================================================================

-- ---------------------------------------------------------------------------
-- EXAMPLE 1 — BAD: misaligned and mis-sorted. No merge join is possible.
-- ---------------------------------------------------------------------------
-- Both tables are DISTSTYLE EVEN, so rows for the same customer_id sit on
-- different slices. Both are sorted on a column that is not the join column.
-- Redshift must redistribute BOTH sides, then hash. Expect DS_DIST_BOTH.
EXPLAIN
SELECT c.segment, SUM(o.order_amount) AS total_amount
FROM jt_orders_bad o
JOIN jt_customers_bad c ON o.customer_id = c.customer_id
GROUP BY c.segment;

-- ---------------------------------------------------------------------------
-- EXAMPLE 2 — GOOD: distributed AND sorted on the join column. Merge join.
-- ---------------------------------------------------------------------------
-- Identical SQL. Only the physical design changed.
-- Each slice already holds its own customers and their orders, both in
-- customer_id order, so the join is one pass down two ordered streams.
EXPLAIN
SELECT c.segment, SUM(o.order_amount) AS total_amount
FROM jt_orders_merge o
JOIN jt_customers_merge c ON o.customer_id = c.customer_id
GROUP BY c.segment;

-- Run both for real and compare the numbers:
SELECT c.segment, SUM(o.order_amount) AS total_amount
FROM jt_orders_bad o
JOIN jt_customers_bad c ON o.customer_id = c.customer_id
GROUP BY c.segment ORDER BY c.segment;

SELECT c.segment, SUM(o.order_amount) AS total_amount
FROM jt_orders_merge o
JOIN jt_customers_merge c ON o.customer_id = c.customer_id
GROUP BY c.segment ORDER BY c.segment;
-- Same answers. That is the point: correctness never changed, only cost.

-- ---------------------------------------------------------------------------
-- EXAMPLE 3 — THE TRAP: right DDL, wrong physical state.
-- ---------------------------------------------------------------------------
-- A SORTKEY is a promise about how rows will be STORED. New rows land in the
-- UNSORTED region and break the ordered walk until VACUUM merges them in.
-- This is why a table that "has the right keys" still refuses to merge join,
-- and it is the number one reason people conclude merge joins are a myth.

-- Add 20,000 rows. They arrive unsorted:
INSERT INTO jt_orders_merge
SELECT order_id + 900000, customer_id, order_date, region, order_amount, order_status
FROM jt_src_orders WHERE order_id <= 20000;

-- Watch the unsorted percentage climb:
SELECT "table", sortkey1, unsorted, tbl_rows
FROM svv_table_info WHERE "table" = 'jt_orders_merge';

-- The plan may now fall back to a hash join even though the DDL is unchanged:
EXPLAIN
SELECT c.segment, SUM(o.order_amount) AS total_amount
FROM jt_orders_merge o
JOIN jt_customers_merge c ON o.customer_id = c.customer_id
GROUP BY c.segment;

-- Restore the sort order and the merge join comes back:
VACUUM SORT ONLY jt_orders_merge;
ANALYZE jt_orders_merge;

SELECT "table", sortkey1, unsorted, tbl_rows
FROM svv_table_info WHERE "table" = 'jt_orders_merge';

EXPLAIN
SELECT c.segment, SUM(o.order_amount) AS total_amount
FROM jt_orders_merge o
JOIN jt_customers_merge c ON o.customer_id = c.customer_id
GROUP BY c.segment;

/*
WHEN TO ENGINEER FOR A MERGE JOIN
  * Two LARGE tables joined on the same column, over and over, in your hottest
    reports. That is the case where the payoff justifies the constraints.
  * You can afford ONE distribution key and ONE leading sort key per table, and
    this join is what you want to spend them on.
  * You are willing to keep the tables vacuumed. An append-heavy table drifts
    out of sorted order continuously.

WHEN NOT TO BOTHER
  * One side is small — DISTSTYLE ALL plus a hash join is simpler and nearly as
    fast, with none of the maintenance. See Example 4.
  * The tables are joined on different columns in different queries. You cannot
    optimise for all of them; pick the dominant one and accept hash joins
    everywhere else.
*/


-- ============================================================================
-- SECTION 3: HASH JOIN — THE NORMAL ONE, AND HOW IT GOES WRONG
-- ============================================================================

-- ---------------------------------------------------------------------------
-- EXAMPLE 4 — GOOD: small side DISTSTYLE ALL. The everyday right answer.
-- ---------------------------------------------------------------------------
-- 5,000 customers replicated to every node. Nothing to redistribute, the build
-- side is tiny and local, and it cannot spill. Expect DS_DIST_ALL_NONE.
-- This is the single highest value-for-effort join fix in Redshift.
EXPLAIN
SELECT c.segment, c.country, SUM(o.order_amount) AS total_amount, COUNT(*) AS orders
FROM jt_orders_bad o
JOIN jt_customers_all c ON o.customer_id = c.customer_id
GROUP BY c.segment, c.country;

-- Note what did NOT change: jt_orders_bad is still DISTSTYLE EVEN. We fixed the
-- join by changing only the SMALL table. That is fix #2 of the hierarchy, and it
-- is one statement against a 5,000-row table.

-- ---------------------------------------------------------------------------
-- EXAMPLE 5 — BAD: both sides large and misaligned. Redistribute, then spill.
-- ---------------------------------------------------------------------------
-- A self-join of the 200,000-row fact. The build side is large, and neither side
-- is distributed on the join column, so both move across the network first.
EXPLAIN
SELECT o1.region, COUNT(*) AS pair_count
FROM jt_orders_bad o1
JOIN jt_orders_bad o2
  ON o1.customer_id = o2.customer_id
 AND o1.order_date  = o2.order_date
GROUP BY o1.region;

-- Run it, then look for the spill:
SELECT o1.region, COUNT(*) AS pair_count
FROM jt_orders_bad o1
JOIN jt_orders_bad o2
  ON o1.customer_id = o2.customer_id
 AND o1.order_date  = o2.order_date
GROUP BY o1.region;

SELECT query_id, segment_id, step_id, step_name,
       input_rows, output_rows, spilled_block_local_disk
FROM sys_query_detail
WHERE query_id = pg_last_query_id()
  AND step_name IN ('hashjoin','hash','distribute','broadcast')
ORDER BY segment_id, step_id;
-- spilled_block_local_disk > 0 on a hash step means the build side did not fit
-- in the memory this query was granted.

-- ---------------------------------------------------------------------------
-- EXAMPLE 6 — BAD: the optimizer builds from the WRONG side (stale statistics)
-- ---------------------------------------------------------------------------
-- The planner chooses the build side from ESTIMATED row counts. If the stats are
-- stale it can build the hash table from the 200,000-row side instead of the
-- 5,000-row side. Same SQL, same DDL, 40x the memory.
--
-- Simulate it: load a lot of rows and deliberately do NOT analyze.
DROP TABLE IF EXISTS jt_stats_demo CASCADE;
CREATE TABLE jt_stats_demo (
    customer_id  INT           NOT NULL,
    order_amount DECIMAL(12,2) NOT NULL
) DISTSTYLE EVEN;

INSERT INTO jt_stats_demo SELECT customer_id, order_amount FROM jt_src_orders;
-- deliberately NO ANALYZE here

-- The planner is now guessing. Check how badly (stats_off is % staleness):
SELECT "table", tbl_rows, stats_off
FROM svv_table_info WHERE "table" = 'jt_stats_demo';

EXPLAIN
SELECT c.segment, SUM(d.order_amount)
FROM jt_stats_demo d
JOIN jt_customers_all c ON d.customer_id = c.customer_id
GROUP BY c.segment;

-- Fix #1 of the hierarchy. One statement, no design change:
ANALYZE jt_stats_demo;

SELECT "table", tbl_rows, stats_off
FROM svv_table_info WHERE "table" = 'jt_stats_demo';

EXPLAIN
SELECT c.segment, SUM(d.order_amount)
FROM jt_stats_demo d
JOIN jt_customers_all c ON d.customer_id = c.customer_id
GROUP BY c.segment;

-- Planner-flagged problems, including missing statistics, land here:
SELECT event, solution, query, event_time
FROM stl_alert_event_log
WHERE event_time >= DATEADD(hour, -1, GETDATE())
ORDER BY event_time DESC
LIMIT 10;

/*
HASH JOIN CHECKLIST
  * Is the build side the SMALL side? If not, ANALYZE (fix #1).
  * Is the small side DISTSTYLE ALL? If not, make it so (fix #2).
  * Is is_diskbased = 't', or spilled_block_local_disk > 0? The hash table did
    not fit. Filter earlier to shrink the build side, or stage in steps.
  * Is the DS_ code DS_DIST_BOTH? Both sides moved before the join even started.
    Align the DISTKEYs (fix #3).
*/


-- ============================================================================
-- SECTION 4: NESTED LOOP — ALMOST ALWAYS A BUG. READ YOUR ON CLAUSE.
-- ============================================================================
-- SAFETY: every example here uses the 1,000-row sandbox tables.

-- ---------------------------------------------------------------------------
-- EXAMPLE 7 — BAD: no ON clause at all. The classic accidental cross join.
-- ---------------------------------------------------------------------------
-- Comma-separated FROM with the join condition forgotten, or lost in a refactor.
-- 1,000 x 1,000 = 1,000,000 rows out of 2,000 rows in.
EXPLAIN
SELECT COUNT(*) FROM jt_nl_left l, jt_nl_right r;

SELECT COUNT(*) AS exploded_rows FROM jt_nl_left l, jt_nl_right r;
-- 1,000,000. From two 1,000-row tables. Now imagine both sides were the fact
-- table: 200,000 x 5,000 = 1,000,000,000. That query does not come back.

-- ---------------------------------------------------------------------------
-- EXAMPLE 8 — BAD: non-equality ON clause (a range join)
-- ---------------------------------------------------------------------------
-- BETWEEN, <, >, <> in the ON clause. There is no equality for a hash to key on,
-- so Redshift has no choice but to test every pair.
EXPLAIN
SELECT COUNT(*)
FROM jt_nl_left l
JOIN jt_nl_right r ON r.val BETWEEN l.lo AND l.hi;

-- ---------------------------------------------------------------------------
-- EXAMPLE 9 — BAD: OR in the ON clause
-- ---------------------------------------------------------------------------
-- An OR of two equalities cannot be served by a single hash key either.
EXPLAIN
SELECT COUNT(*)
FROM jt_nl_left l
JOIN jt_nl_right r ON l.id = r.id OR l.grp = r.grp;

-- GOOD: split the OR into two equi-joins and UNION them. Each half hashes.
EXPLAIN
SELECT COUNT(*) FROM (
    SELECT l.id AS lid, r.id AS rid FROM jt_nl_left l JOIN jt_nl_right r ON l.id  = r.id
    UNION
    SELECT l.id,        r.id        FROM jt_nl_left l JOIN jt_nl_right r ON l.grp = r.grp
);

-- ---------------------------------------------------------------------------
-- EXAMPLE 10 — GOOD: the equi-join, and the one legitimate nested loop
-- ---------------------------------------------------------------------------
-- Restore the equality and the algorithm changes immediately:
EXPLAIN
SELECT COUNT(*) FROM jt_nl_left l JOIN jt_nl_right r ON l.id = r.id;

-- Narrow a range join to an equi-join plus a residual filter. The equality does
-- the joining; the inequality only filters what survived it.
EXPLAIN
SELECT COUNT(*)
FROM jt_nl_left l
JOIN jt_nl_right r
  ON l.grp = r.grp                     -- equality first: this is what hashes
WHERE r.val BETWEEN l.lo AND l.hi;     -- inequality demoted to a filter

-- THE ONE LEGITIMATE CASE: a deliberate cross join against something tiny.
-- Building a dense grid (module 39's calendar spine) is a nested loop by design,
-- and that is fine, because the right side has 7 rows.
EXPLAIN
SELECT l.grp, d.day_offset
FROM (SELECT DISTINCT grp FROM jt_nl_left) l
CROSS JOIN (SELECT 0 AS day_offset UNION SELECT 1 UNION SELECT 2 UNION SELECT 3
            UNION SELECT 4 UNION SELECT 5 UNION SELECT 6) d;

/*
NESTED LOOP TRIAGE — in the order you should check
  1. Is there an ON clause at all? Comma-joins hide missing ones.
  2. Is every ON condition an EQUALITY? BETWEEN, <, >, <> and OR all force it.
  3. Is one side genuinely tiny AND the cross join deliberate? Then it is fine.
  4. Otherwise the stats are lying to the planner. ANALYZE and look again.
*/


-- ============================================================================
-- SECTION 5: THE FIX HIERARCHY, WALKED IN ORDER
-- ============================================================================
-- One bad query. Four fixes, applied one at a time, measuring after each — which
-- is Practice 6, "change one thing at a time", made concrete.

-- The patient: large fact, misaligned; dimension not replicated; no statistics.
DROP TABLE IF EXISTS jt_fix_orders CASCADE;
CREATE TABLE jt_fix_orders (
    order_id     BIGINT        NOT NULL,
    customer_id  INT           NOT NULL,
    order_amount DECIMAL(12,2) NOT NULL
) DISTSTYLE EVEN;

DROP TABLE IF EXISTS jt_fix_customers CASCADE;
CREATE TABLE jt_fix_customers (
    customer_id INT         NOT NULL,
    segment     VARCHAR(16) NOT NULL
) DISTSTYLE EVEN;

INSERT INTO jt_fix_orders    SELECT order_id, customer_id, order_amount FROM jt_src_orders;
INSERT INTO jt_fix_customers SELECT customer_id, segment FROM jt_src_customers;
-- No ANALYZE. No DISTKEY. This is what a "slow join" ticket usually looks like.

-- BASELINE — measure before you change anything (Practice 2):
EXPLAIN
SELECT c.segment, SUM(o.order_amount)
FROM jt_fix_orders o JOIN jt_fix_customers c ON o.customer_id = c.customer_id
GROUP BY c.segment;

-- ---- FIX 1 · ANALYZE. Cheapest, most common cause. Always first. ----------
ANALYZE jt_fix_orders;
ANALYZE jt_fix_customers;

EXPLAIN
SELECT c.segment, SUM(o.order_amount)
FROM jt_fix_orders o JOIN jt_fix_customers c ON o.customer_id = c.customer_id
GROUP BY c.segment;
-- Often this alone fixes the build-side choice. If the plan is now acceptable,
-- STOP. You are done, and you never touched the schema or the SQL.

-- ---- FIX 2 · Make the small side DISTSTYLE ALL. One statement. -----------
ALTER TABLE jt_fix_customers ALTER DISTSTYLE ALL;
ANALYZE jt_fix_customers;

EXPLAIN
SELECT c.segment, SUM(o.order_amount)
FROM jt_fix_orders o JOIN jt_fix_customers c ON o.customer_id = c.customer_id
GROUP BY c.segment;
-- Expect the data movement to collapse to DS_DIST_ALL_NONE. For a fact-to-
-- dimension join this is usually the end of the road, and it is one command.

-- ---- FIX 3 · Align the DISTKEYs. Bigger change; do it when BOTH are large. --
ALTER TABLE jt_fix_orders ALTER DISTSTYLE KEY DISTKEY customer_id;
ANALYZE jt_fix_orders;

EXPLAIN
SELECT c.segment, SUM(o.order_amount)
FROM jt_fix_orders o JOIN jt_fix_customers c ON o.customer_id = c.customer_id
GROUP BY c.segment;
-- To go all the way to a MERGE join you would also need
--   COMPOUND SORTKEY (customer_id) on both sides, plus VACUUM SORT ONLY.
-- Sort keys cannot be added by ALTER, so that means CTAS and swap — which is
-- exactly why this sits at step 3 and not step 1.

-- ---- FIX 4 · Only NOW rewrite the SQL. ----------------------------------
-- Filter early so less reaches the join (module 30), and pre-aggregate to the
-- join grain so fewer rows are joined at all (module 27).
EXPLAIN
SELECT c.segment, SUM(o.total_amount)
FROM (
    SELECT customer_id, SUM(order_amount) AS total_amount
    FROM jt_fix_orders
    GROUP BY customer_id                 -- 200,000 rows collapse to 5,000 first
) o
JOIN jt_fix_customers c ON o.customer_id = c.customer_id
GROUP BY c.segment;

-- Correctness gate: the rewrite MUST return identical numbers (Practice 5).
SELECT 'original' AS version, c.segment, SUM(o.order_amount) AS total_amount
FROM jt_fix_orders o JOIN jt_fix_customers c ON o.customer_id = c.customer_id
GROUP BY c.segment
UNION ALL
SELECT 'rewritten', c.segment, SUM(o.total_amount)
FROM (SELECT customer_id, SUM(order_amount) AS total_amount
      FROM jt_fix_orders GROUP BY customer_id) o
JOIN jt_fix_customers c ON o.customer_id = c.customer_id
GROUP BY c.segment
ORDER BY segment, version;


-- ============================================================================
-- SECTION 6: SUMMARY
-- ============================================================================
/*
┌───────────────┬──────────────────────┬────────────────────┬─────────────────────┐
│ Algorithm     │ Redshift picks it    │ Cost               │ What it tells you   │
│               │ when…                │                    │                     │
├───────────────┼──────────────────────┼────────────────────┼─────────────────────┤
│ MERGE JOIN    │ both sides DISTKEY   │ O(n+m), one pass,  │ Your design is      │
│               │ AND SORTKEY on the   │ no hash table,     │ right. Keep it      │
│               │ join column, AND     │ cannot spill       │ vacuumed or you     │
│               │ actually sorted      │                    │ will lose it.       │
├───────────────┼──────────────────────┼────────────────────┼─────────────────────┤
│ HASH JOIN     │ equi-join, anything  │ builds a hash on   │ Normal. Check WHICH │
│               │ else                 │ the smaller side;  │ side was built, and │
│               │                      │ spills if it does  │ whether it spilled. │
│               │                      │ not fit in memory  │                     │
├───────────────┼──────────────────────┼────────────────────┼─────────────────────┤
│ NESTED LOOP   │ no equality to key   │ n x m. Effectively │ A BUG, until proven │
│               │ on — missing ON,     │ unbounded          │ otherwise. Read the │
│               │ BETWEEN, <, >, OR    │                    │ ON clause.          │
└───────────────┴──────────────────────┴────────────────────┴─────────────────────┘

TWO INDEPENDENT DIMENSIONS ON ONE EXPLAIN LINE
  ALGORITHM       Merge Join / Hash Join / Nested Loop        <- this module
  DATA MOVEMENT   DS_DIST_NONE / DS_DIST_ALL_NONE /
                  DS_BCAST_INNER / DS_DIST_BOTH               <- modules 28, 29
  A collocated nested loop is still a disaster. A hash join that broadcasts a
  30-row dimension is fine. Read both halves of the line.

THE FIX HIERARCHY, ONCE MORE, IN ORDER
  1 · ANALYZE                    cheapest, most common cause, no design change
  2 · small side DISTSTYLE ALL   one statement, fixes most dimension joins
  3 · align DISTKEYs             physical redesign; do when both sides are large
  4 · rewrite the SQL            last. Most tickets never get here.

  Working from 4 backwards is how people spend a week rewriting a query whose
  only problem was a missing ANALYZE.

RELATED MODULES
  28  distribution key alignment    DS_DIST_NONE vs DS_DIST_BOTH
  29  broadcast dimensions          DISTSTYLE ALL, DS_BCAST_INNER
  27  exploding joins and grain     when the join is right but the GRAIN is wrong
  30  filtering before joins        shrink both sides before they meet
  34  staged loads and stats        how missing stats produce a nested loop
  74  query diagnostics             the full triage flowchart
*/


-- ============================================================================
-- CLEANUP
-- ============================================================================
-- DROP TABLE IF EXISTS jt_src_orders CASCADE;
-- DROP TABLE IF EXISTS jt_src_customers CASCADE;
-- DROP TABLE IF EXISTS jt_orders_merge CASCADE;
-- DROP TABLE IF EXISTS jt_customers_merge CASCADE;
-- DROP TABLE IF EXISTS jt_orders_bad CASCADE;
-- DROP TABLE IF EXISTS jt_customers_bad CASCADE;
-- DROP TABLE IF EXISTS jt_customers_all CASCADE;
-- DROP TABLE IF EXISTS jt_nl_left CASCADE;
-- DROP TABLE IF EXISTS jt_nl_right CASCADE;
-- DROP TABLE IF EXISTS jt_stats_demo CASCADE;
-- DROP TABLE IF EXISTS jt_fix_orders CASCADE;
-- DROP TABLE IF EXISTS jt_fix_customers CASCADE;
