/*
======================================================================================
MODULE 63: DATA SHARING — CROSS-ACCOUNT & CROSS-CLUSTER ZERO-COPY DEEP DIVE
======================================================================================
MAPPED BEST PRACTICES (from PROCEDURE_OPTIMIZATION_BEST_PRACTICES_MASTER_FILE.md):
- Practice 48-51: Distribution key alignment carries into datashare consumers.
- Practice 89-91: Medallion layers can be shared as read-only Gold products.
- Practice 92: Consistent naming — producer/consumer namespace conventions.
- Practice 104: Separate ETL from BI — consumers run BI without touching ETL cluster.
- Practice 109: Snapshot safety — datashares are read-only; no accidental writes.

TARGET AUDIENCE: Data Platform Architects, Multi-Team Data Mesh Leads
BUSINESS SCENARIO:
A financial services firm runs three Redshift clusters:
  1. ETL Cluster (us-east-1): Ingests 200M trades/day into Gold star schema.
  2. Risk Analytics Cluster (us-east-1): Runs Monte Carlo simulations against trade data.
  3. Compliance Cluster (eu-west-1): EU regulators require data residency in Ireland.

Without Data Sharing, the firm copies 50TB nightly between clusters — burning $12K/day in
UNLOAD/COPY costs and creating a 6-hour data lag. With Data Sharing, all three clusters
read the same live data with zero copy, zero lag, zero S3 transit cost.

ARCHITECTURE:
┌──────────────────────────────────────────────────────────────────────────────────┐
│                        PRODUCER CLUSTER (ETL – us-east-1)                        │
│  ┌──────────────────────────────────────────────────────────────────────────┐    │
│  │  Gold Schema: analytics.dim_customer, analytics.fact_trades             │    │
│  │  DISTSTYLE KEY (trade_id), SORTKEY (trade_date)                        │    │
│  └──────────────────────────┬───────────────────────────────────────────────┘    │
│                             │ CREATE DATASHARE                                   │
│                             ▼                                                    │
│  ┌──────────────────────────────────────────────────────────────────────────┐    │
│  │  Datashare: ds_gold_analytics                                           │    │
│  │  ├── Schema: analytics                                                  │    │
│  │  ├── Tables: fact_trades, dim_customer, dim_product                     │    │
│  │  └── Views:  vw_daily_trade_summary (late-binding)                      │    │
│  └──────────────┬──────────────────────────────────┬────────────────────────┘    │
│                 │                                   │                             │
└─────────────────┼───────────────────────────────────┼─────────────────────────────┘
                  │ SAME-ACCOUNT                      │ CROSS-ACCOUNT (via AWS RAM)
                  ▼                                   ▼
┌─────────────────────────────────┐  ┌─────────────────────────────────────────────┐
│  CONSUMER: Risk Analytics       │  │  CONSUMER: Compliance (eu-west-1)            │
│  (Same Account, Same Region)    │  │  (Different Account, Cross-Region via        │
│                                 │  │   cross-region datashare)                    │
│  CREATE DATABASE risk_db        │  │  CREATE DATABASE compliance_db               │
│    FROM DATASHARE ds_gold_...   │  │    FROM DATASHARE ds_gold_...                │
│    OF NAMESPACE 'abc123...'     │  │    OF ACCOUNT '<CONSUMER_ACCOUNT_ID>'                 │
│                                 │  │    NAMESPACE 'abc123...'                     │
│  SELECT * FROM risk_db          │  │                                              │
│    .analytics.fact_trades       │  │  -- EU regulators see live data, zero copy   │
│  WHERE trade_date >= CURRENT..  │  │  SELECT * FROM compliance_db                │
└─────────────────────────────────┘  │    .analytics.fact_trades                    │
                                     │  WHERE counterparty_country = 'IE'           │
                                     └─────────────────────────────────────────────┘

======================================================================================
*/

-- ============================================================================
-- SECTION 1: PRODUCER — CREATING AND POPULATING THE DATASHARE
-- ============================================================================
-- IMPLEMENTS: Best Practices #89-91 (Medallion), #92 (Naming Conventions)
-- 
-- A datashare is a named container on the PRODUCER cluster that holds references
-- to schemas, tables, views, and UDFs. No data is copied — the consumer reads
-- directly from the producer's managed storage (RMS).
--
-- KEY RULES:
--   1. Only RA3 or Serverless clusters can produce/consume datashares.
--   2. Datashares are READ-ONLY for consumers — zero risk of accidental writes.
--   3. Tables retain their DISTKEY/SORTKEY — consumer queries benefit from the
--      producer's physical layout.
--   4. Only SUPER users or users with CREATE DATASHARE privilege can create them.

-- Step 1: Create the datashare on the producer
CREATE DATASHARE ds_gold_analytics
  INCLUDENEW = TRUE;           -- Auto-include new tables added to shared schemas
-- INCLUDENEW = TRUE is critical for operational teams: when you add a new Gold
-- table, consumers automatically see it without manual ALTER DATASHARE commands.

-- Step 2: Add schemas and objects to the datashare
ALTER DATASHARE ds_gold_analytics ADD SCHEMA analytics;

ALTER DATASHARE ds_gold_analytics ADD TABLE analytics.fact_trades;
ALTER DATASHARE ds_gold_analytics ADD TABLE analytics.dim_customer;
ALTER DATASHARE ds_gold_analytics ADD TABLE analytics.dim_product;

-- You can also add ALL TABLES in a schema at once:
ALTER DATASHARE ds_gold_analytics ADD ALL TABLES IN SCHEMA analytics;

-- Add a late-binding view (regular views cannot be shared):
ALTER DATASHARE ds_gold_analytics
  ADD TABLE analytics.vw_daily_trade_summary;

-- Step 3: Grant usage to a consumer namespace (same account)
-- Find the consumer's namespace with: SELECT current_namespace;
GRANT USAGE ON DATASHARE ds_gold_analytics
  TO NAMESPACE '<CONSUMER_NAMESPACE>';

-- Step 4: Grant usage to a consumer in a DIFFERENT AWS account
-- This requires AWS RAM (Resource Access Manager) to authorize the account.
GRANT USAGE ON DATASHARE ds_gold_analytics
  TO ACCOUNT '<CONSUMER_ACCOUNT_ID>';
-- After this, the consumer account must ACCEPT the datashare via the Redshift
-- console or AWS CLI before creating a database from it.


-- ============================================================================
-- SECTION 2: CONSUMER — MOUNTING THE DATASHARE AS A LOCAL DATABASE
-- ============================================================================
-- IMPLEMENTS: Best Practice #104 (Separate ETL from BI workloads)
--
-- On the consumer cluster, the datashare appears as a read-only database.
-- Consumers cannot INSERT/UPDATE/DELETE — they can only SELECT.

-- Same-account consumer:
CREATE DATABASE risk_analytics_db
  FROM DATASHARE ds_gold_analytics
  OF NAMESPACE '<CONSUMER_NAMESPACE>';

-- Cross-account consumer:
CREATE DATABASE compliance_eu_db
  FROM DATASHARE ds_gold_analytics
  OF ACCOUNT '<CONSUMER_ACCOUNT_ID>'
  NAMESPACE '<CONSUMER_NAMESPACE>';

-- Now query as if it were a local table:
SELECT
    t.trade_date,
    c.customer_name,
    p.product_category,
    SUM(t.trade_amount) AS total_volume
FROM risk_analytics_db.analytics.fact_trades   t
JOIN risk_analytics_db.analytics.dim_customer  c ON t.customer_key = c.customer_key
JOIN risk_analytics_db.analytics.dim_product   p ON t.product_key  = p.product_key
WHERE t.trade_date >= DATEADD(day, -30, CURRENT_DATE)
GROUP BY 1, 2, 3
ORDER BY total_volume DESC;

-- IMPORTANT: This query runs on the CONSUMER'S compute.
-- The producer cluster is not affected. This is how you separate ETL from BI.


-- ============================================================================
-- SECTION 3: MANAGING PERMISSIONS ON SHARED DATA
-- ============================================================================
-- IMPLEMENTS: Best Practice #92 (Consistent naming and access control)

-- On the CONSUMER cluster, grant access to specific roles:
GRANT USAGE ON DATABASE risk_analytics_db TO ROLE risk_analysts;
GRANT USAGE ON SCHEMA risk_analytics_db.analytics TO ROLE risk_analysts;
GRANT SELECT ON ALL TABLES IN SCHEMA risk_analytics_db.analytics TO ROLE risk_analysts;

-- You can combine datashares with Row-Level Security (RLS) on the PRODUCER.
-- If the producer has an RLS policy on fact_trades, the consumer sees filtered data
-- based on the consumer's session user.


-- ============================================================================
-- SECTION 4: MONITORING DATASHARE USAGE
-- ============================================================================
-- IMPLEMENTS: Best Practices #97-101 (Observability & Monitoring)

-- On the PRODUCER: See which datashares exist and their consumers
SELECT
    share_name,
    share_type,       -- OUTBOUND (producer) or INBOUND (consumer)
    object_type,
    object_name,
    consumer_account,
    consumer_namespace
FROM SVV_DATASHARES
ORDER BY share_name;

-- On the PRODUCER: Track consumer query volume against shared objects
SELECT
    share_name,
    consumer_account,
    consumer_namespace,
    request_type,
    query_count,
    total_data_scanned_bytes / (1024*1024*1024) AS data_scanned_gb
FROM SYS_DATASHARE_USAGE_PRODUCER
WHERE query_date >= DATEADD(day, -7, CURRENT_DATE)
ORDER BY data_scanned_gb DESC;

-- On the CONSUMER: Track your own consumption
SELECT
    share_name,
    producer_account,
    request_type,
    query_count,
    total_data_scanned_bytes / (1024*1024*1024) AS data_scanned_gb
FROM SYS_DATASHARE_USAGE_CONSUMER
WHERE query_date >= DATEADD(day, -7, CURRENT_DATE)
ORDER BY data_scanned_gb DESC;


-- ============================================================================
-- SECTION 5: ANTI-PATTERN — COPYING DATA INSTEAD OF SHARING
-- ============================================================================
-- THE BAD WAY: UNLOAD from producer, COPY into consumer (the "ETL tax")
--
-- PROBLEM: This creates:
--   • 6-hour data lag (UNLOAD takes 2h, S3 transfer 1h, COPY takes 3h)
--   • $12,000/day in S3 PUT/GET + cross-region transfer costs
--   • 50TB of duplicate storage on the consumer cluster
--   • Schema drift — if producer adds a column, consumer COPY breaks
--
-- -- Producer side (BAD):
-- UNLOAD ('SELECT * FROM analytics.fact_trades WHERE trade_date = ''2026-08-14''')
-- TO 's3://<CURATED_BUCKET>/fact_trades/dt=2026-08-14/'
-- IAM_ROLE '<SPECTRUM_ROLE_ARN>'
-- FORMAT AS PARQUET
-- ALLOWOVERWRITE;
--
-- -- Consumer side (BAD):
-- COPY analytics.fact_trades
-- FROM 's3://<CURATED_BUCKET>/fact_trades/dt=2026-08-14/'
-- IAM_ROLE '<SPECTRUM_ROLE_ARN>'
-- FORMAT AS PARQUET;
--
-- THE GOOD WAY: Data sharing (zero copy, zero lag, zero cost)
-- Already shown in Sections 1-2 above. The consumer queries live producer data.


-- ============================================================================
-- SECTION 6: DATASHARE WITH MATERIALIZED VIEWS
-- ============================================================================
-- You CAN share materialized views through datashares.
-- The MV is maintained on the producer; consumers read the pre-computed results.

-- Producer creates an auto-refreshing MV:
CREATE MATERIALIZED VIEW analytics.mv_daily_trade_summary
AUTO REFRESH YES
AS
SELECT
    trade_date,
    product_key,
    COUNT(*)            AS trade_count,
    SUM(trade_amount)   AS total_amount,
    AVG(trade_amount)   AS avg_amount
FROM analytics.fact_trades
GROUP BY trade_date, product_key;

-- Add it to the datashare:
ALTER DATASHARE ds_gold_analytics
  ADD TABLE analytics.mv_daily_trade_summary;

-- Consumer gets sub-second dashboard queries against pre-aggregated data
-- without maintaining their own MV or ETL pipeline.


-- ============================================================================
-- SECTION 7: REVOKING AND DROPPING DATASHARES
-- ============================================================================

-- Revoke access from a specific consumer:
REVOKE USAGE ON DATASHARE ds_gold_analytics
  FROM NAMESPACE '<CONSUMER_NAMESPACE>';

-- Remove specific objects:
ALTER DATASHARE ds_gold_analytics REMOVE TABLE analytics.dim_product;

-- Drop the entire datashare (consumers lose access immediately):
DROP DATASHARE ds_gold_analytics;

-- On the consumer side, drop the mounted database:
DROP DATABASE risk_analytics_db;


-- ============================================================================
-- SECTION 8: CROSS-REGION DATA SHARING (PREVIEW / GA 2025+)
-- ============================================================================
-- Cross-region datashares allow a producer in us-east-1 to share with a consumer
-- in eu-west-1. This is critical for GDPR data residency requirements.
--
-- LIMITATIONS:
--   • Higher latency (cross-region network hops)
--   • Additional data transfer costs (same as any cross-region S3 transfer)
--   • Not all regions support cross-region datashares — check AWS docs
--
-- RECOMMENDATION: For latency-sensitive EU compliance queries, consider
-- a combination of cross-region datashare + consumer-side MV caching.

-- Cross-region consumer setup (on eu-west-1 cluster):
CREATE DATABASE compliance_eu_db
  FROM DATASHARE ds_gold_analytics
  OF ACCOUNT '<PRODUCER_ACCOUNT_ID>'         -- Producer's AWS account
  NAMESPACE '<PRODUCER_NAMESPACE>'     -- Producer's namespace
  REGION 'us-east-1';               -- Producer's region

-- Then query locally:
SELECT trade_date, SUM(trade_amount)
FROM compliance_eu_db.analytics.fact_trades
WHERE counterparty_country = 'IE'
  AND trade_date >= DATEADD(month, -3, CURRENT_DATE)
GROUP BY trade_date;


-- ============================================================================
-- SECTION 9: DATA SHARING vs. OTHER SHARING MECHANISMS
-- ============================================================================
/*
┌─────────────────────┬──────────────────┬───────────────────┬──────────────────┐
│ Feature             │ Data Sharing     │ UNLOAD/COPY       │ Federated Query  │
├─────────────────────┼──────────────────┼───────────────────┼──────────────────┤
│ Data Freshness      │ Real-time (live) │ Batch (hours lag) │ Real-time        │
│ Data Copy Required? │ No (zero-copy)   │ Yes (full copy)   │ No               │
│ Cross-Account       │ Yes              │ Yes (via S3)      │ No               │
│ Cross-Region        │ Yes (preview)    │ Yes               │ No               │
│ Consumer Compute    │ Consumer's       │ Consumer's        │ Producer's       │
│ Write Access        │ Read-only        │ Full (it's a copy)│ Read-only        │
│ Schema Sync         │ Automatic        │ Manual            │ Automatic        │
│ Cost                │ Compute only     │ Storage + Transfer│ Compute only     │
│ Supports MVs        │ Yes              │ N/A               │ N/A              │
│ Supports UDFs       │ Yes              │ N/A               │ N/A              │
└─────────────────────┴──────────────────┴───────────────────┴──────────────────┘
*/

-- ============================================================================
-- SECTION 10: COMPLETE PRODUCER SETUP PROCEDURE
-- ============================================================================
-- IMPLEMENTS: Best Practices #80-87 (Transactions & Reliability), #97 (ROW_COUNT)

CREATE OR REPLACE PROCEDURE admin.sp_setup_datashare(
    p_share_name        VARCHAR(128),
    p_schema_name       VARCHAR(128),
    p_consumer_namespace VARCHAR(256)
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_sql       VARCHAR(2000);
    v_share_exists INT;
BEGIN
    -- 1. Check if datashare already exists (idempotency)
    SELECT COUNT(*) INTO v_share_exists
    FROM SVV_DATASHARES
    WHERE share_name = p_share_name
      AND share_type = 'OUTBOUND';

    IF v_share_exists > 0 THEN
        RAISE INFO 'Datashare % already exists. Adding schema objects.', p_share_name;
    ELSE
        -- Create the datashare
        v_sql := 'CREATE DATASHARE ' || p_share_name || ' INCLUDENEW = TRUE';
        EXECUTE v_sql;
        RAISE INFO 'Created datashare: %', p_share_name;
    END IF;

    -- 2. Add the schema
    v_sql := 'ALTER DATASHARE ' || p_share_name || ' ADD SCHEMA ' || p_schema_name;
    EXECUTE v_sql;

    -- 3. Add all tables in the schema
    v_sql := 'ALTER DATASHARE ' || p_share_name
          || ' ADD ALL TABLES IN SCHEMA ' || p_schema_name;
    EXECUTE v_sql;

    -- 4. Grant to the consumer namespace
    v_sql := 'GRANT USAGE ON DATASHARE ' || p_share_name
          || ' TO NAMESPACE ''' || p_consumer_namespace || '''';
    EXECUTE v_sql;

    RAISE INFO 'Datashare % configured for consumer namespace %.',
               p_share_name, p_consumer_namespace;

EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'sp_setup_datashare FAILED: % — SQLSTATE: %', SQLERRM, SQLSTATE;
    -- Re-raise so the caller knows it failed
    RAISE;
END;
$$;

-- Usage:
-- CALL admin.sp_setup_datashare(
--     'ds_gold_analytics',
--     'analytics',
--     '<CONSUMER_NAMESPACE>'
-- );
