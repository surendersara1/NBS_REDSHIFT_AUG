-- =========================================================================
-- 02 — Spectrum external schema, COPY, and UNLOAD
--
-- The three ways data crosses the Redshift boundary:
--   COPY     S3 -> Redshift managed storage.   Fast, columnar, compressed.
--   Spectrum S3 queried in place.              No load, pay per TB scanned.
--   UNLOAD   Redshift -> S3.                   Parallel, partitioned.
--
-- Choosing between them is the core data-warehouse design decision, and it
-- is decided by ACCESS FREQUENCY, not data size:
--   queried many times a day  -> COPY it in
--   queried occasionally      -> leave it in S3, read with Spectrum
--   handed to another system  -> UNLOAD
--
-- Replace <SPECTRUM_ROLE_ARN>, <RAW_BUCKET>, <CURATED_BUCKET>, <GLUE_DB>
-- with the CDK stack outputs.
-- =========================================================================


-- -------------------------------------------------------------------------
-- 2.1  External schema over the Glue Data Catalog
--
-- This does NOT copy data. It maps a Redshift schema name onto a Glue
-- database. Table metadata resolves through Glue; the bytes stay in S3.
-- -------------------------------------------------------------------------
CREATE EXTERNAL SCHEMA IF NOT EXISTS spectrum_raw
FROM DATA CATALOG
DATABASE '<GLUE_DB>'
IAM_ROLE '<SPECTRUM_ROLE_ARN>'
CREATE EXTERNAL DATABASE IF NOT EXISTS;

-- Prove it resolved before going further.
SELECT schemaname, databasename, esoptions
FROM   svv_external_schemas;


-- -------------------------------------------------------------------------
-- 2.2  External tables over the raw CSVs
--
-- Note what is NOT here: no DISTKEY, no SORTKEY, no compression. External
-- tables have no such concepts — the file layout in S3 IS the physical
-- design. That is why file layout decides Spectrum cost.
--
-- skip.header.line.count is the CSV gotcha. Without it the header row is
-- returned as data, and because customer_id is BIGINT the string
-- 'customer_id' becomes NULL rather than an error.
-- -------------------------------------------------------------------------
CREATE EXTERNAL TABLE spectrum_raw.customers_csv (
    customer_id    BIGINT,
    customer_name  VARCHAR(200),
    segment        VARCHAR(50),
    country        VARCHAR(10),
    signup_date    DATE
)
ROW FORMAT DELIMITED
    FIELDS TERMINATED BY ','
STORED AS TEXTFILE
LOCATION 's3://<RAW_BUCKET>/parent/'
TABLE PROPERTIES ('skip.header.line.count'='1', 'numRows'='505');

CREATE EXTERNAL TABLE spectrum_raw.orders_csv (
    order_id     BIGINT,
    customer_id  BIGINT,
    order_ts     TIMESTAMP,
    status       VARCHAR(20),
    quantity     INTEGER,
    unit_price   DECIMAL(18,2)
)
ROW FORMAT DELIMITED
    FIELDS TERMINATED BY ','
STORED AS TEXTFILE
LOCATION 's3://<RAW_BUCKET>/child/'
TABLE PROPERTIES ('skip.header.line.count'='1', 'numRows'='5000');

-- numRows is NOT decoration. Without it the planner assumes a default row
-- count and will pick a catastrophic join order once external tables meet
-- local ones. Set it, and refresh it after big loads.

-- Query in place — no load has happened yet.
SELECT c.segment, COUNT(*) AS orders, SUM(o.quantity * o.unit_price) AS gross
FROM   spectrum_raw.orders_csv o
JOIN   spectrum_raw.customers_csv c USING (customer_id)
GROUP  BY c.segment
ORDER  BY gross DESC;


-- -------------------------------------------------------------------------
-- 2.3  COPY — S3 into managed storage
--
-- Land in staging first, always. COPY straight into a consumer-facing table
-- means consumers see a half-loaded table.
-- -------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS staging.customers (
    customer_id    BIGINT,
    customer_name  VARCHAR(200),
    segment        VARCHAR(50),
    country        VARCHAR(10),
    signup_date    DATE
)
DISTSTYLE AUTO;

TRUNCATE TABLE staging.customers;

COPY staging.customers
FROM 's3://<RAW_BUCKET>/parent/'
IAM_ROLE '<SPECTRUM_ROLE_ARN>'
FORMAT AS CSV
IGNOREHEADER 1
DATEFORMAT 'YYYY-MM-DD'
BLANKSASNULL
EMPTYASNULL
MAXERROR 100          -- fail the load only after 100 bad rows
COMPUPDATE ON         -- let COPY pick column encodings on first load
STATUPDATE ON;        -- and refresh statistics when it finishes

CREATE TABLE IF NOT EXISTS staging.orders (
    order_id     BIGINT,
    customer_id  BIGINT,
    order_ts     TIMESTAMP,
    status       VARCHAR(20),
    quantity     INTEGER,
    unit_price   DECIMAL(18,2)
)
DISTSTYLE AUTO;

TRUNCATE TABLE staging.orders;

COPY staging.orders
FROM 's3://<RAW_BUCKET>/child/'
IAM_ROLE '<SPECTRUM_ROLE_ARN>'
FORMAT AS CSV
IGNOREHEADER 1
-- HH24, not HH. In Redshift datetime format strings HH means HH12, so a
-- 24-hour timestamp like '2026-08-14 15:30:00' fails to parse with HH and
-- every afternoon row lands in STL_LOAD_ERRORS. This is the single most
-- common COPY format bug.
TIMEFORMAT 'YYYY-MM-DD HH24:MI:SS'
BLANKSASNULL
EMPTYASNULL
MAXERROR 100
COMPUPDATE ON
STATUPDATE ON;


-- -------------------------------------------------------------------------
-- 2.4  When COPY fails — the first thing to run, every time
--
-- STL_LOAD_ERRORS names the file, the line, the column, and the raw value.
-- Learn this query before you need it.
-- -------------------------------------------------------------------------
SELECT starttime, filename, line_number, colname, type, position,
       TRIM(err_reason) AS err_reason, TRIM(raw_field_value) AS bad_value
FROM   stl_load_errors
WHERE  starttime > DATEADD(hour, -2, SYSDATE)
ORDER  BY starttime DESC
LIMIT  50;

-- Modern equivalent, and the one to prefer on new work:
SELECT query_id, table_name, data_source, loaded_rows, error_count, status,
       start_time, duration
FROM   sys_load_history
WHERE  start_time > DATEADD(hour, -2, SYSDATE)
ORDER  BY start_time DESC;

-- Per-file detail of the most recent load:
SELECT * FROM sys_load_detail
WHERE  query_id = (SELECT MAX(query_id) FROM sys_load_history)
ORDER  BY start_time;


-- -------------------------------------------------------------------------
-- 2.5  UNLOAD — Redshift back out to S3
--
-- PARALLEL ON (the default) writes one file per slice. That is what you
-- want for a downstream Spark/Athena reader. PARALLEL OFF writes a single
-- file and serialises the whole export through one slice — only use it when
-- a downstream tool genuinely cannot handle multiple files.
-- -------------------------------------------------------------------------
UNLOAD ('SELECT * FROM staging.orders WHERE status = ''COMPLETED''')
TO 's3://<CURATED_BUCKET>/unload/orders_completed/'
IAM_ROLE '<SPECTRUM_ROLE_ARN>'
FORMAT AS PARQUET
PARTITION BY (status)
ALLOWOVERWRITE
MAXFILESIZE 128 MB;
-- PARTITION BY writes Hive-style status=COMPLETED/ prefixes, which Spectrum
-- and Athena then prune on. This is how you make the next reader cheap.

-- CSV variant, for handing data to a system that cannot read Parquet:
UNLOAD ('SELECT customer_id, customer_name, segment FROM staging.customers')
TO 's3://<CURATED_BUCKET>/unload/customers_csv/'
IAM_ROLE '<SPECTRUM_ROLE_ARN>'
FORMAT AS CSV
HEADER
GZIP
ALLOWOVERWRITE
MAXFILESIZE 64 MB;

SELECT query_id, start_time, duration, path, unloaded_rows, file_count
FROM   sys_unload_history
WHERE  start_time > DATEADD(hour, -2, SYSDATE)
ORDER  BY start_time DESC;


-- -------------------------------------------------------------------------
-- 2.6  Prove Spectrum is pruning — never assume it
--
-- SVL_S3QUERY_SUMMARY reports bytes scanned per external scan. If
-- s3_scanned_bytes does not fall when you add a partition predicate, your
-- partitions are not being used and you are paying full-table scan prices.
-- -------------------------------------------------------------------------
SELECT query, segment, elapsed, s3_scanned_rows, s3_scanned_bytes,
       s3query_returned_rows, s3query_returned_bytes, files
FROM   svl_s3query_summary
WHERE  query IN (SELECT query FROM stl_query
                 WHERE userid = current_user_id
                 ORDER BY starttime DESC LIMIT 10)
ORDER  BY query DESC;

-- Modern equivalent:
SELECT query_id, segment_id, s3_scanned_rows, s3_scanned_bytes,
       s3_query_returned_rows, s3_query_returned_bytes
FROM   sys_external_query_detail
WHERE  start_time > DATEADD(hour, -1, SYSDATE)
ORDER  BY query_id DESC
LIMIT  50;
