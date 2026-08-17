/*
======================================================================================
MODULE 75: COPY ADVANCED PATTERNS — PARQUET, MANIFESTS, ERROR HANDLING & RETRY
======================================================================================
MAPPED BEST PRACTICES (from PROCEDURE_OPTIMIZATION_BEST_PRACTICES_MASTER_FILE.md):
- Practice 68: "Bulk-load with COPY from S3 (ideally Parquet) — never row-by-row INSERT."
- Practice 69: "Use a few large files rather than many tiny ones."
- Practice 70: "Load data pre-sorted to match the target sort key."
- Practice 42: "Make loads idempotent."
- Practice 43: "Avoid duplicate records on retries."

TARGET AUDIENCE: Data Engineers, ETL Developers, Pipeline Architects
BUSINESS SCENARIO:
A data pipeline ingests 500GB of daily transaction data from 3 sources:
  1. Parquet files from a Spark job (well-structured, columnar)
  2. CSV files from a legacy mainframe (fixed-width, encoding issues)
  3. JSON files from a partner API (nested, with occasional malformed records)

Each source has different failure modes: corrupt files, schema drift, encoding errors,
and partial uploads. The pipeline must handle ALL of these gracefully.

ARCHITECTURE:
┌──────────────────────────────────────────────────────────────────────────────┐
│                    COPY COMMAND DECISION TREE                                │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  Source Format?                                                             │
│  │                                                                           │
│  ├─ Parquet/ORC/Avro ──▶ FORMAT AS PARQUET (best performance, auto-schema) │
│  │                        • Column pruning: only reads needed columns       │
│  │                        • No encoding issues (binary format)              │
│  │                        • Compression built-in (Snappy/ZSTD)              │
│  │                                                                           │
│  ├─ CSV/TSV ──▶ DELIMITER ',' + IGNOREHEADER 1                             │
│  │              • ACCEPTINVCHARS AS '?' (replace invalid UTF-8)             │
│  │              • ESCAPE / QUOTE AS '"' (handle embedded delimiters)        │
│  │              • DATEFORMAT / TIMEFORMAT for non-ISO dates                 │
│  │                                                                           │
│  ├─ JSON ──▶ FORMAT AS JSON 'auto' or FORMAT AS JSON 's3://path/jsonpath' │
│  │           • 'auto' for flat JSON                                         │
│  │           • JSONPaths file for nested/renamed fields                      │
│  │                                                                           │
│  └─ Fixed-Width ──▶ FIXEDWIDTH 'col1:10,col2:20,col3:5'                   │
│                                                                              │
│  Error Handling Strategy?                                                   │
│  │                                                                           │
│  ├─ MAXERROR N ──▶ Allow up to N bad records before failing                │
│  ├─ ACCEPTINVCHARS ──▶ Replace invalid characters instead of failing       │
│  └─ STL_LOAD_ERRORS ──▶ Debug which records failed and why                 │
│                                                                              │
│  File Organization?                                                         │
│  │                                                                           │
│  ├─ Prefix path ──▶ COPY FROM 's3://bucket/prefix/'                       │
│  │                   (loads ALL files under the prefix)                      │
│  └─ Manifest ──▶ COPY FROM 's3://bucket/manifest.json' MANIFEST            │
│                  (loads EXACTLY the files listed — idempotent)               │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘

======================================================================================
*/

-- These schemas are referenced throughout this module but are not created by
-- sql/01 (staging, analytics, admin) or sql/07 (rpt). Without these lines every
-- qualified reference below fails with 'schema does not exist'.
CREATE SCHEMA IF NOT EXISTS gold;
CREATE SCHEMA IF NOT EXISTS etl;

-- ============================================================================
-- SECTION 1: COPY FROM PARQUET (THE GOLD STANDARD)
-- ============================================================================
-- IMPLEMENTS: Best Practice #68, #60

-- Parquet is the ideal format for Redshift COPY because:
--   1. Columnar: only reads columns referenced by the target table
--   2. Typed: no parsing overhead (unlike CSV)
--   3. Compressed: Snappy or ZSTD compression built-in
--   4. Self-describing: schema is embedded in the file footer

COPY gold.fact_transactions
FROM 's3://<CURATED_BUCKET>/gold/transactions/dt=2026-08-14/'
IAM_ROLE '<SPECTRUM_ROLE_ARN>'
FORMAT AS PARQUET;

-- Parquet COPY auto-maps columns by NAME (not position).
-- If the Parquet file has extra columns, they're ignored.
-- If the Parquet file is missing columns, they get NULL.


-- ============================================================================
-- SECTION 2: COPY FROM CSV WITH ERROR HANDLING
-- ============================================================================
-- IMPLEMENTS: Best Practice #68, #43

-- Real-world CSV files are messy. Here's how to handle common problems:

COPY staging.stg_legacy_transactions
FROM 's3://<CURATED_BUCKET>/bronze/legacy/transactions_2026-08-14.csv.gz'
IAM_ROLE '<SPECTRUM_ROLE_ARN>'
DELIMITER ','
IGNOREHEADER 1                          -- Skip the header row
GZIP                                     -- File is gzip-compressed
DATEFORMAT 'MM/DD/YYYY'                  -- Legacy dates: 08/14/2026
TIMEFORMAT 'MM/DD/YYYY HH:MI:SS'        -- Legacy timestamps
ACCEPTINVCHARS AS '?'                    -- Replace invalid UTF-8 with '?'
MAXERROR 100                             -- Allow up to 100 bad records
BLANKSASNULL                             -- Treat empty strings as NULL
EMPTYASNULL                              -- Treat empty fields as NULL
TRIMBLANKS                               -- Remove trailing whitespace
NULL AS '\\N'                            -- Treat literal '\N' as NULL
REGION 'us-east-1';                      -- S3 bucket region

-- MAXERROR: If more than 100 records fail, the ENTIRE COPY is rolled back.
-- This gives you a safety valve: a few bad records are OK, but mass corruption
-- means something is fundamentally wrong and you should investigate.


-- ============================================================================
-- SECTION 3: DEBUGGING COPY FAILURES (STL_LOAD_ERRORS)
-- ============================================================================
-- IMPLEMENTS: Best Practice #86 (Handle exceptions intentionally)

-- When COPY fails, the error details are in STL_LOAD_ERRORS:
SELECT
    query,
    filename,                    -- Which S3 file had the error
    line_number,                 -- Which line in the file
    colname,                     -- Which column failed
    type,                        -- Expected data type
    raw_field_value,             -- The actual value that failed
    err_code,                    -- Error code
    err_reason                   -- Human-readable reason
FROM STL_LOAD_ERRORS
WHERE query = (
    SELECT MAX(query) FROM STL_LOAD_ERRORS  -- Most recent COPY
)
ORDER BY line_number
LIMIT 20;

-- COMMON ERRORS AND FIXES:
/*
┌───────────────────────────┬──────────────────────────────────────────────────┐
│ err_reason                │ Fix                                              │
├───────────────────────────┼──────────────────────────────────────────────────┤
│ "Invalid digit"           │ Non-numeric value in INT/DECIMAL column.        │
│                           │ Fix: ACCEPTINVCHARS or clean in source.         │
├───────────────────────────┼──────────────────────────────────────────────────┤
│ "Delimiter not found"     │ Row has fewer columns than expected.            │
│                           │ Fix: Check for embedded newlines in data.       │
├───────────────────────────┼──────────────────────────────────────────────────┤
│ "String length exceeds"   │ Value exceeds VARCHAR(N) target column width.   │
│                           │ Fix: Increase column width or TRUNCATECOLUMNS.  │
├───────────────────────────┼──────────────────────────────────────────────────┤
│ "Invalid timestamp"       │ Date/time format doesn't match DATEFORMAT.      │
│                           │ Fix: Set correct DATEFORMAT / TIMEFORMAT.       │
├───────────────────────────┼──────────────────────────────────────────────────┤
│ "Invalid byte sequence"   │ Non-UTF-8 characters (Latin-1, Windows-1252).   │
│                           │ Fix: ACCEPTINVCHARS or pre-convert to UTF-8.    │
└───────────────────────────┴──────────────────────────────────────────────────┘
*/


-- ============================================================================
-- SECTION 4: MANIFEST FILES (IDEMPOTENT, DETERMINISTIC LOADS)
-- ============================================================================
-- IMPLEMENTS: Best Practice #42 (Idempotent), #43 (No duplicates on retry)

-- A manifest file is a JSON document listing the EXACT files to load.
-- Benefits:
--   1. Deterministic: loads EXACTLY the listed files (no surprise additions)
--   2. Idempotent: re-running with the same manifest loads the same data
--   3. Mandatory mode: COPY fails if ANY listed file is missing (data validation)
--   4. Cross-bucket: can reference files from multiple S3 buckets

-- Manifest file format (s3://<CURATED_BUCKET>/manifests/2026-08-14.manifest):
/*
{
  "entries": [
    {"url": "s3://<CURATED_BUCKET>/gold/transactions/part-00000.parquet", "mandatory": true},
    {"url": "s3://<CURATED_BUCKET>/gold/transactions/part-00001.parquet", "mandatory": true},
    {"url": "s3://<CURATED_BUCKET>/gold/transactions/part-00002.parquet", "mandatory": true},
    {"url": "s3://<CURATED_BUCKET>/gold/transactions/part-00003.parquet", "mandatory": true}
  ]
}
*/

-- Load using the manifest:
COPY gold.fact_transactions
FROM 's3://<CURATED_BUCKET>/manifests/2026-08-14.manifest'
IAM_ROLE '<SPECTRUM_ROLE_ARN>'
FORMAT AS PARQUET
MANIFEST;                                -- ← Key keyword

-- If "mandatory": true and a file is missing, COPY fails immediately.
-- This catches upstream pipeline failures BEFORE loading partial data.


-- ============================================================================
-- SECTION 5: COPY FROM JSON WITH JSONPATHS
-- ============================================================================
-- IMPLEMENTS: Best Practice #68

-- Flat JSON (auto-mapping):
COPY staging.stg_api_events
FROM 's3://<CURATED_BUCKET>/bronze/api-events/2026-08-14/'
IAM_ROLE '<SPECTRUM_ROLE_ARN>'
FORMAT AS JSON 'auto'
MAXERROR 50
GZIP;

-- Nested JSON (requires JSONPaths file):
-- Source JSON: {"user": {"id": 123, "name": "Alice"}, "event": "click", "ts": "2026-08-14T10:00:00Z"}
-- Target table: (user_id INT, user_name VARCHAR, event_type VARCHAR, event_ts TIMESTAMP)

-- JSONPaths file (s3://<CURATED_BUCKET>/config/event_jsonpaths.json):
/*
{
  "jsonpaths": [
    "$['user']['id']",
    "$['user']['name']",
    "$['event']",
    "$['ts']"
  ]
}
*/

-- COPY with JSONPaths:
-- COPY staging.stg_api_events
-- FROM 's3://<CURATED_BUCKET>/bronze/api-events/2026-08-14/'
-- IAM_ROLE '<SPECTRUM_ROLE_ARN>'
-- FORMAT AS JSON 's3://<CURATED_BUCKET>/config/event_jsonpaths.json'
-- TIMEFORMAT 'auto'
-- MAXERROR 50;


-- ============================================================================
-- SECTION 6: FILE SIZE OPTIMIZATION (THE "GOLDILOCKS ZONE")
-- ============================================================================
-- IMPLEMENTS: Best Practice #69

/*
FILE SIZE RULES:
  • Too small (< 1 MB): Overhead per file dominates. S3 LIST is expensive.
    Redshift spends more time opening files than reading data.
    → Anti-pattern: Firehose writing 1,000 tiny files every 60 seconds.

  • Too large (> 1 GB): Single file can't be parallelized across slices.
    One slice gets the entire file while others sit idle.

  • GOLDILOCKS (64 MB – 256 MB): Each slice gets ~1 file. Parallel COPY.
    Aim for: number_of_files = multiple of number_of_slices.

EXAMPLE:
  Cluster: 4 RA3.4xlarge nodes × 16 slices/node = 64 slices
  Daily data: 500 GB
  Ideal: 500 GB / 64 slices ≈ 8 GB per slice, split into ~128 files of ~4 GB?
  NO — too large. Better: ~2,000 files of ~256 MB each, evenly distributed.

  Rule of thumb: Aim for files between 64 MB and 256 MB compressed.
*/

-- Check how many files were loaded in the last COPY:
SELECT
    query,
    COUNT(DISTINCT filename) AS file_count,
    SUM(lines_scanned)       AS total_rows,
    MIN(lines_scanned)       AS min_rows_per_file,
    MAX(lines_scanned)       AS max_rows_per_file,
    AVG(lines_scanned)       AS avg_rows_per_file
FROM STL_LOAD_COMMITS
WHERE query = (SELECT MAX(query) FROM stl_load_commits)
GROUP BY query;


-- ============================================================================
-- SECTION 7: COPY WITH PRE-SORTED DATA
-- ============================================================================
-- IMPLEMENTS: Best Practice #70

-- If your source data is pre-sorted to match the target's SORTKEY,
-- Redshift can skip the post-load VACUUM SORT step.

-- Target table: SORTKEY (event_date, user_id)
-- Source files: Partitioned by event_date, sorted by user_id within each file.

COPY gold.fact_events
FROM 's3://<CURATED_BUCKET>/gold/events/dt=2026-08-14/'
IAM_ROLE '<SPECTRUM_ROLE_ARN>'
FORMAT AS PARQUET
COMPUPDATE OFF                           -- Don't re-analyze compression
STATUPDATE OFF;                          -- Don't re-analyze stats (do it manually after)

-- After COPY, run ANALYZE once:
ANALYZE gold.fact_events;


-- ============================================================================
-- SECTION 8: IDEMPOTENT COPY PROCEDURE (PRODUCTION PATTERN)
-- ============================================================================
-- IMPLEMENTS: Best Practices #42, #43, #97

CREATE OR REPLACE PROCEDURE etl.sp_copy_daily_transactions(
    p_load_date DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_s3_path       VARCHAR(500);
    v_manifest_path VARCHAR(500);
    v_loaded        INT;
    v_errors        INT;
BEGIN
    -- Build dynamic S3 path
    v_s3_path := 's3://<CURATED_BUCKET>/gold/transactions/dt='
              || TO_CHAR(p_load_date, 'YYYY-MM-DD') || '/';

    -- Step 1: Idempotent delete (re-runnable)
    DELETE FROM gold.fact_transactions
    WHERE transaction_date = p_load_date;
    GET DIAGNOSTICS v_loaded = ROW_COUNT;
    RAISE INFO 'Deleted % existing rows for %', v_loaded, p_load_date;

    -- Step 2: COPY from S3
    EXECUTE 'COPY gold.fact_transactions '
         || 'FROM ''' || v_s3_path || ''' '
         || 'IAM_ROLE ''<SPECTRUM_ROLE_ARN>'' '
         || 'FORMAT AS PARQUET';

    GET DIAGNOSTICS v_loaded = ROW_COUNT;

    -- Step 3: Validate
    IF v_loaded = 0 THEN
        RAISE EXCEPTION 'COPY loaded 0 rows for % — source may be empty!', p_load_date;
    END IF;

    -- Step 4: Check for load errors
    SELECT COUNT(*) INTO v_errors
    FROM STL_LOAD_ERRORS
    WHERE query = PG_LAST_COPY_ID();

    IF v_errors > 0 THEN
        RAISE WARNING 'COPY completed with % errors. Check STL_LOAD_ERRORS.', v_errors;
    END IF;

    RAISE INFO 'sp_copy_daily_transactions [%]: Loaded % rows, % errors.',
               p_load_date, v_loaded, v_errors;
END;
$$;

-- Usage: CALL etl.sp_copy_daily_transactions('2026-08-14');


-- ============================================================================
-- SECTION 9: COPY FROM OTHER SOURCES
-- ============================================================================

-- COPY from DynamoDB:
-- COPY staging.stg_dynamo_items
-- FROM 'dynamodb://UserSessions'
-- IAM_ROLE '<DYNAMODB_ROLE_ARN>'
-- READRATIO 50;    -- Max % of DynamoDB provisioned throughput to consume

-- COPY from EMR (HDFS):
-- COPY staging.stg_hadoop_data
-- FROM 'emr://j-XXXXX/user/hadoop/output/'
-- IAM_ROLE '<EMR_ROLE_ARN>'
-- FORMAT AS PARQUET;

-- COPY from SSH (remote host):
-- COPY staging.stg_remote_data
-- FROM 's3://<CURATED_BUCKET>/ssh-manifest/my_ssh_manifest'
-- IAM_ROLE '<SSH_ROLE_ARN>'
-- SSH;
