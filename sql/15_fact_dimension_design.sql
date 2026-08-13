-- =========================================================================
-- 15 — Designing a fact and its dimensions
--
-- DO THEM IN THIS ORDER OR YOU WILL REDO THEM
--
--   1. GRAIN        One row equals one WHAT? Answer in a sentence, out loud,
--                   before writing any DDL.
--   2. COLUMNS      The measures you sum, and the surrogate keys pointing at
--                   the dimensions you slice by.
--   3. DISTKEY      The BUSIEST JOIN — not the primary key by reflex. The
--                   column this table is most often joined on, with enough
--                   distinct values to spread evenly.
--   4. SORTKEY      The ALWAYS-FILTER — the date, first. Sorting on an
--                   ever-increasing date also means new rows land where they
--                   belong, so `unsorted` grows slowly.
--   5. DIMENSIONS   Small ones get DISTSTYLE ALL so every join is local.
--   6. TESTS        A uniqueness test, because nothing else will check it.
--
-- Steps 3 and 4 are the ones people swap. DISTKEY answers "where does the
-- row live"; SORTKEY answers "what order is it in". Choosing the same
-- column for both is usually a sign one of them was not thought about.
-- =========================================================================


-- =========================================================================
-- 15.1  Step 1 — GRAIN
--
--   "One row is one LINE on one sales receipt."
--
-- Not one receipt. Not one order. One line. Every column below must be true
-- at that grain, and any measure that is not (a receipt-level delivery fee)
-- either gets allocated down to the line or belongs in a different fact.
-- =========================================================================


-- =========================================================================
-- 15.2  Steps 2 + 5 — the dimensions
-- =========================================================================
DROP TABLE IF EXISTS analytics.fct_sales_line CASCADE;
DROP TABLE IF EXISTS analytics.dim_store CASCADE;
DROP TABLE IF EXISTS analytics.dim_date_sk CASCADE;

CREATE TABLE analytics.dim_date_sk (
    date_sk      INTEGER     NOT NULL,
    full_date    DATE        NOT NULL,
    fiscal_year  SMALLINT    NOT NULL,
    fiscal_week  SMALLINT    NOT NULL,
    day_name     VARCHAR(9)  NOT NULL,
    is_weekend   BOOLEAN     NOT NULL,
    PRIMARY KEY (date_sk)              -- declared: genuinely true, and tested
)
DISTSTYLE ALL                          -- tiny, joined by everything
SORTKEY (date_sk);

INSERT INTO analytics.dim_date_sk
SELECT (EXTRACT(year FROM date_key) * 10000
        + EXTRACT(month FROM date_key) * 100
        + EXTRACT(day FROM date_key))::INTEGER,
       date_key, fiscal_year,
       EXTRACT(week FROM date_key)::SMALLINT,
       TRIM(day_name), is_weekend
FROM   analytics.dim_date;

-- A Type 2 slowly-changing dimension. valid_from/valid_to/is_current are
-- the three columns that make history queryable: the fact joins on the
-- surrogate key, so it keeps pointing at the store AS IT WAS.
CREATE TABLE analytics.dim_store (
    store_sk    BIGINT       NOT NULL,
    store_id    VARCHAR(20)  NOT NULL,       -- business key
    store_name  VARCHAR(120),
    region      VARCHAR(32),
    valid_from  TIMESTAMP    NOT NULL,       -- Type 2
    valid_to    TIMESTAMP,
    is_current  BOOLEAN      NOT NULL,
    PRIMARY KEY (store_sk)
)
DISTSTYLE ALL
SORTKEY (store_sk);

INSERT INTO analytics.dim_store
SELECT DISTINCT
       store_id,
       'S' || LPAD(store_id::VARCHAR, 4, '0'),
       'Store ' || store_id,
       CASE WHEN store_id % 3 = 0 THEN 'WEST'
            WHEN store_id % 3 = 1 THEN 'EMEA' ELSE 'APAC' END,
       '2023-01-01'::TIMESTAMP, NULL, TRUE
FROM   analytics.fct_retail_sales;


-- =========================================================================
-- 15.3  Steps 3 + 4 — the fact
-- =========================================================================
CREATE TABLE analytics.fct_sales_line (
    sale_date    DATE          NOT NULL ENCODE raw,    -- sort key: leave raw
    date_sk      INTEGER       NOT NULL ENCODE az64,
    store_sk     BIGINT        NOT NULL ENCODE az64,   -- dist key
    product_sk   BIGINT        NOT NULL ENCODE az64,
    receipt_no   VARCHAR(32)            ENCODE zstd,   -- degenerate dimension
    line_no      SMALLINT               ENCODE az64,
    quantity     DECIMAL(12,3)          ENCODE az64,
    net_amount   DECIMAL(14,2)          ENCODE az64,
    vat_amount   DECIMAL(14,2)          ENCODE az64,
    merge_key    VARCHAR(64)   NOT NULL ENCODE zstd,   -- idempotency key
    loaded_at    TIMESTAMP DEFAULT SYSDATE
)
DISTSTYLE KEY
DISTKEY (store_sk)                        -- the busiest join
COMPOUND SORTKEY (sale_date, store_sk);   -- the always-filter, date first

-- Why store_sk and not the receipt or the product:
--   * every report slices by store or region, so store is the busiest join
--   * store_sk has enough distinct values to spread across slices
--   * receipt_no is unique per row -> perfect spread but joins to nothing
--   * a low-cardinality column (region) would pile rows onto few slices
--
-- merge_key is the idempotency key: a deterministic hash of the natural
-- key, so a re-run can DELETE its own rows and reinsert without duplicating.

INSERT INTO analytics.fct_sales_line
    (sale_date, date_sk, store_sk, product_sk, receipt_no, line_no,
     quantity, net_amount, vat_amount, merge_key)
SELECT f.sale_date,
       (EXTRACT(year FROM f.sale_date) * 10000
        + EXTRACT(month FROM f.sale_date) * 100
        + EXTRACT(day FROM f.sale_date))::INTEGER,
       f.store_id, f.product_id,
       'R' || LPAD((f.sale_id % 1000000)::VARCHAR, 8, '0'),
       (f.sale_id % 20)::SMALLINT,
       f.quantity, f.revenue,
       ROUND(f.revenue * 0.20, 2),
       MD5(f.sale_id::VARCHAR || '|' || f.sale_date::VARCHAR || '|' || f.store_id::VARCHAR)
FROM   analytics.fct_retail_sales f;

ANALYZE analytics.fct_sales_line;
ANALYZE analytics.dim_store;
ANALYZE analytics.dim_date_sk;


-- =========================================================================
-- 15.4  Step 6 — VERIFY AFTER THE FIRST REAL LOAD
--
-- These four checks, in this order, after the first load of ANY new fact
-- table. Not sometimes. Every time.
-- =========================================================================

-- 1. Did the distribution work out?
SELECT "table", diststyle, sortkey1, skew_rows, unsorted, stats_off,
       size AS mb, tbl_rows
FROM   svv_table_info
WHERE  "schema" = 'analytics'
  AND  "table" IN ('fct_sales_line','dim_store','dim_date_sk')
ORDER  BY tbl_rows DESC;
-- want: skew_rows below ~4, stats_off near 0, unsorted near 0

-- 2. Is the join co-located?
EXPLAIN
SELECT s.region, SUM(f.net_amount)
FROM   analytics.fct_sales_line f
JOIN   analytics.dim_store s USING (store_sk)
GROUP  BY 1;
-- want: DS_DIST_ALL_NONE or DS_DIST_NONE.  not: DS_BCAST_INNER
--
-- DS_DIST_ALL_NONE appears because dim_store is DISTSTYLE ALL — a copy is
-- already on every node, so nothing moves. That is the dimension pattern
-- working exactly as designed.

-- 3. Are zone maps skipping?
SELECT SUM(f.net_amount)
FROM   analytics.fct_sales_line f
WHERE  f.sale_date >= '2024-03-01' AND f.sale_date < '2024-04-01';

SELECT SUM(rows_pre_filter) AS rows_scanned,
       SUM(rows)            AS rows_returned,
       MAX(CASE WHEN is_rrscan = 't' THEN 1 ELSE 0 END) AS used_zone_map
FROM   stl_scan WHERE query = pg_last_query_id() AND tbl > 0;
-- used_zone_map must be 1, and rows_scanned must be far below the table's
-- total row count. If used_zone_map is 0, re-read file 11 §11.6 — the most
-- likely cause is a function wrapped around sale_date.
--
-- (STL_SCAN has no blocks_read/blocks_skipped columns. rows_pre_filter is
--  the rows the scan emitted before your WHERE was applied, which is the
--  number that shows whether blocks were skipped.)

-- 4. Is the key actually unique?
SELECT COUNT(*) AS rows, COUNT(DISTINCT merge_key) AS keys,
       COUNT(*) - COUNT(DISTINCT merge_key) AS duplicates
FROM   analytics.fct_sales_line;
-- Nothing else will check this. See file 13.

CALL analytics.sp_assert_unique('analytics','dim_store','store_sk');


-- =========================================================================
-- 15.5  The whole design, as a procedure that reloads one day idempotently
-- =========================================================================
CREATE OR REPLACE PROCEDURE analytics.sp_load_sales_line(p_sale_date DATE)
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
DECLARE
    v_deleted BIGINT := 0;
    v_loaded  BIGINT := 0;
    v_dupes   BIGINT := 0;
BEGIN
    -- Idempotency: this day's rows go, then come back. Re-runnable from the
    -- top, which is the only safe design without subtransactions.
    DELETE FROM analytics.fct_sales_line WHERE sale_date = p_sale_date;
    GET DIAGNOSTICS v_deleted := ROW_COUNT;

    INSERT INTO analytics.fct_sales_line
        (sale_date, date_sk, store_sk, product_sk, receipt_no, line_no,
         quantity, net_amount, vat_amount, merge_key)
    SELECT f.sale_date,
           (EXTRACT(year FROM f.sale_date) * 10000
            + EXTRACT(month FROM f.sale_date) * 100
            + EXTRACT(day FROM f.sale_date))::INTEGER,
           f.store_id, f.product_id,
           'R' || LPAD((f.sale_id % 1000000)::VARCHAR, 8, '0'),
           (f.sale_id % 20)::SMALLINT,
           f.quantity, f.revenue, ROUND(f.revenue * 0.20, 2),
           MD5(f.sale_id::VARCHAR || '|' || f.sale_date::VARCHAR || '|' || f.store_id::VARCHAR)
      FROM analytics.fct_retail_sales f
     WHERE f.sale_date = p_sale_date;
    GET DIAGNOSTICS v_loaded := ROW_COUNT;

    -- Step 6, enforced in the pipeline rather than hoped for.
    SELECT COUNT(*) - COUNT(DISTINCT merge_key) INTO v_dupes
      FROM analytics.fct_sales_line WHERE sale_date = p_sale_date;

    IF v_dupes > 0 THEN
        RAISE EXCEPTION 'sp_load_sales_line: % duplicate merge_key on %',
            v_dupes, p_sale_date;
    END IF;

    INSERT INTO analytics.audit_log (event_type, detail)
    VALUES ('LOAD_SALES_LINE',
            p_sale_date || ' deleted=' || v_deleted || ' loaded=' || v_loaded);

    RAISE INFO 'sp_load_sales_line %: % deleted, % loaded, 0 duplicates',
        p_sale_date, v_deleted, v_loaded;
END;
$$;

CALL analytics.sp_load_sales_line('2024-03-15');
CALL analytics.sp_load_sales_line('2024-03-15');   -- again: counts must match

SELECT * FROM analytics.audit_log
WHERE  event_type = 'LOAD_SALES_LINE' ORDER BY event_ts DESC LIMIT 5;


-- =========================================================================
-- 15.6  Checklist
--
--   [ ] I can state the grain in one sentence
--   [ ] Every measure is true at that grain
--   [ ] DISTKEY is the busiest join column, with high cardinality
--   [ ] SORTKEY starts with the column in every WHERE clause
--   [ ] The first sort-key column is ENCODE raw
--   [ ] Small dimensions are DISTSTYLE ALL
--   [ ] There is a merge key, and a test that proves it is unique
--   [ ] I ran the four verification checks after the first load
--
-- YOU HAVE GOT IT WHEN you can design a fact table from a business question
-- in ten minutes, and the four checks pass on the first load.
-- =========================================================================
