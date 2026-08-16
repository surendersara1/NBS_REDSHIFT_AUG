/*
======================================================================================
MODULE 69: ZERO-ETL INTEGRATIONS — AURORA, DYNAMODB & BEYOND
======================================================================================
MAPPED BEST PRACTICES (from PROCEDURE_OPTIMIZATION_BEST_PRACTICES_MASTER_FILE.md):
- Practice 68: "Bulk-load with COPY from S3" — Zero-ETL replaces COPY for certain
  source systems by providing automatic, continuous replication.
- Practice 39: "Prefer incremental processing over full-history rebuilds."
- Practice 91: "Medallion layering" — Zero-ETL feeds Bronze automatically.
- Practice 95: "Orchestrate dependencies with a workflow tool" — Zero-ETL removes
  the need for orchestration on the ingestion layer entirely.

TARGET AUDIENCE: Data Platform Engineers, Migration Architects
BUSINESS SCENARIO:
A SaaS company runs its transactional system on Aurora PostgreSQL. Currently, a complex
Airflow DAG with 47 tasks runs nightly to:
  1. pg_dump 200 tables from Aurora
  2. Upload CSV files to S3 (45 minutes)
  3. COPY 200 tables into Redshift staging (2 hours)
  4. Run MERGE for each table (1 hour)
Total pipeline latency: 4+ hours. If any step fails, the entire pipeline reruns.

With Zero-ETL: Aurora automatically replicates changes to Redshift in near-real-time.
No Airflow DAG, no S3 staging, no COPY, no MERGE. Changes appear in seconds.

ARCHITECTURE:
┌──────────────────────────────────────────────────────────────────────────────┐
│                    ZERO-ETL INTEGRATION FLOW                                 │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌──────────────────┐     Zero-ETL Replication      ┌──────────────────┐   │
│  │  AURORA           │  ──────────────────────────▶  │  REDSHIFT         │   │
│  │  PostgreSQL /     │    (CDC-based, automatic)     │  Serverless or    │   │
│  │  MySQL            │                               │  Provisioned      │   │
│  │                   │    • Captures WAL/binlog       │                   │   │
│  │  200 tables       │    • Applies changes in       │  200 tables auto- │   │
│  │  OLTP workload    │      near-real-time           │  replicated as    │   │
│  │                   │    • No user code required     │  read-only tables │   │
│  └──────────────────┘                               └────────┬─────────┘   │
│                                                               │              │
│  ┌──────────────────┐     Zero-ETL Replication              │              │
│  │  DYNAMODB         │  ──────────────────────────▶          │              │
│  │  NoSQL tables     │    (DynamoDB Streams based)           │              │
│  │                   │    • Item-level changes               │              │
│  └──────────────────┘    • Near-real-time                    │              │
│                                                               │              │
│                                                               ▼              │
│                                                    ┌──────────────────┐     │
│                                                    │  MEDALLION ARCH  │     │
│                                                    │  Bronze: zero-ETL│     │
│                                                    │  Silver: ELT SQL │     │
│                                                    │  Gold: Star Schema│    │
│                                                    └──────────────────┘     │
│                                                                              │
│  WHAT ZERO-ETL REPLACES:                                                    │
│  ┌─────────────┐  ┌─────────┐  ┌──────────┐  ┌─────────┐  ┌──────────┐   │
│  │ pg_dump /   │→ │ S3 Upload│→ │ COPY into│→ │ MERGE / │→ │ Gold     │   │
│  │ mysqldump   │  │ (Airflow)│  │ staging  │  │ Upsert  │  │ tables   │   │
│  └─────────────┘  └─────────┘  └──────────┘  └─────────┘  └──────────┘   │
│  ↑ ALL OF THIS IS ELIMINATED BY ZERO-ETL ↑                                │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘

======================================================================================
*/

-- ============================================================================
-- SECTION 1: AURORA POSTGRESQL ZERO-ETL SETUP
-- ============================================================================
-- IMPLEMENTS: Best Practice #39 (Incremental), #68 (Loading)

-- Prerequisites (AWS Console / CLI — not SQL):
-- 1. Aurora PostgreSQL 15.4+ or MySQL 3.05.0+ cluster
-- 2. Redshift Serverless namespace or Provisioned RA3 cluster
-- 3. Both must be in the same AWS account and region (cross-account coming)

-- Step 1: Enable enhanced binlog on Aurora MySQL (or logical replication on PG)
-- Aurora PostgreSQL:
--   Set parameter group: rds.logical_replication = 1
--   Reboot the Aurora cluster

-- Step 2: Create the zero-ETL integration (AWS Console or CLI):
-- aws rds create-integration \
--     --integration-name aurora-to-redshift \
--     --source-arn <AURORA_CLUSTER_ARN> \
--     --target-arn <REDSHIFT_NAMESPACE_ARN> \
--     --tags Key=Environment,Value=Production

-- Step 3: Create a database in Redshift from the integration
CREATE DATABASE aurora_source
FROM INTEGRATION 'aurora-to-redshift';

-- Step 4: Query the replicated tables immediately
-- Tables appear automatically with the same schema as Aurora:
SELECT
    table_schema,
    table_name,
    table_type
FROM aurora_source.information_schema.tables
WHERE table_schema NOT IN ('pg_catalog', 'information_schema')
ORDER BY table_schema, table_name;

-- Query replicated data (read-only):
SELECT
    customer_id,
    customer_name,
    email,
    created_at
FROM aurora_source.public.customers
WHERE created_at >= DATEADD(day, -1, CURRENT_DATE)
LIMIT 100;

-- NOTE: Zero-ETL tables are READ-ONLY in Redshift.
-- You CANNOT INSERT/UPDATE/DELETE on them. They are Bronze-layer data.


-- ============================================================================
-- SECTION 2: BUILDING SILVER/GOLD LAYERS ON TOP OF ZERO-ETL
-- ============================================================================
-- IMPLEMENTS: Best Practice #91 (Medallion layering)

-- Zero-ETL gives you Bronze for free. You still need ELT for Silver and Gold.
-- Use Materialized Views or procedures to transform zero-ETL data.

-- Silver layer: Cleansed, typed, deduplicated
CREATE MATERIALIZED VIEW silver.mv_customers
AUTO REFRESH YES
AS
SELECT
    customer_id,
    TRIM(customer_name)                    AS customer_name,
    LOWER(TRIM(email))                     AS email_normalized,
    created_at,
    -- Deduplicate: zero-ETL can briefly have duplicates during failover
    ROW_NUMBER() OVER (
        PARTITION BY customer_id
        ORDER BY created_at DESC
    ) AS rn
FROM aurora_source.public.customers
WHERE customer_id IS NOT NULL;

-- Gold layer: Star schema dimension from Silver
CREATE OR REPLACE PROCEDURE etl.sp_load_dim_customer_from_zero_etl()
LANGUAGE plpgsql
AS $$
DECLARE
    v_merged INT;
BEGIN
    MERGE INTO gold.dim_customer AS tgt
    USING (
        SELECT customer_id, customer_name, email_normalized, created_at
        FROM silver.mv_customers
        WHERE rn = 1
    ) AS src
    ON tgt.customer_id = src.customer_id
    WHEN MATCHED AND (
        tgt.customer_name <> src.customer_name OR
        tgt.email         <> src.email_normalized
    ) THEN UPDATE SET
        customer_name = src.customer_name,
        email         = src.email_normalized,
        updated_at    = SYSDATE
    WHEN NOT MATCHED THEN INSERT (
        customer_id, customer_name, email, created_at, updated_at
    ) VALUES (
        src.customer_id, src.customer_name, src.email_normalized,
        src.created_at, SYSDATE
    );

    GET DIAGNOSTICS v_merged = ROW_COUNT;
    RAISE INFO 'sp_load_dim_customer_from_zero_etl: Merged % rows.', v_merged;
END;
$$;


-- ============================================================================
-- SECTION 3: DYNAMODB ZERO-ETL
-- ============================================================================

-- DynamoDB zero-ETL exports DynamoDB table items to Redshift continuously.
-- Items are mapped to a SUPER column (because DynamoDB is schema-less).

-- Setup (AWS Console / CLI):
-- aws dynamodb create-table-export \
--     --table-arn <DYNAMODB_TABLE_ARN> \
--     --s3-bucket <CURATED_BUCKET> \
--     --export-type INCREMENTAL_EXPORT

-- In Redshift, create a database from the DynamoDB integration:
-- CREATE DATABASE dynamo_source FROM INTEGRATION 'dynamodb-to-redshift';

-- Query DynamoDB items (SUPER type — use PartiQL syntax):
-- SELECT
--     item.user_id.S          AS user_id,
--     item.session_start.N    AS session_start_epoch,
--     item.page_views.N       AS page_views,
--     item.device.M.type.S    AS device_type
-- FROM dynamo_source.public.UserSessions;

-- NOTE: DynamoDB's schema-less nature means you use SUPER/PartiQL
-- to extract typed columns, similar to Module 40.


-- ============================================================================
-- SECTION 4: MONITORING ZERO-ETL INTEGRATIONS
-- ============================================================================
-- IMPLEMENTS: Best Practices #97-101 (Observability)

-- Check integration status:
SELECT
    integration_name,
    source_arn,
    target_arn,
    status,                     -- 'active', 'creating', 'deleting', 'failed'
    create_time,
    errors
FROM SVV_INTEGRATION;

-- Monitor replication lag:
SELECT
    integration_name,
    table_schema,
    table_name,
    replication_state,          -- 'synced', 'replicating', 'error'
    last_replication_time,
    DATEDIFF(second, last_replication_time, SYSDATE) AS lag_seconds
FROM SVV_INTEGRATION_TABLE_STATE
WHERE replication_state <> 'synced'
ORDER BY lag_seconds DESC;

-- Check for replication errors:
SELECT
    integration_name,
    table_name,
    error_message,
    error_time
FROM SYS_INTEGRATION_TABLE_STATE_CHANGE_HISTORY
WHERE error_message IS NOT NULL
  AND error_time >= DATEADD(day, -1, SYSDATE)
ORDER BY error_time DESC;


-- ============================================================================
-- SECTION 5: ANTI-PATTERN — BUILDING WHAT ZERO-ETL GIVES YOU FOR FREE
-- ============================================================================

-- ❌ THE BAD WAY: 47-task Airflow DAG with pg_dump → S3 → COPY → MERGE
-- Problems:
--   1. 4+ hour latency between Aurora change and Redshift availability
--   2. 47 DAG tasks to maintain, monitor, and debug
--   3. COPY failures require retry logic, dead-letter queues, alerting
--   4. Schema drift: Aurora adds a column → COPY breaks → 3 AM PagerDuty
--   5. Full reload fallback: if incremental fails, reload 200 tables = 8 hours
--
-- ✅ THE GOOD WAY: Zero-ETL integration
--   1. Near-real-time replication (seconds, not hours)
--   2. Zero DAG tasks for ingestion — only ELT (Silver/Gold) tasks remain
--   3. Automatic retry and error handling by AWS
--   4. Schema changes auto-propagate (new columns appear automatically)
--   5. No S3 intermediate storage costs


-- ============================================================================
-- SECTION 6: WHEN TO USE ZERO-ETL vs. COPY vs. STREAMING INGESTION
-- ============================================================================
/*
┌──────────────────────┬──────────────────┬──────────────────┬──────────────────┐
│ Criteria             │ Zero-ETL         │ COPY from S3     │ Streaming (MV)   │
├──────────────────────┼──────────────────┼──────────────────┼──────────────────┤
│ Source               │ Aurora, DynamoDB │ Any (S3 files)   │ Kinesis, MSK     │
│ Latency              │ Seconds          │ Minutes-hours    │ Seconds          │
│ Schema Management    │ Automatic        │ Manual (DDL)     │ Manual (JSON)    │
│ Orchestration Needed │ None (ingestion) │ Full (Airflow)   │ Minimal          │
│ Transform Control    │ Post-replication │ Pre/Post-load    │ In MV definition │
│ Data Mutability      │ Read-only        │ Read-write       │ Read-only (MV)   │
│ Cross-Account        │ Coming soon      │ Yes              │ Yes              │
│ Best For             │ OLTP → OLAP      │ Data lake files  │ Event streams    │
│ Replaces             │ CDC pipelines    │ N/A              │ Firehose → COPY  │
└──────────────────────┴──────────────────┴──────────────────┴──────────────────┘

RECOMMENDATION:
• OLTP databases (Aurora, RDS) → Zero-ETL
• Data lake files (Parquet on S3) → COPY or Spectrum
• Real-time event streams → Streaming Ingestion (Module 64)
• Legacy databases (Oracle, SQL Server) → DMS to S3 → COPY
*/


-- ============================================================================
-- SECTION 7: LIMITATIONS & GOTCHAS
-- ============================================================================
/*
CURRENT ZERO-ETL LIMITATIONS (as of 2025):
  1. Same AWS account and region required (cross-account coming)
  2. Aurora → Redshift only (not RDS for PostgreSQL/MySQL directly)
  3. Tables with no primary key may have higher replication lag
  4. Large LOB columns (>1MB) may be truncated
  5. DDL changes (DROP TABLE, ALTER TABLE) propagate but may cause brief pauses
  6. Replication lag increases under heavy Aurora write load
  7. Zero-ETL tables are READ-ONLY — no INSERT/UPDATE/DELETE from Redshift
  8. Not all Aurora data types map cleanly (e.g., ENUM, custom types)

MITIGATION:
  • Always define PRIMARY KEYs on Aurora tables for optimal CDC performance
  • Monitor lag via SVV_INTEGRATION_TABLE_STATE (Section 4)
  • Build Silver/Gold layers as local Redshift tables for write access
  • Test schema changes in staging before applying to production Aurora
*/
