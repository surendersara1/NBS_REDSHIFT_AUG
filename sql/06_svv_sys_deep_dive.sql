-- =========================================================================
-- 06 — The system catalog: SVV, SYS, STL, STV, SVL
--
-- This is the file that separates people who can operate a warehouse from
-- people who can only query one. On a real project you will spend more time
-- here than in any other file.
--
-- THE FIVE FAMILIES, and when each is right:
--
--   SVV_  "system view, virtual". Catalog METADATA — what exists right now.
--         Tables, columns, schemas, users, privileges. Start here.
--
--   SYS_  The MODERN monitoring layer. Query history, load history, MV
--         refreshes. Works identically on provisioned and Serverless, and
--         it is already aggregated per query — one row per query, not one
--         per fragment. PREFER THESE FOR ALL NEW WORK.
--
--   STL_  Legacy "system table, log". Persisted to disk from system logs.
--         Retained only 2-5 days. Still the only source for a few things,
--         notably STL_LOAD_ERRORS.
--
--   STV_  Legacy "system table, virtual". Live snapshots of in-memory state
--         — what is running THIS INSTANT. Nothing historical.
--
--   SVL_  Legacy "system view, log". Joins across STL tables for you.
--
-- The rule: reach for SYS_ first. Fall back to STL_/STV_/SVL_ only for the
-- handful of things SYS_ does not yet cover.
--
-- VISIBILITY: a non-superuser sees only their OWN rows unless created with
-- SYSLOG ACCESS UNRESTRICTED. If a learner's monitoring query returns one
-- row and yours returns hundreds, that is why.
-- =========================================================================


-- =========================================================================
-- PART A — SVV: what exists
-- =========================================================================

-- A.1 The single most useful view in Redshift. Learn its columns cold.
SELECT "schema", "table", diststyle, sortkey1, sortkey_num,
       size AS size_mb, pct_used, tbl_rows,
       unsorted,        -- % of rows out of sort order -> VACUUM SORT
       stats_off,       -- % staleness of statistics    -> ANALYZE
       skew_rows,       -- ratio biggest:smallest slice -> bad DISTKEY
       skew_sortkey1,
       encoded, vacuum_sort_benefit
FROM   svv_table_info
WHERE  "schema" IN ('analytics','staging')
ORDER  BY size DESC;

-- How to read it:
--   unsorted   > 10  ->  VACUUM SORT ONLY
--   stats_off  > 10  ->  ANALYZE
--   skew_rows  >  4  ->  your DISTKEY is wrong; one node holds most rows
--   encoded = 'N'    ->  no compression; you are reading far too many bytes

-- A.2 Columns, across local AND external tables in one place.
SELECT database_name, schema_name, table_name, column_name,
       ordinal_position, data_type, is_nullable
FROM   svv_all_columns
WHERE  schema_name IN ('analytics','spectrum_raw','s3t_bronze')
ORDER  BY schema_name, table_name, ordinal_position;

-- A.3 Local tables only, with their real distribution/sort settings.
SELECT database_name, schema_name, table_name, table_type
FROM   svv_redshift_tables
WHERE  schema_name = 'analytics';

-- A.4 External metadata.
SELECT * FROM svv_external_schemas;
SELECT schemaname, tablename, location, input_format, serialization_lib
FROM   svv_external_tables;
SELECT schemaname, tablename, columnname, external_type, columnnum
FROM   svv_external_columns
WHERE  schemaname = 'spectrum_raw';
SELECT schemaname, tablename, values, location
FROM   svv_external_partitions
WHERE  tablename = 'silver_customer_metrics';

-- A.5 Who can do what. Auditors ask for exactly this.
SELECT namespace_name, relation_name, identity_name, identity_type, privilege_type
FROM   svv_relation_privileges
WHERE  namespace_name = 'analytics'
ORDER  BY relation_name, identity_name;

SELECT * FROM svv_role_grants;                 -- role -> role nesting
SELECT * FROM svv_user_grants;                 -- role -> user
SELECT * FROM svv_system_privileges;           -- system-level grants

-- A.6 Storage consumed per schema, against the quota set in file 01.
SELECT trim(schema_name) AS schema_name, schema_quota, schema_used, schema_type
FROM   svv_schema_quota_state;

-- A.7 What Redshift's own advisor thinks you should change.
SELECT type, database, table_id, group_id, auto_eligible, ddl
FROM   svv_alter_table_recommendations;

-- A.8 Interleaved sort key health (only if you used one).
SELECT * FROM svv_interleaved_columns;


-- =========================================================================
-- PART B — SYS: what happened (prefer these)
-- =========================================================================

-- B.1 Query history. One row per query, already aggregated.
SELECT query_id, transaction_id, user_id, database_name, query_type, status,
       start_time, end_time, elapsed_time/1000000.0 AS elapsed_sec,
       queue_time/1000000.0 AS queue_sec,
       execution_time/1000000.0 AS exec_sec,
       returned_rows, returned_bytes,
       LEFT(query_text, 120) AS sql_preview
FROM   sys_query_history
WHERE  start_time > DATEADD(hour, -6, SYSDATE)
  AND  query_type = 'SELECT'
ORDER  BY elapsed_time DESC
LIMIT  50;

-- B.2 Where a slow query actually spent its time — per step.
SELECT query_id, stream_id, segment_id, step_id, step_name, table_name,
       source, input_bytes, output_bytes, input_rows, output_rows,
       spilled_block_local_disk, spilled_block_remote_disk,
       duration/1000000.0 AS step_sec
FROM   sys_query_detail
WHERE  query_id = <QUERY_ID>
ORDER  BY step_sec DESC;
--
-- What to read here:
--   step_name                 the operation. Values include scan, hashjoin,
--                             hash, aggregate, sort, DISTRIBUTE, BROADCAST,
--                             nestloop, merge, window, limit, return.
--   spilled_block_local_disk  > 0 means it ran out of memory and hit disk
--   spilled_block_remote_disk > 0 means it spilled all the way to S3
--
-- SYS_QUERY_DETAIL has NO is_distkey column. Redistribution shows up as a
-- STEP, not a flag — look for step_name in ('distribute','broadcast'):
SELECT query_id, step_name, table_name, output_rows,
       duration/1000000.0 AS step_sec
FROM   sys_query_detail
WHERE  query_id = <QUERY_ID>
  AND  step_name IN ('distribute','broadcast')
ORDER  BY step_sec DESC;
-- Zero rows returned = nothing moved between nodes = a collocated join.
--
-- is_rrscan (was the sort key used?) exists in BOTH SYS_QUERY_DETAIL and
-- STL_SCAN — verified against the SYS_QUERY_DETAIL column reference. Files
-- 10 and 11 read it from SYS_QUERY_DETAIL, which is the preferred modern
-- source. STL_SCAN is shown here because it also carries rows_pre_filter,
-- which is the "how many rows did the scan actually emit" number:
SELECT slice, type, rows, rows_pre_filter, is_rrscan
FROM   stl_scan WHERE query = <QUERY_ID> AND tbl > 0 ORDER BY slice;

-- B.3 The single most valuable operational query: what is slow, repeatedly.
SELECT LEFT(query_text, 100) AS sql_preview,
       COUNT(*)                            AS executions,
       ROUND(AVG(elapsed_time)/1000000, 2) AS avg_sec,
       ROUND(MAX(elapsed_time)/1000000, 2) AS max_sec,
       ROUND(SUM(elapsed_time)/1000000, 2) AS total_sec
FROM   sys_query_history
WHERE  start_time > DATEADD(day, -1, SYSDATE)
  AND  query_type = 'SELECT'
GROUP  BY LEFT(query_text, 100)
HAVING COUNT(*) > 1
ORDER  BY total_sec DESC
LIMIT  25;
-- Optimise by TOTAL time, not max. A 2-second query run 10,000 times costs
-- far more than a 10-minute query run once.

-- B.4 Loads, unloads, MV refreshes.
SELECT * FROM sys_load_history   ORDER BY start_time DESC LIMIT 20;
SELECT * FROM sys_load_error_detail ORDER BY start_time DESC LIMIT 20;
SELECT * FROM sys_unload_history ORDER BY start_time DESC LIMIT 20;
SELECT mv_name, status, refresh_type, start_time, duration, error_message
FROM   sys_mv_refresh_history ORDER BY start_time DESC LIMIT 20;

-- B.5 Spectrum / external scan cost. This is your S3 bill in view form.
SELECT query_id, segment_id, s3_scanned_rows, s3_scanned_bytes,
       s3_query_returned_rows, s3_query_returned_bytes,
       ROUND(s3_scanned_bytes/1024.0/1024.0, 2) AS scanned_mb
FROM   sys_external_query_detail
WHERE  start_time > DATEADD(hour, -6, SYSDATE)
ORDER  BY s3_scanned_bytes DESC
LIMIT  25;

-- B.6 Connections and sessions.
SELECT * FROM sys_connection_log ORDER BY record_time DESC LIMIT 20;
SELECT * FROM sys_session_history ORDER BY start_time DESC LIMIT 20;

-- B.7 Concurrency scaling and queueing.
SELECT query_id, service_class, queue_time/1000000.0 AS queue_sec,
       execution_time/1000000.0 AS exec_sec, status
FROM   sys_query_history
WHERE  queue_time > 0
  AND  start_time > DATEADD(hour, -6, SYSDATE)
ORDER  BY queue_time DESC
LIMIT  25;


-- =========================================================================
-- PART C — STL / STV / SVL: the legacy layer you still need
-- =========================================================================

-- C.1 STL_LOAD_ERRORS — no SYS_ equivalent is as detailed. Run this the
--     moment a COPY fails, before anything else.
SELECT starttime, TRIM(filename) AS filename, line_number, colname, type,
       position, TRIM(err_reason) AS reason, TRIM(raw_field_value) AS bad_value
FROM   stl_load_errors
ORDER  BY starttime DESC
LIMIT  25;

-- C.2 STV_ — live state, right now. Nothing historical.
SELECT * FROM stv_recents WHERE status = 'Running';
SELECT * FROM stv_inflight;
SELECT * FROM stv_wlm_query_state;
SELECT owner, host, diskno, used, capacity,
       ROUND(used::NUMERIC/capacity*100, 1) AS pct_used
FROM   stv_partitions WHERE part_begin = 0;

-- C.3 Locks — the "my query is hung" answer.
-- t."table", not t.table_name. SVV_TABLE_INFO names that column "table",
-- which is a reserved word and therefore always needs the double quotes.
SELECT l.table_id, t."table", l.last_update, l.lock_owner, l.lock_owner_pid,
       l.lock_mode, l.granted
FROM   stv_locks l
LEFT JOIN svv_table_info t ON t.table_id = l.table_id;
-- Then: SELECT pg_terminate_backend(<lock_owner_pid>);

-- C.4 Blocks per column — where storage actually went, and proof that
--     encoding matters. Compare a bytedict column against a raw one.
SELECT col, COUNT(*) AS blocks
FROM   stv_blocklist
WHERE  tbl = (SELECT table_id FROM svv_table_info
              WHERE "table" = 'fct_customer_orders')
GROUP  BY col ORDER BY col;

-- C.5 SVL_ — pre-joined convenience views over STL.
SELECT * FROM svl_qlog ORDER BY starttime DESC LIMIT 20;
SELECT * FROM svl_s3query_summary ORDER BY starttime DESC LIMIT 20;
SELECT userid, query, ROUND(SUM(bytes)/1024.0/1024.0, 2) AS mb_scanned
FROM   svl_query_summary GROUP BY userid, query
ORDER  BY mb_scanned DESC LIMIT 20;


-- =========================================================================
-- PART D — EXPLAIN: reading a plan
-- =========================================================================
EXPLAIN
SELECT c.segment, SUM(o.gross_amount)
FROM   analytics.fct_customer_orders o
JOIN   analytics.dim_country c ON c.country_code = o.country
GROUP  BY c.segment;

-- The words that matter, worst to best:
--   DS_BCAST_INNER    the whole inner table is broadcast to every node.
--                     Acceptable only for a genuinely tiny table.
--   DS_DIST_INNER     the inner table is redistributed. Expensive.
--   DS_DIST_BOTH      both sides redistributed. Almost always a design bug.
--   DS_DIST_NONE      no movement — collocated join. This is the goal.
--
-- Also watch for:
--   Seq Scan on a large table with no filter    -> sort key not used
--   the cost estimate being wildly wrong        -> run ANALYZE

-- Prove the collocated join: fct_customer_orders and fct_customer_metrics
-- share DISTKEY(customer_id), so this should show DS_DIST_NONE.
EXPLAIN
SELECT o.customer_id, COUNT(*), MAX(m.running_ltv)
FROM   analytics.fct_customer_orders o
JOIN   analytics.fct_customer_metrics m ON m.customer_id = o.customer_id
GROUP  BY o.customer_id;


-- =========================================================================
-- PART E — The awslabs admin views
--
-- Clone and install into the `admin` schema created in file 01:
--   git clone https://github.com/awslabs/amazon-redshift-utils
--   cd amazon-redshift-utils/src/AdminViews
-- Then run the views you want. The highest-value ones:
--
--   v_generate_tbl_ddl              reconstruct CREATE TABLE for any table
--   v_get_obj_priv_by_user          who can touch what
--   v_generate_user_object_permissions
--   v_object_dependency             what breaks if I drop this
--   v_open_session                  who is connected
--   v_space_used_per_tbl            storage by table
--   v_check_data_distribution       skew per slice
--
-- v_generate_tbl_ddl alone is worth the clone — Redshift has no SHOW CREATE
-- TABLE, and this view is the substitute.
-- =========================================================================
-- SELECT ddl FROM admin.v_generate_tbl_ddl
--  WHERE schemaname = 'analytics' AND tablename = 'fct_customer_orders'
--  ORDER BY seq;
