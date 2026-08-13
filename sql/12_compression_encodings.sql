-- =========================================================================
-- 12 — Compression and encodings
--
-- THE ENCODINGS YOU WILL ACTUALLY USE
--
--   az64       numbers, dates, timestamps
--              AWS's own scheme for numeric and temporal types. Usually the
--              best choice, and usually what AUTO picks for them.
--
--   zstd       text, wide VARCHARs
--              Strong general-purpose compression that works well on almost
--              anything, and especially on text with repetition.
--
--   bytedict   few distinct values — status flags, country codes
--   runlength  excellent when EQUAL VALUES SIT NEXT TO EACH OTHER after
--              sorting. That "after sorting" clause is the whole trick:
--              runlength on an unsorted column is close to useless.
--
--   raw        ON THE SORT KEY — a deliberate exception.
--              The first sort-key column is often left uncompressed so that
--              range checks against zone maps stay as cheap as possible.
--              Decompressing a block just to test its min/max defeats the
--              purpose of storing min/max in the first place.
-- =========================================================================


-- =========================================================================
-- 12.1  What is in effect right now?
-- =========================================================================
SELECT "column", type, encoding, distkey, sortkey
FROM   pg_table_def
WHERE  schemaname = 'analytics'
  AND  tablename  = 'fct_retail_sales'
ORDER  BY "column";

-- GOTCHA, and it wastes an afternoon the first time: pg_table_def returns
-- rows ONLY for schemas on your search_path. An empty result usually means
-- the schema is not on the path, not that the table is missing.
SHOW search_path;
SET search_path TO '$user', public, analytics, staging, rpt;

-- Which tables have any encoding at all? This is the audit query — large
-- and unencoded is where the money is.
SELECT "table", encoded, size AS mb, tbl_rows, diststyle, sortkey1
FROM   svv_table_info
WHERE  encoded = 'N'
  AND  size > 500                    -- lower to 5 on the teaching cluster
ORDER  BY size DESC;

-- Teaching-cluster version, since our tables are small:
SELECT "table", encoded, size AS mb, tbl_rows
FROM   svv_table_info
WHERE  "schema" = 'analytics' AND encoded = 'N'
ORDER  BY size DESC;


-- =========================================================================
-- 12.2  Applying it
-- =========================================================================

-- On an existing column, for supported transitions:
ALTER TABLE analytics.fct_retail_sales
  ALTER COLUMN revenue ENCODE az64;

-- Or at create time, which is cleaner — the encoding is then part of the
-- table's definition rather than a migration nobody remembers running.
DROP TABLE IF EXISTS analytics.fct_sales_line;

CREATE TABLE analytics.fct_sales_line (
    sale_date    DATE          NOT NULL ENCODE raw,      -- sort key: raw
    store_sk     BIGINT        NOT NULL ENCODE az64,
    product_sk   BIGINT        NOT NULL ENCODE az64,
    country      VARCHAR(2)             ENCODE bytedict,
    channel      VARCHAR(20)            ENCODE runlength, -- sorted-adjacent
    net_amount   DECIMAL(14,2)          ENCODE az64,
    notes        VARCHAR(500)           ENCODE zstd
)
DISTKEY (store_sk)
COMPOUND SORTKEY (sale_date);


-- =========================================================================
-- 12.3  COPY and automatic compression — and exactly when it does NOT happen
--
-- When you COPY into an EMPTY table with NO encodings declared, Redshift
-- samples the incoming data and applies compression automatically. That is
-- usually good, and it is why COPY-first pipelines tend to be fine.
--
-- It does NOT happen when:
--   * the table already has rows, or
--   * you have declared encodings yourself, or
--   * the table was built by CTAS and grown by appends.
--
-- So a table built by an early CTAS and grown by INSERT can end up entirely
-- uncompressed without anyone noticing — for months. This is the single
-- most common source of a silently oversized warehouse.
-- =========================================================================

-- Demonstrate it. CTAS inherits NOTHING unless you say so.
DROP TABLE IF EXISTS analytics.t_ctas_naive;
CREATE TABLE analytics.t_ctas_naive AS
SELECT * FROM analytics.fct_retail_sales;

SELECT "table", encoded, size AS mb, tbl_rows
FROM   svv_table_info
WHERE  "table" IN ('fct_retail_sales','t_ctas_naive');
-- The CTAS copy is larger. Same rows, same columns, no encodings.

-- The fix: state them on the CTAS explicitly.
DROP TABLE IF EXISTS analytics.t_ctas_encoded;
CREATE TABLE analytics.t_ctas_encoded (
    sale_id BIGINT ENCODE az64, sale_date DATE ENCODE raw,
    store_id INTEGER ENCODE az64, customer_id BIGINT ENCODE az64,
    product_id INTEGER ENCODE az64, channel VARCHAR(20) ENCODE bytedict,
    region VARCHAR(20) ENCODE bytedict, quantity INTEGER ENCODE az64,
    unit_price DECIMAL(18,2) ENCODE az64, revenue DECIMAL(18,2) ENCODE az64,
    loaded_at TIMESTAMP ENCODE az64
)
DISTKEY (customer_id) COMPOUND SORTKEY (sale_date);

INSERT INTO analytics.t_ctas_encoded SELECT * FROM analytics.fct_retail_sales;

SELECT "table", encoded, size AS mb, tbl_rows
FROM   svv_table_info
WHERE  "table" IN ('fct_retail_sales','t_ctas_naive','t_ctas_encoded')
ORDER  BY size DESC;


-- =========================================================================
-- 12.4  Try it — recommendations, measured
-- =========================================================================

-- 1. Build a staging copy and ask for recommendations.
--    LIKE copies the column definitions; add INCLUDING DEFAULTS if you
--    want the defaults too.
DROP TABLE IF EXISTS staging.sales_sample;
CREATE TABLE staging.sales_sample (LIKE analytics.fct_retail_sales);

INSERT INTO staging.sales_sample
SELECT * FROM analytics.fct_retail_sales
WHERE  sale_date > DATEADD(day, -7, GETDATE());

-- If that returns nothing on the teaching data, widen the window:
INSERT INTO staging.sales_sample
SELECT * FROM analytics.fct_retail_sales
WHERE  sale_date > DATEADD(day, -400, GETDATE());

ANALYZE COMPRESSION staging.sales_sample;
-- Output columns: Table | Column | Encoding | Est_reduction_pct
-- It RECOMMENDS. It does not apply. You still have to write the ALTER.

-- 2. Compare sizes before and after applying the recommendations.
SELECT "table", size AS mb, tbl_rows, encoded
FROM   svv_table_info
WHERE  "table" IN ('fct_retail_sales','sales_sample');


-- =========================================================================
-- 12.5  Gotchas
--
--   * ANALYZE COMPRESSION TAKES A TABLE LOCK. Run it on a staging copy,
--     never on a production table mid-day.
--   * It only RECOMMENDS. You still have to apply the encodings.
--   * A CTAS inherits nothing unless you say so — the most common source
--     of uncompressed tables.
--   * Sample data gives bad recommendations. Run it against realistic
--     volumes and real value distributions; a 100-row sample will suggest
--     encodings that are wrong at 100 million rows.
--   * runlength only pays off when equal values are ADJACENT. It is a
--     post-sort decision, not a cardinality decision.
--   * Not every ALTER COLUMN ... ENCODE transition is supported. Where it
--     is not, the path is: create a new table with the right encodings,
--     INSERT ... SELECT, swap names.
-- =========================================================================


-- =========================================================================
-- 12.6  Checklist
--
--   [ ] Large tables are encoded — I have checked encoded = 'N'
--   [ ] Encodings came from ANALYZE COMPRESSION, not from guessing
--   [ ] The first sort-key column is raw, deliberately
--   [ ] I ran ANALYZE COMPRESSION on a staging copy, not production
--   [ ] CTAS-created tables were given encodings explicitly
--   [ ] I re-check after a big change in data shape
--
-- YOU HAVE GOT IT WHEN YOU CAN find every large uncompressed table in a
-- schema with one query, and produce a measured recommendation for the
-- worst one without touching production.
--
-- That is these two statements, in order:
-- =========================================================================
SELECT "table", size AS mb, tbl_rows, encoded
FROM   svv_table_info
WHERE  "schema" = 'analytics' AND encoded = 'N'
ORDER  BY size DESC
LIMIT  1;
-- then LIKE it into staging, load a realistic sample, ANALYZE COMPRESSION,
-- and report the estimated reduction — production untouched throughout.
