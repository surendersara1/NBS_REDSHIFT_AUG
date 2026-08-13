-- =========================================================================
-- 11 — Sort keys: the four things that decide whether it works
--
--   SORT ON WHAT YOU FILTER    usually the date
--   COMPOUND                   the default, and usually right
--   INTERLEAVED                rarely worth it
--   UNSORTED ROWS UNDO IT      svv_table_info.unsorted
--
-- Every table below is built and loaded with real Redshift commands —
-- COPY, INSERT INTO ... SELECT, CREATE TABLE AS — so the effects are
-- measured on data that arrived the way project data arrives.
-- =========================================================================


-- =========================================================================
-- 11.1  A retail-shaped fact table, loaded three ways
--
-- Three load mechanisms, because each has different consequences for sort
-- order — and that difference is the whole lesson:
--
--   COPY from S3            sorts within the load if the table is empty
--   INSERT INTO ... SELECT  appends; new rows land in the unsorted region
--   CREATE TABLE AS         builds sorted from scratch
-- =========================================================================
DROP TABLE IF EXISTS analytics.fct_retail_sales CASCADE;

CREATE TABLE analytics.fct_retail_sales (
    sale_id      BIGINT        NOT NULL ENCODE az64,
    sale_date    DATE          NOT NULL ENCODE az64,   -- what everyone filters
    store_id     INTEGER       NOT NULL ENCODE az64,
    customer_id  BIGINT                 ENCODE az64,
    product_id   INTEGER                ENCODE az64,
    channel      VARCHAR(20)            ENCODE bytedict,
    region       VARCHAR(20)            ENCODE bytedict,
    quantity     INTEGER                ENCODE az64,
    unit_price   DECIMAL(18,2)          ENCODE az64,
    revenue      DECIMAL(18,2)          ENCODE az64,
    loaded_at    TIMESTAMP DEFAULT SYSDATE ENCODE az64
)
DISTKEY (customer_id)
COMPOUND SORTKEY (sale_date, store_id);
--                ^^^^^^^^^ first column is what the WHERE clause starts with

-- LOAD 1 — COPY from the raw bucket. On an EMPTY table COPY sorts as it
-- loads, so the table starts fully sorted. Loading into a NON-empty table
-- does not, which is why truncate-and-load exists.
--
-- COPY analytics.fct_retail_sales
--   (sale_id, sale_date, store_id, customer_id, product_id,
--    channel, region, quantity, unit_price, revenue)
-- FROM 's3://<RAW_BUCKET>/retail/'
-- IAM_ROLE '<SPECTRUM_ROLE_ARN>'
-- FORMAT AS CSV IGNOREHEADER 1
-- DATEFORMAT 'YYYY-MM-DD'
-- COMPUPDATE OFF        -- encodings already declared above; do not override
-- STATUPDATE ON;

-- LOAD 2 — INSERT INTO ... SELECT, synthesising a retail shape from the
-- data we already have. This is the realistic in-warehouse load.
INSERT INTO analytics.fct_retail_sales
    (sale_id, sale_date, store_id, customer_id, product_id,
     channel, region, quantity, unit_price, revenue)
SELECT
    ROW_NUMBER() OVER (ORDER BY o.order_id, d.date_key)      AS sale_id,
    d.date_key                                               AS sale_date,
    (o.customer_id % 50) + 1                                 AS store_id,
    o.customer_id,
    (o.order_id % 500) + 1                                   AS product_id,
    CASE WHEN o.order_id % 3 = 0 THEN 'ONLINE'
         WHEN o.order_id % 3 = 1 THEN 'STORE'
         ELSE 'PARTNER' END                                  AS channel,
    CASE WHEN o.country IN ('US','CA','BR') THEN 'WEST'
         WHEN o.country IN ('GB','DE','FR','AE') THEN 'EMEA'
         ELSE 'APAC' END                                     AS region,
    o.quantity,
    o.unit_price,
    (o.quantity * o.unit_price)::DECIMAL(18,2)               AS revenue
FROM   analytics.fct_customer_orders o
JOIN   analytics.dim_date d
       ON d.date_key BETWEEN o.order_date AND DATEADD(day, 60, o.order_date)
WHERE  o.status = 'COMPLETED';

ANALYZE analytics.fct_retail_sales;

SELECT COUNT(*) AS rows_loaded,
       MIN(sale_date) AS from_date, MAX(sale_date) AS to_date
FROM   analytics.fct_retail_sales;


-- =========================================================================
-- 11.2  SORT ON WHAT YOU FILTER — usually the date
--
-- For almost every retail fact this is sale_date. A sort key on a column
-- nobody filters costs you on every load and buys nothing: you pay the
-- sort cost at write time and the zone maps never help at read time.
--
-- Build the wrong choice deliberately and measure the difference.
-- =========================================================================
DROP TABLE IF EXISTS analytics.fct_retail_wrongsort;

CREATE TABLE analytics.fct_retail_wrongsort
DISTKEY (customer_id)
COMPOUND SORTKEY (product_id)     -- nobody filters on product_id alone
AS SELECT * FROM analytics.fct_retail_sales;

ANALYZE analytics.fct_retail_wrongsort;

-- The query the business actually runs, every morning:
SELECT region, SUM(revenue) FROM analytics.fct_retail_sales
WHERE  sale_date BETWEEN '2024-03-01' AND '2024-03-31' GROUP BY region;

SELECT region, SUM(revenue) FROM analytics.fct_retail_wrongsort
WHERE  sale_date BETWEEN '2024-03-01' AND '2024-03-31' GROUP BY region;

-- is_rrscan tells you whether the zone map was used at all.
SELECT query_id, table_name, step_name, is_rrscan,
       input_rows, output_rows, duration/1000.0 AS ms
FROM   sys_query_detail
WHERE  query_id > pg_last_query_id() - 3
  AND  step_name ILIKE '%scan%'
ORDER  BY query_id;
-- Correct sort key: is_rrscan = true, input_rows ~ the month.
-- Wrong sort key:   is_rrscan = false, input_rows = the whole table.


-- =========================================================================
-- 11.3  COMPOUND — the default, and usually right
--
-- Sorted by the columns in order. Only helps when your filter STARTS with
-- the first column — exactly like a composite index in an OLTP database.
-- SORTKEY (sale_date, store_id) helps:
--
--     WHERE sale_date = X                    yes
--     WHERE sale_date = X AND store_id = Y    yes, best case
--     WHERE store_id = Y                      NO — skips the leading column
-- =========================================================================

-- Leading column present — fast.
SELECT COUNT(*), SUM(revenue) FROM analytics.fct_retail_sales
WHERE  sale_date BETWEEN '2024-03-01' AND '2024-03-07' AND store_id = 7;

-- Leading column absent — the zone maps cannot help.
SELECT COUNT(*), SUM(revenue) FROM analytics.fct_retail_sales
WHERE  store_id = 7;

SELECT query_id, LEFT(query_text,55) AS sql_preview, table_name,
       is_rrscan, input_rows, duration/1000.0 AS ms
FROM   sys_query_detail
WHERE  query_id > pg_last_query_id() - 3 AND step_name ILIKE '%scan%'
ORDER  BY query_id;

-- Column order within a COMPOUND key: most-filtered FIRST, and among
-- equally-filtered columns, LOWEST cardinality first.
SELECT 'sale_date' AS col, COUNT(DISTINCT sale_date) AS distinct_values
FROM analytics.fct_retail_sales
UNION ALL SELECT 'store_id', COUNT(DISTINCT store_id) FROM analytics.fct_retail_sales
UNION ALL SELECT 'region',   COUNT(DISTINCT region)   FROM analytics.fct_retail_sales
UNION ALL SELECT 'product_id', COUNT(DISTINCT product_id) FROM analytics.fct_retail_sales
ORDER BY distinct_values;


-- =========================================================================
-- 11.4  INTERLEAVED — rarely worth it
--
-- Equal weight to every column, so ANY one of them filters well rather
-- than only the leading one. The cost: maintenance is expensive, loads are
-- slower, and it needs VACUUM REINDEX (not plain VACUUM) as it degrades.
--
-- Use only when filters genuinely vary — an ad-hoc exploration table where
-- analysts filter by store one day and product the next. For a scheduled
-- report that always filters by date, COMPOUND wins every time.
-- =========================================================================
DROP TABLE IF EXISTS analytics.fct_retail_interleaved;

CREATE TABLE analytics.fct_retail_interleaved
DISTKEY (customer_id)
INTERLEAVED SORTKEY (sale_date, store_id, product_id, region)
AS SELECT * FROM analytics.fct_retail_sales;

ANALYZE analytics.fct_retail_interleaved;

-- Filter on a NON-leading column — where interleaved earns its keep.
SELECT COUNT(*) FROM analytics.fct_retail_sales       WHERE product_id = 42;
SELECT COUNT(*) FROM analytics.fct_retail_interleaved WHERE product_id = 42;

-- Filter on the leading column — where COMPOUND usually still wins.
SELECT COUNT(*) FROM analytics.fct_retail_sales
WHERE sale_date BETWEEN '2024-03-01' AND '2024-03-07';
SELECT COUNT(*) FROM analytics.fct_retail_interleaved
WHERE sale_date BETWEEN '2024-03-01' AND '2024-03-07';

SELECT query_id, table_name, is_rrscan, input_rows, duration/1000.0 AS ms
FROM   sys_query_detail
WHERE  query_id > pg_last_query_id() - 5 AND step_name ILIKE '%scan%'
ORDER  BY query_id;

-- Interleaved skew — how unbalanced the interleaved key has become.
-- Above ~1.4, it needs VACUUM REINDEX.
SELECT tbl, col, interleaved_skew, last_reindex
FROM   svv_interleaved_columns
WHERE  tbl = (SELECT table_id FROM svv_table_info
              WHERE "table" = 'fct_retail_interleaved');

-- VACUUM REINDEX analytics.fct_retail_interleaved;   -- expensive; schedule it


-- =========================================================================
-- 11.5  UNSORTED ROWS UNDO IT
--
-- New rows append to an unsorted region at the end of the table. Once a
-- table drifts, block min/max ranges widen, blocks start overlapping, and
-- skipping quietly stops working. Query times climb with no change to the
-- query and no change to the schema. That is what VACUUM is for.
-- =========================================================================

-- Baseline.
SELECT "table", tbl_rows, unsorted, vacuum_sort_benefit, stats_off
FROM   svv_table_info WHERE "table" = 'fct_retail_sales';

SELECT COUNT(*), SUM(revenue) FROM analytics.fct_retail_sales
WHERE  sale_date BETWEEN '2024-03-01' AND '2024-03-07';

-- Simulate a month of daily loads landing out of order — old dates arriving
-- after new ones, which is exactly what a late-arriving feed does.
INSERT INTO analytics.fct_retail_sales
    (sale_id, sale_date, store_id, customer_id, product_id,
     channel, region, quantity, unit_price, revenue)
SELECT sale_id + 90000000, sale_date - 400, store_id, customer_id, product_id,
       channel, region, quantity, unit_price, revenue
FROM   analytics.fct_retail_sales
WHERE  sale_date BETWEEN '2024-03-01' AND '2024-03-31';

-- The damage, in one column:
SELECT "table", tbl_rows, unsorted, vacuum_sort_benefit
FROM   svv_table_info WHERE "table" = 'fct_retail_sales';
-- unsorted is the % of rows outside sort order. Above 10, act.

-- Same query, now slower — nothing else changed.
SELECT COUNT(*), SUM(revenue) FROM analytics.fct_retail_sales
WHERE  sale_date BETWEEN '2024-03-01' AND '2024-03-07';

-- Blocks now overlap: many blocks span the target range, so few can be
-- skipped. Compare minvalue/maxvalue spread against 10.x before the load.
SELECT slice, blocknum, minvalue, maxvalue, num_values
FROM   stv_blocklist
WHERE  tbl = (SELECT table_id FROM svv_table_info WHERE "table"='fct_retail_sales')
  AND  col = 1
ORDER  BY slice, blocknum LIMIT 20;

-- The fix.
VACUUM SORT ONLY analytics.fct_retail_sales;
ANALYZE analytics.fct_retail_sales;

SELECT "table", tbl_rows, unsorted, vacuum_sort_benefit, stats_off
FROM   svv_table_info WHERE "table" = 'fct_retail_sales';

-- And the query is fast again.
SELECT COUNT(*), SUM(revenue) FROM analytics.fct_retail_sales
WHERE  sale_date BETWEEN '2024-03-01' AND '2024-03-07';

-- VACUUM variants:
--   VACUUM DELETE ONLY   reclaims space from deletes; does not re-sort
--   VACUUM SORT ONLY     re-sorts; does not reclaim
--   VACUUM FULL          both (the default when you write plain VACUUM)
--   VACUUM REINDEX       interleaved sort keys only; rebuilds the zone maps
--
-- VACUUM cannot run inside a stored procedure. Drive it from EventBridge
-- Scheduler -> Lambda -> Redshift Data API. sp_health_check in file 10
-- detects the need and records it; the scheduler acts on it.

-- Everything currently drifting:
SELECT "table", tbl_rows, unsorted, vacuum_sort_benefit, stats_off, skew_rows
FROM   svv_table_info
WHERE  "schema" = 'analytics' AND unsorted > 5
ORDER  BY unsorted DESC;

-- Was VACUUM effective? Check what it actually did:
SELECT * FROM svv_vacuum_summary ORDER BY 1 DESC LIMIT 10;
SELECT * FROM svl_auto_worker_action ORDER BY eventtime DESC LIMIT 20;
-- Redshift also runs automatic table optimization in the background —
-- auto-vacuum, auto-analyze, and auto sort/dist key changes. Check what it
-- has been doing before concluding a table is neglected.


-- =========================================================================
-- 11.6  THE MISTAKE THAT SILENTLY DEFEATS ALL OF IT
--
-- Wrapping the sort key in a function inside WHERE. The zone map holds the
-- min and max of the RAW column. The moment you apply a function to it,
-- Redshift can no longer compare your predicate against those stored
-- min/max pairs, so it must read every block and evaluate the function on
-- every row.
--
-- This is the single most common way people accidentally turn a fast query
-- into a full scan, and it looks completely innocent in review.
-- =========================================================================

--  BAD — the function hides the column from the zone map:
--     WHERE DATE_TRUNC('month', sale_date) = '2026-01-01'
--     WHERE EXTRACT(year FROM sale_date) = 2026
--     WHERE sale_date::VARCHAR LIKE '2026-01%'
--
--  GOOD — a plain range on the raw column:
--     WHERE sale_date >= '2026-01-01' AND sale_date < '2026-02-01'
--
-- The two forms return identical results. Only one of them can skip blocks.

-- 1. What is each table sorted on?
SELECT "table", sortkey1, sortkey_num, unsorted
FROM   svv_table_info
WHERE  "schema" = 'analytics'
ORDER  BY unsorted DESC;

-- 2. Compare a good filter with a bad one, checking stl_scan after each.
--    Do this by hand, once. The contrast is what makes the lesson stick.

-- NOTE ON COLUMNS: STL_SCAN has no blocks_read / blocks_skipped columns —
-- verified against the STL_SCAN reference. The zone-map evidence is
-- `is_rrscan` (was a range-restricted scan used?) together with
-- `rows_pre_filter` (how many rows the scan actually emitted before your
-- WHERE clause was applied). rows_pre_filter IS the "did it skip?" number:
-- when zone maps work it is a fraction of the table; when they do not it
-- equals the whole table.

--  GOOD: plain range on the raw column
SELECT COUNT(*) FROM analytics.fct_retail_sales
WHERE  sale_date >= '2024-03-01' AND sale_date < '2024-04-01';

SELECT slice, type, rows, rows_pre_filter, bytes, is_rrscan
FROM   stl_scan
WHERE  query = pg_last_query_id() AND tbl > 0
ORDER  BY slice LIMIT 10;

--  BAD: same answer, function applied to the sort key
SELECT COUNT(*) FROM analytics.fct_retail_sales
WHERE  DATE_TRUNC('month', sale_date) = '2024-03-01';

SELECT slice, type, rows, rows_pre_filter, bytes, is_rrscan
FROM   stl_scan
WHERE  query = pg_last_query_id() AND tbl > 0
ORDER  BY slice LIMIT 10;

-- The good form: is_rrscan = 't', rows_pre_filter is a fraction of the
-- table. The bad form: is_rrscan = 'f', rows_pre_filter equals the FULL
-- row count — every block was read and the function evaluated per row.

-- Side by side, for the readout:
SELECT s.query,
       LEFT(q.querytxt, 70)                     AS sql_preview,
       SUM(s.rows_pre_filter)                   AS rows_scanned,
       SUM(s.rows)                              AS rows_returned,
       MAX(CASE WHEN s.is_rrscan = 't' THEN 1 ELSE 0 END) AS used_zone_map
FROM   stl_scan s
JOIN   stl_query q ON q.query = s.query
WHERE  s.query > pg_last_query_id() - 6 AND s.tbl > 0
GROUP  BY 1, 2
ORDER  BY 1;

-- Block-level truth, if you want to see the skipping physically. Zone maps
-- live in STV_BLOCKLIST as per-block minvalue/maxvalue: on a sorted table
-- the ranges are tight and non-overlapping, so most blocks can be excluded
-- by inspection alone.
SELECT COUNT(*) AS total_blocks
FROM   stv_blocklist
WHERE  tbl = (SELECT table_id FROM svv_table_info
              WHERE "table" = 'fct_retail_sales')
  AND  col = 1;

-- The same trap in other disguises — all of these defeat the zone map:
--   WHERE YEAR(sale_date) = 2024
--   WHERE TO_CHAR(sale_date, 'YYYY-MM') = '2024-03'
--   WHERE sale_date + 0 = '2024-03-01'
--   WHERE COALESCE(sale_date, '1900-01-01') >= '2024-03-01'
--   WHERE CAST(sale_date AS TIMESTAMP) >= '2024-03-01'
-- Rewrite every one as a half-open range on the raw column:
--   WHERE sale_date >= <start> AND sale_date < <end_exclusive>
-- Half-open (>= / <) also avoids the timestamp boundary bug that BETWEEN
-- introduces when the column is a TIMESTAMP rather than a DATE.


-- =========================================================================
-- 11.7  Gotchas
--
--   * A sort key you never filter on costs you on every load and buys
--     nothing.
--   * Interleaved needs VACUUM REINDEX, which is expensive.
--   * Only the FIRST sort-key column gives good skipping in a compound key.
--   * `unsorted` climbing after every load means either the wrong sort
--     column or missing maintenance.
--   * A function around the sort key in WHERE silently disables skipping.
--
-- Checklist
--   [ ] Every fact is sorted on the column it is filtered by, usually date
--   [ ] The most-filtered column is FIRST in a compound key
--   [ ] I default to compound and only consider interleaved after measuring
--   [ ] I never wrap the sort key in a function in WHERE
--   [ ] I check `unsorted` regularly
--   [ ] I have proved skipping with stl_scan at least once myself
--
-- You have got it when you can take a slow query with DATE_TRUNC in the
-- WHERE clause, rewrite it as a half-open range, and show the drop in
-- rows_pre_filter — with is_rrscan flipping to 't' — without being told to.
-- =========================================================================
