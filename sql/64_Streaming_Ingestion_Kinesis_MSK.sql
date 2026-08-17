/*
======================================================================================
MODULE 64: STREAMING INGESTION — KINESIS DATA STREAMS & AMAZON MSK DEEP DIVE
======================================================================================
MAPPED BEST PRACTICES (from PROCEDURE_OPTIMIZATION_BEST_PRACTICES_MASTER_FILE.md):
- Practice 39-40: Incremental processing with real-time watermarks (stream offsets).
- Practice 42-43: Idempotent consumption — Kinesis sequence numbers as dedup keys.
- Practice 68: Bulk-load with COPY from S3 is the batch pattern; streaming is the
  real-time complement that replaces it for sub-minute latency requirements.
- Practice 91: Medallion layering — streaming feeds Bronze, ELT promotes to Silver/Gold.
- Practice 62: ANALYZE after streaming MV refresh to keep planner stats current.

TARGET AUDIENCE: Real-Time Data Engineers, IoT Platform Architects
BUSINESS SCENARIO:
An e-commerce platform processes 500K click events per second during flash sales.
The old pattern: Kinesis → Firehose → S3 (micro-batch every 60s) → COPY into Redshift.
This creates a 2-5 minute data lag for real-time dashboards showing live conversion rates.

THE NEW PATTERN: Native streaming ingestion reads directly from Kinesis into a
Materialized View, giving sub-10-second freshness with zero Lambda/Firehose glue code.

ARCHITECTURE:
┌─────────────────────┐   ┌─────────────────────────┐   ┌──────────────────────┐
│   Web Application   │   │  IoT Device Fleet       │   │  Mobile App Events   │
│   (Click Events)    │   │  (Sensor Telemetry)     │   │  (Purchase Events)   │
└────────┬────────────┘   └────────────┬────────────┘   └──────────┬───────────┘
         │                             │                           │
         ▼                             ▼                           ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│                    AMAZON KINESIS DATA STREAMS                               │
│    Stream: clickstream-events   (4 shards, 4MB/s write, 8MB/s read)        │
│    Record Format: JSON { user_id, event_type, page_url, ts, device_info }  │
└──────────────────────────────────┬───────────────────────────────────────────┘
                                   │
         ┌─────────────────────────┼──────────────────────────────┐
         │ OLD WAY (Bad Pattern)   │  NEW WAY (Streaming Ingest)  │
         ▼                         ▼                              │
┌──────────────────────┐  ┌───────────────────────────────┐      │
│ Kinesis Data Firehose│  │ Redshift Streaming MV         │      │
│ → S3 micro-batch     │  │ (AUTO REFRESH from stream)    │      │
│ → COPY every 60s     │  │ Latency: < 10 seconds         │      │
│ Latency: 2-5 min     │  │ No Firehose/Lambda needed     │      │
│ Cost: Firehose + S3  │  │ Cost: Redshift compute only   │      │
└──────────────────────┘  └───────────────┬───────────────┘      │
                                          │                       │
                                          ▼                       │
                          ┌───────────────────────────────┐      │
                          │  GOLD TABLES (Star Schema)    │      │
                          │  ELT from MV → fact_clicks    │      │
                          └───────────────────────────────┘      │
                                                                  │
======================================================================================
*/

-- These schemas are referenced throughout this module but are not created by
-- sql/01 (staging, analytics, admin) or sql/07 (rpt). Without these lines every
-- qualified reference below fails with 'schema does not exist'.
CREATE SCHEMA IF NOT EXISTS gold;
CREATE SCHEMA IF NOT EXISTS etl;

-- ============================================================================
-- SECTION 1: PREREQUISITES — IAM ROLE & EXTERNAL SCHEMA FROM KINESIS
-- ============================================================================
-- IMPLEMENTS: Best Practice #68 (Loading mechanisms)
--
-- Streaming ingestion requires:
--   1. A Kinesis Data Stream (already provisioned in AWS)
--   2. An IAM role attached to Redshift with kinesis:GetRecords, kinesis:GetShardIterator,
--      kinesis:DescribeStream, kinesis:ListShards, kinesis:DescribeStreamSummary
--   3. An external schema of type KINESIS

-- Create the external schema pointing to Kinesis
CREATE EXTERNAL SCHEMA kinesis_clickstream
FROM KINESIS
IAM_ROLE '<KINESIS_ROLE_ARN>';
-- NOTE: Unlike Spectrum schemas (which need a Glue database), Kinesis schemas
-- don't need a database — they connect directly to the stream.


-- ============================================================================
-- SECTION 2: THE STREAMING MATERIALIZED VIEW (THE CORE MECHANISM)
-- ============================================================================
-- IMPLEMENTS: Best Practices #39-40 (Incremental with watermarks), #42 (Idempotent)
--
-- The Materialized View is the "consumer" of the Kinesis stream. Redshift:
--   1. Reads from the stream's shard iterators
--   2. Deserializes JSON/Avro/CSV records
--   3. Materializes rows into Redshift managed storage
--   4. Tracks the stream position (sequence number) so it never re-reads data
--
-- AUTO REFRESH YES means Redshift periodically refreshes the MV (every few seconds)
-- without any external scheduler or Lambda trigger.

CREATE MATERIALIZED VIEW bronze.mv_clickstream_raw
AUTO REFRESH YES
AS
SELECT
    -- Kinesis metadata columns (automatically available):
    approximate_arrival_timestamp,          -- When Kinesis received the record
    partition_key,                          -- The partition key used for sharding
    shard_id,                               -- Which shard delivered this record
    sequence_number,                        -- Unique ID within the shard (dedup key)
    refresh_time,                           -- When Redshift ingested this record

    -- Business payload (parsed from JSON):
    JSON_PARSE(kinesis_data) AS raw_payload, -- Keep raw SUPER for Bronze
    
    -- Extracted typed columns for Silver promotion:
    JSON_EXTRACT_PATH_TEXT(
        kinesis_data, 'user_id')            AS user_id,
    JSON_EXTRACT_PATH_TEXT(
        kinesis_data, 'event_type')         AS event_type,
    JSON_EXTRACT_PATH_TEXT(
        kinesis_data, 'page_url')           AS page_url,
    JSON_EXTRACT_PATH_TEXT(
        kinesis_data, 'device_info')        AS device_info,
    CAST(JSON_EXTRACT_PATH_TEXT(
        kinesis_data, 'ts') AS TIMESTAMP)   AS event_timestamp

FROM kinesis_clickstream."<KINESIS_STREAM_NAME>"
-- The stream name is quoted because Kinesis stream names can contain hyphens.
WHERE is_utf8(kinesis_data)                 -- Skip malformed binary records
  AND CAN_JSON_PARSE(kinesis_data);         -- Skip non-JSON records gracefully


-- ============================================================================
-- SECTION 3: QUERYING THE STREAMING MV (REAL-TIME DASHBOARDS)
-- ============================================================================
-- IMPLEMENTS: Best Practice #17 (Filter early), #22 (EXISTS vs IN)

-- Real-time conversion funnel (last 5 minutes):
SELECT
    event_type,
    COUNT(DISTINCT user_id)         AS unique_users,
    COUNT(*)                        AS event_count,
    SUM(CASE WHEN event_type = 'purchase'  THEN 1 ELSE 0 END)
        * 100.0 / NULLIF(SUM(CASE WHEN event_type = 'page_view' THEN 1 ELSE 0 END), 0)
        AS conversion_rate_pct
FROM bronze.mv_clickstream_raw
WHERE approximate_arrival_timestamp >= DATEADD(minute, -5, SYSDATE)
GROUP BY event_type
ORDER BY event_count DESC;

-- Top pages in the last 60 seconds:
SELECT
    page_url,
    COUNT(*) AS hits
FROM bronze.mv_clickstream_raw
WHERE approximate_arrival_timestamp >= DATEADD(second, -60, SYSDATE)
GROUP BY page_url
ORDER BY hits DESC
LIMIT 20;


-- ============================================================================
-- SECTION 4: ELT FROM STREAMING MV INTO GOLD STAR SCHEMA
-- ============================================================================
-- IMPLEMENTS: Best Practices #91 (Medallion), #42 (Idempotent), #44 (MERGE)
--
-- The streaming MV is your Bronze layer. Promote to Gold on a schedule
-- (e.g., every 5 minutes via Redshift Query Scheduler or Airflow).

-- Gold fact table design:
CREATE TABLE IF NOT EXISTS gold.fact_clickstream (
    click_key           BIGINT IDENTITY(1,1),   -- Surrogate key
    event_timestamp     TIMESTAMP   NOT NULL,
    user_id             VARCHAR(64) NOT NULL,
    event_type          VARCHAR(32) NOT NULL,
    page_url            VARCHAR(512),
    device_info         VARCHAR(128),
    kinesis_sequence    VARCHAR(256) NOT NULL,   -- Natural dedup key
    ingested_at         TIMESTAMP   DEFAULT SYSDATE
)
DISTSTYLE KEY
DISTKEY (user_id)
SORTKEY (event_timestamp);

-- Idempotent ELT: use sequence_number to prevent duplicates on retry
CREATE OR REPLACE PROCEDURE etl.sp_promote_clicks_to_gold()
LANGUAGE plpgsql
AS $$
DECLARE
    v_max_sequence  VARCHAR(256);
    v_inserted      INT;
BEGIN
    -- Find the high-water mark (last successfully promoted sequence)
    SELECT COALESCE(MAX(kinesis_sequence), '')
    INTO v_max_sequence
    FROM gold.fact_clickstream;

    -- Insert only NEW records beyond the watermark
    INSERT INTO gold.fact_clickstream (
        event_timestamp, user_id, event_type,
        page_url, device_info, kinesis_sequence
    )
    SELECT
        event_timestamp, user_id, event_type,
        page_url, device_info, sequence_number
    FROM bronze.mv_clickstream_raw
    WHERE sequence_number > v_max_sequence
      AND event_timestamp IS NOT NULL       -- Data quality gate
      AND user_id IS NOT NULL;

    GET DIAGNOSTICS v_inserted = ROW_COUNT;
    RAISE INFO 'sp_promote_clicks_to_gold: Inserted % rows beyond watermark %.',
               v_inserted, v_max_sequence;
END;
$$;

-- Schedule this every 5 minutes via Redshift Query Scheduler:
-- (See Module 49 for orchestration patterns)


-- ============================================================================
-- SECTION 5: STREAMING FROM AMAZON MSK (MANAGED KAFKA)
-- ============================================================================
-- The pattern is identical to Kinesis, but the external schema points to MSK.

-- CREATE EXTERNAL SCHEMA msk_transactions
-- FROM MSK
-- IAM_ROLE '<MSK_ROLE_ARN>'
-- AUTHENTICATION { none | iam }
-- CLUSTER_ARN '<MSK_CLUSTER_ARN>';

-- CREATE MATERIALIZED VIEW bronze.mv_kafka_transactions
-- AUTO REFRESH YES
-- AS
-- SELECT
--     kafka_partition,
--     kafka_offset,
--     kafka_timestamp,
--     kafka_key,
--     JSON_PARSE(kafka_value) AS payload,
--     refresh_time
-- FROM msk_transactions."<MSK_TOPIC_NAME>"
-- WHERE is_utf8(kafka_value)
--   AND CAN_JSON_PARSE(kafka_value);


-- ============================================================================
-- SECTION 6: ANTI-PATTERN — FIREHOSE + S3 + COPY MICRO-BATCH
-- ============================================================================
-- THE BAD WAY (What the app dev team naturally builds):
--
-- Architecture: Kinesis → Firehose → S3 (buffer 60s) → Lambda trigger → COPY
--
-- Problems:
--   1. 2-5 minute latency (Firehose buffers for 60-300 seconds)
--   2. Firehose costs ($0.029/GB) + S3 PUT costs + Lambda invocation costs
--   3. Small files problem: Firehose creates thousands of tiny Parquet files
--      that degrade Redshift scan performance (see Module 60, Practice #61)
--   4. COPY failures require dead-letter queue + retry logic + monitoring
--   5. Schema changes require Firehose reconfiguration + S3 schema evolution
--
-- THE GOOD WAY: Native streaming ingestion (Sections 1-4 above)
--   1. Sub-10 second latency
--   2. Zero Firehose/Lambda/S3 intermediate costs
--   3. No small files — data goes directly into Redshift managed storage
--   4. AUTO REFRESH handles retries internally
--   5. Schema changes: just ALTER the MV definition


-- ============================================================================
-- SECTION 7: MONITORING STREAMING INGESTION HEALTH
-- ============================================================================
-- IMPLEMENTS: Best Practices #97-101 (Observability & Monitoring)

-- Check MV refresh status and lag:
SELECT
    mv_name,
    schema_name,
    state,                           -- 'Active', 'Refreshing', 'Error'
    last_refresh_time,
    DATEDIFF(second, last_refresh_time, SYSDATE) AS seconds_since_refresh,
    rows_inserted_since_last_refresh
FROM SYS_MV_STATE
WHERE schema_name = 'bronze'
ORDER BY last_refresh_time DESC;

-- Check for streaming ingestion errors:
SELECT
    mv_name,
    error_code,
    error_message,
    start_time,
    end_time
FROM SYS_STREAM_SCAN_ERRORS
WHERE start_time >= DATEADD(hour, -24, SYSDATE)
ORDER BY start_time DESC;

-- Monitor stream throughput:
SELECT
    mv_name,
    SUM(rows_produced) AS total_rows_ingested,
    SUM(bytes_scanned) / (1024*1024*1024) AS gb_scanned,
    COUNT(*) AS refresh_count,
    AVG(DATEDIFF(millisecond, start_time, end_time)) AS avg_refresh_ms
FROM SYS_STREAM_SCAN_STATES
WHERE start_time >= DATEADD(hour, -1, SYSDATE)
GROUP BY mv_name;


-- ============================================================================
-- SECTION 8: CAPACITY PLANNING FOR STREAMING
-- ============================================================================
/*
KINESIS SHARD MATH:
  • 1 shard = 1 MB/s write, 2 MB/s read, 1000 records/s write
  • For 500K events/s at ~500 bytes/event = 250 MB/s → need ~250 shards
  • Cost: ~$250/day for 250 shards in on-demand mode

REDSHIFT COMPUTE SIZING:
  • Serverless: Set base RPU to 32-64 for heavy streaming workloads
  • Provisioned: RA3.4xlarge with at least 4 nodes for parallel shard consumption
  • Each Redshift slice reads from one or more Kinesis shards in parallel

TUNING:
  • If lag > 30 seconds, increase RPUs or add nodes
  • If Kinesis ReadProvisionedThroughputExceeded, add more shards
  • Set REFRESH INTERVAL on the MV to control refresh frequency vs. compute cost
*/
