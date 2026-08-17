/*
======================================================================================
MODULE 38: CONDITIONAL AGGREGATIONS (SUM CASE PIVOTING VS MULTI-JOINS)
======================================================================================
MAPPED BEST PRACTICES (from PROCEDURE_OPTIMIZATION_BEST_PRACTICES_MASTER_FILE.md):
- Practice 20: Avoid recomputing the same expression repeatedly — pivot in a single pass.
- Practice 25: Replace correlated subqueries and multi-joins with conditional aggregations.
- Practice 16: Never SELECT * — select specific measures.
- Practice 27: Set-based, not row-by-row.

TARGET AUDIENCE: Application Developers transitioning to Redshift
BUSINESS SCENARIO: 
We are building a daily payment reconciliation table. 
For each merchant account, we need columns for:
- Total Settled Amount
- Total Refunded Amount
- Total Chargeback Amount
- Total Pending Amount

THE PROBLEM:
App developers write 4 separate self-joins or CTEs:
`SELECT settled.amt, refund.amt FROM (SELECT ...) settled LEFT JOIN (SELECT ...) refund ON ...`
Each self-join scans the fact table another time. For a 100-million row payment table, 
a 4-way self-join takes **10 minutes and reads 400 million rows**.

THE GOAL:
1. Master conditional aggregation pivoting (`SUM(CASE WHEN status = 'REFUND' THEN amount ELSE 0 END)`).
2. Scan the fact table **exactly ONCE** to produce all status columns in parallel.
3. Eliminate expensive self-joins and reduce query execution time by 75%+.
======================================================================================
*/

-- ===================================================================================
-- 1. DATA GENERATION BLOCK (Run this to set up the scenario)
-- ===================================================================================
DROP TABLE IF EXISTS fct_merchant_payments CASCADE;
CREATE TABLE fct_merchant_payments (
    payment_id BIGINT NOT NULL ENCODE az64,
    merchant_id BIGINT NOT NULL ENCODE az64,
    payment_status VARCHAR(20) NOT NULL ENCODE bytedict,
    amount DECIMAL(12,2) NOT NULL ENCODE az64,
    payment_date DATE NOT NULL ENCODE az64
)
DISTSTYLE KEY
DISTKEY (merchant_id)
COMPOUND SORTKEY (payment_date, merchant_id);

-- Insert 100,000 payment records across 1,000 merchants
INSERT INTO fct_merchant_payments (payment_id, merchant_id, payment_status, amount, payment_date)
SELECT 
    s.n AS payment_id,
    (s.n % 1000 + 1) AS merchant_id,
    CASE WHEN (s.n % 10) = 0 THEN 'REFUND'
         WHEN (s.n % 20) = 0 THEN 'CHARGEBACK'
         WHEN (s.n % 5) = 0  THEN 'PENDING'
         ELSE 'SETTLED' END AS payment_status,
    (20.00 + (s.n % 200))::DECIMAL(12,2) AS amount,
    DATEADD(day, -(s.n % 30), '2026-08-15'::DATE) AS payment_date
FROM (
    SELECT ROW_NUMBER() OVER () AS n
    FROM (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) a
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) b
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) c
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) d
    CROSS JOIN (SELECT 0 UNION SELECT 1) e
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) f
    LIMIT 100000
) s;

ANALYZE fct_merchant_payments;

DROP TABLE IF EXISTS rpt_merchant_daily_summary CASCADE;
CREATE TABLE rpt_merchant_daily_summary (
    merchant_id BIGINT NOT NULL,
    settled_amount DECIMAL(16,2) NOT NULL,
    refund_amount DECIMAL(16,2) NOT NULL,
    chargeback_amount DECIMAL(16,2) NOT NULL,
    pending_amount DECIMAL(16,2) NOT NULL,
    net_revenue DECIMAL(16,2) NOT NULL
);


-- ===================================================================================
-- 2. THE "BAD" PROCEDURE (The 4-Way Self-Join Anti-Pattern)
-- ===================================================================================
/*
WHY IT'S SLOW:
- Scans `fct_merchant_payments` 4 separate times.
- Executes 3 costly Hash Left Joins.
- Scales linearly worse with each additional status bucket added.
*/
CREATE OR REPLACE PROCEDURE prc_bad_self_join_pivot()
LANGUAGE plpgsql
AS $$
BEGIN
    TRUNCATE TABLE rpt_merchant_daily_summary;
    
    INSERT INTO rpt_merchant_daily_summary
    WITH settled AS (
        SELECT merchant_id, SUM(amount) AS amt FROM fct_merchant_payments WHERE payment_status = 'SETTLED' GROUP BY merchant_id
    ),
    refunds AS (
        SELECT merchant_id, SUM(amount) AS amt FROM fct_merchant_payments WHERE payment_status = 'REFUND' GROUP BY merchant_id
    ),
    chargebacks AS (
        SELECT merchant_id, SUM(amount) AS amt FROM fct_merchant_payments WHERE payment_status = 'CHARGEBACK' GROUP BY merchant_id
    ),
    pending AS (
        SELECT merchant_id, SUM(amount) AS amt FROM fct_merchant_payments WHERE payment_status = 'PENDING' GROUP BY merchant_id
    )
    SELECT 
        m.merchant_id,
        NVL(s.amt, 0.00) AS settled_amount,
        NVL(r.amt, 0.00) AS refund_amount,
        NVL(c.amt, 0.00) AS chargeback_amount,
        NVL(p.amt, 0.00) AS pending_amount,
        (NVL(s.amt, 0.00) - NVL(r.amt, 0.00) - NVL(c.amt, 0.00)) AS net_revenue
    FROM (SELECT DISTINCT merchant_id FROM fct_merchant_payments) m
    LEFT JOIN settled s ON m.merchant_id = s.merchant_id
    LEFT JOIN refunds r ON m.merchant_id = r.merchant_id
    LEFT JOIN chargebacks c ON m.merchant_id = c.merchant_id
    LEFT JOIN pending p ON m.merchant_id = p.merchant_id;
    
    RAISE INFO 'Multi-join pivot complete.';
END;
$$;


-- ===================================================================================
-- 3. THE "GOOD" PROCEDURE (Single-Pass Conditional Aggregation Best Practice)
-- ===================================================================================
/*
WHY IT'S 4x FASTER:
1. SINGLE SCAN: Reads `fct_merchant_payments` exactly once.
2. VECTORIZED COMPUTATION: Evaluates `SUM(CASE WHEN...)` expressions inside the single scan pass.
3. ZERO SELF-JOINS: Eliminates all 3 hash joins and saves 75% of memory.
*/
CREATE OR REPLACE PROCEDURE prc_good_conditional_agg_pivot()
LANGUAGE plpgsql
AS $$
DECLARE
    v_rows BIGINT := 0;
BEGIN
    TRUNCATE TABLE rpt_merchant_daily_summary;

    INSERT INTO rpt_merchant_daily_summary (
        merchant_id, settled_amount, refund_amount, chargeback_amount, pending_amount, net_revenue
    )
    SELECT 
        merchant_id,
        SUM(CASE WHEN payment_status = 'SETTLED'    THEN amount ELSE 0.00 END) AS settled_amount,
        SUM(CASE WHEN payment_status = 'REFUND'     THEN amount ELSE 0.00 END) AS refund_amount,
        SUM(CASE WHEN payment_status = 'CHARGEBACK' THEN amount ELSE 0.00 END) AS chargeback_amount,
        SUM(CASE WHEN payment_status = 'PENDING'    THEN amount ELSE 0.00 END) AS pending_amount,
        -- Net Revenue calculation in one shot:
        SUM(CASE WHEN payment_status = 'SETTLED' THEN amount
                 WHEN payment_status IN ('REFUND', 'CHARGEBACK') THEN -amount
                 ELSE 0.00 END) AS net_revenue
    FROM fct_merchant_payments
    GROUP BY merchant_id;

    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RAISE INFO 'Single-pass conditional aggregation complete: % merchant summaries computed.', v_rows;

EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'prc_good_conditional_agg_pivot failed: %', SQLERRM;
END;
$$;


-- ===================================================================================
-- 4. USAGE, VERIFICATION & EXPLAIN COMPARISON
-- ===================================================================================

-- (a) Execute procedures:
-- CALL prc_bad_self_join_pivot();
-- CALL prc_good_conditional_agg_pivot();
-- SELECT * FROM rpt_merchant_daily_summary ORDER BY net_revenue DESC LIMIT 10;

-- (b) Compare execution plans (EXPLAIN):
-- Notice 1 Scan in Conditional Agg vs 5 Scans in Multi-join:
EXPLAIN
SELECT 
    merchant_id,
    SUM(CASE WHEN payment_status = 'SETTLED' THEN amount ELSE 0.00 END) AS settled_amt,
    SUM(CASE WHEN payment_status = 'REFUND'  THEN amount ELSE 0.00 END) AS refund_amt
FROM fct_merchant_payments
GROUP BY merchant_id;
