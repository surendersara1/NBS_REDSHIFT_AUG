-- =========================================================================
-- 03 — S3 Tables (Iceberg) through the federated Glue catalog
--
-- This is the newest and least-documented path in the platform. Verified
-- against the Amazon Redshift Database Developer Guide, "Query Amazon S3
-- Tables from Amazon Redshift" (2026-08).
--
-- THE MAPPING. When S3 Tables is integrated with the Glue Data Catalog, the
-- service builds this hierarchy for you:
--
--   S3 table bucket   ->  a CHILD CATALOG under the federated catalog
--                         `s3tablescatalog`
--   S3 namespace      ->  a Glue DATABASE
--   S3 table          ->  a Glue TABLE
--
-- so our bronze table lives at the Glue path:
--
--   s3tablescatalog/<TABLE_BUCKET_NAME>/coaching/bronze_customers
--
-- -------------------------------------------------------------------------
-- THE THREE PREREQUISITES. Skip any one and this file fails.
--
--   1. S3 Tables integrated with the Glue Data Catalog
--        Once per ACCOUNT + REGION. Creates the `s3tablescatalog` federated
--        catalog. Eight learners in one account do this ONCE, not eight
--        times.
--
--   2. A Glue RESOURCE LINK to the namespace
--        Once per LEARNER (each learner has their own table bucket).
--        Redshift cannot point an external schema at a federated catalog
--        path directly — it can only point at a resource link that lives in
--        the ordinary Data Catalog and targets the federated path.
--
--   3. Lake Formation grants on the S3 Tables objects
--        Once per LEARNER. IAM alone is NOT sufficient. The s3tablescatalog
--        objects are Lake-Formation-governed, so the Redshift IAM role needs
--        DESCRIBE on the resource link, DESCRIBE on the target database, and
--        SELECT + DESCRIBE on the tables.
--
--   All three are done for you by:  scripts/bootstrap_s3tables.sh
--   Run it after `cdk deploy` and before this file. It is idempotent.
-- -------------------------------------------------------------------------
--
-- WHY THIS FILE WAS WRONG BEFORE, because the failure is worth teaching:
-- an earlier version pointed the external schema straight at the namespace
-- with CATALOG_ID '<account>:s3tablescatalog/<bucket>'. That composite form
-- is real, but it belongs to the resource link's TargetDatabase.CatalogId in
-- the Glue API — NOT to Redshift's CATALOG_ID, which takes a bare account
-- id. Getting it wrong yields "database does not exist", which reads like a
-- typo and sends people hunting the wrong problem for an hour.
--
-- Placeholders resolved by scripts/render_sql.sh:
--   <ACCOUNT_ID> <REGION> <S3TABLES_ROLE_ARN> <RESOURCE_LINK> <TABLE_BUCKET_NAME>
-- =========================================================================


-- =========================================================================
-- 3.0  Preflight — confirm the three prerequisites before debugging SQL
--
-- Run these in a terminal, not here. Each one fails loudly if a
-- prerequisite is missing, and the fix is named in the failure.
-- =========================================================================
--   # 1. Is the federated catalog there? (account+region wide)
--   aws glue get-catalog --catalog-id s3tablescatalog --region <REGION>
--
--   # 2. Is MY resource link there?
--   aws glue get-database --name <RESOURCE_LINK> --region <REGION>
--
--   # 3. Does my Redshift role hold Lake Formation grants?
--   aws lakeformation list-permissions --region <REGION> \
--     --principal DataLakePrincipalIdentifier=<S3TABLES_ROLE_ARN>
--
--   All three are asserted by:  ./scripts/bootstrap_s3tables.sh --verify


-- -------------------------------------------------------------------------
-- 3.1  Method 1 — CREATE EXTERNAL SCHEMA over the resource link
--
-- The one to teach. Explicit, inspectable, and the schema name is yours.
--
-- Read the three arguments carefully, because each is a place people go
-- wrong:
--
--   DATABASE    the RESOURCE LINK name in the ordinary catalog.
--               NOT the S3 namespace ('coaching'), and NOT the federated
--               path. The resource link is what points at those.
--   CATALOG_ID  the bare 12-digit ACCOUNT ID.
--               NOT '<account>:s3tablescatalog/<bucket>'.
--   REGION      required. Catalog, cluster and bucket must all be in the
--               same region for an external schema to resolve at all.
-- -------------------------------------------------------------------------
DROP SCHEMA IF EXISTS s3t_bronze;

CREATE EXTERNAL SCHEMA s3t_bronze
FROM DATA CATALOG
DATABASE '<RESOURCE_LINK>'
IAM_ROLE '<S3TABLES_ROLE_ARN>'
REGION '<REGION>'
CATALOG_ID '<ACCOUNT_ID>';

-- Confirm the mapping resolved. If `esoptions` is empty or the table list is
-- empty but the CREATE succeeded, the resource link exists but the Lake
-- Formation grants (prerequisite 3) are missing — CREATE EXTERNAL SCHEMA
-- does not validate them, so this is where that shows up.
SELECT schemaname, databasename, esoptions FROM svv_external_schemas
WHERE  schemaname = 's3t_bronze';

SELECT schemaname, tablename FROM svv_external_tables
WHERE  schemaname = 's3t_bronze'
ORDER  BY tablename;
-- Expect exactly three: bronze_customers, bronze_orders, silver_customer_orders

-- Now query Iceberg tables that Glue wrote, from Redshift, with no load.
SELECT COUNT(*) AS bronze_customers FROM s3t_bronze.bronze_customers;
SELECT COUNT(*) AS bronze_orders    FROM s3t_bronze.bronze_orders;

SELECT segment, country, COUNT(*) AS customers
FROM   s3t_bronze.bronze_customers
GROUP  BY segment, country
ORDER  BY customers DESC
LIMIT  20;


-- -------------------------------------------------------------------------
-- 3.2  Method 2 — CREATE DATABASE FROM ARN
--
-- Mounts the resource link as a Redshift DATABASE rather than a schema, so
-- the tables address with three-part notation. Useful when you want the S3
-- Tables namespace to look like a peer of `coaching` rather than a schema
-- inside it.
--
-- Note the ARN is the resource link's ARN in the ORDINARY catalog
-- (database/<RESOURCE_LINK>) — not an s3tablescatalog path.
-- -------------------------------------------------------------------------
DROP DATABASE IF EXISTS s3tables_db;

CREATE DATABASE s3tables_db
FROM ARN 'arn:aws:glue:<REGION>:<ACCOUNT_ID>:database/<RESOURCE_LINK>'
WITH DATA CATALOG SCHEMA bronze
IAM_ROLE '<S3TABLES_ROLE_ARN>';

SELECT * FROM s3tables_db.bronze.bronze_orders LIMIT 10;

-- Confirm it mounted:
SELECT database_name, database_type FROM svv_redshift_databases
ORDER  BY database_name;


-- -------------------------------------------------------------------------
-- 3.3  Method 3 — the auto-mounted awsdatacatalog
--
-- Redshift auto-mounts the Glue Data Catalog as a read-only database named
-- `awsdatacatalog`, reachable with three-part notation and no external
-- schema at all.
--
-- THE CATCH, and it is a real one: this requires Federated Access to
-- Spectrum (FAS). You must connect to Redshift AS AN IAM IDENTITY, not as
-- the local `nbsadmin` user. Redshift then creates a database user named
-- `IAMR:<role>` (for roles) or `IAM:<user>` (for users), and permissions are
-- granted to THAT principal.
--
-- Connecting as a local user and running these will show an empty
-- awsdatacatalog and look like a permissions bug. It is not — it is the
-- wrong login type. Teach this explicitly; it costs a full afternoon
-- otherwise.
--
-- In Query Editor v2: choose "Federated user" / "Temporary credentials
-- using your IAM identity", not "Database user name and password".
-- -------------------------------------------------------------------------
SHOW SCHEMAS FROM DATABASE awsdatacatalog;

-- As cluster admin, grant the federated principal access. Replace with your
-- own IAM role name — this is the role your laptop's credentials assume,
-- from `aws sts get-caller-identity`.
GRANT USAGE ON DATABASE awsdatacatalog TO "IAMR:<YOUR_IAM_ROLE_NAME>";
GRANT ALL   ON SCHEMA   awsdatacatalog TO "IAMR:<YOUR_IAM_ROLE_NAME>";

-- Query through the resource link name.
SELECT * FROM awsdatacatalog."<RESOURCE_LINK>"."bronze_orders" LIMIT 10;


-- -------------------------------------------------------------------------
-- 3.4  The silver join, read from Redshift
--
-- Glue produced silver_customer_orders. Redshift reads it in place. This is
-- the moment to make the architectural point out loud:
--
--   The join was done ONCE, in Spark, and written to Iceberg. Redshift
--   reads the result. It did not re-join anything.
--
-- Compare against re-joining bronze inside Redshift and note the cost
-- difference in sys_external_query_detail.
-- -------------------------------------------------------------------------
SELECT segment, country,
       COUNT(*)                AS order_count,
       SUM(gross_amount)       AS gross,
       AVG(gross_amount)       AS avg_order
FROM   s3t_bronze.silver_customer_orders
WHERE  status = 'COMPLETED'
GROUP  BY segment, country
ORDER  BY gross DESC;

-- The same answer, joined live instead. Time both.
SELECT c.segment, c.country,
       COUNT(*) AS order_count,
       SUM(o.quantity * o.unit_price) AS gross
FROM   s3t_bronze.bronze_orders o
JOIN   s3t_bronze.bronze_customers c USING (customer_id)
WHERE  o.status = 'COMPLETED'
GROUP  BY c.segment, c.country
ORDER  BY gross DESC;

-- How much S3 did each one actually touch? This is the number that makes
-- the argument, not the wall-clock.
SELECT query_id, segment_id, total_partitions, qualified_partitions,
       scanned_files, returned_rows, returned_bytes
FROM   sys_external_query_detail
WHERE  query_id IN (SELECT query_id FROM sys_query_history
                    WHERE  user_id = current_user_id
                    ORDER  BY start_time DESC LIMIT 10)
ORDER  BY query_id DESC;


-- -------------------------------------------------------------------------
-- 3.5  Writing back to Iceberg from Redshift
--
-- Redshift's Iceberg write support is narrower than Spark's, and the
-- boundary matters when you design a write path:
--
--   INSERT              supported against S3 Tables
--   UPDATE/DELETE/MERGE do these in Glue, not Redshift
--
-- The IAM role already carries s3tables:PutTableData and glue:UpdateTable.
-- Verify against the Developer Guide for your cluster version before
-- designing anything that depends on this.
-- -------------------------------------------------------------------------
-- INSERT INTO s3t_bronze.silver_customer_orders
-- SELECT ... FROM analytics.fct_customer_orders;


-- =========================================================================
-- 3.6  When it fails — the four errors, and what each actually means
--
--   "database does not exist" on CREATE EXTERNAL SCHEMA
--       The resource link is missing, or DATABASE was given the namespace
--       ('coaching') instead of the resource link name.
--       Fix: ./scripts/bootstrap_s3tables.sh
--
--   CREATE EXTERNAL SCHEMA succeeds, but svv_external_tables is EMPTY
--       Lake Formation grants missing. IAM is not enough.
--       Fix: ./scripts/bootstrap_s3tables.sh --grants-only
--
--   "Insufficient privileges" on SELECT
--       Grants exist on the resource link but not on the target database or
--       the tables. All three levels are required.
--
--   awsdatacatalog is empty (3.3 only)
--       You are connected as a local database user. Reconnect with your IAM
--       identity. Nothing is wrong with the catalog.
-- =========================================================================
