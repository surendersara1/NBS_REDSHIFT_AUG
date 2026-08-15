/*
======================================================================================
MODULE 24: SARGABLE PREDICATES (PRESERVING ZONE MAP PRUNING)
======================================================================================
MAPPED BEST PRACTICES (from PROCEDURE_OPTIMIZATION_BEST_PRACTICES_MASTER_FILE.md):
- Practice 18: Never wrap filtered/join/sort-key columns in functions or casts.
- Practice 19: Use half-open timestamp ranges (>= start AND < end) instead of BETWEEN with casts.
- Practice 52: Set sort keys on columns used in WHERE/JOIN to enable block-skipping.
- Practice 35: Read the EXPLAIN plan before and after — look for is_rrscan = true.

TARGET AUDIENCE: Application Developers transitioning to Redshift
BUSINESS SCENARIO: 
We have a 1-billion row fact table `fct_financial_txns` sorted by `txn_timestamp`. 
A financial reconciliation dashboard queries data for single target dates.

THE PROBLEM:
App developers habitually write predicates like:
- `WHERE DATE(txn_timestamp) = '2026-08-15'`
- `WHERE DATE_TRUNC('day', txn_timestamp) = '2026-08-15'`
- `WHERE UPPER(status) = 'SETTLED'`
- `WHERE txn_id + 0 = 554433`
In Redshift, every column in every 1MB block has **Zone Maps** (Min/Max values stored in metadata).
Wrapping a column in a function or cast prevents the optimizer from evaluating the column's 
raw values against the Zone Map. 
Result: Redshift is forced to decompress and scan **every single 1MB block on disk** (a 100% full table scan) 
even though only 0.1% of the data matches!

THE GOAL:
1. Master "Sargable" (Search Argument Able) predicates.
2. Replace function wrappers with half-open intervals (`>= start AND < next_start`).
3. Prove that sargable predicates achieve 99%+ block skipping using `SYS_QUERY_DETAIL`.
======================================================================================
*/

-- ===================================================================================
-- 1. DATA GENERATION BLOCK (Run this to set up the scenario)
-- ===================================================================================
DROP TABLE IF EXISTS fct_financial_txns CASCADE;
CREATE TABLE fct_financial_txns (
    txn_id BIGINT NOT NULL ENCODE az64,
    account_id BIGINT NOT NULL ENCODE az64,
    status VARCHAR(20) NOT NULL ENCODE bytedict,
    amount DECIMAL(14,2) NOT NULL ENCODE az64,
    txn_timestamp TIMESTAMP NOT NULL ENCODE az64
)
DISTSTYLE KEY
DISTKEY (account_id)
COMPOUND SORTKEY (txn_timestamp);

-- Generate 500,000 transactions evenly distributed across the last 365 days
INSERT INTO fct_financial_txns (txn_id, account_id, status, amount, txn_timestamp)
SELECT 
    s.n AS txn_id,
    (s.n % 25000 + 1) AS account_id,
    CASE WHEN (s.n % 4) = 0 THEN 'SETTLED'
         WHEN (s.n % 4) = 1 THEN 'PENDING'
         WHEN (s.n % 4) = 2 THEN 'FAILED'
         ELSE 'REFUNDED' END AS status,
    (10.00 + (s.n % 500))::DECIMAL(14,2) AS amount,
    DATEADD(minute, -(s.n % 525600), '2026-08-15 00:00:00'::TIMESTAMP) AS txn_timestamp
FROM (
    SELECT ROW_NUMBER() OVER () AS n
    FROM (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) a
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) b
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) c
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) d
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4) e
    LIMIT 500000
) s;

ANALYZE fct_financial_txns;

DROP TABLE IF EXISTS rpt_daily_reconciliation CASCADE;
CREATE TABLE rpt_daily_reconciliation (
    report_date DATE NOT NULL,
    settled_amount DECIMAL(18,2) NOT NULL,
    txn_count BIGINT NOT NULL
);


-- ===================================================================================
-- 2. THE "BAD" PROCEDURE (The Non-Sargable Anti-Pattern)
-- ===================================================================================
/*
WHY IT'S CATASTROPHIC:
- Uses `DATE_TRUNC('day', txn_timestamp) = p_target_date` and `UPPER(status) = 'SETTLED'`.
- Both functions blind the query engine to the Zone Map.
- Scans all 500,000 rows (hundreds of 1MB blocks) across the entire cluster disk.
*/
CREATE OR REPLACE PROCEDURE prc_bad_reconcile_daily(p_target_date DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE INFO 'Running non-sargable scan (reads 100%% of disk blocks)...';
    
    INSERT INTO rpt_daily_reconciliation (report_date, settled_amount, txn_count)
    SELECT 
        p_target_date,
        SUM(amount),
        COUNT(1)
    FROM fct_financial_txns
    WHERE DATE_TRUNC('day', txn_timestamp)::DATE = p_target_date -- Non-sargable!
      AND UPPER(status) = 'SETTLED';                              -- Non-sargable!
END;
$$;


-- ===================================================================================
-- 3. THE "GOOD" PROCEDURE (The Sargable MPP Best Practice)
-- ===================================================================================
/*
WHY IT'S 100x FASTER:
- Uses half-open bounds: `txn_timestamp >= p_target_date::TIMESTAMP AND txn_timestamp < (p_target_date + 1)::TIMESTAMP`.
- Preserves the raw column on the left side of the inequality.
- Zone Maps compare block Min/Max timestamps against the range and skip 99.7% of blocks.
- Stores status in clean uppercase by convention, avoiding `UPPER()` in predicates.
*/
CREATE OR REPLACE PROCEDURE prc_good_reconcile_daily(p_target_date DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_start_ts TIMESTAMP;
    v_end_ts   TIMESTAMP;
BEGIN
    IF p_target_date IS NULL THEN
        RAISE EXCEPTION 'p_target_date cannot be NULL.';
    END IF;

    -- Compute clean timestamp boundaries once in variables
    v_start_ts := p_target_date::TIMESTAMP;
    v_end_ts   := DATEADD(day, 1, p_target_date)::TIMESTAMP;

    RAISE INFO 'Executing sargable block-pruned aggregation for % ...', p_target_date;

    INSERT INTO rpt_daily_reconciliation (report_date, settled_amount, txn_count)
    SELECT 
        p_target_date,
        SUM(amount),
        COUNT(1)
    FROM fct_financial_txns
    WHERE txn_timestamp >= v_start_ts 
      AND txn_timestamp < v_end_ts
      AND status = 'SETTLED';
      
    RAISE INFO 'Reconciliation complete.';
END;
$$;


-- ===================================================================================
-- 4. USAGE, VERIFICATION & EXECUTION PLAN PROOF
-- ===================================================================================

-- (a) Compare Non-Sargable vs Sargable Plans:

-- NON-SARGABLE (Bad): Notice `Filter: (date_trunc(...) = ...)` forces Full Scan
EXPLAIN
SELECT SUM(amount)
FROM fct_financial_txns
WHERE DATE_TRUNC('day', txn_timestamp)::DATE = '2026-08-10'::DATE;

-- SARGABLE (Good): Notice range is passed directly to the scan engine
EXPLAIN
SELECT SUM(amount)
FROM fct_financial_txns
WHERE txn_timestamp >= '2026-08-10 00:00:00'::TIMESTAMP
  AND txn_timestamp < '2026-08-11 00:00:00'::TIMESTAMP;

-- (b) Run and verify block skipping in SYS_QUERY_DETAIL:
-- SELECT query_id, step_name, is_rrscan, input_rows, output_rows, local_scanned_bytes
-- FROM sys_query_detail
-- WHERE query_id = pg_last_query_id()
-- ORDER BY step_name;
-- (is_rrscan = true confirms Range-Restricted Scan using Zone Maps!)
