/*
======================================================================================
MODULE 76: PERFORMANCE BENCHMARKING LAB — THE COMPLETE OPTIMIZATION WORKFLOW
======================================================================================
MAPPED BEST PRACTICES (from PROCEDURE_OPTIMIZATION_BEST_PRACTICES_MASTER_FILE.md):
THIS MODULE IMPLEMENTS THE ENTIRE §A (Method & Mindset) — PRACTICES 1–10:
- Practice 1: "Reproduce reliably — get a repeatable case with fixed inputs."
- Practice 2: "Measure before you change anything — capture baseline."
- Practice 3: "Understand before changing — map inputs, steps, outputs."
- Practice 4: "Chase the 80/20 — fix the 2-3 slowest steps."
- Practice 5: "Correctness is the gate — diff output before vs. after."
- Practice 6: "Change one thing at a time — edit, re-measure, keep or revert."
- Practice 7: "Fix approach before micro-tuning syntax."
- Practice 8: "Keep the original safe."
- Practice 9: "Leave code more readable than you found it."
- Practice 10: "Measure continuously, not just once."

ALSO IMPLEMENTS:
- Practice 35: "Read the EXPLAIN plan before and after every change."
- Practice 111: "Diff output row counts/checksums before vs. after."
- Practice 112: "Optimize incrementally — fix the biggest bottleneck, re-measure."

TARGET AUDIENCE: ALL Redshift Engineers (this is the #1 skill)
BUSINESS SCENARIO:
You've inherited a stored procedure (sp_build_daily_fact_orders) that runs in the
nightly ETL pipeline. It used to take 8 minutes. Now it takes 2.5 hours.
Management is asking "why is the pipeline late?" and you have 4 hours to fix it.

This module is a HANDS-ON LAB. Follow each step in order.

THE METHOD (EVERY TIME, WITHOUT EXCEPTION):
┌──────────────────────────────────────────────────────────────────────────────┐
│                    THE OPTIMIZATION METHOD                                   │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌──────────────────────────────────────────┐                               │
│  │ STEP 1: REPRODUCE                        │                               │
│  │ Get a repeatable case with fixed inputs. │                               │
│  │ If you can't reproduce it, you can't     │                               │
│  │ measure it, and you can't fix it.        │                               │
│  └──────────────┬───────────────────────────┘                               │
│                 ▼                                                            │
│  ┌──────────────────────────────────────────┐                               │
│  │ STEP 2: MEASURE BASELINE                 │                               │
│  │ Capture: runtime, EXPLAIN plan, row      │                               │
│  │ counts, checksums. This is your "before."│                               │
│  └──────────────┬───────────────────────────┘                               │
│                 ▼                                                            │
│  ┌──────────────────────────────────────────┐                               │
│  │ STEP 3: UNDERSTAND                       │                               │
│  │ Map the procedure's steps. Comment them. │                               │
│  │ Find which 2-3 steps take 80% of time.   │                               │
│  └──────────────┬───────────────────────────┘                               │
│                 ▼                                                            │
│  ┌──────────────────────────────────────────┐                               │
│  │ STEP 4: FIX ONE THING                    │                               │
│  │ Change the single biggest bottleneck.    │                               │
│  │ Only ONE change at a time.               │                               │
│  └──────────────┬───────────────────────────┘                               │
│                 ▼                                                            │
│  ┌──────────────────────────────────────────┐                               │
│  │ STEP 5: RE-MEASURE                       │                               │
│  │ Same inputs, same conditions.            │                               │
│  │ Compare: Did runtime improve? Did the    │                               │
│  │ bottleneck shift to a different step?    │                               │
│  └──────────────┬───────────────────────────┘                               │
│                 ▼                                                            │
│  ┌──────────────────────────────────────────┐                               │
│  │ STEP 6: VERIFY CORRECTNESS               │                               │
│  │ Diff row counts + checksums.             │                               │
│  │ "A faster wrong answer is still wrong."  │                               │
│  └──────────────┬───────────────────────────┘                               │
│                 ▼                                                            │
│  ┌──────────────────────────────────────────┐                               │
│  │ STEP 7: KEEP or REVERT                   │                               │
│  │ If faster AND correct → keep the change. │                               │
│  │ If not → revert. Go back to Step 4.      │                               │
│  └──────────────────────────────────────────┘                               │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘

======================================================================================
*/

-- ============================================================================
-- LAB SETUP: CREATE THE "SLOW" PROCEDURE AND SEED DATA
-- ============================================================================

-- Create the tables the procedure operates on:
CREATE TABLE IF NOT EXISTS lab.raw_orders (
    order_id        BIGINT       NOT NULL,
    customer_id     INT          NOT NULL,
    order_date      DATE         NOT NULL,
    product_id      INT          NOT NULL,
    quantity        INT,
    unit_price      DECIMAL(10,2),
    discount_pct    DECIMAL(5,2),
    order_status    VARCHAR(20),
    created_at      TIMESTAMP
)
DISTSTYLE KEY DISTKEY (customer_id)
SORTKEY (order_date);

CREATE TABLE IF NOT EXISTS lab.dim_products (
    product_id      INT PRIMARY KEY,
    product_name    VARCHAR(200),
    category        VARCHAR(50),
    brand           VARCHAR(50)
)
DISTSTYLE ALL;

CREATE TABLE IF NOT EXISTS lab.fact_orders_gold (
    order_key       BIGINT IDENTITY(1,1),
    order_id        BIGINT,
    customer_id     INT,
    order_date      DATE,
    product_id      INT,
    product_name    VARCHAR(200),
    category        VARCHAR(50),
    quantity        INT,
    unit_price      DECIMAL(10,2),
    discount_pct    DECIMAL(5,2),
    net_amount      DECIMAL(12,2),
    order_status    VARCHAR(20),
    loaded_at       TIMESTAMP
)
DISTSTYLE KEY DISTKEY (customer_id)
SORTKEY (order_date);

-- Seed 10M raw orders:
INSERT INTO lab.raw_orders
SELECT
    seq AS order_id,
    (seq % 500000) + 1 AS customer_id,
    DATEADD(day, -(seq % 365), CURRENT_DATE) AS order_date,
    (seq % 1000) + 1 AS product_id,
    (seq % 10) + 1 AS quantity,
    ROUND((RANDOM() * 100 + 5)::DECIMAL(10,2), 2) AS unit_price,
    ROUND((RANDOM() * 20)::DECIMAL(5,2), 2) AS discount_pct,
    CASE seq % 4 WHEN 0 THEN 'completed' WHEN 1 THEN 'shipped'
                 WHEN 2 THEN 'pending' ELSE 'cancelled' END,
    DATEADD(second, -(seq % 86400), SYSDATE)
FROM (SELECT ROW_NUMBER() OVER () AS seq FROM stl_scan LIMIT 10000000) g;

-- Seed 1000 products:
INSERT INTO lab.dim_products
SELECT
    seq AS product_id,
    'Product ' || seq AS product_name,
    CASE seq % 5 WHEN 0 THEN 'Electronics' WHEN 1 THEN 'Clothing'
                 WHEN 2 THEN 'Books' WHEN 3 THEN 'Home' ELSE 'Sports' END,
    'Brand ' || (seq % 50)
FROM (SELECT ROW_NUMBER() OVER () AS seq FROM stl_scan LIMIT 1000) g;

ANALYZE lab.raw_orders;
ANALYZE lab.dim_products;


-- ============================================================================
-- THE "BAD" PROCEDURE (Intentionally slow — your starting point)
-- ============================================================================

CREATE OR REPLACE PROCEDURE lab.sp_build_fact_orders_SLOW(
    p_load_date DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    rec RECORD;
    v_product_name VARCHAR(200);
    v_category     VARCHAR(50);
    v_net_amount   DECIMAL(12,2);
    v_count        INT := 0;
BEGIN
    -- ANTI-PATTERN 1: Delete without sort key filter
    DELETE FROM lab.fact_orders_gold;     -- Full table delete!

    -- ANTI-PATTERN 2: Row-by-row cursor processing
    FOR rec IN
        SELECT order_id, customer_id, order_date, product_id,
               quantity, unit_price, discount_pct, order_status
        FROM lab.raw_orders
        WHERE DATE_TRUNC('day', created_at::TIMESTAMP) = p_load_date  -- Non-sargable!
    LOOP
        -- ANTI-PATTERN 3: Correlated lookup per row
        SELECT product_name, category
        INTO v_product_name, v_category
        FROM lab.dim_products
        WHERE product_id = rec.product_id;

        -- ANTI-PATTERN 4: Calculation in application code
        v_net_amount := rec.quantity * rec.unit_price * (1 - rec.discount_pct / 100);

        -- ANTI-PATTERN 5: Single-row INSERT
        INSERT INTO lab.fact_orders_gold (
            order_id, customer_id, order_date, product_id,
            product_name, category, quantity, unit_price,
            discount_pct, net_amount, order_status, loaded_at
        ) VALUES (
            rec.order_id, rec.customer_id, rec.order_date, rec.product_id,
            v_product_name, v_category, rec.quantity, rec.unit_price,
            rec.discount_pct, v_net_amount, rec.order_status, SYSDATE
        );

        v_count := v_count + 1;
        -- ANTI-PATTERN 6: Logging in hot loop
        IF MOD(v_count, 10000) = 0 THEN
            RAISE INFO 'Processed % rows...', v_count;
        END IF;
    END LOOP;

    RAISE INFO 'Total rows loaded: %', v_count;
END;
$$;


-- ============================================================================
-- STEP 1: REPRODUCE (Practice #1)
-- ============================================================================
-- Fix inputs: always use the same date for benchmarking.

-- CALL lab.sp_build_fact_orders_SLOW('2026-08-14');
-- NOTE: This will be VERY slow. That's the point.
-- Record the query_id from SYS_QUERY_HISTORY for your baseline.


-- ============================================================================
-- STEP 2: MEASURE BASELINE (Practice #2)
-- ============================================================================

-- Capture baseline metrics:
CREATE TEMP TABLE lab_baseline AS
SELECT
    query_id,
    elapsed_time / 1000000.0 AS elapsed_sec,
    execution_time / 1000000.0 AS exec_sec,
    queue_time / 1000000.0 AS queue_sec,
    returned_rows,
    start_time
FROM SYS_QUERY_HISTORY
WHERE query_text LIKE '%sp_build_fact_orders_SLOW%'
  AND status = 'success'
ORDER BY start_time DESC
LIMIT 1;

-- Capture output checksum (correctness gate):
CREATE TEMP TABLE lab_baseline_checksum AS
SELECT
    COUNT(*)                AS row_count,
    SUM(net_amount)         AS total_net_amount,
    COUNT(DISTINCT order_id) AS unique_orders
FROM lab.fact_orders_gold;

SELECT * FROM lab_baseline;
SELECT * FROM lab_baseline_checksum;
-- WRITE THESE DOWN. This is your "before."


-- ============================================================================
-- STEP 3: UNDERSTAND — IDENTIFY THE 80/20 BOTTLENECK (Practice #3, #4)
-- ============================================================================

-- The anti-patterns in the "bad" procedure:
-- 1. Full table DELETE (should be date-filtered or use TRUNCATE)
-- 2. Non-sargable filter: DATE_TRUNC('day', created_at) — wraps column in function
-- 3. Cursor loop with row-by-row processing — 100-1000x slower than set-based
-- 4. Correlated lookup per row — should be a JOIN
-- 5. Single-row INSERT — should be INSERT...SELECT
-- 6. RAISE INFO in hot loop — I/O overhead per iteration

-- THE 80/20: The cursor + row-by-row INSERT is ~95% of the runtime.
-- Fix THAT first. Everything else is secondary.


-- ============================================================================
-- STEP 4: FIX — THE "GOOD" PROCEDURE (Practice #6, #7)
-- ============================================================================

CREATE OR REPLACE PROCEDURE lab.sp_build_fact_orders_FAST(
    p_load_date DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_deleted   INT;
    v_inserted  INT;
BEGIN
    -- FIX 1: Delete only the target date (idempotent, not full table)
    DELETE FROM lab.fact_orders_gold
    WHERE order_date = p_load_date;
    GET DIAGNOSTICS v_deleted = ROW_COUNT;

    -- FIX 2: Set-based INSERT...SELECT with JOIN (replaces cursor + correlated lookup)
    INSERT INTO lab.fact_orders_gold (
        order_id, customer_id, order_date, product_id,
        product_name, category, quantity, unit_price,
        discount_pct, net_amount, order_status, loaded_at
    )
    SELECT
        r.order_id,
        r.customer_id,
        r.order_date,
        r.product_id,
        p.product_name,                              -- FIX 3: JOIN replaces per-row lookup
        p.category,
        r.quantity,
        r.unit_price,
        r.discount_pct,
        r.quantity * r.unit_price * (1 - r.discount_pct / 100.0),  -- FIX 4: In-line calc
        r.order_status,
        SYSDATE
    FROM lab.raw_orders r
    JOIN lab.dim_products p ON r.product_id = p.product_id   -- Set-based join!
    WHERE r.order_date = p_load_date;                         -- FIX 5: Sargable predicate!
    -- order_date is the SORTKEY → zone-map pruning skips 364/365 days of data

    GET DIAGNOSTICS v_inserted = ROW_COUNT;

    -- FIX 6: Log ONCE at the end (not in a loop)
    RAISE INFO 'sp_build_fact_orders_FAST [%]: Deleted %, Inserted %.',
               p_load_date, v_deleted, v_inserted;
END;
$$;


-- ============================================================================
-- STEP 5: RE-MEASURE (Practice #10)
-- ============================================================================

-- Run the optimized procedure:
-- CALL lab.sp_build_fact_orders_FAST('2026-08-14');

-- Capture new metrics:
CREATE TEMP TABLE lab_after AS
SELECT
    query_id,
    elapsed_time / 1000000.0 AS elapsed_sec,
    execution_time / 1000000.0 AS exec_sec,
    queue_time / 1000000.0 AS queue_sec,
    returned_rows,
    start_time
FROM SYS_QUERY_HISTORY
WHERE query_text LIKE '%sp_build_fact_orders_FAST%'
  AND status = 'success'
ORDER BY start_time DESC
LIMIT 1;


-- ============================================================================
-- STEP 6: VERIFY CORRECTNESS (Practice #5, #111)
-- ============================================================================

-- Capture output checksum AFTER optimization:
CREATE TEMP TABLE lab_after_checksum AS
SELECT
    COUNT(*)                AS row_count,
    SUM(net_amount)         AS total_net_amount,
    COUNT(DISTINCT order_id) AS unique_orders
FROM lab.fact_orders_gold;

-- DIFF: Compare before vs. after
SELECT
    b.row_count         AS before_rows,
    a.row_count         AS after_rows,
    b.total_net_amount  AS before_amount,
    a.total_net_amount  AS after_amount,
    b.unique_orders     AS before_orders,
    a.unique_orders     AS after_orders,
    CASE
        WHEN b.row_count = a.row_count
         AND b.total_net_amount = a.total_net_amount
         AND b.unique_orders = a.unique_orders
        THEN '✅ PASS — Output is identical. Optimization is SAFE.'
        ELSE '❌ FAIL — Output changed! Revert the optimization!'
    END AS correctness_check
FROM lab_baseline_checksum b, lab_after_checksum a;


-- ============================================================================
-- STEP 7: PERFORMANCE COMPARISON REPORT (Practice #112)
-- ============================================================================

SELECT
    'BEFORE (slow)' AS version,
    b.elapsed_sec,
    bc.row_count
FROM lab_baseline b, lab_baseline_checksum bc
UNION ALL
SELECT
    'AFTER (fast)' AS version,
    a.elapsed_sec,
    ac.row_count
FROM lab_after a, lab_after_checksum ac;

-- Expected result:
-- BEFORE: ~2 hours (cursor loop)
-- AFTER:  ~30 seconds (set-based)
-- Improvement: ~240x faster
-- Correctness: ✅ PASS


-- ============================================================================
-- SUMMARY: THE 6 ANTI-PATTERNS AND THEIR FIXES
-- ============================================================================
/*
┌─────┬─────────────────────────────┬──────────────────────────────────────────┐
│ #   │ Anti-Pattern (Bad)          │ Fix (Good)                               │
├─────┼─────────────────────────────┼──────────────────────────────────────────┤
│ 1   │ DELETE without filter       │ DELETE WHERE order_date = p_load_date   │
│ 2   │ DATE_TRUNC on sort key col │ Direct = comparison on sort key          │
│ 3   │ FOR rec IN ... LOOP         │ INSERT ... SELECT (set-based)           │
│ 4   │ Per-row correlated lookup   │ JOIN in the INSERT...SELECT             │
│ 5   │ Single-row INSERT in loop   │ One INSERT...SELECT for all rows        │
│ 6   │ RAISE INFO every 10K rows   │ RAISE INFO once at the end              │
└─────┴─────────────────────────────┴──────────────────────────────────────────┘

THE METHOD WORKS. USE IT EVERY TIME:
  1. Reproduce → 2. Measure → 3. Understand → 4. Fix ONE thing →
  5. Re-measure → 6. Verify → 7. Keep or Revert → Repeat
*/


-- ============================================================================
-- CLEANUP
-- ============================================================================
-- DROP TABLE IF EXISTS lab.raw_orders;
-- DROP TABLE IF EXISTS lab.dim_products;
-- DROP TABLE IF EXISTS lab.fact_orders_gold;
-- DROP PROCEDURE IF EXISTS lab.sp_build_fact_orders_SLOW(DATE);
-- DROP PROCEDURE IF EXISTS lab.sp_build_fact_orders_FAST(DATE);
