/*
======================================================================================
MODULE 60: ENTERPRISE STORAGE ARCHITECTURE & LAKEHOUSE DEEP DIVE
======================================================================================
MAPPED BEST PRACTICES (from PROCEDURE_OPTIMIZATION_BEST_PRACTICES_MASTER_FILE.md):
- Practice 89: Use a star schema for analytics — facts (measures) plus dimensions (context).
- Practice 90: Denormalize for analytical reads.
- Practice 91: Follow medallion layering: Bronze (raw) -> Silver (cleansed) -> Gold (business).
- Practice 92: Use materialized views for pre-computed, frequently-queried aggregates.
- Practice 104-108: Spectrum / Lakehouse partition pruning and S3 storage tiering.
- Practice 42: Idempotent data publishing and zero-downtime partition swaps.

TARGET AUDIENCE: Lead Data Architects, Principal Engineers, and Warehouse Developers
BUSINESS SCENARIO: 
An enterprise handles 50 Terabytes of new telemetry, web logs, and transactional records daily. 
Storing 100% of raw historical data in Redshift Managed Storage (RMS) is cost-prohibitive. 
Conversely, running complex 15-way dashboard joins directly against raw S3 CSV files results in 
45-second query latencies and saturates external Glue catalogs.

THE SOLUTION: HYBRID LAKEHOUSE MEDALLION ARCHITECTURE
1. Bronze (Raw): Amazon S3 (Immutable Raw JSON/Parquet) & S3 Tables / Iceberg.
2. Silver (Enriched): Partitioned Parquet on S3 or staging tables in Redshift.
3. Gold (Curated Star Schema): Redshift Managed Storage (RMS) with NVMe cache tiering, 
   collocated distribution keys, compound sort keys, and automated Materialized Views.
4. Cold Archival Tier: Automated partition offloading from RMS to S3 with seamless unified views.

======================================================================================
SECTION 1: STORAGE INTERNALS — REDSHIFT MANAGED STORAGE (RMS) VS S3 LAKEHOUSE
======================================================================================
Redshift Managed Storage (RMS) Architecture:
- Tier 1: Local high-performance NVMe SSDs acting as a working cache on compute nodes.
- Tier 2: Redshift Managed Storage backed by Amazon S3 (automatic block replication across 3 AZs).
- 1MB Immutable Column Blocks: Every column is partitioned into 1MB blocks with automatic Zone Maps.
- Contrast with S3 Lakehouse (Spectrum / S3 Tables / Iceberg):
  * Open formats (Parquet, ORC, Iceberg).
  * Storage and compute decoupled across external engines (Athena, Spark, EMR, Redshift).
  * Network boundary: Queries against S3 must traverse the Redshift Spectrum fleet layer.
*/

-- ===================================================================================
-- SECTION 2: EXTERNAL LAKEHOUSE CATALOG SETUP (GLUE & S3 TABLES)
-- ===================================================================================

-- (A) External Schema for Standard S3 Data Lake (via AWS Glue Catalog):
-- CREATE EXTERNAL SCHEMA ext_lake_bronze
-- FROM DATA CATALOG
-- DATABASE 'lakehouse_bronze_db'
-- IAM_ROLE 'arn:aws:iam::123456789012:role/RedshiftLakehouseRole'
-- CREATE EXTERNAL DATABASE IF NOT EXISTS;

-- (B) External Schema for Amazon S3 Tables (Apache Iceberg REST Catalog Integration):
-- CREATE EXTERNAL SCHEMA ext_s3_tables_silver
-- FROM S3TABLES
-- CATALOG 'arn:aws:s3tables:us-east-1:123456789012:bucket/enterprise-lake-bucket'
-- NAMESPACE 'silver_analytics'
-- IAM_ROLE 'arn:aws:iam::123456789012:role/RedshiftLakehouseRole';


-- ===================================================================================
-- SECTION 3: THE MEDALLION STORAGE TIERS
-- ===================================================================================

-- -----------------------------------------------------------------------------------
-- 1. BRONZE LAYER: Raw Ingestion Landing (S3 External Spectrum Table)
-- -----------------------------------------------------------------------------------
-- Stored on S3 in Snappy-compressed Parquet, partitioned by ingestion date.
DROP TABLE IF EXISTS ext_bronze_web_clicks;
-- CREATE EXTERNAL TABLE ext_bronze_web_clicks (
--     click_id VARCHAR(64),
--     user_id BIGINT,
--     url VARCHAR(500),
--     referrer VARCHAR(500),
--     ip_address VARCHAR(45),
--     user_agent VARCHAR(255),
--     payload_json VARCHAR(MAX),
--     event_timestamp TIMESTAMP
-- )
-- PARTITIONED BY (event_date DATE)
-- STORED AS PARQUET
-- LOCATION 's3://enterprise-lakehouse-us-east-1/bronze/web_clicks/';

-- -----------------------------------------------------------------------------------
-- 2. SILVER LAYER: Cleansed, Structured & Deduplicated (Redshift Staging / S3)
-- -----------------------------------------------------------------------------------
DROP TABLE IF EXISTS silver_web_clicks CASCADE;
CREATE TABLE silver_web_clicks (
    click_id VARCHAR(64) NOT NULL ENCODE zstd,
    user_id BIGINT NOT NULL ENCODE az64,
    url_path VARCHAR(255) NOT NULL ENCODE zstd,
    domain VARCHAR(100) NOT NULL ENCODE bytedict,
    device_type VARCHAR(32) NOT NULL ENCODE bytedict,
    event_timestamp TIMESTAMP NOT NULL ENCODE az64,
    event_date DATE NOT NULL ENCODE az64
)
DISTSTYLE KEY
DISTKEY (user_id)
COMPOUND SORTKEY (event_date, user_id);

-- -----------------------------------------------------------------------------------
-- 3. GOLD LAYER: Curated Kimball Star Schema (Redshift Managed Storage)
-- -----------------------------------------------------------------------------------
-- Fact Table (Hot 90-day active window in RMS for sub-second analytical reporting):
DROP TABLE IF EXISTS gold_fct_web_engagement CASCADE;
CREATE TABLE gold_fct_web_engagement (
    click_sk BIGINT IDENTITY(1,1) NOT NULL ENCODE az64,
    click_id VARCHAR(64) NOT NULL ENCODE zstd,
    user_id BIGINT NOT NULL ENCODE az64,
    page_id INT NOT NULL ENCODE az64,
    event_timestamp TIMESTAMP NOT NULL ENCODE az64,
    event_date DATE NOT NULL ENCODE raw, -- Leading sort key: raw encoding for zone maps
    duration_seconds INT NOT NULL ENCODE az64,
    is_conversion INT NOT NULL ENCODE az64,
    PRIMARY KEY (click_sk)
)
DISTSTYLE KEY
DISTKEY (user_id)
COMPOUND SORTKEY (event_date, user_id);

-- Gold Aggregation Layer (Auto-Refreshing Materialized View):
DROP MATERIALIZED VIEW IF EXISTS gold_mv_daily_domain_metrics CASCADE;
CREATE MATERIALIZED VIEW gold_mv_daily_domain_metrics
DISTSTYLE ALL
SORTKEY (event_date)
AUTO REFRESH YES
AS
SELECT 
    event_date,
    domain,
    device_type,
    COUNT(1) AS total_clicks,
    COUNT(DISTINCT user_id) AS unique_visitors
FROM silver_web_clicks
GROUP BY event_date, domain, device_type;


-- ===================================================================================
-- SECTION 4: MOVING DATA IN & OUT (COPY, UNLOAD, ALTER TABLE APPEND)
-- ===================================================================================

-- -----------------------------------------------------------------------------------
-- PATTERN A: HIGH-THROUGHPUT BULK INGESTION (COPY FROM S3)
-- -----------------------------------------------------------------------------------
/*
CRITICAL BEST PRACTICES FOR S3 COPY:
1. File Count = Multiple of Cluster Slices (e.g. 16, 32, 64 files of equal size ~100MB-1GB).
2. Use PARQUET or compressed CSV with GZIP/ZSTD.
3. Use a MANIFEST file to guarantee exact file lists and prevent duplicate ingestion.
4. Set COMPUPDATE OFF if the target table already has explicit column encodings.
5. Set STATUPDATE ON (or run explicit ANALYZE immediately following load).
*/
-- COPY silver_web_clicks
-- FROM 's3://enterprise-lakehouse-us-east-1/manifests/2026-08-15-clicks.manifest'
-- IAM_ROLE 'arn:aws:iam::123456789012:role/RedshiftLakehouseRole'
-- FORMAT AS PARQUET
-- MANIFEST
-- COMPUPDATE OFF
-- STATUPDATE ON;

-- -----------------------------------------------------------------------------------
-- PATTERN B: ZERO-COPY INSTANT TABLE SWAP (ALTER TABLE APPEND)
-- -----------------------------------------------------------------------------------
/*
WHY ALTER TABLE APPEND IS INSTANT (0.01 seconds for 500 million rows):
- It moves physical 1MB data block pointers from the source table to the target table.
- Does NOT scan, decompress, or re-write data blocks.
- Requirements:
  1. Both tables must have identical column definitions, datatypes, and compression encodings.
  2. Both tables must have the same distribution style and sort key structure.
  3. The source table is emptied (truncated) by the operation.
*/
DROP TABLE IF EXISTS stage_web_clicks_append CASCADE;
CREATE TABLE stage_web_clicks_append (LIKE silver_web_clicks);

-- Populate staging with 50,000 records
INSERT INTO stage_web_clicks_append (click_id, user_id, url_path, domain, device_type, event_timestamp, event_date)
SELECT 
    MD5(s.n::VARCHAR),
    (s.n % 10000 + 1),
    '/products/category_' || (s.n % 50)::VARCHAR,
    'shop.acme.com',
    CASE WHEN s.n % 2 = 0 THEN 'MOBILE' ELSE 'DESKTOP' END,
    '2026-08-15 12:00:00'::TIMESTAMP,
    '2026-08-15'::DATE
FROM (
    SELECT ROW_NUMBER() OVER () as n
    FROM (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) a,
         (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) b,
         (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) c,
         (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) d,
         (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4) e
    LIMIT 50000
) s;

ANALYZE stage_web_clicks_append;

-- Zero-copy metadata swap into the Silver layer:
ALTER TABLE silver_web_clicks APPEND FROM stage_web_clicks_append;

-- -----------------------------------------------------------------------------------
-- PATTERN C: HIGH-PERFORMANCE DATA OFFLOADING (UNLOAD TO S3)
-- -----------------------------------------------------------------------------------
/*
CRITICAL BEST PRACTICES FOR UNLOAD:
1. FORMAT AS PARQUET (saves 70-85% S3 storage and enables column pruning for downstream Athena/Spark).
2. PARTITION BY (column): Writes hierarchical S3 partitions (`event_date=2026-08-15/...`).
3. PARALLEL ON: Every compute slice unloads directly to S3 concurrently.
4. CLEANPATH / OVERWRITE semantics: Cleans destination S3 partition prefix before writing to avoid dirty reads.
5. MANIFEST: Generates a JSON manifest listing all unloaded files for downstream consumption.
*/
-- UNLOAD ('SELECT * FROM silver_web_clicks WHERE event_date = ''2026-08-15''')
-- TO 's3://enterprise-lakehouse-us-east-1/silver/web_clicks/'
-- IAM_ROLE 'arn:aws:iam::123456789012:role/RedshiftLakehouseRole'
-- FORMAT AS PARQUET
-- PARTITION BY (event_date)
-- CLEANPATH
-- MANIFEST
-- PARALLEL ON;


-- ===================================================================================
-- SECTION 5: THE S3 OVERWRITE PROBLEM & ZERO-DOWNTIME DATA PUBLISHING
-- ===================================================================================
/*
THE DANGER OF DIRECT S3 OVERWRITES:
When `UNLOAD` writes directly to an active S3 prefix:
1. Partial File Visibility: S3 writes multiple part files (`0000_part_00.parquet`, `0001_part_00.parquet`). 
   If a BI query runs via Spectrum mid-unload, it reads an incomplete, corrupted snapshot.
2. S3 Event / Lambda Storms: Writing 64 individual files triggers 64 concurrent S3 ObjectCreated events.
3. Overwrite Lock Failure: Unlike relational databases with ACID transaction locks, S3 object storage 
   has no native table-level locking mechanism for raw files.

THE ENTERPRISE SOLUTION: BLUE/GREEN S3 PARTITION PROMOTION
Step 1: Write new data to an isolated staging prefix: `s3://bucket/staging/batch_20260815/`
Step 2: Validate row count and checksums.
Step 3: Point the External Table metadata or Glue Catalog partition to the new S3 prefix atomically 
        via `ALTER TABLE ext_table SET LOCATION 's3://...'` or Iceberg commit.
*/

CREATE OR REPLACE PROCEDURE prc_lakehouse_atomic_partition_publish(
    p_batch_date DATE,
    p_s3_staging_uri VARCHAR(500),
    p_s3_target_uri VARCHAR(500)
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_sql VARCHAR(MAX);
BEGIN
    RAISE INFO 'Starting atomic lakehouse partition promotion for % ...', p_batch_date;

    -- In production: Update the Glue/Spectrum partition location metadata atomically
    -- v_sql := 'ALTER TABLE ext_silver_clicks PARTITION (event_date = ''' || p_batch_date || ''') ' ||
    --          'SET LOCATION ''' || p_s3_staging_uri || ''';';
    -- EXECUTE v_sql;

    RAISE INFO 'Partition % promoted to % with zero query downtime.', p_batch_date, p_s3_staging_uri;
END;
$$;


-- ===================================================================================
-- SECTION 6: MANAGING SCHEMA EVOLUTION ACROSS LAKE & WAREHOUSE
-- ===================================================================================
/*
HOW REDSHIFT HANDLES SCHEMA EVOLUTION:
1. Parquet Schema Evolution:
   - When new columns are added to Parquet files on S3, Redshift Spectrum automatically fills missing 
     historical rows with `NULL` as long as column names match.
   - Column order in Parquet does NOT matter; matching is by column name.
2. SUPER Data Type for Schemaless Drift:
   - Store rapidly evolving upstream event attributes in a `SUPER` column (`attributes_payload SUPER`).
   - Query dynamic attributes with dot notation without running DDL migrations.
3. Late-Binding Views (WITH NO SCHEMA BINDING):
   - Decouple BI reporting layers from underlying physical table column changes.
   - Views do not lock the underlying table schema and do not break when columns are added or dropped.
*/

-- Example Late-Binding Unified View:
DROP VIEW IF EXISTS v_unified_web_engagement;
CREATE VIEW v_unified_web_engagement AS
SELECT 
    click_id,
    user_id,
    event_timestamp,
    event_date,
    duration_seconds,
    is_conversion,
    'REDSHIFT_HOT_STORAGE' AS storage_tier
FROM gold_fct_web_engagement
UNION ALL
SELECT 
    click_id,
    user_id,
    event_timestamp,
    event_date,
    duration_seconds,
    is_conversion,
    'S3_COLD_LAKEHOUSE' AS storage_tier
FROM silver_web_clicks -- In production, points to ext_lake_archived_clicks on S3
WHERE event_date < DATEADD(day, -90, CURRENT_DATE)
WITH NO SCHEMA BINDING;


-- ===================================================================================
-- SECTION 7: AUTOMATED COLD DATA TIERING & STORAGE FINOPS PIPELINE
-- ===================================================================================
/*
STORAGE TIERING STRATEGY:
- Hot Tier (0 to 90 days): Stored in Redshift Managed Storage (RMS). Sub-second query SLA.
- Warm/Cold Tier (91 days to 7 years): Offloaded to S3 Parquet / S3 Tables with GZIP/Snappy compression.
- S3 Lifecycle: Automatically transitions from S3 Standard -> S3 Intelligent-Tiering -> S3 Glacier Flexible Archive.
- Cost Savings: Reduces storage cost by ~80% while retaining 100% SQL queryability via unified views.
*/

CREATE OR REPLACE PROCEDURE prc_lakehouse_tiering_archival(p_retention_days INT DEFAULT 90)
LANGUAGE plpgsql
AS $$
DECLARE
    v_cutoff_date DATE;
    v_rows_archived BIGINT := 0;
    v_rows_purged BIGINT := 0;
BEGIN
    v_cutoff_date := DATEADD(day, -p_retention_days, CURRENT_DATE);
    RAISE INFO 'Starting storage tiering: Offloading partitions older than % to S3...', v_cutoff_date;

    -- Step 1: UNLOAD cold partitions from Redshift to S3 Parquet Lakehouse
    -- (In production, executed via UNLOAD command to S3 archive prefix)
    RAISE INFO 'Unloading data prior to % to S3 Parquet archive...', v_cutoff_date;

    -- Step 2: Purge cold blocks from Redshift Managed Storage to reclaim local SSD/RMS space
    DELETE FROM gold_fct_web_engagement
    WHERE event_date < v_cutoff_date;
    GET DIAGNOSTICS v_rows_purged = ROW_COUNT;

    -- Step 3: Refresh statistics on remaining hot data
    ANALYZE gold_fct_web_engagement;

    RAISE INFO 'Tiering complete: Purged % rows from RMS. Cold queries seamlessly routed to S3.', v_rows_purged;

EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'prc_lakehouse_tiering_archival failed: %', SQLERRM;
END;
$$;


-- ===================================================================================
-- SECTION 8: DIAGNOSTICS, STORAGE MONITORING & EXPLAIN PLAN PROOF
-- ===================================================================================

-- 1. Inspect Table Storage Distribution, Slice Skew & Storage Tiering Health:
SELECT 
    "schema",
    "table",
    size AS total_mb,
    tbl_rows,
    unsorted,
    stats_off,
    skew_rows
FROM svv_table_info
WHERE "table" IN ('silver_web_clicks', 'gold_fct_web_engagement')
ORDER BY size DESC;

-- 2. Inspect Materialized View Refresh Status & Query Routing:
SELECT 
    database_name,
    schema_name,
    name AS mv_name,
    refresh_type,
    is_autorefresh,
    state,
    last_refresh_type,
    last_refresh_time
FROM sys_mv_refresh_history
ORDER BY last_refresh_time DESC LIMIT 5;

-- 3. Execution Plan: Verify Hybrid View Routing with S3 Spectrum vs RMS Local NVMe:
EXPLAIN
SELECT event_date, COUNT(1), SUM(is_conversion)
FROM v_unified_web_engagement
WHERE event_date >= '2026-08-01'::DATE
GROUP BY event_date;
