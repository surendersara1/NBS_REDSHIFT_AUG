-- =========================================================================
-- 08 — External schemas: TWO KINDS, POINTING AT TWO DIFFERENT THINGS
--
-- "External schema" is one phrase covering two unrelated capabilities.
-- Confusing them wastes days, because the syntax is nearly identical and
-- the failure modes are completely different.
--
--   SPECTRUM      CREATE EXTERNAL SCHEMA ... FROM DATA CATALOG
--                 Reads FILES in the lake through the Glue catalog:
--                 Parquet, ORC, CSV, JSON, Avro — plus Iceberg, Hudi CoW
--                 and Delta Lake.
--                 The data is at rest in S3. Nothing is live.
--
--   FEDERATED     CREATE EXTERNAL SCHEMA ... FROM POSTGRES / FROM MYSQL
--                 Reads a LIVE RDS or Aurora PostgreSQL/MySQL database as
--                 it is right now. Filters are pushed down to the source,
--                 so the remote database does the WHERE.
--                 The data is live. You are querying someone's OLTP system.
--
-- GOVERNANCE MOVES. Redshift GRANT governs local tables. Anything read
-- through the Glue catalog is governed by LAKE FORMATION instead. Two
-- permission systems inside one query — see 8.4.
--
-- READ, MOSTLY. Spectrum's READ support is broad. Its WRITE support is
-- narrow and format-dependent. Verify for your specific format before
-- promising a write path — do not assume symmetry with read.
-- =========================================================================


-- =========================================================================
-- 8.1  KIND ONE — Spectrum, over the data catalog
-- =========================================================================
-- Already created in file 02, repeated here for contrast:
--
--   CREATE EXTERNAL SCHEMA spectrum_raw
--   FROM DATA CATALOG
--   DATABASE '<GLUE_DB>'
--   IAM_ROLE '<SPECTRUM_ROLE_ARN>'
--   CREATE EXTERNAL DATABASE IF NOT EXISTS;
--
-- Variants worth knowing:
--
--   FROM DATA CATALOG        Glue Data Catalog (the normal case)
--   FROM HIVE METASTORE      a self-managed Hive metastore on EMR
--                            URI 'thrift://<host>' PORT 9083
--
-- Open table formats readable this way: Iceberg, Hudi Copy-on-Write, and
-- Delta Lake. Note Hudi Merge-on-Read is NOT the same as CoW — check which
-- one your source actually writes before designing around it.


-- =========================================================================
-- 8.2  KIND TWO — Federated query, to a live operational database
--
-- This is the one nobody expects Redshift to do. It queries RDS/Aurora
-- PostgreSQL or MySQL live, in the same SELECT as your warehouse tables.
--
-- Prerequisites, all three or it will not work:
--   1. Redshift and the RDS instance can reach each other on the network
--      (same VPC, or peered, with the RDS security group allowing 5432/3306
--      from the Redshift security group).
--   2. A Secrets Manager secret holding the DB credentials.
--   3. The cluster's IAM role has secretsmanager:GetSecretValue on it.
--
-- Not deployed by this stack — the coaching environment has no RDS. Left
-- here as the reference shape, because you WILL meet it on the project.
-- =========================================================================

-- PostgreSQL / Aurora PostgreSQL:
--
--   CREATE EXTERNAL SCHEMA fed_orders_pg
--   FROM POSTGRES
--   DATABASE 'orders_db'
--   SCHEMA 'public'
--   URI 'orders.cluster-abc123.us-east-1.rds.amazonaws.com'
--   PORT 5432
--   IAM_ROLE 'arn:aws:iam::<ACCOUNT_ID>:role/RedshiftFederatedRole'
--   SECRET_ARN 'arn:aws:secretsmanager:us-east-1:<ACCOUNT_ID>:secret:orders-db-xxxxx';

-- MySQL / Aurora MySQL:
--
--   CREATE EXTERNAL SCHEMA fed_orders_mysql
--   FROM MYSQL
--   DATABASE 'orders_db'
--   URI 'orders.cluster-abc123.us-east-1.rds.amazonaws.com'
--   PORT 3306
--   IAM_ROLE 'arn:aws:iam::<ACCOUNT_ID>:role/RedshiftFederatedRole'
--   SECRET_ARN 'arn:aws:secretsmanager:us-east-1:<ACCOUNT_ID>:secret:orders-mysql-xxxxx';
--
-- Note MySQL federation has no SCHEMA clause — MySQL's "database" IS the
-- schema. Copying the Postgres form and adding SCHEMA is a syntax error.

-- The payoff — warehouse history joined to live operational state in one
-- query, with no pipeline in between:
--
--   SELECT h.customer_id, h.running_ltv, live.credit_hold, live.updated_at
--   FROM   analytics.fct_customer_metrics h
--   JOIN   fed_orders_pg.customer_status live USING (customer_id)
--   WHERE  live.credit_hold = TRUE;
--
-- FOUR THINGS TO SAY OUT LOUD BEFORE ANYONE USES THIS:
--
--   1. You are putting warehouse load on a production OLTP database.
--      Predicate pushdown limits it, but a careless join will scan the
--      remote table. Agree this with the OLTP owner first.
--   2. Federated tables are READ ONLY. No INSERT, UPDATE, or DELETE.
--   3. It is live, so the same query run twice returns different answers.
--      That is a feature here and a bug in a reconciliation report.
--   4. Pushdown is not guaranteed. Verify it (8.5) rather than assume it.


-- =========================================================================
-- 8.3  Once you have them — how to check what actually exists
-- =========================================================================

-- What external schemas exist, and where do they point?
-- esoptions carries the target: the Glue database for Spectrum, or the
-- host/port/secret for a federated schema. It is the fastest way to tell
-- the two kinds apart at a glance.
SELECT schemaname, databasename, esoptions
FROM   svv_external_schemas
ORDER  BY schemaname;

-- What tables are visible through them?
SELECT schemaname, tablename, location, input_format
FROM   svv_external_tables
ORDER  BY 1, 2;

-- Column-level detail, including the external type names (which are Glue
-- type strings, not Redshift ones — 'bigint' here, 'string' not 'varchar').
SELECT schemaname, tablename, columnname, external_type, columnnum, part_key
FROM   svv_external_columns
ORDER  BY schemaname, tablename, columnnum;

-- Partitions actually registered. A partition that exists in S3 but not
-- here is invisible to Spectrum — this is the "my data is missing" answer.
SELECT schemaname, tablename, values, location
FROM   svv_external_partitions
ORDER  BY schemaname, tablename;


-- =========================================================================
-- 8.4  Where governance moves — the two-permission-systems problem
--
-- A single query touching analytics.fct_customer_orders AND
-- spectrum_raw.silver_customer_metrics is governed by BOTH:
--
--   analytics.*      -> Redshift GRANT       (svv_relation_privileges)
--   spectrum_raw.*   -> Lake Formation       (LF grants, not visible here)
--
-- So "I granted SELECT and they still get permission denied" almost always
-- means the Redshift grant succeeded and the Lake Formation grant is
-- missing. Check both.
-- =========================================================================

-- The Redshift half:
GRANT USAGE ON SCHEMA spectrum_raw TO ROLE analyst_role;
GRANT SELECT ON ALL TABLES IN SCHEMA spectrum_raw TO ROLE analyst_role;

SELECT namespace_name, relation_name, identity_name, privilege_type
FROM   svv_relation_privileges
WHERE  namespace_name IN ('spectrum_raw','s3t_bronze')
ORDER  BY relation_name;

-- The Lake Formation half is NOT in Redshift's catalog. Check it from the
-- CLI — there is no SQL for this, which is exactly why it gets forgotten:
--
--   aws lakeformation list-permissions \
--     --resource '{"Table":{"DatabaseName":"<GLUE_DB>","TableWildcard":{}}}'
--
--   aws lakeformation grant-permissions \
--     --principal DataLakePrincipalIdentifier=arn:aws:iam::<ACCT>:role/<SPECTRUM_ROLE_NAME> \
--     --resource '{"Table":{"DatabaseName":"<GLUE_DB>","TableWildcard":{}}}' \
--     --permissions SELECT


-- =========================================================================
-- 8.5  How much did that external query actually scan?
--
-- The single most important habit for anyone touching Spectrum: after every
-- external query, look at the bytes. Spectrum bills per TB scanned, so an
-- unpruned query is a bill, not just a slow query.
--
-- pg_last_query_id() returns the query id of the statement you just ran in
-- this session, so this works as a copy-paste follow-up to anything.
-- =========================================================================

-- Run something external first:
SELECT COUNT(*), AVG(running_ltv)
FROM   spectrum_raw.silver_customer_metrics
WHERE  ltv_tier = 'PLATINUM';

-- Then immediately:
SELECT query,
       SUM(s3_scanned_bytes) / 1024 / 1024 AS mb_scanned,
       SUM(s3_scanned_rows)                AS rows_scanned,
       SUM(s3query_returned_rows)          AS rows_returned
FROM   svl_s3query_summary
WHERE  query = pg_last_query_id()
GROUP  BY 1;
-- (column is s3_scanned_rows, with the underscore — s3scanned_rows does
--  not exist and returns "column does not exist")

-- The modern equivalent, preferred for new work:
SELECT query_id, segment_id, s3_scanned_rows, s3_scanned_bytes,
       s3_query_returned_rows, s3_query_returned_bytes
FROM   sys_external_query_detail
WHERE  query_id = pg_last_query_id();

-- THE PRUNING PROOF — run both and compare mb_scanned. If the numbers are
-- the same, your partitions are not being used and you are paying for a
-- full scan on every query.
SELECT COUNT(*) FROM spectrum_raw.silver_customer_metrics
WHERE  ltv_tier = 'PLATINUM';                     -- one partition
SELECT COUNT(*) FROM spectrum_raw.silver_customer_metrics;  -- all partitions

-- Per-file detail — how many files were opened, and were any of them tiny?
-- Many small files is the other Spectrum cost trap: overhead per file
-- dominates once files drop below ~64 MB.
SELECT query, file_format, is_partitioned,
       COUNT(*) AS files, SUM(s3_scanned_bytes)/1024/1024 AS mb
FROM   svl_s3query_summary
WHERE  query > pg_last_query_id() - 20
GROUP  BY 1, 2, 3
ORDER  BY query DESC;


-- =========================================================================
-- 8.6  Write support — verify, do not promise
--
-- Read support is broad. Write support is narrow and format-dependent:
--
--   INSERT INTO an external table          Parquet/text on Glue, limited
--   INSERT INTO an Iceberg / S3 Tables     supported with the right IAM,
--                                          but narrower than Spark's
--   UPDATE / DELETE / MERGE externally     do it in Glue, not Redshift
--   Federated (Postgres/MySQL)             READ ONLY, no writes at all
--
-- Before designing any write path, confirm against the Redshift Database
-- Developer Guide for YOUR cluster version and YOUR table format. This is
-- the area that changes most between releases, so a blog post from last
-- year is not evidence.
-- =========================================================================
SELECT version();   -- pin the answer to a version before you check the docs
