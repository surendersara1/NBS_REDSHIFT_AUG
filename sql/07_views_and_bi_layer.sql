-- =========================================================================
-- 07 — Views, late-binding views, materialized views, and what BI sees
--
-- Three things called "view" that behave completely differently. Choosing
-- wrong is the most common self-inflicted wound on a warehouse project.
--
--   VIEW (bound)              Re-runs its query every time. Bound to the
--                             tables underneath at CREATE time, so dropping
--                             one of them FAILS until the view is dropped
--                             too.
--
--   LATE-BINDING VIEW         Resolved at query time instead. You can drop
--   (WITH NO SCHEMA BINDING)  and rebuild the tables beneath it freely —
--                             which is exactly what a nightly rebuild does.
--
--   MATERIALIZED VIEW         Stores the result and refreshes it. Fast to
--                             read, and exactly as stale as its last
--                             refresh. It is a cache, with all that implies.
--
-- THE RULE: expose late-binding views or MVs to BI. Never base tables.
-- Point a Power BI report at a base table and you have frozen your schema
-- by accident — you can no longer rename a column without breaking a
-- report you cannot see.
-- =========================================================================


-- -------------------------------------------------------------------------
-- 7.0  A little more data, so the BI examples are real
--
-- A date dimension turns the fact table into an actual star schema, which
-- is what BI tools expect and what makes the join patterns below meaningful.
-- Generated from a recursive CTE — no external file needed.
-- -------------------------------------------------------------------------
DROP TABLE IF EXISTS analytics.dim_date CASCADE;

CREATE TABLE analytics.dim_date (
    date_key      DATE     NOT NULL,
    year_num      SMALLINT NOT NULL,
    quarter_num   SMALLINT NOT NULL,
    month_num     SMALLINT NOT NULL,
    month_name    VARCHAR(12),
    day_of_month  SMALLINT,
    day_of_week   SMALLINT,
    day_name      VARCHAR(12),
    is_weekend    BOOLEAN,
    fiscal_year   SMALLINT,
    fiscal_quarter SMALLINT
)
DISTSTYLE ALL              -- date dimensions are always ALL
SORTKEY (date_key);

INSERT INTO analytics.dim_date
WITH RECURSIVE d(dt) AS (
    SELECT '2023-01-01'::DATE
    UNION ALL
    SELECT (dt + 1)::DATE FROM d WHERE dt < '2026-12-31'::DATE
)
SELECT dt,
       EXTRACT(year    FROM dt)::SMALLINT,
       EXTRACT(quarter FROM dt)::SMALLINT,
       EXTRACT(month   FROM dt)::SMALLINT,
       TO_CHAR(dt, 'Month'),
       EXTRACT(day FROM dt)::SMALLINT,
       EXTRACT(dow FROM dt)::SMALLINT,
       TO_CHAR(dt, 'Day'),
       EXTRACT(dow FROM dt) IN (0, 6),
       -- fiscal year starts 1 Feb
       (CASE WHEN EXTRACT(month FROM dt) = 1
             THEN EXTRACT(year FROM dt) - 1
             ELSE EXTRACT(year FROM dt) END)::SMALLINT,
       (((EXTRACT(month FROM dt)::INT + 10) % 12) / 3 + 1)::SMALLINT
FROM d;

ANALYZE analytics.dim_date;
SELECT COUNT(*) AS date_rows, MIN(date_key), MAX(date_key) FROM analytics.dim_date;


-- =========================================================================
-- 7.1  A BOUND view — and the failure it causes
-- =========================================================================
CREATE OR REPLACE VIEW analytics.v_orders_bound AS
SELECT o.order_id, o.customer_id, o.segment, o.order_date, o.gross_amount
FROM   analytics.fct_customer_orders o;

-- Now try the thing a nightly rebuild does every single night:
--
--     DROP TABLE analytics.fct_customer_orders;
--
-- It FAILS:
--     ERROR: cannot drop table fct_customer_orders because other objects
--     depend on it
--
-- You are then forced into DROP ... CASCADE, which silently destroys the
-- view as well, and tomorrow BI reports "object does not exist".
-- Prove it, then drop the view:
--
--     DROP TABLE analytics.fct_customer_orders;         -- fails
--     DROP TABLE analytics.fct_customer_orders CASCADE; -- takes the view too

-- Find what is bound to what BEFORE you drop anything:
SELECT DISTINCT
       src_nsp.nspname  AS source_schema,
       src.relname      AS source_object,
       dep_nsp.nspname  AS dependent_schema,
       dep.relname      AS dependent_object
FROM   pg_depend d
JOIN   pg_rewrite r    ON r.oid = d.objid
JOIN   pg_class dep    ON dep.oid = r.ev_class
JOIN   pg_namespace dep_nsp ON dep_nsp.oid = dep.relnamespace
JOIN   pg_class src    ON src.oid = d.refobjid
JOIN   pg_namespace src_nsp ON src_nsp.oid = src.relnamespace
WHERE  d.refclassid = 'pg_class'::regclass
  AND  dep.relname <> src.relname
  AND  src_nsp.nspname = 'analytics'
ORDER  BY 1, 2;


-- =========================================================================
-- 7.2  A LATE-BINDING view — the same query, none of the pain
--
-- WITH NO SCHEMA BINDING resolves object names at QUERY time. The view can
-- be created before its base table even exists, and the base table can be
-- dropped and rebuilt underneath it all night long.
--
-- The trade: nothing validates the reference. A typo in a column name is
-- not an error at CREATE time — it is an error the first time BI runs it.
-- Late-binding views are also REQUIRED for any view over an external table.
-- =========================================================================
CREATE OR REPLACE VIEW analytics.v_orders_latebound AS
SELECT o.order_id, o.customer_id, o.segment, o.country,
       o.order_date, o.gross_amount, o.status
FROM   analytics.fct_customer_orders o
WITH NO SCHEMA BINDING;

-- This now works, and the view survives:
--     DROP TABLE analytics.fct_customer_orders;   -- succeeds, no CASCADE
--     ... rebuild it ...
--     SELECT * FROM analytics.v_orders_latebound; -- works again

-- Which of your views are late-binding? Late-binding views do NOT appear in
-- the dependency query above — that absence IS the property.
SELECT schemaname, viewname, definition LIKE '%no schema binding%' AS is_late_binding
FROM   pg_views
WHERE  schemaname = 'analytics';


-- =========================================================================
-- 7.3  The BI reporting layer — what Power BI is actually allowed to see
--
-- Pattern: a dedicated `rpt` schema containing ONLY late-binding views and
-- materialized views. BI has USAGE on `rpt` and nothing at all on
-- `analytics` or `staging`. That single boundary buys you:
--
--   * freedom to rename, repartition, or rebuild any base table
--   * a place to apply business naming ("Gross Revenue", not gross_amount)
--   * one auditable surface when someone asks "what can BI see?"
-- =========================================================================
CREATE SCHEMA IF NOT EXISTS rpt;
COMMENT ON SCHEMA rpt IS 'BI-facing layer. Late-binding views + MVs only. No base tables, ever.';

-- (a) Late-binding view: business names, star-schema join, no stored bytes.
CREATE OR REPLACE VIEW rpt.v_sales_by_month AS
SELECT d.year_num             AS "Year",
       d.month_num            AS "Month Number",
       TRIM(d.month_name)     AS "Month",
       o.segment              AS "Customer Segment",
       o.country              AS "Country",
       COUNT(*)               AS "Order Count",
       COUNT(DISTINCT o.customer_id) AS "Distinct Customers",
       SUM(o.gross_amount)    AS "Gross Revenue",
       AVG(o.gross_amount)    AS "Average Order Value"
FROM   analytics.fct_customer_orders o
JOIN   analytics.dim_date d ON d.date_key = o.order_date
WHERE  o.status = 'COMPLETED'
GROUP  BY 1, 2, 3, 4, 5
WITH NO SCHEMA BINDING;

-- (b) Materialized view for the dashboard tile that loads on every page.
--     Same data, stored. Read it when latency matters more than freshness.
DROP MATERIALIZED VIEW IF EXISTS rpt.mv_exec_dashboard;

CREATE MATERIALIZED VIEW rpt.mv_exec_dashboard
DISTSTYLE ALL
SORTKEY (order_date)
AUTO REFRESH YES
AS
SELECT o.order_date,
       o.segment,
       COUNT(*)                          AS order_count,
       SUM(o.gross_amount)               AS gross_revenue,
       SUM(CASE WHEN o.status = 'CANCELLED' THEN o.gross_amount ELSE 0 END)
                                         AS cancelled_value
FROM   analytics.fct_customer_orders o
GROUP  BY o.order_date, o.segment;

REFRESH MATERIALIZED VIEW rpt.mv_exec_dashboard;

-- (c) Grant the BI role the reporting layer and NOTHING else.
GRANT USAGE  ON SCHEMA rpt TO ROLE analyst_role;
GRANT SELECT ON ALL TABLES IN SCHEMA rpt TO ROLE analyst_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA rpt
  GRANT SELECT ON TABLES TO ROLE analyst_role;

-- And explicitly do NOT grant analytics/staging:
REVOKE ALL ON SCHEMA staging   FROM ROLE analyst_role;
REVOKE ALL ON ALL TABLES IN SCHEMA staging FROM ROLE analyst_role;


-- =========================================================================
-- 7.4  Proving the boundary works
-- =========================================================================

-- Everything the BI role can reach. If a base table appears here, the
-- boundary has leaked.
SELECT namespace_name, relation_name, privilege_type
FROM   svv_relation_privileges
WHERE  identity_name = 'analyst_role'
ORDER  BY namespace_name, relation_name;

-- Which objects in rpt are views, MVs, or (wrongly) tables?
SELECT schemaname, tablename AS object_name, 'table' AS kind
FROM   pg_tables  WHERE schemaname = 'rpt'
UNION ALL
SELECT schemaname, viewname, 'view'
FROM   pg_views   WHERE schemaname = 'rpt'
UNION ALL
-- SVV_MV_INFO's column is `name`, not `table_name`. Verified against the
-- Redshift Database Developer Guide: the columns are database_name,
-- schema_name, user_name, name, is_stale, state, autorewrite, autorefresh.
SELECT schema_name, name, 'matview'
FROM   svv_mv_info WHERE schema_name = 'rpt'
ORDER  BY kind, object_name;
-- Expected: zero rows of kind 'table'.

-- MV staleness — the question every BI user eventually asks.
SELECT schema_name, name, is_stale, autorefresh, state
FROM   svv_mv_info
WHERE  schema_name IN ('rpt','analytics');

SELECT mv_name, status, refresh_type, start_time, duration
FROM   sys_mv_refresh_history
ORDER  BY start_time DESC LIMIT 10;


-- =========================================================================
-- 7.5  Choosing between the three — the decision, stated plainly
--
--   Query is cheap, data must be current      -> late-binding view
--   Query is expensive, staleness acceptable  -> materialized view
--   Object will never be dropped or rebuilt   -> bound view (rare;
--                                                default to late-binding)
--
-- The measurement, not the assertion: run both and compare.
-- =========================================================================
SELECT COUNT(*) FROM rpt.v_sales_by_month;    -- computes the join every time
SELECT COUNT(*) FROM rpt.mv_exec_dashboard;   -- reads stored rows

SELECT query_id, LEFT(query_text, 60) AS sql_preview,
       elapsed_time/1000000.0 AS elapsed_sec, returned_rows
FROM   sys_query_history
WHERE  start_time > DATEADD(minute, -10, SYSDATE)
  AND  query_text ILIKE '%rpt.%'
ORDER  BY start_time DESC LIMIT 10;
