-- =========================================================================
-- 18 — Applications, transactions, locking, and workload management
--
-- You are application developers. This is the file about the part you will
-- actually own: how an application talks to Redshift without falling over.
--
-- The headline, stated early because it inverts an OLTP instinct:
--
--   REDSHIFT IS NOT AN APPLICATION DATABASE.
--
-- It has a few hundred connection slots, not tens of thousands. It is built
-- for a few dozen heavy analytical queries, not ten thousand small ones per
-- second. If your app needs single-row lookups at request rate, that data
-- belongs in DynamoDB, Aurora, or a cache — with Redshift feeding it.
-- Designing around that is a day-1 architecture decision, not a tuning
-- problem you fix later.
-- =========================================================================


-- =========================================================================
-- 18.1  Connection limits — the number that ends the debate
-- =========================================================================
SELECT setting AS max_connections FROM pg_settings WHERE name = 'max_connections';

-- Who is connected right now, and doing what:
SELECT recordtime, username, dbname, remotehost, event
FROM   stl_connection_log
ORDER  BY recordtime DESC LIMIT 20;

SELECT * FROM stv_sessions;

SELECT COUNT(*) AS open_sessions FROM stv_sessions;

-- A connection-per-request web app exhausts this in minutes. The fixes, in
-- order of preference:
--   1. The Redshift Data API — HTTP, no persistent connection at all
--   2. A pooler (pgbouncer / RDS Proxy pattern) in front of JDBC
--   3. A small fixed application pool: 5-20 connections, NOT per-request
--
-- Idle sessions holding transactions open are the usual culprit. Find them:
SELECT s.process, s.user_name, s.starttime,
       DATEDIFF(minute, s.starttime, GETDATE()) AS session_age_min,
       t.txn_start, t.lock_mode, t.relation
FROM   stv_sessions s
LEFT   JOIN stv_locks t ON t.lock_owner_pid = s.process
ORDER  BY s.starttime;

-- Kill one:  SELECT pg_terminate_backend(<process>);


-- =========================================================================
-- 18.2  How applications should connect
--
-- (a) REDSHIFT DATA API — the default choice for anything serverless.
--     HTTP-based, IAM-authenticated, asynchronous, no connection to manage,
--     no VPC route needed. This is how our own scripts reach the cluster,
--     and why the cluster has no public endpoint.
--
--       import boto3
--       rs = boto3.client('redshift-data')
--       r = rs.execute_statement(
--               ClusterIdentifier='<CLUSTER_ID>',
--               Database='coaching',
--               SecretArn='<MASTER_SECRET_ARN>',
--               Sql='SELECT segment, SUM(gross_amount) FROM analytics.'
--                   'fct_customer_orders GROUP BY segment')
--       # asynchronous: poll, then fetch
--       rs.describe_statement(Id=r['Id'])       # -> FINISHED / FAILED
--       rs.get_statement_result(Id=r['Id'])
--
--     Limits worth knowing before you design around it: results are held
--     for 24 hours, a statement has a size cap, and it is ASYNCHRONOUS —
--     you poll rather than block. Do not wrap it to look synchronous and
--     then call it in a request handler.
--
-- (b) JDBC / ODBC / psycopg2 — for BI tools and long-lived services.
--     Use the Amazon Redshift JDBC driver, not the generic PostgreSQL one:
--     it handles IAM auth, and it knows Redshift-specific types the
--     Postgres driver mis-maps.
--
--       jdbc:redshift://<endpoint>:5439/coaching
--
--     psycopg2 works because of wire compatibility, but you are responsible
--     for pooling and for not sending Postgres-only SQL.
--
-- (c) IAM-based temporary credentials — no stored password anywhere:
--       aws redshift get-cluster-credentials \
--         --cluster-identifier <CLUSTER_ID> --db-user app_svc \
--         --db-name coaching --duration-seconds 3600
-- =========================================================================


-- =========================================================================
-- 18.3  Transactions — where SQL Server habits break
--
-- Redshift is SERIALIZABLE isolation. Not READ COMMITTED. There is no
-- READ UNCOMMITTED, no NOLOCK, and no row-level locking.
--
--   * Every statement runs in a transaction, autocommit unless you BEGIN.
--   * Locks are TABLE level, not row level.
--   * Concurrent transactions touching the same tables in a way that
--     cannot be serialized get: ERROR 1023 — Serializable isolation
--     violation. The loser is aborted and MUST BE RETRIED BY YOUR CODE.
--   * DDL is transactional (unlike MySQL), so a rolled-back CREATE TABLE
--     really does disappear.
--   * There are NO SUBTRANSACTIONS. No savepoints, no partial rollback.
-- =========================================================================
BEGIN;
    INSERT INTO analytics.audit_log (event_type, detail)
    VALUES ('TXN_DEMO', 'inside an explicit transaction');
    -- SAVEPOINT sp1;   -- NOT SUPPORTED
ROLLBACK;

SELECT COUNT(*) FROM analytics.audit_log WHERE event_type = 'TXN_DEMO'; -- 0

-- Serialization failures are a NORMAL operating condition under concurrency,
-- not a bug. Application code must catch SQLSTATE 40001 / error 1023 and
-- retry the whole transaction with backoff. Design every transaction to be
-- safely re-runnable from the top — the same discipline the stored
-- procedures in file 05 follow, and for the same reason.

-- Who is blocking whom:
SELECT l.table_id, i."table" AS table_name, l.lock_owner_pid,
       l.lock_mode, l.granted, l.last_update
FROM   stv_locks l
LEFT   JOIN svv_table_info i ON i.table_id = l.table_id
ORDER  BY l.last_update;

SELECT * FROM svv_transactions;

-- Long-running transactions block VACUUM and hold locks. Find them:
SELECT txn_owner, txn_db, xid, pid, txn_start,
       DATEDIFF(minute, txn_start, GETDATE()) AS age_min, lock_mode
FROM   svv_transactions
WHERE  DATEDIFF(minute, txn_start, GETDATE()) > 5
ORDER  BY txn_start;


-- =========================================================================
-- 18.4  Workload management — keeping the report queue away from the ETL
--
-- WLM decides how much memory each query gets and how many run at once.
-- The default is Automatic WLM, and for most projects that is correct.
-- What you add on top is QUERY PRIORITY and QUERY MONITORING RULES.
--
-- Concepts:
--   Queue / service class   a pool of concurrency + memory
--   Slot                    one running query's share of that memory
--   Priority                HIGHEST / HIGH / NORMAL / LOW / LOWEST
--   Concurrency scaling     burst to extra clusters under load
--   SQA                     short-query acceleration; small queries jump
-- =========================================================================

-- What queues exist and how are they configured?
SELECT * FROM stv_wlm_service_class_config;

-- What is queueing right now?
SELECT * FROM stv_wlm_query_state ORDER BY queue_time DESC;

-- Historical queueing — the number that justifies concurrency scaling:
SELECT service_class,
       COUNT(*)                                   AS queries,
       ROUND(AVG(queue_time)/1000000.0, 2)        AS avg_queue_sec,
       ROUND(MAX(queue_time)/1000000.0, 2)        AS max_queue_sec,
       ROUND(AVG(execution_time)/1000000.0, 2)    AS avg_exec_sec
FROM   sys_query_history
WHERE  start_time > DATEADD(day, -1, SYSDATE)
GROUP  BY service_class
ORDER  BY avg_queue_sec DESC;
-- Queue time approaching execution time means you are concurrency-bound,
-- not compute-bound. Adding nodes will NOT help; more slots or concurrency
-- scaling will.

-- Assign the ETL role to a priority. Requires a manual WLM config:
--   CREATE WORKLOAD GROUP etl_group WITH (query_group = 'etl');
--   SET query_group TO 'etl';        -- at the top of a load session
--   ... the load ...
--   RESET query_group;

-- Query monitoring rules abort runaway queries before they take the
-- cluster down. Configured on the parameter group, not in SQL — the shape:
--   { "rule_name": "abort_long_scans",
--     "predicate": [{"metric_name":"scan_row_count","operator":">","value":1000000000}],
--     "action": "abort" }
SELECT * FROM stl_wlm_rule_action ORDER BY recordtime DESC LIMIT 20;

-- Concurrency scaling usage — it is billed, so watch it:
SELECT * FROM svcs_concurrency_scaling_query_mapping LIMIT 20;


-- =========================================================================
-- 18.5  The query-tuning runbook
--
-- A systematic order for "this query is slow". Follow it top to bottom;
-- stop when you find the cause. Most incidents end at step 2 or 3.
-- =========================================================================

-- STEP 1 — Is it actually slow, or is it QUEUEING?
SELECT query_id, status,
       queue_time/1000000.0     AS queue_sec,
       execution_time/1000000.0 AS exec_sec,
       elapsed_time/1000000.0   AS total_sec
FROM   sys_query_history
WHERE  query_id = pg_last_query_id();
-- queue_sec >> exec_sec: it is a WLM problem, not a SQL problem. Stop here.

-- STEP 2 — Are the statistics current?
SELECT "table", tbl_rows, stats_off, unsorted, skew_rows
FROM   svv_table_info
WHERE  "schema" = 'analytics' AND stats_off > 5;
-- stats_off high: ANALYZE and re-test before touching the SQL.

-- STEP 3 — Read the plan. Is data moving, and is the scan restricted?
--   EXPLAIN <the query>;
--   Look for DS_BCAST_INNER / DS_DIST_BOTH (file 10)
SELECT step_name, table_name, input_rows, output_rows,
       duration/1000000.0 AS sec
FROM   sys_query_detail
WHERE  query_id = pg_last_query_id()
ORDER  BY duration DESC LIMIT 20;

-- STEP 4 — Did it spill to disk? That means it ran out of memory.
SELECT query_id, step_name,
       spilled_block_local_disk, spilled_block_remote_disk
FROM   sys_query_detail
WHERE  query_id = pg_last_query_id()
  AND  (spilled_block_local_disk > 0 OR spilled_block_remote_disk > 0);
-- Spilling: reduce the working set (fewer columns, earlier filters), or
-- give the query more memory via WLM.

-- STEP 5 — Was the sort key used?
SELECT slice, rows, rows_pre_filter, is_rrscan
FROM   stl_scan WHERE query = pg_last_query_id() AND tbl > 0;
-- is_rrscan = 'f': see file 11 §11.6 — a function in WHERE is the usual cause.

-- STEP 6 — If external, how many bytes did it scan?
SELECT query_id, SUM(s3_scanned_bytes)/1024/1024 AS mb_scanned
FROM   sys_external_query_detail
WHERE  query_id = pg_last_query_id() GROUP BY 1;

-- Only after all six do you rewrite the SQL. Most "slow query" tickets are
-- stale statistics or a queueing problem, and rewriting the SQL fixes
-- neither.


-- =========================================================================
-- 18.6  Checklist for the application side
--
--   [ ] The app does NOT open a connection per request
--   [ ] Data API for serverless/async; pooled JDBC for long-lived services
--   [ ] Credentials come from Secrets Manager or IAM, never config files
--   [ ] Every transaction is retryable, and 40001/1023 IS retried
--   [ ] No single-row INSERT loops — COPY or INSERT...SELECT
--   [ ] Request-rate point lookups live somewhere else, not Redshift
--   [ ] Long transactions are monitored (svv_transactions)
--   [ ] Queue time is measured before anyone rewrites SQL
-- =========================================================================
