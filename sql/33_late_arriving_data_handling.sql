/*
======================================================================================
MODULE 33: LATE ARRIVING DATA & LOOKBACK WINDOWS
======================================================================================
MAPPED BEST PRACTICES (from PROCEDURE_OPTIMIZATION_BEST_PRACTICES_MASTER_FILE.md):
- Practice 39: Prefer incremental processing over full-history rebuilds — process only new or changed data.
- Practice 41: Handle late-arriving data with a deliberate lookback/reprocessing window.
- Practice 42: Make loads idempotent — re-running the lookback window replaces rather than duplicates.
- Practice 102: Comment the reason, not the obvious SQL — explain why the reload window exists.

TARGET AUDIENCE: Application Developers transitioning to Redshift
BUSINESS SCENARIO: 
We run a daily pipeline to aggregate transactions in `fct_transactions` into `agg_daily_revenue`. 
Mobile point-of-sale devices in retail stores occasionally operate offline and upload transactions 
3 to 5 days after the transaction physically occurred.

THE PROBLEM:
If the pipeline strictly processes `WHERE txn_date = CURRENT_DATE - 1`, late-arriving offline transactions 
are permanently missed, resulting in understated historical revenue. 
Conversely, if the pipeline reprocesses the entire 10-year history every night to capture late data, 
the batch window explodes from 2 minutes to 6 hours.

THE GOAL:
1. Implement a parameterized **Lookback Window** (e.g. 7 days).
2. Reprocess the lookback window idempotently using a delete-and-replace strategy.
3. Leverage Sort Keys on `txn_date` so the 7-day lookback scan skips 98% of the fact table blocks.
======================================================================================
*/

-- ===================================================================================
-- 1. DATA GENERATION BLOCK (Run this to set up the scenario)
-- ===================================================================================
DROP TABLE IF EXISTS fct_transactions CASCADE;
CREATE TABLE fct_transactions (
    txn_id BIGINT NOT NULL ENCODE az64,
    account_id BIGINT NOT NULL ENCODE az64,
    txn_date DATE NOT NULL ENCODE az64,
    amount DECIMAL(12,2) NOT NULL ENCODE az64,
    ingested_at TIMESTAMP NOT NULL ENCODE az64
)
DISTSTYLE KEY
DISTKEY (account_id)
COMPOUND SORTKEY (txn_date, account_id);

-- Populate 100,000 historical transactions across August 2026
INSERT INTO fct_transactions (txn_id, account_id, txn_date, amount, ingested_at)
SELECT 
    s.n AS txn_id,
    (s.n % 10000 + 1) AS account_id,
    DATEADD(day, -(s.n % 30), '2026-08-15'::DATE) AS txn_date,
    (10.00 + (s.n % 100))::DECIMAL(12,2) AS amount,
    '2026-08-14 00:00:00'::TIMESTAMP AS ingested_at
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

-- INJECT LATE-ARRIVING DATA:
-- Transactions that happened on '2026-08-10', but arrived today ('2026-08-15')
INSERT INTO fct_transactions VALUES 
(999001, 101, '2026-08-10', 5000.00, '2026-08-15 08:30:00'),
(999002, 102, '2026-08-10', 7500.00, '2026-08-15 08:35:00');

ANALYZE fct_transactions;

DROP TABLE IF EXISTS agg_daily_revenue CASCADE;
CREATE TABLE agg_daily_revenue (
    txn_date DATE NOT NULL,
    total_revenue DECIMAL(16,2) NOT NULL,
    txn_count BIGINT NOT NULL
)
DISTSTYLE EVEN
COMPOUND SORTKEY (txn_date);


-- ===================================================================================
-- 2. THE "BAD" PROCEDURE (The Zero-Lookback Anti-Pattern)
-- ===================================================================================
/*
WHY IT'S FLAWED:
- Blindly processes only `p_target_date` (e.g. yesterday).
- Completely ignores the $12,500 in late-arriving revenue from '2026-08-10'.
- Leads to permanent audit discrepancies between operational billing and data warehouse numbers.
*/
CREATE OR REPLACE PROCEDURE prc_bad_single_day_agg(p_target_date DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    DELETE FROM agg_daily_revenue WHERE txn_date = p_target_date;
    
    INSERT INTO agg_daily_revenue (txn_date, total_revenue, txn_count)
    SELECT txn_date, SUM(amount), COUNT(1)
    FROM fct_transactions
    WHERE txn_date = p_target_date
    GROUP BY txn_date;
END;
$$;


-- ===================================================================================
-- 3. THE "GOOD" PROCEDURE (The Parameterized Lookback Window Best Practice)
-- ===================================================================================
/*
WHY IT'S ACCURATE AND FAST:
- Employs a rolling lookback window (e.g., 7 days) via `DATEADD(day, -p_lookback_days, p_target_date)`.
- Idempotently wipes and recalculates ONLY the 7-day window in `agg_daily_revenue`.
- Because `fct_transactions` is sorted by `txn_date`, Zone Maps skip reading the preceding 358 days of data.
- Captures 100% of offline / late-syncing records automatically.
*/
CREATE OR REPLACE PROCEDURE prc_good_lookback_agg(p_target_date DATE, p_lookback_days INT DEFAULT 7)
LANGUAGE plpgsql
AS $$
DECLARE
    v_start_date DATE;
    v_rows_inserted BIGINT := 0;
BEGIN
    IF p_target_date IS NULL THEN
        RAISE EXCEPTION 'p_target_date cannot be NULL.';
    END IF;
    
    IF p_lookback_days < 0 OR p_lookback_days > 60 THEN
        RAISE EXCEPTION 'p_lookback_days must be between 0 and 60 days.';
    END IF;

    v_start_date := DATEADD(day, -p_lookback_days, p_target_date);
    RAISE INFO 'Processing rolling lookback window from % to % ...', v_start_date, p_target_date;

    -- Step 1: Idempotent purge of the lookback window in target
    DELETE FROM agg_daily_revenue
    WHERE txn_date >= v_start_date AND txn_date <= p_target_date;

    -- Step 2: Set-based re-aggregation of the lookback window
    INSERT INTO agg_daily_revenue (txn_date, total_revenue, txn_count)
    SELECT txn_date, SUM(amount), COUNT(1)
    FROM fct_transactions
    WHERE txn_date >= v_start_date AND txn_date <= p_target_date
    GROUP BY txn_date;

    GET DIAGNOSTICS v_rows_inserted = ROW_COUNT;
    RAISE INFO 'Lookback aggregation complete: % days updated.', v_rows_inserted;

EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'prc_good_lookback_agg failed: %', SQLERRM;
END;
$$;


-- ===================================================================================
-- 4. USAGE, VERIFICATION & AUDIT COMPARISON
-- ===================================================================================

-- (a) Run Bad Procedure for today:
-- CALL prc_bad_single_day_agg('2026-08-15'::DATE);
-- SELECT * FROM agg_daily_revenue WHERE txn_date = '2026-08-10'::DATE; 
-- --> Empty or missing the $12,500 late revenue!

-- (b) Run Good Procedure with 7-day lookback:
-- CALL prc_good_lookback_agg('2026-08-15'::DATE, 7);
-- SELECT * FROM agg_daily_revenue WHERE txn_date = '2026-08-10'::DATE;
-- --> Correctly captures and reflects the late-arriving $12,500.00!

-- (c) Explain Plan Verification: Range-Restricted Scan on Lookback Window:
EXPLAIN
SELECT txn_date, SUM(amount), COUNT(1)
FROM fct_transactions
WHERE txn_date >= '2026-08-08'::DATE AND txn_date <= '2026-08-15'::DATE
GROUP BY txn_date;

-- (d) Check Range-Restricted scan efficiency in SYS_QUERY_DETAIL:
SELECT query_id, step_name, is_rrscan, input_rows, output_rows, blocks_read
FROM sys_query_detail
WHERE query_id = pg_last_query_id()
ORDER BY step_name;
