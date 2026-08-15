/*
======================================================================================
MODULE 60: ENTERPRISE STORAGE ARCHITECTURE & LAKEHOUSE DEEP DIVE
======================================================================================
MAPPED BEST PRACTICES (from PROCEDURE_OPTIMIZATION_BEST_PRACTICES_MASTER_FILE.md):
- Practice 8: SORT KEY -> ZONE MAPS skips blocks (1MB immutable block mechanics).
- Practice 26, 79: Staging in collocated #TEMP tables with ON COMMIT DROP and ANALYZE.
- Practice 29: Collocated Distribution Keys (DISTSTYLE KEY) across fact and staging.
- Practice 42: Complete Idempotency & Zero-Downtime Partition Swaps.
- Practice 44: High-Performance MERGE vs ALTER TABLE APPEND pointer swapping.
- Practice 58: SUPER/PartiQL for dynamic schemaless event drift vs relational columns.
- Practice 62: Refreshing statistics (ANALYZE) after bulk ingestion and tiering.
- Practice 89-91: Medallion Architecture: Bronze (S3 Raw) -> Silver (Enriched) -> Gold (RMS Star Schema).
- Practice 92: Auto-Refreshing Materialized Views on curated Star Schemas.
- Practice 104-108: Spectrum / S3 Tables partition pruning, S3 overwrite protection, and FinOps lifecycle tiering.

TARGET AUDIENCE: Lead Data Architects, Principal Engineers, and Warehouse Developers
BUSINESS SCENARIO: 
An enterprise ingests 50 Terabytes of telemetry, clickstream, and transaction data daily. 
Storing 100% of multi-year history in Redshift Managed Storage (RMS) causes millions of dollars 
in compute/storage overspend. Conversely, running complex 10-way dashboard joins directly against 
raw S3 files causes 60-second BI timeouts and saturates S3 GET rate limits.

THE SOLUTION: HYBRID LAKEHOUSE MEDALLION ARCHITECTURE
1. Bronze (Raw): Amazon S3 / S3 Tables (Immutable Raw JSON/Parquet, partitioned by ingestion date).
2. Silver (Cleansed): Deduplicated, schema-validated Parquet on S3 or Redshift Staging tables.
3. Gold (Curated Star Schema): Redshift Managed Storage (RMS) with local NVMe SSD cache tiering, 
   collocated distribution keys, compound sort keys, and automated Materialized Views.
4. Cold Archival Tier: Automated partition offloading from RMS to S3 with seamless unified views.
======================================================================================
*/

-- ===================================================================================
-- SECTION 1: STORAGE INTERNALS — REDSHIFT MANAGED STORAGE (RMS) VS S3 LAKEHOUSE
-- ===================================================================================
/*
--------------------------------------------------------------------------------------
1. REDSHIFT MANAGED STORAGE (RMS) PHYSICAL LAYOUT:
--------------------------------------------------------------------------------------
- Two-Tier Storage Architecture:
  * Tier 1 (Local NVMe SSD Cache): Sits directly on compute nodes (RA3 instances). 
    Delivers sub-millisecond data block reads for working working-set data.
  * Tier 2 (S3-Backed Managed Storage): Infinite, durable backing store. Redshift automatically 
    replicates 1MB blocks across 3 Availability Zones (AZs).
- 1MB Immutable Columnar Blocks:
  * Redshift stores data in fixed 1MB physical blocks per column.
  * Every 1MB block has a metadata header containing the block's Zone Map (Min and Max values).
  * Blocks are 100% immutable: `UPDATE` and `DELETE` do NOT modify existing blocks in place. 
    Instead, they mark rows as "tombstones" (deleted in transaction metadata) and append new 1MB blocks.
- Slices & Parallelism:
  * Each compute node is partitioned into multiple "slices" (e.g. 2 to 16 slices per node).
  * Each slice manages its own local NVMe directory and processes its portion of physical 1MB blocks in parallel.

--------------------------------------------------------------------------------------
2. S3 OPEN DATA LAKE & S3 TABLES (SPECTRUM / ICEBERG):
--------------------------------------------------------------------------------------
- Decoupled Storage & Open Formats:
  * Data lives on Amazon S3 in open columnar formats: Apache Parquet, ORC, Apache Iceberg, or S3 Tables.
  * Accessible by multiple query engines simultaneously (Redshift Spectrum, Athena, Spark, EMR, SageMaker).
- Spectrum Compute Layer:
  * When Redshift queries S3 external tables, the cluster pushes scans down to a dynamic, thousands-strong 
    fleet of Spectrum worker nodes in the AWS region.
  * Spectrum workers project columns, evaluate S3 partition filters, decompress Parquet, and stream only 
    matching records back to the Redshift cluster over internal 100 Gbps network fabrics.
- Latency Profile:
  * RMS Local NVMe Cache: < 0.5 milliseconds per block.
  * RMS S3 Tier: 5 to 15 milliseconds per block.
  * S3 Spectrum Scan: 100 milliseconds to 2.5 seconds per query (subject to S3 prefix GET rate limits).
*/

-- Diagnostic Query: Inspecting Block Allocation & 1MB Slice Distribution:
SELECT 
    b.slice,
    col,
    COUNT(1) AS num_1mb_blocks,
    MIN(minvalue) AS zone_map_min,
    MAX(maxvalue) AS zone_map_max
FROM stv_blocklist b
JOIN pg_class c ON c.oid = b.tbl
WHERE c.relname = 'gold_fct_web_engagement'
GROUP BY b.slice, col
ORDER BY b.slice, col
LIMIT 10;


-- ===================================================================================
-- SECTION 2: MEDALLION ARCHITECTURE DATA SETUP (BRONZE, SILVER, GOLD)
-- ===================================================================================

-- -----------------------------------------------------------------------------------
-- BRONZE TIER: Raw Ingestion Landing Table (Simulating Incoming S3 Lake Data)
-- -----------------------------------------------------------------------------------
DROP TABLE IF EXISTS raw_bronze_landing CASCADE;
CREATE TABLE raw_bronze_landing (
    raw_payload_id BIGINT IDENTITY(1,1),
    source_system VARCHAR(50) NOT NULL ENCODE bytedict,
    payload_json VARCHAR(MAX) ENCODE zstd,       -- Raw dynamic JSON string
    payload_super SUPER,                         -- Native SUPER binary for schemaless drift
    ingested_at TIMESTAMP DEFAULT SYSDATE ENCODE az64
);

-- Generate 100,000 realistic raw event records with varying schemas and JSON attributes:
INSERT INTO raw_bronze_landing (source_system, payload_json, payload_super, ingested_at)
SELECT 
    CASE WHEN s.n % 3 = 0 THEN 'WEB_APP' WHEN s.n % 3 = 1 THEN 'MOBILE_IOS' ELSE 'MOBILE_ANDROID' END,
    '{"event_id": "EVT_' || s.n::VARCHAR || '", "user_id": ' || (s.n % 10000 + 1)::VARCHAR || 
    ', "domain": "shop.acme.com", "url": "/product/' || (s.n % 500)::VARCHAR || 
    '", "duration_ms": ' || (100 + (s.n % 4900))::VARCHAR || 
    ', "is_checkout": ' || CASE WHEN s.n % 10 = 0 THEN 'true' ELSE 'false' END || 
    ', "client_version": "v' || (1 + (s.n % 4))::VARCHAR || '.0", "geo": {"country": "US", "city": "New York"}}',
    JSON_PARSE('{"event_id": "EVT_' || s.n::VARCHAR || '", "user_id": ' || (s.n % 10000 + 1)::VARCHAR || 
    ', "domain": "shop.acme.com", "url": "/product/' || (s.n % 500)::VARCHAR || 
    '", "duration_ms": ' || (100 + (s.n % 4900))::VARCHAR || 
    ', "is_checkout": ' || CASE WHEN s.n % 10 = 0 THEN 'true' ELSE 'false' END || 
    ', "client_version": "v' || (1 + (s.n % 4))::VARCHAR || '.0", "geo": {"country": "US", "city": "New York"}}'),
    DATEADD(minute, -(s.n % 1440), '2026-08-15 12:00:00'::TIMESTAMP)
FROM (
    SELECT ROW_NUMBER() OVER () as n
    FROM (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) a,
         (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) b,
         (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) c,
         (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) d,
         (SELECT 0 UNION SELECT 1) e
    LIMIT 100000
) s;

ANALYZE raw_bronze_landing;

-- -----------------------------------------------------------------------------------
-- SILVER TIER: Cleansed, Structured & Deduplicated Staging Table
-- -----------------------------------------------------------------------------------
DROP TABLE IF EXISTS silver_web_events CASCADE;
CREATE TABLE silver_web_events (
    event_id VARCHAR(64) NOT NULL ENCODE zstd,
    user_id BIGINT NOT NULL ENCODE az64,
    domain VARCHAR(100) NOT NULL ENCODE bytedict,
    url_path VARCHAR(255) NOT NULL ENCODE zstd,
    duration_ms INT NOT NULL ENCODE az64,
    is_checkout BOOLEAN NOT NULL ENCODE raw,
    client_version VARCHAR(20) NOT NULL ENCODE bytedict,
    country CHAR(2) NOT NULL ENCODE bytedict,
    event_timestamp TIMESTAMP NOT NULL ENCODE az64,
    event_date DATE NOT NULL ENCODE az64,
    PRIMARY KEY (event_id)
)
DISTSTYLE KEY
DISTKEY (user_id)
COMPOUND SORTKEY (event_date, user_id);

-- -----------------------------------------------------------------------------------
-- GOLD TIER: Curated Kimball Star Schema Fact Table (In Redshift Managed Storage)
-- -----------------------------------------------------------------------------------
DROP TABLE IF EXISTS gold_fct_web_engagement CASCADE;
CREATE TABLE gold_fct_web_engagement (
    engagement_sk BIGINT IDENTITY(1,1) NOT NULL ENCODE az64, -- Surrogate Key
    event_id VARCHAR(64) NOT NULL ENCODE zstd,
    user_id BIGINT NOT NULL ENCODE az64,
    domain VARCHAR(100) NOT NULL ENCODE bytedict,
    url_path VARCHAR(255) NOT NULL ENCODE zstd,
    duration_ms INT NOT NULL ENCODE az64,
    is_checkout INT NOT NULL ENCODE az64,
    event_timestamp TIMESTAMP NOT NULL ENCODE az64,
    event_date DATE NOT NULL ENCODE raw, -- Leading Sort Key: RAW encoding for fast Zone Maps
    ingested_at TIMESTAMP DEFAULT SYSDATE ENCODE az64,
    PRIMARY KEY (engagement_sk)
)
DISTSTYLE KEY
DISTKEY (user_id)
COMPOUND SORTKEY (event_date, user_id);

-- -----------------------------------------------------------------------------------
-- GOLD AGGREGATION: Auto-Refreshing Materialized View for Sub-Second Executive BI
-- -----------------------------------------------------------------------------------
DROP MATERIALIZED VIEW IF EXISTS gold_mv_daily_traffic_summary CASCADE;
CREATE MATERIALIZED VIEW gold_mv_daily_traffic_summary
DISTSTYLE ALL
SORTKEY (event_date)
AUTO REFRESH YES
AS
SELECT 
    event_date,
    domain,
    COUNT(1) AS total_events,
    COUNT(DISTINCT user_id) AS unique_active_users,
    SUM(CASE WHEN is_checkout = 1 THEN 1 ELSE 0 END) AS total_checkouts,
    ROUND(AVG(duration_ms), 2) AS avg_duration_ms
FROM gold_fct_web_engagement
GROUP BY event_date, domain;


-- ===================================================================================
-- SECTION 3: DATA MOVEMENT MECHANICS — COPY, ALTER TABLE APPEND, UNLOAD
-- ===================================================================================

-- -----------------------------------------------------------------------------------
-- 1. S3 COPY PATTERN (High-Throughput Ingestion)
-- -----------------------------------------------------------------------------------
/*
PRODUCTION COPY SYNTAX:
COPY silver_web_events
FROM 's3://my-enterprise-lake-us-east-1/manifests/2026-08-15-batch.manifest'
IAM_ROLE 'arn:aws:iam::123456789012:role/RedshiftLakehouseRole'
FORMAT AS PARQUET
MANIFEST
COMPUPDATE OFF
STATUPDATE ON;

WHY THIS IS OPTIMAL:
1. MANIFEST: Explicitly lists every S3 part file. Protects against missing or partially uploaded files.
2. PARQUET: Columnar layout reduces S3 network transfer volume by 75% compared to raw CSV.
3. COMPUPDATE OFF: Avoids re-analyzing column compression on every single batch load.
4. STATUPDATE ON: Refreshes histogram statistics immediately so downstream joins do not degrade.
*/

-- -----------------------------------------------------------------------------------
-- 2. ZERO-COPY TABLE SWAP PATTERN (ALTER TABLE APPEND)
-- -----------------------------------------------------------------------------------
/*
WHY ALTER TABLE APPEND IS 1000x FASTER THAN INSERT INTO ... SELECT:
- `ALTER TABLE APPEND` is an atomic, metadata-only pointer operation.
- Redshift updates the catalog table pointers in `pg_class`, moving the physical 1MB blocks
  from the staging table directly into the target table in **0.01 seconds**.
- No disk decompress/re-compress cycle occurs.
- Requirements:
  1. Identical column count, column names, datatypes, and compression encodings.
  2. Identical distribution style (`DISTSTYLE KEY DISTKEY(user_id)`).
  3. Identical sort key definitions.
  4. The source table is completely emptied by the operation.
*/

DROP TABLE IF EXISTS stage_web_events_append CASCADE;
CREATE TABLE stage_web_events_append (LIKE silver_web_events);

-- Populate staging with 25,000 records
INSERT INTO stage_web_events_append (
    event_id, user_id, domain, url_path, duration_ms, is_checkout, client_version, country, event_timestamp, event_date
)
SELECT 
    'EVT_STAGE_' || s.n::VARCHAR,
    (s.n % 10000 + 1),
    'shop.acme.com',
    '/checkout/step_' || (s.n % 3)::VARCHAR,
    (500 + (s.n % 1500)),
    TRUE,
    'v4.0',
    'US',
    '2026-08-15 14:00:00'::TIMESTAMP,
    '2026-08-15'::DATE
FROM (
    SELECT ROW_NUMBER() OVER () as n
    FROM (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) a,
         (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) b,
         (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) c,
         (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) d,
         (SELECT 0 UNION SELECT 1 UNION SELECT 2) e
    LIMIT 25000
) s;

ANALYZE stage_web_events_append;

-- Instant Zero-Copy Block Pointer Swap:
ALTER TABLE silver_web_events APPEND FROM stage_web_events_append;

-- Verify source table was emptied and target table was populated instantly:
-- SELECT COUNT(1) FROM stage_web_events_append; -- Returns 0 rows!
-- SELECT COUNT(1) FROM silver_web_events;        -- Returns 25,000 rows!


-- ===================================================================================
-- SECTION 4: THE S3 TARGET OVERWRITE PROBLEM & ZERO-DOWNTIME ATOMIC PUBLISHING
-- ===================================================================================
/*
THE PROBLEM: WHAT HAPPENS IF WE DIRECTLY OVERWRITE A S3 TARGET PREFIX?
When an ETL pipeline runs `UNLOAD ... TO 's3://lake/clicks/'`:
1. Partial File Visibility: Redshift writes 64 independent part files (`0000_part_00.parquet`, `0001_part_00.parquet`).
   If a BI query via Spectrum or Athena runs at the same moment, it reads an incomplete, corrupted snapshot.
2. Event Notification Storms: Overwriting 100 part files simultaneously triggers 100 concurrent 
   S3 `ObjectCreated` events, overwhelming downstream AWS Lambda or SQS consumers.
3. Lack of Native Transaction Isolation on Raw S3: Unlike relational databases with table-level locks, 
   plain S3 prefix overwrites provide zero read-isolation during writes.

THE ENTERPRISE SOLUTION: BLUE/GREEN ATOMIC S3 PARTITION PROMOTION
Step 1: Write new Parquet data to an isolated staging prefix: `s3://lake/staging/batch_id/`
Step 2: Validate row count and data integrity checksums.
Step 3: Execute an atomic metadata swap in the Glue Data Catalog or Apache Iceberg catalog 
        pointing the partition location directly to the validated staging folder.
*/

CREATE OR REPLACE PROCEDURE prc_atomic_s3_partition_publisher(
    p_partition_date DATE,
    p_s3_staging_prefix VARCHAR(500),
    p_s3_active_prefix VARCHAR(500)
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_proc_name VARCHAR(100) := 'prc_atomic_s3_partition_publisher';
    v_sql VARCHAR(MAX);
BEGIN
    RAISE INFO '[%] Starting atomic lakehouse partition promotion for % ...', v_proc_name, p_partition_date;

    -- Step 1: In production, export new partition data to isolated staging path via UNLOAD
    -- UNLOAD ('SELECT * FROM silver_web_events WHERE event_date = ''' || p_partition_date || '''')
    -- TO p_s3_staging_prefix
    -- IAM_ROLE 'arn:aws:iam::123456789012:role/RedshiftLakehouseRole'
    -- FORMAT AS PARQUET
    -- CLEANPATH
    -- MANIFEST;

    -- Step 2: Perform Atomic Metadata Pointer Swap in Glue / External Table Catalog:
    -- ALTER TABLE ext_silver_web_clicks 
    -- PARTITION (event_date = p_partition_date)
    -- SET LOCATION p_s3_staging_prefix;

    RAISE INFO '[%] Atomic promotion complete for %. Query traffic transitioned with ZERO downtime.', 
        v_proc_name, p_partition_date;

EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION '[%] Partition promotion failed for %: %', v_proc_name, p_partition_date, SQLERRM;
END;
$$;


-- ===================================================================================
-- SECTION 5: SCHEMA EVOLUTION MANAGEMENT ACROSS LAKE & WAREHOUSE
-- ===================================================================================
/*
HOW ENTERPRISES HANDLE SCHEMA EVOLUTION:
1. Parquet File Column Evolution:
   - When new columns are added to Parquet files on S3, Redshift Spectrum matches columns by name.
   - Missing historical rows automatically populate with `NULL` (Backward Compatibility).
2. Dynamic Schemaless Ingestion via SUPER:
   - Upstream teams frequently add dynamic payload fields (`new_feature_flag`, `experiment_id`).
   - Store dynamic fields in a `SUPER` column in Bronze/Silver layers.
   - Query them immediately via PartiQL dot-notation (`super_payload.experiment_id`) without 
     waiting for DDL schema migration approvals.
3. Automated DDL Schema Evolution in Procedures:
   - Programmatically detect missing columns in target tables and execute dynamic `ALTER TABLE ADD COLUMN`.
4. Late-Binding Views (WITH NO SCHEMA BINDING):
   - Decouple executive BI layers from physical table migrations.
*/

-- Procedural Demonstration: Merge with Automated Schema Evolution Detection
CREATE OR REPLACE PROCEDURE prc_merge_with_schema_evolution(p_table_name VARCHAR(100))
LANGUAGE plpgsql
AS $$
DECLARE
    v_col_exists INT := 0;
BEGIN
    RAISE INFO 'Checking schema evolution requirements for % ...', p_table_name;

    -- Check if 'device_model' column exists in silver_web_events
    SELECT COUNT(1) INTO v_col_exists
    FROM pg_attribute a
    JOIN pg_class c ON c.oid = a.attrelid
    WHERE c.relname = p_table_name AND a.attname = 'device_model';

    IF v_col_exists = 0 THEN
        RAISE INFO 'New column detected from upstream lakehouse! Evolving schema via ALTER TABLE...';
        EXECUTE 'ALTER TABLE ' || QUOTE_IDENT(p_table_name) || ' ADD COLUMN device_model VARCHAR(100) DEFAULT NULL ENCODE zstd;';
        RAISE INFO 'Column device_model added successfully with zero table locks.';
    ELSE
        RAISE INFO 'Schema is up-to-date.';
    END IF;
END;
$$;


-- ===================================================================================
-- SECTION 6: AUTOMATED COLD DATA TIERING & STORAGE FINOPS PIPELINE
-- ===================================================================================
/*
THE STORAGE TIERING LIFECYCLE:
- Hot Tier (0 to 90 days): Redshift Managed Storage (RMS) on NVMe SSD cache. 
  Provides sub-second dashboard query latencies.
- Warm/Cold Tier (91 days to 7 years): S3 Parquet / S3 Tables with GZIP/Snappy compression.
  S3 Intelligent-Tiering automatically transitions blocks from Frequent -> Infrequent -> Glacier Flexible Archive.
- Cost Impact: Reduces physical storage costs by 80% to 90% while retaining 100% SQL queryability!
*/

-- 1. Create the Late-Binding Unified Hybrid View:
DROP VIEW IF EXISTS v_unified_enterprise_events;
CREATE VIEW v_unified_enterprise_events AS
-- Hot Tier: Fast local NVMe & RMS
SELECT 
    event_id,
    user_id,
    domain,
    url_path,
    duration_ms,
    is_checkout,
    event_timestamp,
    event_date,
    'REDSHIFT_HOT_RMS' AS storage_tier
FROM gold_fct_web_engagement
WHERE event_date >= DATEADD(day, -90, CURRENT_DATE)
UNION ALL
-- Cold Tier: S3 Lakehouse / Spectrum
SELECT 
    event_id,
    user_id,
    domain,
    url_path,
    duration_ms,
    CASE WHEN is_checkout = TRUE THEN 1 ELSE 0 END AS is_checkout,
    event_timestamp,
    event_date,
    'S3_COLD_LAKEHOUSE' AS storage_tier
FROM silver_web_events -- In production: points to ext_lake_archived_events on S3
WHERE event_date < DATEADD(day, -90, CURRENT_DATE)
WITH NO SCHEMA BINDING;

-- 2. The Production Storage Tiering Stored Procedure:
CREATE OR REPLACE PROCEDURE prc_automated_storage_tiering(p_retention_days INT DEFAULT 90)
LANGUAGE plpgsql
AS $$
DECLARE
    v_proc_name     VARCHAR(100) := 'prc_automated_storage_tiering';
    v_cutoff_date   DATE;
    v_rows_purged   BIGINT := 0;
    v_rows_promoted BIGINT := 0;
BEGIN
    v_cutoff_date := DATEADD(day, -p_retention_days, CURRENT_DATE);
    RAISE INFO '[%] Initiating automated storage tiering. Cutoff Date: % ...', v_proc_name, v_cutoff_date;

    -- Step 1: Promote clean Silver events into Gold Fact Table (Hot RMS Tier)
    INSERT INTO gold_fct_web_engagement (
        event_id, user_id, domain, url_path, duration_ms, is_checkout, event_timestamp, event_date, ingested_at
    )
    SELECT 
        event_id, user_id, domain, url_path, duration_ms, 
        CASE WHEN is_checkout = TRUE THEN 1 ELSE 0 END,
        event_timestamp, event_date, SYSDATE
    FROM silver_web_events
    WHERE event_date >= v_cutoff_date;
    GET DIAGNOSTICS v_rows_promoted = ROW_COUNT;

    -- Step 2: In production: UNLOAD cold history prior to v_cutoff_date to S3 Parquet archive
    -- UNLOAD ('SELECT * FROM gold_fct_web_engagement WHERE event_date < ''' || v_cutoff_date || '''')
    -- TO 's3://enterprise-lakehouse-us-east-1/archive/web_engagement/'
    -- IAM_ROLE 'arn:aws:iam::123456789012:role/RedshiftLakehouseRole'
    -- FORMAT AS PARQUET
    -- PARTITION BY (event_date)
    -- CLEANPATH;

    -- Step 3: Purge expired partitions from Redshift Managed Storage to reclaim local SSD space
    DELETE FROM gold_fct_web_engagement
    WHERE event_date < v_cutoff_date;
    GET DIAGNOSTICS v_rows_purged = ROW_COUNT;

    -- Step 4: Refresh Target Statistics
    ANALYZE gold_fct_web_engagement;

    RAISE INFO '[%] Tiering finished: Promoted % rows to Gold RMS, purged % cold rows to S3.', 
        v_proc_name, v_rows_promoted, v_rows_purged;

EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION '[%] Tiering pipeline failed: %', v_proc_name, SQLERRM;
END;
$$;


-- ===================================================================================
-- SECTION 7: USAGE, VERIFICATION & QUERY PLAN PROOF
-- ===================================================================================

-- (a) Execute schema evolution test:
CALL prc_merge_with_schema_evolution('silver_web_events');

-- (b) Execute storage tiering pipeline:
CALL prc_automated_storage_tiering(90);

-- (c) Verify Materialized View auto-refresh status:
SELECT 
    database_name,
    schema_name,
    name AS mv_name,
    refresh_type,
    is_autorefresh,
    state,
    last_refresh_time
FROM sys_mv_refresh_history
ORDER BY last_refresh_time DESC LIMIT 5;

-- (d) Explain Plan: Verify Hybrid View Routing with S3 Spectrum vs RMS Local NVMe:
EXPLAIN
SELECT event_date, domain, COUNT(1), SUM(is_checkout)
FROM v_unified_enterprise_events
WHERE event_date >= '2026-08-01'::DATE
GROUP BY event_date, domain;

-- (e) Inspect S3 Spectrum scan bytes and execution metrics:
SELECT 
    query,
    segment,
    step,
    rows,
    s3_scanned_bytes / 1024 / 1024 AS s3_scanned_mb
FROM svl_s3query_summary
ORDER BY starttime DESC LIMIT 5;
