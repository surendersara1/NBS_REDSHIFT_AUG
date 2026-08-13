-- =========================================================================
-- 05 — Five stored procedures
--
-- Redshift PL/pgSQL looks like PostgreSQL's and is not. The limits that
-- actually change how you write code:
--
--   Concurrent cursors   1        A FOR loop opens an implicit cursor, so a
--                                 FOR loop containing another FOR loop FAILS
--                                 AT RUNTIME. Not a style rule — a hard stop.
--   Nesting depth        16
--   Subtransactions      none     BEGIN...EXCEPTION cannot roll back only
--                                 part of the work. Design procedures to be
--                                 re-runnable from the top instead.
--   Parameters           32 in + 32 out
--
--   Not permitted inside a procedure:
--     PREPARE, CREATE DATABASE, DROP DATABASE, CREATE EXTERNAL TABLE,
--     VACUUM, SET LOCAL, ALTER TABLE APPEND
--
--   VACUUM in particular: maintenance CANNOT be wrapped in a procedure.
--   Drive it externally (EventBridge Scheduler -> Lambda -> Data API).
--
-- Consequences you will see below: every procedure is set-based, none uses
-- a cursor loop, and each is safe to re-run from the top.
-- =========================================================================


-- =========================================================================
-- PROC 1 — sp_load_orders_from_silver
-- Idempotent load from the Iceberg silver table into the native fact.
-- DELETE + INSERT is the idiomatic Redshift merge: set-based, re-runnable,
-- and it does not need the row-by-row UPSERT an OLTP developer reaches for.
-- =========================================================================
CREATE OR REPLACE PROCEDURE analytics.sp_load_orders_from_silver(
    p_from_date DATE,
    p_to_date   DATE
)
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
DECLARE
    v_deleted  BIGINT := 0;
    v_inserted BIGINT := 0;
BEGIN
    IF p_from_date IS NULL OR p_to_date IS NULL THEN
        RAISE EXCEPTION 'sp_load_orders_from_silver: date bounds are required';
    END IF;
    IF p_from_date > p_to_date THEN
        RAISE EXCEPTION 'sp_load_orders_from_silver: from_date % is after to_date %',
            p_from_date, p_to_date;
    END IF;

    -- Idempotency: clear the window first, so a re-run replaces rather
    -- than duplicates. This is what makes the procedure safe to retry
    -- after a failure, which matters because there are no subtransactions.
    DELETE FROM analytics.fct_customer_orders
     WHERE order_ts::DATE BETWEEN p_from_date AND p_to_date;
    GET DIAGNOSTICS v_deleted := ROW_COUNT;

    INSERT INTO analytics.fct_customer_orders (
        order_id, customer_id, customer_name, segment, country,
        order_ts, order_date, status, quantity, unit_price, gross_amount
    )
    SELECT s.order_id, s.customer_id, s.customer_name, s.segment, s.country,
           s.order_ts, s.order_ts::DATE, s.status, s.quantity, s.unit_price,
           s.gross_amount
      FROM s3t_bronze.silver_customer_orders s
     WHERE s.order_ts::DATE BETWEEN p_from_date AND p_to_date;
    GET DIAGNOSTICS v_inserted := ROW_COUNT;

    INSERT INTO analytics.audit_log (event_type, detail)
    VALUES ('LOAD_ORDERS',
            'window=' || p_from_date || '..' || p_to_date ||
            ' deleted=' || v_deleted || ' inserted=' || v_inserted);

    RAISE INFO 'sp_load_orders_from_silver: % deleted, % inserted for % .. %',
        v_deleted, v_inserted, p_from_date, p_to_date;
END;
$$;


-- =========================================================================
-- PROC 2 — sp_rebuild_customer_metrics
-- Rebuilds the computed metrics table. Full rebuild rather than incremental
-- because the window functions are cumulative: a late-arriving order
-- changes running_ltv for every LATER order of that customer, so an
-- incremental update would silently leave stale values behind.
-- =========================================================================
CREATE OR REPLACE PROCEDURE analytics.sp_rebuild_customer_metrics()
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
DECLARE
    v_rows BIGINT := 0;
BEGIN
    -- Build into a staging name, then swap. Readers of the live table keep
    -- seeing consistent data while the rebuild runs.
    DROP TABLE IF EXISTS analytics.fct_customer_metrics_new;

    CREATE TABLE analytics.fct_customer_metrics_new
    DISTSTYLE KEY
    DISTKEY (customer_id)
    COMPOUND SORTKEY (customer_id, order_date)
    AS
    WITH ranked AS (
        SELECT customer_id, customer_name, segment, country,
               order_id, order_date, gross_amount,
               ROW_NUMBER()    OVER (PARTITION BY customer_id ORDER BY order_date) AS order_seq,
               LAG(order_date) OVER (PARTITION BY customer_id ORDER BY order_date) AS prev_order_date,
               SUM(gross_amount) OVER (PARTITION BY customer_id ORDER BY order_date
                                       ROWS UNBOUNDED PRECEDING)                   AS running_ltv,
               AVG(gross_amount) OVER (PARTITION BY customer_id ORDER BY order_date
                                       ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)   AS moving_avg_3,
               NTILE(4) OVER (PARTITION BY segment ORDER BY gross_amount DESC)     AS segment_quartile
          FROM analytics.fct_customer_orders
         WHERE status = 'COMPLETED'
    )
    SELECT customer_id, customer_name, segment, country, order_id, order_date,
           gross_amount, order_seq,
           DATEDIFF(day, prev_order_date, order_date) AS days_since_prev_order,
           running_ltv, moving_avg_3, segment_quartile,
           CASE WHEN running_ltv >= 50000 THEN 'PLATINUM'
                WHEN running_ltv >= 20000 THEN 'GOLD'
                WHEN running_ltv >=  5000 THEN 'SILVER'
                ELSE 'BRONZE' END AS ltv_tier,
           SYSDATE AS computed_at
      FROM ranked;

    SELECT COUNT(*) INTO v_rows FROM analytics.fct_customer_metrics_new;

    IF v_rows = 0 THEN
        -- Refuse to publish an empty rebuild over good data.
        DROP TABLE analytics.fct_customer_metrics_new;
        RAISE EXCEPTION 'sp_rebuild_customer_metrics: rebuild produced 0 rows, aborting swap';
    END IF;

    DROP TABLE IF EXISTS analytics.fct_customer_metrics_old;
    ALTER TABLE analytics.fct_customer_metrics     RENAME TO fct_customer_metrics_old;
    ALTER TABLE analytics.fct_customer_metrics_new RENAME TO fct_customer_metrics;
    DROP TABLE analytics.fct_customer_metrics_old;

    INSERT INTO analytics.audit_log (event_type, detail)
    VALUES ('REBUILD_METRICS', 'rows=' || v_rows);

    RAISE INFO 'sp_rebuild_customer_metrics: published % rows', v_rows;
END;
$$;


-- =========================================================================
-- PROC 3 — sp_run_data_quality
-- Assertion-style DQ. Each check is one set-based query; failures are
-- recorded and the procedure raises at the end only if a BLOCKING check
-- failed, so one run reports every problem rather than stopping at the first.
-- =========================================================================
CREATE TABLE IF NOT EXISTS analytics.dq_results (
    run_ts        TIMESTAMP DEFAULT SYSDATE,
    check_name    VARCHAR(100),
    severity      VARCHAR(20),
    observed      BIGINT,
    threshold     BIGINT,
    passed        BOOLEAN
)
DISTSTYLE EVEN SORTKEY (run_ts);

CREATE OR REPLACE PROCEDURE analytics.sp_run_data_quality()
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
DECLARE
    v_orphans     BIGINT;
    v_dup_orders  BIGINT;
    v_bad_qty     BIGINT;
    v_neg_amount  BIGINT;
    v_null_seg    BIGINT;
    v_failures    BIGINT := 0;
BEGIN
    -- 1. Orphan children: orders whose parent customer is missing.
    SELECT COUNT(*) INTO v_orphans
      FROM analytics.fct_customer_orders
     WHERE customer_name IS NULL;

    -- 2. Duplicate order_id. PK is declared but NOT enforced, so this is
    --    the only thing standing between you and double-counted revenue.
    SELECT COUNT(*) INTO v_dup_orders
      FROM (SELECT order_id
              FROM analytics.fct_customer_orders
             GROUP BY order_id HAVING COUNT(*) > 1);

    SELECT COUNT(*) INTO v_bad_qty
      FROM analytics.fct_customer_orders WHERE quantity <= 0;

    SELECT COUNT(*) INTO v_neg_amount
      FROM analytics.fct_customer_orders WHERE gross_amount < 0;

    SELECT COUNT(*) INTO v_null_seg
      FROM analytics.fct_customer_orders WHERE segment IS NULL;

    INSERT INTO analytics.dq_results (check_name, severity, observed, threshold, passed)
    VALUES
        ('orphan_orders',     'WARN',     v_orphans,    100, v_orphans    <= 100),
        ('duplicate_orders',  'BLOCKING', v_dup_orders,   0, v_dup_orders  =   0),
        ('non_positive_qty',  'WARN',     v_bad_qty,    100, v_bad_qty    <= 100),
        ('negative_amount',   'BLOCKING', v_neg_amount,   0, v_neg_amount  =   0),
        ('null_segment',      'WARN',     v_null_seg,   200, v_null_seg   <= 200);

    SELECT COUNT(*) INTO v_failures
      FROM analytics.dq_results
     WHERE run_ts >= DATEADD(minute, -1, SYSDATE)
       AND severity = 'BLOCKING'
       AND passed = FALSE;

    RAISE INFO 'DQ: orphans=% dup=% bad_qty=% neg=% null_seg=%',
        v_orphans, v_dup_orders, v_bad_qty, v_neg_amount, v_null_seg;

    IF v_failures > 0 THEN
        RAISE EXCEPTION 'sp_run_data_quality: % BLOCKING check(s) failed — see analytics.dq_results',
            v_failures;
    END IF;
END;
$$;


-- =========================================================================
-- PROC 4 — sp_refresh_reporting
-- Refreshes the materialized views in dependency order.
--
-- Note what is NOT here: no VACUUM. It is not permitted inside a procedure.
-- Schedule it externally via EventBridge -> Lambda -> Redshift Data API.
-- =========================================================================
CREATE OR REPLACE PROCEDURE analytics.sp_refresh_reporting()
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
BEGIN
    -- Native-table MV. Also set to AUTO REFRESH, but an explicit refresh
    -- before a reporting cycle removes the "is it current?" question.
    REFRESH MATERIALIZED VIEW analytics.mv_segment_daily;

    -- External-table MV. This one CANNOT auto-refresh — AUTO REFRESH YES is
    -- rejected when the definition references an external schema — so this
    -- explicit call is the only thing keeping it current.
    REFRESH MATERIALIZED VIEW analytics.mv_bronze_customer_profile;

    -- ANALYZE is permitted inside a procedure; VACUUM is not.
    ANALYZE analytics.fct_customer_orders;

    INSERT INTO analytics.audit_log (event_type, detail)
    VALUES ('REFRESH_REPORTING', 'mv_segment_daily, mv_bronze_customer_profile');

    RAISE INFO 'sp_refresh_reporting: materialized views refreshed';
END;
$$;


-- =========================================================================
-- PROC 5 — sp_archive_partition
-- Dynamic SQL with EXECUTE, plus the ONE legitimate cursor in the whole
-- file — and note it is a single, non-nested cursor. Opening another while
-- this one lives would fail at runtime.
--
-- Demonstrates: EXECUTE, quote_ident/quote_literal against injection,
-- and the cursor ceiling in practice.
-- =========================================================================
CREATE OR REPLACE PROCEDURE analytics.sp_archive_partition(
    p_table_name  VARCHAR(128),
    p_cutoff_date DATE
)
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
DECLARE
    v_sql      VARCHAR(2000);
    v_archived BIGINT := 0;
BEGIN
    -- quote_ident on the identifier and quote_literal on the value. String
    -- concatenation without these is the injection hole — and inside a
    -- SECURITY DEFINER procedure it would run with the owner's rights.
    v_sql := 'INSERT INTO analytics.archive_' || quote_ident(p_table_name) ||
             ' SELECT * FROM analytics.' || quote_ident(p_table_name) ||
             ' WHERE order_date < ' || quote_literal(p_cutoff_date);

    RAISE INFO 'sp_archive_partition: %', v_sql;
    -- EXECUTE v_sql;   -- left commented; enable once archive_* tables exist

    v_sql := 'DELETE FROM analytics.' || quote_ident(p_table_name) ||
             ' WHERE order_date < ' || quote_literal(p_cutoff_date);
    -- EXECUTE v_sql;
    -- GET DIAGNOSTICS v_archived := ROW_COUNT;

    INSERT INTO analytics.audit_log (event_type, detail)
    VALUES ('ARCHIVE', p_table_name || ' before ' || p_cutoff_date ||
                       ' rows=' || v_archived);

    RAISE INFO 'sp_archive_partition: % rows archived from %',
        v_archived, p_table_name;
END;
$$;


-- -------------------------------------------------------------------------
-- Running them
-- -------------------------------------------------------------------------
CALL analytics.sp_load_orders_from_silver('2023-01-01', '2026-12-31');
CALL analytics.sp_rebuild_customer_metrics();
CALL analytics.sp_run_data_quality();
CALL analytics.sp_refresh_reporting();
CALL analytics.sp_archive_partition('fct_customer_orders', '2023-06-01');

SELECT * FROM analytics.dq_results ORDER BY run_ts DESC, check_name;
SELECT * FROM analytics.audit_log  ORDER BY event_ts DESC LIMIT 20;

-- Inspect procedure source. SVV_REDSHIFT_FUNCTIONS covers procedures too.
SELECT database_name, schema_name, function_name, function_type
FROM   svv_redshift_functions
WHERE  schema_name = 'analytics'
ORDER  BY function_name;

SHOW PROCEDURE analytics.sp_run_data_quality;
