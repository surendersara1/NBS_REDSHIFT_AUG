-- =========================================================================
-- 04 — Physical modelling, materialized views, and the compute-back-to-silver
--       round trip
--
-- This is the file that turns application developers into warehouse
-- engineers. Everything before it was plumbing.
--
-- The one idea to hold on to: Redshift has no indexes. Query speed comes
-- from THREE decisions, made at CREATE TABLE time, that determine how many
-- bytes leave disk and how many cross the network:
--
--   DISTKEY  which node a row lives on   -> decides if a join needs a shuffle
--   SORTKEY  the order rows sit on disk  -> decides how many blocks are read
--   ENCODE   the per-column compression  -> decides how big those blocks are
-- =========================================================================


-- -------------------------------------------------------------------------
-- 4.1  Distribution styles, and how to choose
--
--   ALL   full copy on every node. Dimensions under ~5M rows.
--         Cost: storage x node count, and every write goes everywhere.
--   KEY   rows hashed on one column. Put the JOIN column here so matching
--         rows are co-located and the join needs no shuffle.
--   EVEN  round-robin. The safe default when nothing joins.
--   AUTO  Redshift starts ALL for small tables and switches to EVEN/KEY as
--         the table grows. Correct default for new work; be explicit when
--         you know the access pattern.
--
-- The fact table distributes on customer_id — the same key the dimension
-- distributes on — so the join is collocated.
-- -------------------------------------------------------------------------
DROP TABLE IF EXISTS analytics.fct_customer_orders CASCADE;

CREATE TABLE analytics.fct_customer_orders (
    order_id       BIGINT        NOT NULL ENCODE az64,
    customer_id    BIGINT        NOT NULL ENCODE az64,
    customer_name  VARCHAR(200)           ENCODE zstd,
    segment        VARCHAR(50)            ENCODE bytedict,
    country        VARCHAR(10)            ENCODE bytedict,
    order_ts       TIMESTAMP              ENCODE az64,
    order_date     DATE                   ENCODE az64,
    status         VARCHAR(20)            ENCODE bytedict,
    quantity       INTEGER                ENCODE az64,
    unit_price     DECIMAL(18,2)          ENCODE az64,
    gross_amount   DECIMAL(18,2)          ENCODE az64,
    loaded_at      TIMESTAMP DEFAULT SYSDATE ENCODE az64
)
DISTSTYLE KEY
DISTKEY (customer_id)
COMPOUND SORTKEY (order_date, segment);

-- Encoding notes worth saying out loud:
--   az64     numerics and dates. Almost always the right answer.
--   zstd     high-cardinality strings (names, free text).
--   bytedict low-cardinality strings (<256 distinct). segment/status/country
--            are the textbook case — a 20-byte value becomes a 1-byte code.
--   raw      only for a column you sort on and filter with ranges, where
--            decompression would cost more than it saves.
-- Let COPY choose on first load (COMPUPDATE ON) and then check its work:
--   ANALYZE COMPRESSION analytics.fct_customer_orders;


-- -------------------------------------------------------------------------
-- 4.2  Sort keys
--
--   COMPOUND      (default) prefix-ordered. Filtering on the FIRST column is
--                 fast; on the second alone, much less so. Match it to your
--                 most common WHERE clause.
--   INTERLEAVED   equal weight to each column. Helps when queries filter on
--                 different single columns unpredictably, but VACUUM
--                 REINDEX is expensive. Use rarely and deliberately.
--   AUTO          Redshift observes the workload and sorts accordingly.
--
-- The payoff is zone maps: Redshift stores min/max per 1 MB block and skips
-- blocks that cannot match. A sorted column turns a full scan into a seek.
-- -------------------------------------------------------------------------

-- Load from the Glue-produced silver Iceberg table.
INSERT INTO analytics.fct_customer_orders (
    order_id, customer_id, customer_name, segment, country,
    order_ts, order_date, status, quantity, unit_price, gross_amount
)
SELECT order_id, customer_id, customer_name, segment, country,
       order_ts, order_ts::DATE, status, quantity, unit_price, gross_amount
FROM   s3t_bronze.silver_customer_orders;

-- ANALYZE after every material load. The planner works from statistics; a
-- stale stat is the single most common cause of "it was fast yesterday".
ANALYZE analytics.fct_customer_orders;


-- -------------------------------------------------------------------------
-- 4.3  Materialized views
--
-- An MV stores the RESULT. Redshift can also rewrite an unrelated query to
-- use it automatically (automatic query rewriting), which is why an MV can
-- speed up queries nobody rewrote.
--
-- AUTO REFRESH YES is allowed here because every base table is native.
-- The next MV cannot use it — see 4.4.
-- -------------------------------------------------------------------------
DROP MATERIALIZED VIEW IF EXISTS analytics.mv_segment_daily;

CREATE MATERIALIZED VIEW analytics.mv_segment_daily
DISTSTYLE KEY
DISTKEY (segment)
SORTKEY (order_date)
AUTO REFRESH YES
AS
SELECT order_date,
       segment,
       country,
       COUNT(*)                                   AS order_count,
       COUNT(DISTINCT customer_id)                AS distinct_customers,
       SUM(gross_amount)                          AS gross_amount,
       AVG(gross_amount)                          AS avg_order_value,
       SUM(CASE WHEN status = 'CANCELLED' THEN 1 ELSE 0 END) AS cancelled_count
FROM   analytics.fct_customer_orders
GROUP  BY order_date, segment, country;

REFRESH MATERIALIZED VIEW analytics.mv_segment_daily;

-- Was the refresh incremental or a full recompute? Incremental is far
-- cheaper, and small changes to the definition silently disqualify it.
SELECT mv_name, status, refresh_type, start_time, duration, error_message
FROM   sys_mv_refresh_history
ORDER  BY start_time DESC
LIMIT  20;


-- -------------------------------------------------------------------------
-- 4.4  A materialized view over EXTERNAL data
--
-- Supported, and useful: it caches a Spectrum/Iceberg scan in local storage
-- so repeat queries stop paying per-TB scan costs.
--
-- LIMITATION, verified against the Redshift Database Developer Guide:
-- AUTO REFRESH YES cannot be used when the definition references an
-- external schema. Refresh it on a schedule instead. Omitting AUTO REFRESH
-- (as below) is required; adding it raises an error at CREATE time.
-- -------------------------------------------------------------------------
DROP MATERIALIZED VIEW IF EXISTS analytics.mv_bronze_customer_profile;

CREATE MATERIALIZED VIEW analytics.mv_bronze_customer_profile
DISTSTYLE ALL
AS
SELECT customer_id, customer_name, segment, country, signup_date
FROM   s3t_bronze.bronze_customers;

REFRESH MATERIALIZED VIEW analytics.mv_bronze_customer_profile;


-- -------------------------------------------------------------------------
-- 4.5  The compute, and the write back to silver
--
-- The requirement: compute over the joined table, then publish the result
-- back to the lake as a new silver-layer artefact.
--
-- The computation is a genuine warehouse workload — window functions over
-- a partitioned set, which is exactly the shape that makes DISTKEY matter.
-- Because the table distributes on customer_id and these windows partition
-- by customer_id, each node computes its own customers with no data
-- movement at all. Change the DISTKEY to EVEN and re-read the plan to see
-- the redistribution appear.
-- -------------------------------------------------------------------------
DROP TABLE IF EXISTS analytics.fct_customer_metrics;

CREATE TABLE analytics.fct_customer_metrics
DISTSTYLE KEY
DISTKEY (customer_id)
COMPOUND SORTKEY (customer_id, order_date)
AS
WITH ranked AS (
    SELECT
        customer_id, customer_name, segment, country,
        order_id, order_date, gross_amount, status,
        ROW_NUMBER()  OVER (PARTITION BY customer_id ORDER BY order_date)          AS order_seq,
        LAG(order_date) OVER (PARTITION BY customer_id ORDER BY order_date)        AS prev_order_date,
        SUM(gross_amount) OVER (PARTITION BY customer_id ORDER BY order_date
                                ROWS UNBOUNDED PRECEDING)                          AS running_ltv,
        AVG(gross_amount) OVER (PARTITION BY customer_id ORDER BY order_date
                                ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)          AS moving_avg_3,
        NTILE(4) OVER (PARTITION BY segment ORDER BY gross_amount DESC)            AS segment_quartile
    FROM analytics.fct_customer_orders
    WHERE status = 'COMPLETED'
)
SELECT
    customer_id, customer_name, segment, country,
    order_id, order_date, gross_amount,
    order_seq,
    DATEDIFF(day, prev_order_date, order_date) AS days_since_prev_order,
    running_ltv,
    moving_avg_3,
    segment_quartile,
    CASE
        WHEN running_ltv >= 50000 THEN 'PLATINUM'
        WHEN running_ltv >= 20000 THEN 'GOLD'
        WHEN running_ltv >=  5000 THEN 'SILVER'
        ELSE 'BRONZE'
    END AS ltv_tier,
    SYSDATE AS computed_at
FROM ranked;

ANALYZE analytics.fct_customer_metrics;

-- `rows` is a RESERVED WORD in Redshift (it is the window-frame keyword), so
-- `COUNT(*) AS rows` is a syntax error unless double-quoted. Renamed rather
-- than quoted, because a quoted identifier is then case-sensitive forever.
SELECT ltv_tier, COUNT(*) AS row_count, COUNT(DISTINCT customer_id) AS customers,
       ROUND(AVG(running_ltv), 2) AS avg_ltv
FROM   analytics.fct_customer_metrics
GROUP  BY ltv_tier
ORDER  BY avg_ltv DESC;

-- Publish the computed result back to the lake as Parquet, partitioned by
-- the tier so downstream readers prune. This is the "silver dump" — the
-- computed artefact leaving the warehouse.
UNLOAD ('SELECT customer_id, customer_name, segment, country, order_id,
                order_date, gross_amount, order_seq, days_since_prev_order,
                running_ltv, moving_avg_3, segment_quartile, ltv_tier,
                computed_at
         FROM analytics.fct_customer_metrics')
TO 's3://<CURATED_BUCKET>/silver/customer_metrics/'
IAM_ROLE '<SPECTRUM_ROLE_ARN>'
FORMAT AS PARQUET
PARTITION BY (ltv_tier)
ALLOWOVERWRITE
MAXFILESIZE 128 MB;

-- Register it back so Redshift (and Athena, and Glue) can read the dump.
CREATE EXTERNAL TABLE spectrum_raw.silver_customer_metrics (
    customer_id            BIGINT,
    customer_name          VARCHAR(200),
    segment                VARCHAR(50),
    country                VARCHAR(10),
    order_id               BIGINT,
    order_date             DATE,
    gross_amount           DECIMAL(18,2),
    order_seq              BIGINT,
    days_since_prev_order  INTEGER,
    running_ltv            DECIMAL(18,2),
    moving_avg_3           DECIMAL(18,2),
    segment_quartile       INTEGER,
    computed_at            TIMESTAMP
)
PARTITIONED BY (ltv_tier VARCHAR(20))
STORED AS PARQUET
LOCATION 's3://<CURATED_BUCKET>/silver/customer_metrics/';

-- Partition columns are NOT stored in the files — they come from the S3
-- prefix. A column appearing in both the column list and PARTITIONED BY is
-- an error. UNLOAD ... PARTITION BY wrote the prefixes; this makes them
-- visible to the catalog:
ALTER TABLE spectrum_raw.silver_customer_metrics
  ADD IF NOT EXISTS PARTITION (ltv_tier='PLATINUM')
  LOCATION 's3://<CURATED_BUCKET>/silver/customer_metrics/ltv_tier=PLATINUM/';
ALTER TABLE spectrum_raw.silver_customer_metrics
  ADD IF NOT EXISTS PARTITION (ltv_tier='GOLD')
  LOCATION 's3://<CURATED_BUCKET>/silver/customer_metrics/ltv_tier=GOLD/';
ALTER TABLE spectrum_raw.silver_customer_metrics
  ADD IF NOT EXISTS PARTITION (ltv_tier='SILVER')
  LOCATION 's3://<CURATED_BUCKET>/silver/customer_metrics/ltv_tier=SILVER/';
ALTER TABLE spectrum_raw.silver_customer_metrics
  ADD IF NOT EXISTS PARTITION (ltv_tier='BRONZE')
  LOCATION 's3://<CURATED_BUCKET>/silver/customer_metrics/ltv_tier=BRONZE/';

-- Full circle: computed in Redshift, published to S3, read back through
-- Spectrum, and pruned to one partition.
SELECT COUNT(*), ROUND(AVG(running_ltv), 2)
FROM   spectrum_raw.silver_customer_metrics
WHERE  ltv_tier = 'PLATINUM';


-- -------------------------------------------------------------------------
-- 4.6  Maintenance — the part that decides whether this stays fast
-- -------------------------------------------------------------------------
-- Reclaim space from deletes and re-sort rows inserted out of order.
VACUUM DELETE ONLY analytics.fct_customer_orders;
VACUUM SORT ONLY   analytics.fct_customer_orders;
-- VACUUM FULL does both; VACUUM REINDEX is for interleaved sort keys only.

ANALYZE analytics.fct_customer_orders;

-- What does Redshift itself think needs fixing?
SELECT type, database, table_id, group_id, auto_eligible, ddl
FROM   svv_alter_table_recommendations;

-- Unsorted percentage and skew, the two numbers to watch:
SELECT "table", size, tbl_rows, unsorted, stats_off, skew_rows, skew_sortkey1,
       diststyle, sortkey1, encoded
FROM   svv_table_info
WHERE  schema IN ('analytics','staging')
ORDER  BY size DESC;
