/*
======================================================================================
MODULE 27: EXPLODING JOINS AND GRAIN MISMATCHES
======================================================================================
MAPPED BEST PRACTICES (from PROCEDURE_OPTIMIZATION_BEST_PRACTICES_MASTER_FILE.md):
- Practice 28: Confirm join keys are unique at the expected grain — avoid exploding joins.
- Practice 33: Avoid Cartesian products and cross joins — check EXPLAIN for warning signs.
- Practice 88: Define the grain explicitly before modeling ("one row = one ___").
- Practice 5: Correctness is the gate — diff output row counts before vs after.

TARGET AUDIENCE: Application Developers transitioning to Redshift
BUSINESS SCENARIO: 
We are computing total sales per customer. 
We have `fct_orders` (Order Header: 1 row per order) and `fct_order_discounts` (Discounts: multiple promo codes per order). 
An analyst joins `fct_orders` to `fct_order_discounts` on `order_id` and sums `order_total`.

THE PROBLEM:
If an order has 3 discount coupons applied, joining headers to discounts **triples** the order header rows. 
A $100 order is summed 3 times ($300)! 
This is the single most common data engineering bug in enterprise reporting: **Join Explosion from Grain Mismatch**. 
The dashboard reports $30M in revenue when the company only made $10M.

THE GOAL:
1. Identify and prevent grain mismatches.
2. Pre-aggregate child tables to the header grain BEFORE joining.
3. Add post-join assertion checks to detect row explosion instantly.
======================================================================================
*/

-- ===================================================================================
-- 1. DATA GENERATION BLOCK (Run this to set up the scenario)
-- ===================================================================================
DROP TABLE IF EXISTS grain_orders CASCADE;
CREATE TABLE grain_orders (
    order_id BIGINT NOT NULL ENCODE az64,
    customer_id BIGINT NOT NULL ENCODE az64,
    order_total DECIMAL(12,2) NOT NULL ENCODE az64
)
DISTSTYLE KEY
DISTKEY (customer_id);

INSERT INTO grain_orders VALUES 
(101, 1, 100.00), -- Order with 2 discounts
(102, 1, 200.00), -- Order with 0 discounts
(103, 2, 300.00); -- Order with 3 discounts
-- Total True Order Revenue = $600.00

DROP TABLE IF EXISTS grain_order_discounts CASCADE;
CREATE TABLE grain_order_discounts (
    discount_id BIGINT NOT NULL ENCODE az64,
    order_id BIGINT NOT NULL ENCODE az64,
    discount_code VARCHAR(20) NOT NULL ENCODE bytedict,
    discount_val DECIMAL(10,2) NOT NULL ENCODE az64
)
DISTSTYLE EVEN;

INSERT INTO grain_order_discounts VALUES 
(1, 101, 'SUMMER10', 10.00),
(2, 101, 'VIP5',      5.00),
(3, 103, 'BLACKFRI',  50.00),
(4, 103, 'LOYALTY',   20.00),
(5, 103, 'FREESHIP',  15.00);

DROP TABLE IF EXISTS rpt_customer_summary CASCADE;
CREATE TABLE rpt_customer_summary (
    customer_id BIGINT NOT NULL,
    total_order_revenue DECIMAL(14,2) NOT NULL,
    total_discounts_applied DECIMAL(14,2) NOT NULL
);


-- ===================================================================================
-- 2. THE "BAD" PROCEDURE (The Exploding Join Anti-Pattern)
-- ===================================================================================
/*
WHY IT'S BROKEN:
- Joins 1:N table (`grain_order_discounts`) directly to 1:1 table (`grain_orders`).
- Order 101 is duplicated 2x ($100 becomes $200).
- Order 103 is duplicated 3x ($300 becomes $900).
- Reported revenue = $1,300.00 instead of real revenue = $600.00 (overstated by 116%!).
*/
CREATE OR REPLACE PROCEDURE prc_bad_exploding_join_revenue()
LANGUAGE plpgsql
AS $$
BEGIN
    TRUNCATE TABLE rpt_customer_summary;
    
    INSERT INTO rpt_customer_summary (customer_id, total_order_revenue, total_discounts_applied)
    SELECT 
        o.customer_id,
        SUM(o.order_total) AS total_order_revenue,           -- INFLATED SUM BUG!
        SUM(NVL(d.discount_val, 0)) AS total_discounts_applied
    FROM grain_orders o
    LEFT JOIN grain_order_discounts d ON o.order_id = d.order_id
    GROUP BY o.customer_id;
    
    RAISE INFO 'Bad procedure finished. (Revenue is wildly inflated!)';
END;
$$;


-- ===================================================================================
-- 3. THE "GOOD" PROCEDURE (The Pre-Aggregated Grain-Aligned Best Practice)
-- ===================================================================================
/*
WHY IT'S 100% ACCURATE:
1. PRE-AGGREGATION: Aggregates `grain_order_discounts` to the `order_id` grain BEFORE joining.
2. 1:1 JOIN: Joining `grain_orders` (1 row per order) to `agg_discounts` (1 row per order)
   guarantees that `order_total` is never multiplied.
3. ROW COUNT INTEGRITY: Revenue correctly computes as $600.00.
*/
CREATE OR REPLACE PROCEDURE prc_good_grain_aligned_revenue()
LANGUAGE plpgsql
AS $$
DECLARE
    v_rows_inserted BIGINT := 0;
BEGIN
    TRUNCATE TABLE rpt_customer_summary;
    
    INSERT INTO rpt_customer_summary (customer_id, total_order_revenue, total_discounts_applied)
    WITH pre_aggregated_discounts AS (
        -- Collapse the 1:N child table down to 1:1 at the order_id grain FIRST
        SELECT 
            order_id,
            SUM(discount_val) AS order_discount_total
        FROM grain_order_discounts
        GROUP BY order_id
    )
    SELECT 
        o.customer_id,
        SUM(o.order_total) AS total_order_revenue,
        SUM(NVL(d.order_discount_total, 0.00)) AS total_discounts_applied
    FROM grain_orders o
    LEFT JOIN pre_aggregated_discounts d ON o.order_id = d.order_id
    GROUP BY o.customer_id;
    
    GET DIAGNOSTICS v_rows_inserted = ROW_COUNT;
    RAISE INFO 'Good procedure complete: % customer summaries calculated accurately.', v_rows_inserted;

EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'prc_good_grain_aligned_revenue failed: %', SQLERRM;
END;
$$;


-- ===================================================================================
-- 4. USAGE, VERIFICATION & FINANCIAL AUDIT
-- ===================================================================================

-- (a) Run Bad Procedure:
-- CALL prc_bad_exploding_join_revenue();
-- SELECT * FROM rpt_customer_summary ORDER BY customer_id;
-- Customer 1 reported revenue: $400.00 (Actual is $300.00)
-- Customer 2 reported revenue: $900.00 (Actual is $300.00)
-- Total sum = $1,300.00 (WRONG!)

-- (b) Run Good Procedure:
-- CALL prc_good_grain_aligned_revenue();
-- SELECT * FROM rpt_customer_summary ORDER BY customer_id;
-- Customer 1 reported revenue: $300.00 (Correct!)
-- Customer 2 reported revenue: $300.00 (Correct!)
-- Total sum = $600.00 (100% ACCURATE!)
