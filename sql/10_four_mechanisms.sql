-- =========================================================================
-- 10 — FOUR MECHANISMS, NONE OF THEM AN INDEX
--
-- Redshift has no indexes. Application developers reach for one on day one
-- and find nothing there. Four mechanisms replace it, and each is a
-- CREATE TABLE decision, not something you add later when it is slow.
--
--   SORT KEY   -> ZONE MAPS       skips blocks
--   DIST KEY   -> NO DATA MOVEMENT co-located joins
--   COLUMNAR   -> FEWER BYTES      + compression
--   STATISTICS -> A GOOD PLAN      ANALYZE
--
-- This file builds the SAME data four different ways so each mechanism can
-- be MEASURED rather than asserted. Run every comparison. Write the numbers
-- down. A learner who has seen a 40x difference with their own eyes never
-- forgets the mechanism that caused it.
--
-- Scale up first — the effects need volume to be visible:
--     python data/generate_sample_data.py --customers 200000 --orders 4000000
-- Or synthesise directly in-database, as 10.0 does.
-- =========================================================================


-- -------------------------------------------------------------------------
-- 10.0  Build a bigger fact table, entirely in SQL
--
-- Cross-joining the existing orders against a small multiplier table is the
-- cheapest way to get millions of rows without leaving Redshift.
-- -------------------------------------------------------------------------
DROP TABLE IF EXISTS analytics.big_orders_source;

CREATE TABLE analytics.big_orders_source
DISTSTYLE EVEN
AS
WITH multiplier AS (
    SELECT n FROM (
        SELECT ROW_NUMBER() OVER () AS n
        FROM analytics.dim_date LIMIT 400          -- 400 copies
    )
)
SELECT
    (o.order_id * 1000 + m.n)                       AS order_id,
    o.customer_id,
    DATEADD(day, (m.n % 1000), o.order_date)        AS sale_date,
    o.segment,
    o.country,
    o.status,
    o.quantity,
    o.unit_price,
    (o.quantity * o.unit_price)::DECIMAL(18,2)      AS revenue,
    -- a few wide columns, so the columnar test has something to skip
    REPEAT('x', 200)                                AS filler_a,
    REPEAT('y', 200)                                AS filler_b,
    REPEAT('z', 200)                                AS filler_c
FROM   analytics.fct_customer_orders o
CROSS JOIN multiplier m;

ANALYZE analytics.big_orders_source;
SELECT COUNT(*) AS source_rows FROM analytics.big_orders_source;


-- =========================================================================
-- MECHANISM 1 — SORT KEY -> ZONE MAPS
--
-- Redshift stores the MIN and MAX of every column for each 1 MB block.
-- Before reading a block it compares your WHERE clause against that pair
-- and skips the block entirely if it cannot match. That is a zone map.
--
-- Sorted on sale_date, a query for one week reads only the blocks that
-- could contain that week. Unsorted, the same query reads everything,
-- because any block might contain any date.
-- =========================================================================
DROP TABLE IF EXISTS analytics.t_sort_none;
DROP TABLE IF EXISTS analytics.t_sort_date;

CREATE TABLE analytics.t_sort_none
DISTSTYLE EVEN
AS SELECT * FROM analytics.big_orders_source;

CREATE TABLE analytics.t_sort_date
DISTSTYLE EVEN
COMPOUND SORTKEY (sale_date)
AS SELECT * FROM analytics.big_orders_source;

ANALYZE analytics.t_sort_none;
ANALYZE analytics.t_sort_date;

-- Same query, both tables. Time them.
SELECT COUNT(*), SUM(revenue) FROM analytics.t_sort_none
WHERE  sale_date BETWEEN '2024-06-01' AND '2024-06-07';

SELECT COUNT(*), SUM(revenue) FROM analytics.t_sort_date
WHERE  sale_date BETWEEN '2024-06-01' AND '2024-06-07';

-- THE PROOF — blocks actually read, not elapsed time (which is noisy).
-- is_rrscan = true means a range-restricted scan: the zone map was used.
SELECT query_id,
       LEFT(query_text, 55) AS sql_preview,
       step_name, table_name, is_rrscan,
       input_rows, output_rows,
       duration/1000.0 AS ms
FROM   sys_query_detail
WHERE  query_id > pg_last_query_id() - 4
  AND  step_name ILIKE '%scan%'
ORDER  BY query_id, step_name;

-- Block-level truth. The sorted table should touch far fewer blocks.
SELECT t."table", COUNT(*) AS total_blocks
FROM   stv_blocklist b
JOIN   svv_table_info t ON t.table_id = b.tbl
WHERE  t."table" IN ('t_sort_none','t_sort_date')
GROUP  BY 1;

-- The zone maps themselves — min/max per block for the sort column:
SELECT slice, col, blocknum, minvalue, maxvalue, num_values
FROM   stv_blocklist
WHERE  tbl = (SELECT table_id FROM svv_table_info WHERE "table" = 't_sort_date')
  AND  col = 2
ORDER  BY slice, blocknum
LIMIT  20;
-- On t_sort_date the ranges are tight and non-overlapping. On t_sort_none
-- every block spans nearly the whole date range, so nothing can be skipped.

-- Sort key decay: rows inserted after the initial load land unsorted.
INSERT INTO analytics.t_sort_date
SELECT * FROM analytics.big_orders_source LIMIT 100000;

SELECT "table", tbl_rows, unsorted, vacuum_sort_benefit
FROM   svv_table_info WHERE "table" = 't_sort_date';
-- unsorted > 10 means the zone maps are degrading. Fix:
VACUUM SORT ONLY analytics.t_sort_date;
ANALYZE analytics.t_sort_date;


-- =========================================================================
-- MECHANISM 2 — DIST KEY -> NO DATA MOVEMENT
--
-- Two tables distributed on the SAME key join slice-locally: the matching
-- rows are already on the same node. The alternative is shipping rows
-- between nodes mid-query, and that network cost is the real expense in a
-- distributed join — usually far larger than the scan.
-- =========================================================================
DROP TABLE IF EXISTS analytics.t_dist_even;
DROP TABLE IF EXISTS analytics.t_dist_key;
DROP TABLE IF EXISTS analytics.t_dim_even;
DROP TABLE IF EXISTS analytics.t_dim_key;

-- Pair A: mismatched distribution -> the join must redistribute.
CREATE TABLE analytics.t_dist_even DISTSTYLE EVEN AS
SELECT * FROM analytics.big_orders_source;

CREATE TABLE analytics.t_dim_even DISTSTYLE EVEN AS
SELECT customer_id, customer_name, segment, country
FROM   analytics.fct_customer_orders;

-- Pair B: both on customer_id -> collocated, no movement.
CREATE TABLE analytics.t_dist_key DISTKEY (customer_id) AS
SELECT * FROM analytics.big_orders_source;

CREATE TABLE analytics.t_dim_key DISTKEY (customer_id) AS
SELECT customer_id, customer_name, segment, country
FROM   analytics.fct_customer_orders;

ANALYZE analytics.t_dist_even; ANALYZE analytics.t_dim_even;
ANALYZE analytics.t_dist_key;  ANALYZE analytics.t_dim_key;

-- Read the plans. Look for the DS_ prefix.
EXPLAIN
SELECT d.segment, COUNT(*), SUM(f.revenue)
FROM   analytics.t_dist_even f JOIN analytics.t_dim_even d USING (customer_id)
GROUP  BY d.segment;
-- expect DS_BCAST_INNER or DS_DIST_BOTH

EXPLAIN
SELECT d.segment, COUNT(*), SUM(f.revenue)
FROM   analytics.t_dist_key f JOIN analytics.t_dim_key d USING (customer_id)
GROUP  BY d.segment;
-- expect DS_DIST_NONE  <- the goal

-- Worst to best:
--   DS_DIST_BOTH    both sides redistributed. Almost always a design bug.
--   DS_BCAST_INNER  whole inner table broadcast to every node. Fine only
--                   for a genuinely tiny table.
--   DS_DIST_INNER   inner side redistributed. Expensive.
--   DS_DIST_NONE    no movement. Collocated.

-- Now run them and measure the bytes that actually crossed the network:
SELECT d.segment, COUNT(*), SUM(f.revenue)
FROM   analytics.t_dist_even f JOIN analytics.t_dim_even d USING (customer_id)
GROUP  BY d.segment;

SELECT d.segment, COUNT(*), SUM(f.revenue)
FROM   analytics.t_dist_key f JOIN analytics.t_dim_key d USING (customer_id)
GROUP  BY d.segment;

-- SYS_QUERY_DETAIL has no is_distkey and no network_distribute_bytes.
-- Data movement appears as a STEP: 'distribute' or 'broadcast'. Their
-- presence is the redistribution; their absence is the collocated join.
SELECT query_id, step_name, table_name,
       input_rows, output_rows, duration/1000.0 AS ms
FROM   sys_query_detail
WHERE  query_id > pg_last_query_id() - 3
  AND  step_name IN ('distribute','broadcast','hashjoin','scan')
ORDER  BY query_id, step_id;

-- The count that settles it — rows shipped across the network per query:
SELECT query_id,
       SUM(CASE WHEN step_name = 'distribute' THEN output_rows ELSE 0 END) AS rows_distributed,
       SUM(CASE WHEN step_name = 'broadcast'  THEN output_rows ELSE 0 END) AS rows_broadcast
FROM   sys_query_detail
WHERE  query_id > pg_last_query_id() - 3
GROUP  BY query_id ORDER BY query_id;
-- Both zero on the DISTKEY-matched pair. Non-zero on the EVEN pair.

-- Legacy equivalent, with actual bytes and packets on the wire:
SELECT query, slice, step, rows, bytes, packets,
       DATEDIFF(seconds, starttime, endtime) AS duration_sec
FROM   stl_dist
WHERE  query > pg_last_query_id() - 3
ORDER  BY query, slice;

-- Skew — the failure mode of a BAD dist key. Choosing a low-cardinality
-- column (status, country) puts most rows on one slice, and that slice
-- becomes the whole query's runtime.
DROP TABLE IF EXISTS analytics.t_dist_skewed;
CREATE TABLE analytics.t_dist_skewed DISTKEY (status) AS
SELECT * FROM analytics.big_orders_source;
ANALYZE analytics.t_dist_skewed;

SELECT "table", diststyle, skew_rows, tbl_rows
FROM   svv_table_info
WHERE  "table" IN ('t_dist_even','t_dist_key','t_dist_skewed');
-- skew_rows is biggest-slice : smallest-slice. Above ~4, the dist key is
-- wrong. status has 6 distinct values, so it cannot spread across slices.

SELECT slice, COUNT(*) AS blocks
FROM   stv_blocklist
WHERE  tbl = (SELECT table_id FROM svv_table_info WHERE "table" = 't_dist_skewed')
GROUP  BY slice ORDER BY blocks DESC;


-- =========================================================================
-- MECHANISM 3 — COLUMNAR -> FEWER BYTES, THEN COMPRESSION
--
-- You only read the columns you name, and they are compressed. Three
-- columns out of two hundred is 1.5% of the table before compression helps
-- at all. This is why SELECT * is a different category of mistake here than
-- in an OLTP database.
-- =========================================================================
DROP TABLE IF EXISTS analytics.t_encode_raw;
DROP TABLE IF EXISTS analytics.t_encode_good;

CREATE TABLE analytics.t_encode_raw (
    order_id BIGINT ENCODE raw, customer_id BIGINT ENCODE raw,
    sale_date DATE ENCODE raw, segment VARCHAR(50) ENCODE raw,
    country VARCHAR(10) ENCODE raw, status VARCHAR(20) ENCODE raw,
    quantity INTEGER ENCODE raw, unit_price DECIMAL(18,2) ENCODE raw,
    revenue DECIMAL(18,2) ENCODE raw,
    filler_a VARCHAR(256) ENCODE raw, filler_b VARCHAR(256) ENCODE raw,
    filler_c VARCHAR(256) ENCODE raw
) DISTSTYLE EVEN;

CREATE TABLE analytics.t_encode_good (
    order_id BIGINT ENCODE az64, customer_id BIGINT ENCODE az64,
    sale_date DATE ENCODE az64, segment VARCHAR(50) ENCODE bytedict,
    country VARCHAR(10) ENCODE bytedict, status VARCHAR(20) ENCODE bytedict,
    quantity INTEGER ENCODE az64, unit_price DECIMAL(18,2) ENCODE az64,
    revenue DECIMAL(18,2) ENCODE az64,
    filler_a VARCHAR(256) ENCODE zstd, filler_b VARCHAR(256) ENCODE zstd,
    filler_c VARCHAR(256) ENCODE zstd
) DISTSTYLE EVEN;

INSERT INTO analytics.t_encode_raw  SELECT * FROM analytics.big_orders_source;
INSERT INTO analytics.t_encode_good SELECT * FROM analytics.big_orders_source;
ANALYZE analytics.t_encode_raw; ANALYZE analytics.t_encode_good;

-- The size multiple. Report this number in the day-4 readout.
SELECT "table", size AS size_mb, tbl_rows, encoded,
       ROUND(size::NUMERIC / NULLIF(MIN(size) OVER (), 0), 2) AS x_vs_smallest
FROM   svv_table_info
WHERE  "table" IN ('t_encode_raw','t_encode_good');

-- What Redshift itself would choose, given the actual data:
ANALYZE COMPRESSION analytics.t_encode_raw;

-- Column projection: three narrow columns vs SELECT *.
SELECT segment, SUM(revenue) FROM analytics.t_encode_good GROUP BY segment;
SELECT COUNT(*) FROM (SELECT * FROM analytics.t_encode_good) x;

SELECT query_id, LEFT(query_text, 50) AS sql_preview,
       SUM(input_bytes)/1024/1024 AS mb_read
FROM   sys_query_detail
WHERE  query_id > pg_last_query_id() - 3
GROUP  BY 1, 2 ORDER BY query_id;

-- Bytes per column — where the storage actually went.
SELECT b.col, c.attname AS column_name, COUNT(*) AS blocks
FROM   stv_blocklist b
JOIN   pg_attribute c
       ON c.attrelid = (SELECT table_id FROM svv_table_info WHERE "table"='t_encode_good')
      AND c.attnum = b.col + 1
WHERE  b.tbl = (SELECT table_id FROM svv_table_info WHERE "table"='t_encode_good')
GROUP  BY 1, 2 ORDER BY blocks DESC;


-- =========================================================================
-- MECHANISM 4 — STATISTICS -> A GOOD PLAN
--
-- The planner needs table sizes and value spread to choose a join strategy
-- and a join ORDER. Stale statistics are the closest thing Redshift has to
-- a "missing index": the data is fine, the storage is fine, and the plan is
-- catastrophic.
-- =========================================================================
DROP TABLE IF EXISTS analytics.t_stats_stale;

CREATE TABLE analytics.t_stats_stale DISTKEY (customer_id) AS
SELECT * FROM analytics.big_orders_source WHERE 1 = 0;    -- empty, stats say 0

-- Plan while the planner believes the table is empty:
EXPLAIN
SELECT d.segment, COUNT(*) FROM analytics.t_stats_stale f
JOIN   analytics.t_dim_key d USING (customer_id) GROUP BY d.segment;

-- Load millions of rows WITHOUT analyzing. Statistics still say zero.
INSERT INTO analytics.t_stats_stale SELECT * FROM analytics.big_orders_source;

SELECT "table", tbl_rows, stats_off FROM svv_table_info
WHERE  "table" = 't_stats_stale';
-- stats_off near 100 means the planner's numbers are entirely fictional.

-- Same EXPLAIN. The estimated rows are still ~0 while the table holds
-- millions — this is exactly how a nested-loop plan gets chosen and a
-- query that should take 2 seconds takes 40 minutes.
EXPLAIN
SELECT d.segment, COUNT(*) FROM analytics.t_stats_stale f
JOIN   analytics.t_dim_key d USING (customer_id) GROUP BY d.segment;

ANALYZE analytics.t_stats_stale;

-- And again, with truth:
EXPLAIN
SELECT d.segment, COUNT(*) FROM analytics.t_stats_stale f
JOIN   analytics.t_dim_key d USING (customer_id) GROUP BY d.segment;

SELECT "table", tbl_rows, stats_off FROM svv_table_info
WHERE  "table" = 't_stats_stale';

-- Everything currently lying to the planner:
SELECT "table", tbl_rows, stats_off, unsorted, skew_rows, size
FROM   svv_table_info
WHERE  "schema" = 'analytics' AND stats_off > 5
ORDER  BY stats_off DESC;


-- =========================================================================
-- 10.5  Putting all four inside a procedure
--
-- A maintenance procedure that reads the catalog, decides what needs
-- attention, and manipulates the data accordingly. Set-based, one cursor,
-- re-runnable — and note that VACUUM is NOT here, because it cannot be.
-- =========================================================================
CREATE TABLE IF NOT EXISTS analytics.maintenance_log (
    run_ts       TIMESTAMP DEFAULT SYSDATE,
    table_name   VARCHAR(128),
    metric       VARCHAR(40),
    value        DECIMAL(18,2),
    action_taken VARCHAR(200)
) DISTSTYLE EVEN SORTKEY (run_ts);

CREATE OR REPLACE PROCEDURE analytics.sp_health_check(p_stats_threshold INT)
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
DECLARE
    v_tbl        VARCHAR(128);
    v_stats_off  DECIMAL(18,2);
    v_unsorted   DECIMAL(18,2);
    v_skew       DECIMAL(18,2);
    v_analyzed   INT := 0;
    -- ONE cursor. Opening a second anywhere in this call stack fails at
    -- runtime — Redshift allows exactly one concurrent cursor.
    c_tables CURSOR FOR
        SELECT "table", NVL(stats_off,0), NVL(unsorted,0), NVL(skew_rows,0)
        FROM   svv_table_info
        WHERE  "schema" = 'analytics'
          AND  NVL(stats_off,0) > p_stats_threshold;
BEGIN
    OPEN c_tables;
    LOOP
        FETCH c_tables INTO v_tbl, v_stats_off, v_unsorted, v_skew;
        EXIT WHEN NOT FOUND;

        -- MECHANISM 4: refresh the statistics.
        -- EXECUTE is required — ANALYZE takes an identifier, not a variable.
        EXECUTE 'ANALYZE analytics.' || quote_ident(v_tbl);
        v_analyzed := v_analyzed + 1;

        INSERT INTO analytics.maintenance_log (table_name, metric, value, action_taken)
        VALUES (v_tbl, 'stats_off', v_stats_off, 'ANALYZE executed');

        -- MECHANISM 1: report sort decay. VACUUM cannot run in a procedure,
        -- so this records the need and an external scheduler acts on it.
        IF v_unsorted > 10 THEN
            INSERT INTO analytics.maintenance_log (table_name, metric, value, action_taken)
            VALUES (v_tbl, 'unsorted', v_unsorted,
                    'NEEDS: VACUUM SORT ONLY analytics.' || v_tbl);
        END IF;

        -- MECHANISM 2: report distribution skew.
        IF v_skew > 4 THEN
            INSERT INTO analytics.maintenance_log (table_name, metric, value, action_taken)
            VALUES (v_tbl, 'skew_rows', v_skew,
                    'NEEDS: review DISTKEY — one slice holds most rows');
        END IF;
    END LOOP;
    CLOSE c_tables;

    RAISE INFO 'sp_health_check: analyzed % table(s) above stats_off %',
        v_analyzed, p_stats_threshold;
END;
$$;

CALL analytics.sp_health_check(5);

SELECT * FROM analytics.maintenance_log ORDER BY run_ts DESC, table_name;

-- MECHANISM 3 as a procedure: report the encoding cost of every table, so
-- "we should compress that" becomes a number instead of an opinion.
CREATE OR REPLACE PROCEDURE analytics.sp_report_encoding()
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
DECLARE
    v_unencoded INT;
BEGIN
    SELECT COUNT(*) INTO v_unencoded
      FROM svv_table_info
     WHERE "schema" = 'analytics' AND encoded = 'N';

    INSERT INTO analytics.maintenance_log (table_name, metric, value, action_taken)
    SELECT "table", 'size_mb', size,
           CASE WHEN encoded = 'N'
                THEN 'NEEDS: column encoding — run ANALYZE COMPRESSION'
                ELSE 'encoded' END
      FROM svv_table_info
     WHERE "schema" = 'analytics';

    RAISE INFO 'sp_report_encoding: % unencoded table(s) in analytics', v_unencoded;
END;
$$;

CALL analytics.sp_report_encoding();

SELECT metric, COUNT(*), ROUND(SUM(value),2) AS total
FROM   analytics.maintenance_log
GROUP  BY metric ORDER BY metric;


-- -------------------------------------------------------------------------
-- 10.6  Cleanup — these demo tables are large
-- -------------------------------------------------------------------------
-- DROP TABLE IF EXISTS analytics.big_orders_source, analytics.t_sort_none,
--   analytics.t_sort_date, analytics.t_dist_even, analytics.t_dist_key,
--   analytics.t_dim_even, analytics.t_dim_key, analytics.t_dist_skewed,
--   analytics.t_encode_raw, analytics.t_encode_good, analytics.t_stats_stale;
