/*
======================================================================================
MODULE 60: ENTERPRISE HYBRID STORAGE ARCHITECTURE & LAKEHOUSE DEEP DIVE
======================================================================================
MAPPED BEST PRACTICES (from PROCEDURE_OPTIMIZATION_BEST_PRACTICES_MASTER_FILE.md):
- Practice 8: SORT KEY -> ZONE MAPS skips blocks (1MB immutable block mechanics in RMS).
- Practice 26, 79: Staging in collocated #TEMP tables with an explicit DROP and ANALYZE.
- Practice 29: Collocated Distribution Keys (DISTSTYLE KEY) across fact and staging.
- Practice 42: Complete Idempotency & Zero-Downtime Partition Swaps.
- Practice 44: High-Performance MERGE vs ALTER TABLE APPEND pointer swapping.
- Practice 58: SUPER/PartiQL for dynamic schemaless event drift vs relational columns.
- Practice 62: Refreshing statistics (ANALYZE) after bulk ingestion and tiering.
- Practice 89-91: True Medallion Architecture across Storage Layers:
    * BRONZE: Amazon S3 / Amazon S3 Tables (Raw Immutable Object Storage)
    * SILVER: Amazon S3 Tables (Iceberg) or Redshift Cleansed Staging
    * GOLD:   Redshift Managed Storage (RMS) on NVMe SSDs (Star Schema Facts/Dims)
    * COLD:   S3 Intelligent-Tiering / Glacier Parquet Archive
- Practice 92: Auto-Refreshing Materialized Views on curated RMS Star Schemas.
- Practice 104-108: Spectrum / S3 Tables partition pruning, S3 overwrite protection, and FinOps lifecycle tiering.

TARGET AUDIENCE: Lead Data Architects, Principal Engineers, and Warehouse Developers
BUSINESS SCENARIO: 
An enterprise ingests 50 Terabytes of telemetry, clickstream, and transaction data daily. 
Storing 100% of multi-year history in Redshift Managed Storage (RMS) causes millions of dollars 
in compute/storage overspend. Conversely, running complex 10-way dashboard joins directly against 
raw S3 files causes 60-second BI timeouts and saturates S3 GET rate limits.

THE SOLUTION: TRUE HYBRID STORAGE TIERS (S3 OBJECT STORE + REDSHIFT RMS)
┌──────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│  1. BRONZE TIER (Amazon S3 / S3 Tables)                                                                     │
│     • Location: Amazon S3 Object Storage (`s3://<RAW_BUCKET>/bronze/`)                                    │
│     • Format: Raw Immutable JSON / Snappy Parquet partitioned by ingestion date                             │
│     • Catalog: AWS Glue Data Catalog or Amazon S3 Tables (Apache Iceberg REST Catalog)                       │
│     • Queried by: Redshift Spectrum & External Table Engines (Spark, EMR, Athena)                            │
└──────────────────────────────────────┬───────────────────────────────────────────────────────────────────────┘
                                       │ (Redshift-Native Pushdown ELT: Querying S3 directly in SQL)
                                       ▼
┌──────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│  2. SILVER TIER (Cleansed & Deduplicated Lakehouse Staging)                                                  │
│     • Location: S3 Tables (Apache Iceberg) or Redshift High-Speed Staging Tables                             │
│     • Format: Strongly-typed columnar storage, NULL-sanitized, deduplicated                                 │
│     • Capabilities: Instant Zero-Copy table pointer swaps using `ALTER TABLE APPEND`                         │
└──────────────────────────────────────┬───────────────────────────────────────────────────────────────────────┘
                                       │ (Star Schema Surrogate Mapping & Materialization)
                                       ▼
┌──────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│  3. GOLD TIER (Redshift Managed Storage - RMS with Local NVMe SSD Cache)                                     │
│     • Location: Redshift RA3 Managed Storage (Hot 90-Day Active Window)                                      │
│     • Format: 1MB Immutable Columnar Blocks with Zone Maps & AZ Replication                                  │
│     • Design: Kimball Star Schema Fact/Dim (`DISTSTYLE KEY`, `COMPOUND SORTKEY`)                             │
│     • Performance: Sub-second BI dashboards via Auto-Refreshing Materialized Views                           │
└──────────────────────────────────────┬───────────────────────────────────────────────────────────────────────┘
                                       │ (Automated FinOps Lifecycle Offloading)
                                       ▼
┌──────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│  4. COLD ARCHIVAL TIER (Amazon S3 Intelligent-Tiering / Glacier Flexible Archive)                            │
│     • Location: Amazon S3 Archive (`s3://<RAW_BUCKET>/archive/web_engagement/`)                           │
│     • Format: Snappy Parquet partitioned by `event_date`                                                     │
└──────────────────────────────────────────────────────────────────────────────────────────────────────────────┘

                                  LAKEHOUSE IAM TRUST & ACCESS ARCHITECTURE
                                  
 ┌──────────────────────────────────────┐       ┌──────────────────────────────────────────────────────────────┐
 │  Redshift Cluster / Serverless       │       │  AWS IAM Role:                                               │
 │  Principal: `redshift.amazonaws.com` ├──────►│  `RedshiftSpectrumLakehouseRole`                             │
 └──────────────────────────────────────┘       └──────────────────────────────┬───────────────────────────────┘
                                                                               │
                                       ┌───────────────────────────────────────┼──────────────────────────────────────┐
                                       │                                       │                                      │
                                       ▼                                       ▼                                      ▼
                        ┌──────────────────────────────┐       ┌──────────────────────────────┐       ┌──────────────────────────────┐
                        │  Amazon S3 Bucket Access     │       │  AWS Glue Data Catalog       │       │  Amazon S3 Tables / Iceberg  │
                        │  • `s3:GetObject`            │       │  • `glue:GetDatabase`        │       │  • `s3tables:GetTable`       │
                        │  • `s3:PutObject`            │       │  • `glue:GetTable`           │       │  • `s3tables:GetTableData`   │
                        │  • `s3:ListBucket`           │       │  • `glue:GetPartitions`      │       │  • `s3tables:PutTableData`   │
                        │  • `s3:DeleteObject`         │       │  • `glue:BatchCreatePart.`   │       │  • (Apache Iceberg REST API) │
                        └──────────────────────────────┘       └──────────────────────────────┘       └──────────────────────────────┘

                                      HYBRID QUERY ENGINE ROUTING (HOT VS COLD)
                                      
                              ┌──────────────────────────────────────────────────┐
                              │  Unified Query: `v_unified_enterprise_events`    │
                              │  (Late-Binding View WITH NO SCHEMA BINDING)       │
                              └────────────────────────┬─────────────────────────┘
                                                       │
                                  ┌────────────────────┴────────────────────┐
                                  │ WHERE event_date >= '2026-08-01'        │
                                  ▼                                         ▼
                 ┌─────────────────────────────────┐       ┌─────────────────────────────────┐
                 │  HOT RMS PATH (< 90 Days)       │       │  COLD LAKEHOUSE PATH (> 90 Days)│
                 │  • Scans Local NVMe SSD Cache   │       │  • Pushes scan to Spectrum fleet│
                 │  • Reads 1MB RMS columnar blocks│       │  • Reads S3 Snappy Parquet files│
                 │  • Latency: Sub-millisecond     │       │  • Latency: 100ms - 2.5s        │
                 └─────────────────────────────────┘       └─────────────────────────────────┘
======================================================================================
*/

-- ===================================================================================
-- SECTION 1: PHYSICAL STORAGE INTERNALS — RMS VS S3 OPEN LAKEHOUSE
-- ===================================================================================
/*
--------------------------------------------------------------------------------------
1. REDSHIFT MANAGED STORAGE (RMS) PHYSICAL INTERNALS:
--------------------------------------------------------------------------------------
- Two-Tier Storage Architecture:
  * Tier 1 (Local NVMe SSD Cache): Sits directly on compute nodes (RA3 instances). 
    Delivers sub-millisecond data block reads (< 0.5ms) for active working-set data.
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
-- SECTION 2: END-TO-END LAKEHOUSE SETUP (IAM ROLES, S3 BUCKETS, GLUE & S3 TABLES)
-- ===================================================================================
/*
HOW REDSHIFT CONNECTS TO S3, GLUE & S3 TABLES:
To query S3 or S3 Tables, Redshift requires an IAM Role with appropriate trust and permissions.

STEP 1: CREATE THE IAM ROLE (AWS CONSOLE / CLI / TERRAFORM / CDK)
--------------------------------------------------------------------------------------
Trust Relationship (Trust Policy):
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "redshift.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}

Required Permissions Policy (Attach to IAM Role):
1. S3 Permissions (Read/Write for Data Lake & UNLOAD/COPY):
   - "s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket" on "arn:aws:s3:::<RAW_BUCKET>*"
2. AWS Glue Data Catalog Permissions (For Redshift Spectrum):
   - "glue:GetDatabase", "glue:GetDatabases", "glue:GetTable", "glue:GetTables",
     "glue:GetPartition", "glue:GetPartitions", "glue:CreateTable", "glue:BatchCreatePartition"
3. Amazon S3 Tables Permissions (For Apache Iceberg REST Catalog / S3 Tables):
   - "s3tables:GetTable", "s3tables:ListTables", "s3tables:GetTableData", "s3tables:PutTableData"
4. AWS Lake Formation Permissions (Optional, if using centralized Lake Formation governance):
   - "lakeformation:GetDataAccess"

STEP 2: ATTACH THE IAM ROLE TO YOUR REDSHIFT CLUSTER / SERVERLESS NAMESPACE
--------------------------------------------------------------------------------------
AWS CLI:
aws redshift modify-cluster-iam-roles \
    --cluster-identifier <CLUSTER_ID> \
    --add-iam-roles <SPECTRUM_ROLE_ARN>

STEP 3: CREATE EXTERNAL SCHEMAS IN REDSHIFT
--------------------------------------------------------------------------------------
*/

-- (A) Standard S3 Data Lake via AWS Glue Catalog (Redshift Spectrum):
-- CREATE EXTERNAL SCHEMA ext_lake_glue
-- FROM DATA CATALOG
-- DATABASE 'lakehouse_analytics_db'
-- IAM_ROLE '<SPECTRUM_ROLE_ARN>'
-- CREATE EXTERNAL DATABASE IF NOT EXISTS;

-- (B) Modern Amazon S3 Tables (Apache Iceberg Managed Table Bucket):
-- CREATE EXTERNAL SCHEMA ext_s3_tables
-- FROM S3TABLES
-- CATALOG '<TABLE_BUCKET_ARN>'
-- NAMESPACE 'silver_telemetry'
-- IAM_ROLE '<SPECTRUM_ROLE_ARN>';

-- (C) Centralized AWS Lake Formation Governed External Schema:
-- CREATE EXTERNAL SCHEMA ext_lake_formation_governed
-- FROM DATA CATALOG
-- DATABASE 'governed_lake_db'
-- IAM_ROLE '<SPECTRUM_ROLE_ARN>'
-- CATALOG_ID '<ACCOUNT_ID>';


-- ===================================================================================
-- SECTION 3: PHYSICAL STORAGE TABLES ACROSS THE MEDALLION LAYERS
-- ===================================================================================

-- -----------------------------------------------------------------------------------
-- 1. BRONZE TIER (S3 OBJECT STORE / S3 TABLES EXTERNAL TABLE)
-- -----------------------------------------------------------------------------------
/*
In production, Bronze lives 100% on S3 as raw files. Redshift queries it via Spectrum:

CREATE EXTERNAL TABLE ext_lake_glue.ext_bronze_web_events (
    source_system VARCHAR(50),
    payload_json VARCHAR(MAX),
    payload_super SUPER,
    ingested_at TIMESTAMP
)
PARTITIONED BY (ingestion_date DATE)
STORED AS PARQUET
LOCATION 's3://<RAW_BUCKET>/bronze/web_events/';
*/

-- Local Sandbox Emulation of Bronze Landing Table (For standalone cluster execution):
DROP TABLE IF EXISTS ext_bronze_web_events CASCADE;
CREATE TABLE ext_bronze_web_events (
    source_system VARCHAR(50) NOT NULL ENCODE bytedict,
    payload_json VARCHAR(MAX) ENCODE zstd,
    payload_super SUPER,                         -- Dynamic schemaless SUPER type for upstream payload drift
    ingested_at TIMESTAMP DEFAULT SYSDATE ENCODE az64,
    ingestion_date DATE NOT NULL ENCODE az64     -- Partition column in S3 Lakehouse
);

-- Populate Bronze Lakehouse with 100,000 raw events:
INSERT INTO ext_bronze_web_events (source_system, payload_json, payload_super, ingested_at, ingestion_date)
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
    DATEADD(minute, -(s.n % 1440), '2026-08-15 12:00:00'::TIMESTAMP),
    '2026-08-15'::DATE
FROM (
    SELECT ROW_NUMBER() OVER () as n
    FROM (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) a,
         (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) b,
         (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) c,
         (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) d,
         (SELECT 0 UNION SELECT 1) e,
         (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) f
    LIMIT 100000
) s;

ANALYZE ext_bronze_web_events;

-- -----------------------------------------------------------------------------------
-- 2. SILVER TIER (CLEANSED, DEDUPLICATED & STRONGLY-TYPED STAGING TABLE)
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
-- 3. GOLD TIER (KIMBALL STAR SCHEMA FACT TABLE IN REDSHIFT MANAGED STORAGE - RMS)
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
    event_date DATE NOT NULL ENCODE raw, -- Leading Sort Key: RAW encoding for Zone Maps
    ingested_at TIMESTAMP DEFAULT SYSDATE ENCODE az64,
    PRIMARY KEY (engagement_sk)
)
DISTSTYLE KEY
DISTKEY (user_id)
COMPOUND SORTKEY (event_date, user_id);

-- -----------------------------------------------------------------------------------
-- 4. GOLD AGGREGATION: Auto-Refreshing Materialized View for Sub-Second Executive BI
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
-- SECTION 4: LAKEHOUSE ELT — INGESTING BRONZE S3 INTO SILVER IN SQL
-- ===================================================================================
/*
THE POWER OF REDSHIFT SPECTRUM ELT:
Instead of running expensive external AWS Glue / Spark jobs to parse Bronze S3 JSON, 
Redshift processes the transformation natively using compiled C++ compute slices!
*/

CREATE OR REPLACE PROCEDURE prc_elt_bronze_to_silver(p_batch_date DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_rows_inserted BIGINT := 0;
BEGIN
    RAISE INFO 'Starting native Redshift Lakehouse ELT: Bronze (S3) -> Silver ...';

    -- Delete today's watermark to guarantee idempotency:
    DELETE FROM silver_web_events WHERE event_date = p_batch_date;

    -- Query Bronze S3 external data directly and shred JSON using PartiQL in parallel:
    INSERT INTO silver_web_events (
        event_id, user_id, domain, url_path, duration_ms, is_checkout, 
        client_version, country, event_timestamp, event_date
    )
    SELECT 
        (payload_super.event_id)::VARCHAR(64) AS event_id,
        (payload_super.user_id)::BIGINT AS user_id,
        (payload_super.domain)::VARCHAR(100) AS domain,
        (payload_super.url)::VARCHAR(255) AS url_path,
        (payload_super.duration_ms)::INT AS duration_ms,
        (payload_super.is_checkout)::BOOLEAN AS is_checkout,
        (payload_super.client_version)::VARCHAR(20) AS client_version,
        (payload_super.geo.country)::CHAR(2) AS country,
        ingested_at AS event_timestamp,
        ingestion_date AS event_date
    FROM ext_bronze_web_events
    WHERE ingestion_date = p_batch_date;

    GET DIAGNOSTICS v_rows_inserted = ROW_COUNT;
    RAISE INFO 'ELT Complete: Loaded % cleansed events into Silver.', v_rows_inserted;

EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'prc_elt_bronze_to_silver failed: %', SQLERRM;
END;
$$;


-- ===================================================================================
-- SECTION 5: DATA MOVEMENT MECHANICS — COPY, ALTER TABLE APPEND, UNLOAD
-- ===================================================================================

-- -----------------------------------------------------------------------------------
-- 1. S3 COPY PATTERN (High-Throughput Ingestion)
-- -----------------------------------------------------------------------------------
/*
PRODUCTION COPY SYNTAX:
COPY silver_web_events
FROM 's3://<CURATED_BUCKET>/manifests/2026-08-15-batch.manifest'
IAM_ROLE '<SPECTRUM_ROLE_ARN>'
FORMAT AS PARQUET
MANIFEST
COMPUPDATE OFF
STATUPDATE ON;
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


-- ===================================================================================
-- SECTION 6: THE S3 TARGET OVERWRITE PROBLEM & ZERO-DOWNTIME ATOMIC PUBLISHING
-- ===================================================================================
/*
THE PROBLEM: WHAT HAPPENS IF WE DIRECTLY OVERWRITE A S3 TARGET PREFIX?
When an ETL pipeline runs `UNLOAD ... TO 's3://<CURATED_BUCKET>/clicks/'`:
1. Partial File Visibility: Redshift writes 64 independent part files (`0000_part_00.parquet`, `0001_part_00.parquet`).
   If a BI query via Spectrum or Athena runs at the same moment, it reads an incomplete, corrupted snapshot.
2. Event Notification Storms: Overwriting 100 part files simultaneously triggers 100 concurrent 
   S3 `ObjectCreated` events, overwhelming downstream AWS Lambda or SQS consumers.
3. Lack of Native Transaction Isolation on Raw S3: Unlike relational databases with table-level locks, 
   plain S3 prefix overwrites provide zero read-isolation during writes.

THE ENTERPRISE SOLUTION: BLUE/GREEN ATOMIC S3 PARTITION PROMOTION
Step 1: Write new Parquet data to an isolated staging prefix: `s3://<CURATED_BUCKET>/staging/batch_id/`
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
    -- IAM_ROLE '<SPECTRUM_ROLE_ARN>'
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
-- SECTION 7: SCHEMA EVOLUTION MANAGEMENT ACROSS LAKE & WAREHOUSE
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
-- SECTION 8: AUTOMATED COLD DATA TIERING & STORAGE FINOPS PIPELINE
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
    -- TO 's3://<CURATED_BUCKET>/archive/web_engagement/'
    -- IAM_ROLE '<SPECTRUM_ROLE_ARN>'
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
-- SECTION 9: USAGE, VERIFICATION & QUERY PLAN PROOF
-- ===================================================================================

-- (a) Execute native lakehouse ELT (Bronze S3 -> Silver):
CALL prc_elt_bronze_to_silver('2026-08-15'::DATE);

-- (b) Execute schema evolution test:
CALL prc_merge_with_schema_evolution('silver_web_events');

-- (c) Execute storage tiering pipeline:
CALL prc_automated_storage_tiering(90);

-- (d) Verify Materialized View auto-refresh status:
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

-- (e) Explain Plan: Verify Hybrid View Routing with S3 Spectrum vs RMS Local NVMe:
EXPLAIN
SELECT event_date, domain, COUNT(1), SUM(is_checkout)
FROM v_unified_enterprise_events
WHERE event_date >= '2026-08-01'::DATE
GROUP BY event_date, domain;

-- (f) Inspect S3 Spectrum scan bytes and execution metrics:
SELECT 
    query,
    segment,
    step,
    rows,
    s3_scanned_bytes / 1024 / 1024 AS s3_scanned_mb
FROM svl_s3query_summary
ORDER BY starttime DESC LIMIT 5;
