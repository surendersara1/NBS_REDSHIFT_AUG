/*
======================================================================================
MODULE 25: EXISTS VS IN AND MASSIVE SUBQUERY LISTS
======================================================================================
MAPPED BEST PRACTICES (from PROCEDURE_OPTIMIZATION_BEST_PRACTICES_MASTER_FILE.md):
- Practice 22: Use EXISTS/NOT EXISTS instead of IN/NOT IN for large subqueries.
- Practice 25: Replace correlated subqueries with joins or window functions.
- Practice 34: Check EXPLAIN for DS_DIST_BOTH / DS_BCAST_INNER data movement.

TARGET AUDIENCE: Application Developers transitioning to Redshift
BUSINESS SCENARIO: 
We have a fact table `fct_orders` with 10 million rows. We have a fraud security table 
`dim_fraudulent_accounts` containing 200,000 flagged user IDs. 
We need to extract all legitimate orders (filtering out fraudulent users).

THE PROBLEM:
Application developers often write:
`WHERE user_id NOT IN (SELECT user_id FROM dim_fraudulent_accounts)`
or pass a comma-separated list of 50,000 IDs from application memory.
In Redshift:
1. `NOT IN` with ANY `NULL` in the subquery returns ZERO rows (ANSI SQL three-valued logic trap).
2. Large `IN (SELECT...)` clauses are materialized in memory on the single Leader Node.
3. The optimizer often generates a costly Cartesian subplan.

THE GOAL:
1. Understand why `NOT IN` fails with NULLs.
2. Replace `IN` / `NOT IN` with `EXISTS` / `NOT EXISTS` or `LEFT JOIN ... WHERE ... IS NULL`.
3. Compare execution plans: Subplan materialization vs. Hash Anti-Join.
======================================================================================
*/

-- ===================================================================================
-- 1. DATA GENERATION BLOCK (Run this to set up the scenario)
-- ===================================================================================
DROP TABLE IF EXISTS fct_orders CASCADE;
CREATE TABLE fct_orders (
    order_id BIGINT NOT NULL ENCODE az64,
    user_id BIGINT NOT NULL ENCODE az64,
    order_amount DECIMAL(12,2) NOT NULL ENCODE az64,
    order_date DATE NOT NULL ENCODE az64
)
DISTSTYLE KEY
DISTKEY (user_id)
COMPOUND SORTKEY (order_date, user_id);

-- Generate 200,000 orders
INSERT INTO fct_orders (order_id, user_id, order_amount, order_date)
SELECT 
    s.n AS order_id,
    (s.n % 20000 + 1) AS user_id,
    (15.00 + (s.n % 300))::DECIMAL(12,2) AS order_amount,
    DATEADD(day, -(s.n % 60), '2026-08-15'::DATE) AS order_date
FROM (
    SELECT ROW_NUMBER() OVER () AS n
    FROM (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) a
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) b
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) c
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) d
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2) e
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) f
    LIMIT 200000
) s;

ANALYZE fct_orders;

DROP TABLE IF EXISTS dim_fraudulent_accounts CASCADE;
CREATE TABLE dim_fraudulent_accounts (
    user_id BIGINT ENCODE az64,
    reason VARCHAR(100) ENCODE zstd
)
DISTSTYLE ALL; -- Small lookup table replicated to all nodes (Practice 31, 49)

INSERT INTO dim_fraudulent_accounts VALUES 
(50, 'Stolen Card'), 
(150, 'Account Takeover'),
(NULL, 'Unconfirmed Flag'); -- DELIBERATE NULL TO PROVE THE NOT IN TRAP!

ANALYZE dim_fraudulent_accounts;

DROP TABLE IF EXISTS target_clean_orders CASCADE;
CREATE TABLE target_clean_orders (LIKE fct_orders);


-- ===================================================================================
-- 2. THE "BAD" PROCEDURE (The NOT IN Anti-Pattern)
-- ===================================================================================
/*
WHY IT'S BROKEN:
1. THREE-VALUED LOGIC TRAP: Because `dim_fraudulent_accounts` has a NULL row,
   `user_id NOT IN (..., NULL)` evaluates to UNKNOWN for every row. 
   Result: ZERO rows are inserted! The entire company thinks sales dropped to $0.
2. LEADER NODE BOTTLENECK: If the subquery returns 500,000 rows, Redshift materializes
   the entire list into Leader Node RAM, risking Out-Of-Memory errors.
*/
CREATE OR REPLACE PROCEDURE prc_bad_filter_fraud()
LANGUAGE plpgsql
AS $$
BEGIN
    TRUNCATE TABLE target_clean_orders;
    
    -- DANGEROUS NOT IN QUERY:
    INSERT INTO target_clean_orders
    SELECT order_id, user_id, order_amount, order_date
    FROM fct_orders
    WHERE user_id NOT IN (SELECT user_id FROM dim_fraudulent_accounts);
    
    RAISE INFO 'Bad procedure finished. (Check row count — it will be 0 due to NULLs!)';
END;
$$;


-- ===================================================================================
-- 3. THE "GOOD" PROCEDURE (The Redshift Hash Anti-Join Best Practice)
-- ===================================================================================
/*
WHY IT'S GOOD:
1. IMMUNE TO NULLs: `NOT EXISTS` checks for existence of a match. NULLs in the fraud table
   do not invalidate non-matching rows.
2. DISTRIBUTED HASH ANTI-JOIN: Compiles into a distributed Hash Anti-Join across all compute
   slices with zero leader-node memory bottleneck.
*/
CREATE OR REPLACE PROCEDURE prc_good_filter_fraud()
LANGUAGE plpgsql
AS $$
DECLARE
    v_rows_inserted BIGINT := 0;
BEGIN
    TRUNCATE TABLE target_clean_orders;
    
    -- Method A: NOT EXISTS (Clean, Declarative, NULL-Safe)
    INSERT INTO target_clean_orders (order_id, user_id, order_amount, order_date)
    SELECT o.order_id, o.user_id, o.order_amount, o.order_date
    FROM fct_orders o
    WHERE NOT EXISTS (
        SELECT 1 
        FROM dim_fraudulent_accounts f 
        WHERE f.user_id = o.user_id
    );
    
    GET DIAGNOSTICS v_rows_inserted = ROW_COUNT;
    RAISE INFO 'Good procedure complete: % legitimate orders loaded safely.', v_rows_inserted;

EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'prc_good_filter_fraud failed: %', SQLERRM;
END;
$$;


-- ===================================================================================
-- 4. USAGE, VERIFICATION & EXPLAIN PLAN COMPARISON
-- ===================================================================================

-- (a) Prove the NOT IN NULL Trap:
-- CALL prc_bad_filter_fraud();
-- SELECT COUNT(1) AS bad_count FROM target_clean_orders; 
-- --> Returns 0! (Catastrophic Silent Data Loss)

-- (b) Prove the NOT EXISTS Fix:
-- CALL prc_good_filter_fraud();
-- SELECT COUNT(1) AS good_count FROM target_clean_orders; 
-- --> Returns ~199,980 rows correctly!

-- (c) Execution Plan Comparison (EXPLAIN):
-- Notice how NOT EXISTS compiles into a Hash Anti Join:
EXPLAIN
SELECT o.order_id, o.user_id, o.order_amount, o.order_date
FROM fct_orders o
WHERE NOT EXISTS (
    SELECT 1 FROM dim_fraudulent_accounts f WHERE f.user_id = o.user_id
);
