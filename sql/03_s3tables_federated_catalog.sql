-- =========================================================================
-- 03 — S3 Tables (Iceberg) through the federated catalog
--
-- This is the newest and least-documented path in the platform, so the
-- mapping is worth memorising. When S3 Tables is integrated with the Glue
-- Data Catalog, the service builds this hierarchy for you:
--
--   S3 table bucket   ->  a CATALOG under the federated catalog `s3tablescatalog`
--   S3 namespace      ->  a Glue DATABASE
--   S3 table          ->  a Glue TABLE
--
-- so our bronze table addresses as:
--
--   s3tablescatalog/nbs-coaching-tables-dev/coaching/bronze_customers
--
-- PREREQUISITE, and the step everyone skips: S3 Tables must first be
-- integrated with the Glue Data Catalog for the account+region, and the
-- cluster must have the S3 Tables IAM role attached (CDK does the second
-- part; the first is a one-time account action).
--
--   aws s3tables get-table-bucket --table-bucket-arn <arn>
--
-- Replace <S3TABLES_ROLE_ARN>, <ACCOUNT_ID>, <TABLE_BUCKET_NAME>.
-- =========================================================================


-- -------------------------------------------------------------------------
-- 3.1  Method 1 — external schema pointed at the federated catalog
--
-- The CATALOG_ID here is NOT just the account. For a federated S3 Tables
-- catalog it is '<account>:s3tablescatalog/<table-bucket-name>'. Getting
-- this wrong produces "database does not exist" rather than a permission
-- error, which sends people hunting the wrong problem for an hour.
-- -------------------------------------------------------------------------
CREATE EXTERNAL SCHEMA IF NOT EXISTS s3t_bronze
FROM DATA CATALOG
DATABASE 'coaching'                       -- the S3 namespace
IAM_ROLE '<S3TABLES_ROLE_ARN>'
CATALOG_ID '<ACCOUNT_ID>:s3tablescatalog/<TABLE_BUCKET_NAME>';

-- Confirm the mapping resolved.
SELECT schemaname, databasename, esoptions FROM svv_external_schemas;
SELECT schemaname, tablename FROM svv_external_tables
WHERE  schemaname = 's3t_bronze';

-- Now query Iceberg tables that Glue wrote, from Redshift, with no load.
SELECT COUNT(*) AS bronze_customers FROM s3t_bronze.bronze_customers;
SELECT COUNT(*) AS bronze_orders    FROM s3t_bronze.bronze_orders;

SELECT segment, country, COUNT(*) AS customers
FROM   s3t_bronze.bronze_customers
GROUP  BY segment, country
ORDER  BY customers DESC
LIMIT  20;


-- -------------------------------------------------------------------------
-- 3.2  Method 2 — the auto-mounted awsdatacatalog
--
-- Redshift auto-mounts the Glue Data Catalog as a read-only database named
-- `awsdatacatalog`, reachable with three-part notation and NO external
-- schema at all. Requires a Glue resource link to the S3 Tables database
-- (create it once in the Glue console: Databases -> Create -> Resource link).
--
-- Three-part notation: <database>.<schema>.<table>
-- -------------------------------------------------------------------------
SHOW SCHEMAS FROM DATABASE awsdatacatalog;

-- Grant a learner access to the auto-mounted catalog:
GRANT USAGE ON SCHEMA awsdatacatalog."coaching_link" TO ROLE engineer_role;

SELECT * FROM awsdatacatalog."coaching_link"."bronze_orders" LIMIT 10;


-- -------------------------------------------------------------------------
-- 3.3  The silver join, read from Redshift
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


-- -------------------------------------------------------------------------
-- 3.4  Writing back to Iceberg from Redshift
--
-- Redshift can INSERT into S3 Tables when the role carries s3tables:PutTableData
-- and glue:UpdateTable (both are in the CDK policy). This is how the
-- computed silver dump in file 04 gets published back to the lake.
--
-- Caveat worth stating plainly: Redshift's Iceberg write support is
-- narrower than Spark's. INSERT works; UPDATE/DELETE/MERGE against S3
-- Tables should be done in Glue. Verify against the Redshift Database
-- Developer Guide for your cluster version before designing a write path.
-- -------------------------------------------------------------------------
-- INSERT INTO s3t_bronze.silver_customer_orders
-- SELECT ... FROM analytics.fct_customer_orders;
