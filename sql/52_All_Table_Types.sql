/*
======================================================================================
MODULE 52: ALL TABLE TYPES, VIEWS, AND MATERIALIZED VIEWS
======================================================================================
TARGET AUDIENCE: Application Developers & Senior Data Engineers
BUSINESS SCENARIO: 
An engineering team is building out the Data Warehouse. The application developers 
default to creating standard permanent tables for everything—staging data, raw logs, 
final aggregations, and API-serving layers. 

THE PROBLEM:
Treating every table as a standard permanent table in Redshift causes:
1. Massive snapshot/backup bloat (paying AWS to backup disposable staging data).
2. Poor performance for aggregations that could be pre-computed.
3. Nightmare deployments when altering schemas because Views lock underlying tables.
4. Cluster storage exhaustion from lingering temporary data.

THE GOAL:
Provide the definitive Master Checklist of EVERY table/view type in Redshift.
Show exact DDL examples, options, and explicitly explain WHEN to use each.
======================================================================================
*/


-- ===================================================================================
-- 1. THE PERMANENT TABLE (The Standard)
-- ===================================================================================
/*
USE CASE: Core Fact and Dimension tables in your Gold/Silver layer.
PROS: Fully persistent, backed up in automated snapshots, high availability.
CONS: Consumes physical storage, backups cost money.
*/
CREATE TABLE IF NOT EXISTS gold_sales_fct (
    sale_id BIGINT,
    amount DECIMAL(10,2)
)
DISTSTYLE KEY DISTKEY (sale_id)
SORTKEY (sale_id);


-- ===================================================================================
-- 2. THE PERMANENT TABLE WITH "BACKUP NO"
-- ===================================================================================
/*
USE CASE: Massive Staging Tables or intermediate processing tables that persist 
          beyond a session but DO NOT need to be restored if the cluster crashes 
          (because you can just reload the source file from S3).
PROS: Saves significant AWS snapshot costs. Faster to write to (slightly) because 
      blocks aren't tracked for incremental backup.
CONS: If the cluster reboots from a snapshot, this table will be EMPTY.
*/
CREATE TABLE IF NOT EXISTS stg_sales_massive (
    sale_id BIGINT,
    amount DECIMAL(10,2)
) 
BACKUP NO; -- <--- The magic keyword


-- ===================================================================================
-- 3. THE TEMPORARY TABLE (Session-Scoped)
-- ===================================================================================
/*
USE CASE: Intermediate data inside a Stored Procedure or an Airflow session.
PROS: Private to the session. No schema locks. Extremely fast. 
CONS: App developers assume they evaporate after the procedure ends. THEY DO NOT. 
      They evaporate when the *connection* closes. If you use a connection pool, 
      they live forever and bloat the cluster.
*/
-- The Standard Temp Table (lives until connection closes)
CREATE TEMP TABLE #temp_raw_data (id INT);

-- The Optimized Temp Table (evaporates instantly at the end of the transaction)
-- USE THIS 99% OF THE TIME IN STORED PROCEDURES.
CREATE TEMP TABLE #temp_safe_data (
    id INT
) ON COMMIT DROP;


-- ===================================================================================
-- 4. THE EXTERNAL TABLE (Redshift Spectrum)
-- ===================================================================================
/*
USE CASE: Querying Petabytes of cold data (JSON/Parquet) sitting in S3 without 
          actually loading it into Redshift's local SSDs.
PROS: Infinite storage. You pay per terabyte scanned, not for storage.
CONS: Slower than local tables. Cannot run UPDATE or DELETE statements on them.
*/
-- Requires an External Schema pointing to AWS Glue/Athena Data Catalog
-- CREATE EXTERNAL SCHEMA spectrum_schema FROM DATA CATALOG ... 

-- CREATE EXTERNAL TABLE spectrum_schema.ext_web_logs (
--     log_id VARCHAR,
--     event_timestamp TIMESTAMP
-- )
-- PARTITIONED BY (year INT, month INT) -- Crucial for Spectrum performance
-- STORED AS PARQUET
-- LOCATION 's3://my-company-data-lake/web_logs/';


-- ===================================================================================
-- 5. STANDARD VIEWS vs LATE-BINDING VIEWS
-- ===================================================================================
/*
USE CASE: Creating an abstraction layer for BI tools (Looker, Tableau).
THE PROBLEM WITH STANDARD VIEWS: 
If you create a standard View on `gold_sales_fct`, Redshift places a schema lock on it. 
If a data engineer tries to `DROP TABLE gold_sales_fct` or `ALTER TABLE`, it fails 
because the view depends on it. This breaks CI/CD pipelines.

THE SOLUTION: Late-Binding Views (WITH NO SCHEMA BINDING).
*/

-- BAD: Standard View (Locks the underlying table)
CREATE OR REPLACE VIEW vw_sales_standard AS 
SELECT sale_id FROM gold_sales_fct;

-- GOOD: Late-Binding View 
-- Redshift doesn't check if the underlying table exists until query time.
-- You can freely DROP/RECREATE the underlying table without touching the view!
CREATE OR REPLACE VIEW vw_sales_late_binding
AS 
SELECT sale_id FROM gold_sales_fct
WITH NO SCHEMA BINDING;


-- ===================================================================================
-- 6. MATERIALIZED VIEWS (The Ultimate Performance Booster)
-- ===================================================================================
/*
USE CASE: A BI dashboard queries a complex aggregate (e.g., Daily Revenue by Region) 
          10,000 times a day. Running the `GROUP BY` on a 10-billion row fact table 
          every time kills the cluster CPU.
SOLUTION: Materialized Views physicalize the result set to disk. The BI tool queries 
          the pre-computed MV instantly.

OPTIONS:
1. AUTO REFRESH: Redshift automatically updates the MV in the background when the 
                 base tables change.
2. MANUAL REFRESH: You control exactly when it updates via `REFRESH MATERIALIZED VIEW`.
*/

-- Create a Materialized view that automatically updates itself
CREATE MATERIALIZED VIEW mv_daily_revenue_by_region
AUTO REFRESH YES
AS
SELECT 
    DATE_TRUNC('day', event_timestamp) as sales_day,
    region,
    SUM(amount) as total_revenue
FROM gold_sales_fct
GROUP BY 1, 2;

-- If you set AUTO REFRESH NO, you must orchestrate this command in Airflow:
-- REFRESH MATERIALIZED VIEW mv_daily_revenue_by_region;


-- ===================================================================================
-- SUMMARY CHECKLIST FOR ARCHITECTS
-- ===================================================================================
/*
1. Is it the final Gold layer? -> STANDARD PERMANENT TABLE.
2. Is it a massive Staging table? -> PERMANENT TABLE with BACKUP NO.
3. Is it intermediate processing in a procedure? -> TEMP TABLE ... ON COMMIT DROP.
4. Is it a Petabyte of cold historical data? -> EXTERNAL TABLE (Spectrum).
5. Are you building a BI layer to hide column names? -> LATE BINDING VIEW.
6. Is it a heavy aggregation queried constantly? -> MATERIALIZED VIEW.
*/
