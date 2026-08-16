-- =========================================================================
-- 16 — COPY in depth
--
-- The only load path that scales. Every slice reads its own file in
-- parallel, which is why THE NUMBER OF FILES MATTERS AS MUCH AS THE SQL.
--
-- IN PLAIN ENGLISH
--   Sixteen people at the loading bay. Send one enormous crate and fifteen
--   of them watch. Send sixteen crates and the lorry empties in a
--   sixteenth of the time.
--
-- One enormous file is read by ONE slice while the rest idle. Aim for a
-- multiple of your slice count, each roughly 100 MB - 1 GB compressed.
--
-- ONE BIG FILE IS THE MOST COMMON REASON A LOAD IS SLOW.
-- =========================================================================


-- =========================================================================
-- 16.0  FIRST — how many slices do you actually have?
--
-- "A multiple of your slice count" is useless advice until you know the
-- number. Nobody tells you; you have to ask.
-- =========================================================================
SELECT COUNT(*) AS total_slices
FROM   stv_slices
WHERE  type = 'D';                  -- 'D' = data slices; excludes the leader

SELECT node, COUNT(*) AS slices_per_node
FROM   stv_slices WHERE type = 'D'
GROUP  BY node ORDER BY node;

-- On this teaching cluster: ra3.large, single node, 2 slices.
-- So the target file count is 2, 4, 6, 8... never 1, and never 7.
--
-- On a 4-node ra3.4xlarge (4 slices/node = 16 slices) the same rule says
-- 16, 32, 48 files. The number changes with the cluster; the rule does not.


-- =========================================================================
-- 16.1  FOUR THINGS THAT DECIDE HOW FAST IT LOADS
-- =========================================================================

-- ---------------------------------------------------------------------
-- (1) FILE COUNT AND SIZE — multiple of slice count
--
-- The single biggest factor. Sixteen slices and one file means fifteen
-- idle workers. Sixteen files means all of them working.
--
-- Too many tiny files is the opposite failure: per-file overhead starts to
-- dominate below ~10 MB. The sweet spot is 100 MB - 1 GB compressed.
--
-- Splitting is the producer's job, not Redshift's. In Glue:
--     df.repartition(16).write.parquet(path)
-- In the AWS CLI, a single large file cannot be split at load time — you
-- must re-write it.
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- (2) FORMAT — PARQUET > CSV
--
-- Parquet is typed and columnar, so there is no parsing and no guessing.
-- CSV needs delimiters, quoting and NULL handling declared, and every one
-- of those declarations is a chance to be wrong.
--
-- Parquet also carries its own compression, so GZIP is neither needed
-- nor allowed.
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- (3) A MANIFEST FOR EXACTNESS
--
-- A prefix loads whatever happens to be there. A manifest NAMES THE EXACT
-- FILES — which is what makes a load reproducible, and what stops a stray
-- file dropped in the same prefix from silently joining your fact table.
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- (4) COMPRESSION ON FIRST LOAD — empty table only
--
-- COPY into an EMPTY table with NO encodings samples the data and applies
-- compression. Into a populated table it does not. See file 12 §12.3 —
-- this is why CTAS-built tables end up uncompressed forever.
-- ---------------------------------------------------------------------


-- =========================================================================
-- 16.2  The SQL
-- =========================================================================

-- The staging target for the Parquet examples below.
CREATE TABLE IF NOT EXISTS staging.sales_line (
    sale_date    DATE,
    store_sk     BIGINT,
    product_sk   BIGINT,
    receipt_no   VARCHAR(32),
    line_no      SMALLINT,
    quantity     DECIMAL(12,3),
    net_amount   DECIMAL(14,2),
    vat_amount   DECIMAL(14,2)
)
DISTSTYLE EVEN;
-- No encodings declared, deliberately: this is the empty table that lets
-- COPY choose them on first load. See §16.1(4).

-- Parquet — almost nothing to declare, because the file knows its own types.
-- NOTE: this prefix does not exist until you produce Parquet there. The
-- runnable CSV loads are in file 02; this is the reference form.
COPY staging.sales_line
FROM 's3://<RAW_BUCKET>/raw/sales/dt=2026-08-12/'
IAM_ROLE '<SPECTRUM_ROLE_ARN>'
FORMAT AS PARQUET;

-- CSV needs more said out loud. Every clause below is a decision that
-- silently corrupts data if you get it wrong.
COPY staging.customers
FROM 's3://<RAW_BUCKET>/parent/'
IAM_ROLE '<SPECTRUM_ROLE_ARN>'
CSV
IGNOREHEADER 1
-- NO GZIP. This prefix holds the plain customers.csv that the CDK uploads,
-- and GZIP against an uncompressed file fails the whole load. Add GZIP only
-- when the producer actually writes .gz — it is not a free "handle either".
TIMEFORMAT 'auto'
DATEFORMAT 'YYYY-MM-DD'
BLANKSASNULL          -- '   ' becomes NULL
EMPTYASNULL           -- ''    becomes NULL
TRIMBLANKS
MAXERROR 100
COMPUPDATE ON
STATUPDATE ON;

-- With a manifest — the reproducible form.
--
-- manifest.json:
-- {
--   "entries": [
--     {"url":"s3://bucket/raw/sales/part-00000.parquet","mandatory":true},
--     {"url":"s3://bucket/raw/sales/part-00001.parquet","mandatory":true}
--   ]
-- }
--
-- mandatory:true makes a missing file an ERROR rather than a silent
-- short load. That single flag is the difference between "the load
-- succeeded" and "the load succeeded and we lost a day of sales".
COPY staging.sales_line
FROM 's3://<RAW_BUCKET>/manifests/sales_2026-08-12.json'
IAM_ROLE '<SPECTRUM_ROLE_ARN>'
FORMAT AS PARQUET
MANIFEST;

-- Column subset / reordering. Without the column list, COPY maps by
-- POSITION, so a producer adding a column in the middle silently shifts
-- every value one column to the right. Name the columns.
COPY staging.orders (order_id, customer_id, order_ts, status, quantity, unit_price)
FROM 's3://<RAW_BUCKET>/child/'
IAM_ROLE '<SPECTRUM_ROLE_ARN>'
CSV IGNOREHEADER 1;


-- =========================================================================
-- 16.3  Did the parallelism actually happen?
--
-- Do not assume. stl_load_commits has one row per file per slice — count
-- the distinct slices and you know how many workers were used.
-- =========================================================================
SELECT query, TRIM(filename) AS filename, slice, lines_scanned, status
FROM   stl_load_commits
WHERE  query = pg_last_query_id()
ORDER  BY slice, filename;

-- The summary that tells you whether you sent one crate or sixteen:
SELECT query,
       COUNT(DISTINCT TRIM(filename)) AS files,
       COUNT(DISTINCT slice)          AS slices_used,
       SUM(lines_scanned)             AS rows_loaded
FROM   stl_load_commits
WHERE  query = pg_last_query_id()
GROUP  BY query;
-- slices_used well below your total slice count means idle workers.

-- Modern equivalent, per load and per file:
SELECT query_id, table_name, data_source, loaded_rows, error_count,
       status, start_time, duration/1000000.0 AS sec
FROM   sys_load_history
WHERE  start_time > DATEADD(hour, -2, SYSDATE)
ORDER  BY start_time DESC;

SELECT file_name, loaded_rows, error_count, status, duration/1000000.0 AS sec
FROM   sys_load_detail
WHERE  query_id = (SELECT MAX(query_id) FROM sys_load_history)
ORDER  BY duration DESC;
-- One file taking far longer than the rest = skewed file sizes.


-- =========================================================================
-- 16.4  GOTCHAS
--
--   * COPY IS NOT IDEMPOTENT. Running it twice loads the rows twice — no
--     error, no warning, doubled revenue. Stage, then MERGE. See 16.5.
--
--   * A PREFIX PICKS UP FILES YOU DID NOT EXPECT. Including a _SUCCESS
--     marker, a .crc, a re-run's leftovers, or someone's manual upload.
--     Use a manifest when correctness matters.
--
--   * NEVER COPY STRAIGHT INTO A LIVE TABLE. Consumers see a half-loaded
--     table, and a failed load leaves it half-populated with no way back.
--
--   * REGION MISMATCH. If the bucket is not in the cluster's region, COPY
--     fails until you add REGION 'us-west-2'. The error names the bucket,
--     not the region, so it reads like a permissions problem.
--
--   * MAXERROR HIDES PROBLEMS. MAXERROR 100 means up to 100 rows vanish
--     silently. Use it to survive a load, then always read stl_load_errors.
--
--   * COMPUPDATE ON A POPULATED TABLE DOES NOTHING. Encodings are set on
--     first load into an empty table only.
--
--   * PARQUET DOES NOT TAKE GZIP/CSV OPTIONS. FORMAT AS PARQUET plus
--     IGNOREHEADER is a syntax error — the file has no header.
--
--   * PARQUET TYPE MISMATCH IS A HARD FAIL, not a coercion. An INT64 in
--     the file against an INTEGER column errors rather than truncating.
--     That is a feature: CSV would have silently accepted it.
-- =========================================================================


-- =========================================================================
-- 16.5  The pattern that makes it safe — stage, then merge
--
-- COPY is not idempotent, so the idempotency has to live one layer up.
-- This is the shape every production load takes.
-- =========================================================================
CREATE OR REPLACE PROCEDURE analytics.sp_copy_then_merge(p_load_date DATE)
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
DECLARE
    v_staged  BIGINT := 0;
    v_deleted BIGINT := 0;
    v_merged  BIGINT := 0;
BEGIN
    -- 1. Land in staging. Truncate first, so a retry cannot double-load.
    TRUNCATE TABLE staging.orders;

    -- 2. COPY happens here. It cannot run inside a procedure with a
    --    dynamic credential, so in production this procedure is called
    --    AFTER the COPY by the orchestrator (EventBridge -> Lambda ->
    --    Data API), or the COPY is issued via EXECUTE with a static role.
    --
    --    EXECUTE 'COPY staging.orders FROM ''s3://...'' IAM_ROLE ''...''
    --             FORMAT AS PARQUET';

    SELECT COUNT(*) INTO v_staged FROM staging.orders;
    IF v_staged = 0 THEN
        RAISE EXCEPTION 'sp_copy_then_merge: staging is empty for %', p_load_date;
    END IF;

    -- 3. MERGE = DELETE the target window + INSERT. Set-based, idempotent,
    --    and re-runnable from the top — the only safe shape without
    --    subtransactions.
    DELETE FROM analytics.fct_customer_orders
     WHERE order_date = p_load_date;
    GET DIAGNOSTICS v_deleted := ROW_COUNT;

    INSERT INTO analytics.fct_customer_orders
        (order_id, customer_id, order_ts, order_date, status,
         quantity, unit_price, gross_amount)
    SELECT s.order_id, s.customer_id, s.order_ts, s.order_ts::DATE, s.status,
           s.quantity, s.unit_price,
           (s.quantity * s.unit_price)::DECIMAL(18,2)
      FROM staging.orders s
     WHERE s.order_ts::DATE = p_load_date;
    GET DIAGNOSTICS v_merged := ROW_COUNT;

    INSERT INTO analytics.audit_log (event_type, detail)
    VALUES ('COPY_MERGE', p_load_date || ' staged=' || v_staged ||
                          ' deleted=' || v_deleted || ' merged=' || v_merged);

    RAISE INFO 'sp_copy_then_merge %: staged=% deleted=% merged=%',
        p_load_date, v_staged, v_deleted, v_merged;
END;
$$;

-- Redshift also has a native MERGE statement, which is cleaner where it fits:
--
--   MERGE INTO analytics.fct_customer_orders t
--   USING staging.orders s ON t.order_id = s.order_id
--   WHEN MATCHED THEN UPDATE SET quantity = s.quantity, status = s.status
--   WHEN NOT MATCHED THEN INSERT (order_id, customer_id, quantity)
--                         VALUES (s.order_id, s.customer_id, s.quantity);
--
-- DELETE+INSERT still wins for a whole-partition reload: it is one pass
-- rather than a row-matched join, and it removes rows that disappeared
-- from the source — which MERGE will not do.


-- =========================================================================
-- 16.6  Checklist
--
--   [ ] I know my slice count (stv_slices) and my file count is a multiple
--   [ ] Files are 100 MB - 1 GB compressed, not one big one and not 10,000
--   [ ] Parquet unless something upstream makes it impossible
--   [ ] A manifest with mandatory:true where correctness matters
--   [ ] COPY lands in staging, never in a live table
--   [ ] Idempotency is handled by the MERGE, not hoped for from COPY
--   [ ] I read stl_load_errors after every failed load, before guessing
--   [ ] I checked slices_used in stl_load_commits at least once myself
--
-- YOU HAVE GOT IT WHEN you can look at a slow load, run one query against
-- stl_load_commits, and say "it used 1 of 16 slices — the producer is
-- writing a single file" without opening the console.
-- =========================================================================
