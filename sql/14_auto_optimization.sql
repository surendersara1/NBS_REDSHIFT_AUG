-- =========================================================================
-- 14 — What AUTO actually does
--
--   DISTSTYLE AUTO   ALL -> EVEN -> KEY
--                    Starts a small table as ALL, converts to EVEN as it
--                    grows, and may adopt a KEY once it sees a repeated
--                    join on the same column.
--
--   SORTKEY AUTO     from observed filters
--                    Picks a sort column from the predicates it sees
--                    repeatedly, and reorganises the table in the background.
--
--   ENCODE AUTO      on first COPY
--                    Samples the incoming data on a COPY into an empty table
--                    and applies compression. This one is nearly always right.
--
--   IT NEEDS TIME AND EVIDENCE — days, not minutes.
--                    Before it has seen a workload, it guesses. On a big
--                    fact table you ALREADY KNOW the join column: state it
--                    rather than wait for Redshift to discover it.
--
-- THE RULE: AUTO where you do not know. Explicit where you do.
-- =========================================================================


-- =========================================================================
-- 14.1  AUTO in practice
-- =========================================================================
DROP TABLE IF EXISTS analytics.t_auto_demo;

CREATE TABLE analytics.t_auto_demo (
    sale_id     BIGINT,
    sale_date   DATE,
    store_sk    BIGINT,
    net_amount  DECIMAL(14,2)
)
DISTSTYLE AUTO
SORTKEY AUTO;

INSERT INTO analytics.t_auto_demo
SELECT sale_id, sale_date, store_id, revenue
FROM   analytics.fct_retail_sales;

ANALYZE analytics.t_auto_demo;

-- Right now it will most likely report AUTO(ALL) or AUTO(EVEN) — small
-- table, no observed workload yet.
SELECT "table", diststyle, sortkey1, sortkey_num, tbl_rows, size
FROM   svv_table_info
WHERE  "table" = 't_auto_demo';

-- Compare against the table where we stated the answer ourselves:
SELECT "table", diststyle, sortkey1, skew_rows, tbl_rows
FROM   svv_table_info
WHERE  "table" IN ('t_auto_demo','fct_retail_sales');


-- =========================================================================
-- 14.2  What does Redshift WANT to change?
--
-- Automatic table optimization records its intentions here before acting.
-- Reading this view is how you find out what the system thinks of your
-- schema — a free design review from the engine.
-- =========================================================================
SELECT type, database, table_id, group_id, auto_eligible, ddl
FROM   svv_alter_table_recommendations;

-- Joined to table names, which the raw view does not give you:
SELECT r.type, t."schema", t."table", t.diststyle, t.sortkey1,
       t.tbl_rows, r.auto_eligible, r.ddl
FROM   svv_alter_table_recommendations r
JOIN   svv_table_info t ON t.table_id = r.table_id
ORDER  BY t.tbl_rows DESC;

-- auto_eligible = 't' means Redshift will apply it itself, in a maintenance
-- window. 'f' means it is advice only — you have to run the DDL.


-- =========================================================================
-- 14.3  What has it ALREADY done?
--
-- Check this before concluding a table is neglected, and before "fixing" a
-- dist key: the system may have changed it under you, and your mental model
-- of the schema may be out of date.
-- =========================================================================
SELECT * FROM svl_auto_worker_action
ORDER  BY eventtime DESC
LIMIT  50;

-- Automatic VACUUM / ANALYZE activity:
SELECT * FROM svl_auto_vacuum_sort_summary ORDER BY 1 DESC LIMIT 20;
SELECT * FROM svv_vacuum_summary ORDER BY 1 DESC LIMIT 20;

-- Automated materialized views — Redshift may create MVs you did not write.
SELECT * FROM svv_mv_info WHERE schema_name NOT IN ('rpt','analytics');


-- =========================================================================
-- 14.4  Turning it off where you know better
-- =========================================================================
-- State the answer explicitly. This also STOPS automatic optimization from
-- changing it, which is the point on a table whose access pattern you own.
ALTER TABLE analytics.t_auto_demo ALTER DISTSTYLE KEY DISTKEY (store_sk);
ALTER TABLE analytics.t_auto_demo ALTER COMPOUND SORTKEY (sale_date);

SELECT "table", diststyle, sortkey1 FROM svv_table_info
WHERE  "table" = 't_auto_demo';

-- Going back to AUTO, if you decide you were wrong:
--   ALTER TABLE analytics.t_auto_demo ALTER DISTSTYLE AUTO;
--   ALTER TABLE analytics.t_auto_demo ALTER SORTKEY AUTO;


-- =========================================================================
-- 14.5  Gotchas
--
--   * AUTO needs DAYS of real workload. A table created this morning and
--     benchmarked this afternoon has had no chance to be optimised — do not
--     conclude AUTO is useless from that test.
--   * Automatic optimization runs in maintenance windows and may not run at
--     all while the cluster is busy. On a paused teaching cluster it will
--     essentially never run.
--   * DISTSTYLE AUTO starting as ALL means small tables are replicated to
--     every node. That is correct for a dimension and expensive for a table
--     that is about to grow to a billion rows.
--   * ENCODE AUTO applies on COPY INTO AN EMPTY TABLE only. CTAS + INSERT
--     gets you nothing — see file 12 §12.3.
--   * A background reorganisation can change skew and plans without any
--     deployment. When "nothing changed but it got slower", check
--     svl_auto_worker_action before anything else.
--   * You cannot rely on AUTO for a table you drop and recreate nightly.
--     Every rebuild resets what it had learned.
--
-- THE DECISION, stated plainly:
--   Do you know the join column and the filter column?
--     yes -> state them. You are right and you are right today.
--     no  -> AUTO, and revisit in a week with svv_alter_table_recommendations.
-- =========================================================================
DROP TABLE IF EXISTS analytics.t_auto_demo;
