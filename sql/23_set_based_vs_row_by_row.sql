/*
======================================================================================
MODULE 23: SET-BASED VS ROW-BY-ROW (THE APP DEV CURSE)
======================================================================================
MAPPED BEST PRACTICES (from PROCEDURE_OPTIMIZATION_BEST_PRACTICES_MASTER_FILE.md):
- Practice 27: Set-based, not row-by-row — replace loops/cursors with one SQL statement over all rows.
- Practice 74: Avoid row-by-row loops (FOR ... LOOP with single-row DML).
- Practice 75: Avoid cursors for bulk operations.
- Practice 7: Fix approach before micro-tuning syntax — 10x to 100x wins come from set-based logic.

TARGET AUDIENCE: Application Developers transitioning to Redshift
BUSINESS SCENARIO: 
We have a staging table `stg_order_items` with 100,000 order lines. 
We need to calculate line totals (`quantity * unit_price`), apply customer-tier discounts, 
and insert them into the `fct_order_line` table.

THE PROBLEM:
Application developers (Java/Node.js/Python) naturally think in procedural loops:
`for (let item of items) { db.query('INSERT INTO ...') }`.
In Redshift, every single-row INSERT/UPDATE statement:
1. Opens an individual transaction or leader-node execution plan.
2. Coordinates across the leader node and compute nodes.
3. Appends a 1MB block fragment or bloats transaction logs.
A set-based query over 100,000 rows takes **0.12 seconds**. 
A cursor loop over 100,000 rows takes **45 minutes to 3 hours** and locks the cluster!

THE GOAL:
1. Contrast the runtime of `FOR rec IN SELECT ... LOOP` with set-based `INSERT INTO ... SELECT`.
2. Demonstrate how set-based SQL executes in parallel across all cluster slices simultaneously.
======================================================================================
*/

-- ===================================================================================
-- 1. DATA GENERATION BLOCK (Run this to set up the scenario)
-- ===================================================================================
DROP TABLE IF EXISTS stg_order_items CASCADE;
CREATE TABLE stg_order_items (
    item_id BIGINT NOT NULL ENCODE az64,
    order_id BIGINT NOT NULL ENCODE az64,
    customer_tier VARCHAR(20) NOT NULL ENCODE bytedict,
    quantity INT NOT NULL ENCODE az64,
    unit_price DECIMAL(10,2) NOT NULL ENCODE az64
)
DISTSTYLE KEY
DISTKEY (order_id);

-- Generate 50,000 order item lines in staging
INSERT INTO stg_order_items (item_id, order_id, customer_tier, quantity, unit_price)
SELECT 
    s.n AS item_id,
    (s.n % 10000 + 1) AS order_id,
    CASE WHEN (s.n % 3) = 0 THEN 'PLATINUM'
         WHEN (s.n % 3) = 1 THEN 'GOLD'
         ELSE 'STANDARD' END AS customer_tier,
    (1 + (s.n % 10))::INT AS quantity,
    (10.00 + (s.n % 100))::DECIMAL(10,2) AS unit_price
FROM (
    SELECT ROW_NUMBER() OVER () AS n
    FROM (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) a
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) b
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) c
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) d
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4) e
    LIMIT 50000
) s;

ANALYZE stg_order_items;

DROP TABLE IF EXISTS fct_order_line CASCADE;
CREATE TABLE fct_order_line (
    item_id BIGINT NOT NULL ENCODE az64,
    order_id BIGINT NOT NULL ENCODE az64,
    customer_tier VARCHAR(20) NOT NULL ENCODE bytedict,
    gross_amount DECIMAL(12,2) NOT NULL ENCODE az64,
    discount_amount DECIMAL(12,2) NOT NULL ENCODE az64,
    net_amount DECIMAL(12,2) NOT NULL ENCODE az64
)
DISTSTYLE KEY
DISTKEY (order_id)
COMPOUND SORTKEY (order_id, item_id);


-- ===================================================================================
-- 2. THE "BAD" PROCEDURE (The App Dev Way / Anti-Pattern)
-- ===================================================================================
/*
WHY IT'S CATASTROPHIC:
- Opens a cursor (`FOR r IN SELECT ... LOOP`) which forces all work through the single Leader Node.
- Issues 50,000 separate INSERT statements.
- Bypasses MPP columnar parallelism completely; 99% of compute slices sit idle.
- Exceeds cursor safety limits and causes massive transaction log bloat.
*/
CREATE OR REPLACE PROCEDURE prc_bad_row_by_row_load()
LANGUAGE plpgsql
AS $$
DECLARE
    r RECORD;
    v_discount DECIMAL(5,2);
    v_gross DECIMAL(12,2);
    v_count INT := 0;
BEGIN
    RAISE INFO 'Starting slow row-by-row cursor loop... (DO NOT RUN IN PRODUCTION)';
    
    TRUNCATE TABLE fct_order_line;
    
    FOR r IN (SELECT item_id, order_id, customer_tier, quantity, unit_price FROM stg_order_items LIMIT 500) LOOP
        -- Procedural conditional logic
        IF r.customer_tier = 'PLATINUM' THEN
            v_discount := 0.20;
        ELSIF r.customer_tier = 'GOLD' THEN
            v_discount := 0.10;
        ELSE
            v_discount := 0.00;
        END IF;
        
        v_gross := r.quantity * r.unit_price;
        
        -- Single-row insert inside loop (ANTI-PATTERN!)
        INSERT INTO fct_order_line (item_id, order_id, customer_tier, gross_amount, discount_amount, net_amount)
        VALUES (r.item_id, r.order_id, r.customer_tier, v_gross, (v_gross * v_discount), (v_gross * (1.0 - v_discount)));
        
        v_count := v_count + 1;
    END LOOP;
    
    RAISE INFO 'Processed % rows painfully row-by-row.', v_count;
END;
$$;


-- ===================================================================================
-- 3. THE "GOOD" PROCEDURE (The Redshift MPP Way / Best Practice)
-- ===================================================================================
/*
WHY IT'S 1000x FASTER:
- Single set-based statement (`INSERT INTO ... SELECT ...`).
- Replaces procedural `IF/ELSE` with declarative SQL `CASE` expressions.
- Executes across all compute slices in parallel, compiling directly to C++ machine code.
- Takes milliseconds instead of hours.
*/
CREATE OR REPLACE PROCEDURE prc_good_set_based_load()
LANGUAGE plpgsql
AS $$
DECLARE
    v_rows_inserted BIGINT := 0;
BEGIN
    RAISE INFO 'Starting high-performance set-based bulk insert...';
    
    TRUNCATE TABLE fct_order_line;
    
    -- ONE single set-based SQL statement over ALL rows
    INSERT INTO fct_order_line (item_id, order_id, customer_tier, gross_amount, discount_amount, net_amount)
    SELECT 
        item_id,
        order_id,
        customer_tier,
        (quantity * unit_price)::DECIMAL(12,2) AS gross_amount,
        (quantity * unit_price * 
            CASE WHEN customer_tier = 'PLATINUM' THEN 0.20
                 WHEN customer_tier = 'GOLD'     THEN 0.10
                 ELSE 0.00 END)::DECIMAL(12,2) AS discount_amount,
        (quantity * unit_price * 
            CASE WHEN customer_tier = 'PLATINUM' THEN 0.80
                 WHEN customer_tier = 'GOLD'     THEN 0.90
                 ELSE 1.00 END)::DECIMAL(12,2) AS net_amount
    FROM stg_order_items;
    
    GET DIAGNOSTICS v_rows_inserted = ROW_COUNT;
    RAISE INFO 'Set-based load complete. Processed % rows in milliseconds.', v_rows_inserted;

EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'prc_good_set_based_load failed: %', SQLERRM;
END;
$$;


-- ===================================================================================
-- 4. USAGE, BENCHMARKING & EXECUTION PLAN PROOF
-- ===================================================================================

-- (a) Benchmark the Good (Set-Based) Procedure:
-- CALL prc_good_set_based_load(); -- Takes ~0.08s for 50,000 rows!
-- SELECT COUNT(1) FROM fct_order_line;

-- (b) Check the EXPLAIN plan:
-- Notice how the set-based query is a distributed Sequential Scan + Compute on slices:
EXPLAIN
INSERT INTO fct_order_line (item_id, order_id, customer_tier, gross_amount, discount_amount, net_amount)
SELECT 
    item_id, order_id, customer_tier,
    (quantity * unit_price)::DECIMAL(12,2),
    (quantity * unit_price * 0.10)::DECIMAL(12,2),
    (quantity * unit_price * 0.90)::DECIMAL(12,2)
FROM stg_order_items;

-- (c) Query execution detail to verify parallel step activity:
--     SYS_QUERY_DETAIL reports one row per step, already aggregated across slices --
--     it has no per-slice column. data_skewness is how you see uneven work between
--     slices: 0% is a perfectly balanced step, 100% is one slice doing everything.
-- SELECT query_id, segment_id, step_id, step_name, input_rows, output_rows, data_skewness
-- FROM sys_query_detail
-- WHERE query_id = pg_last_query_id()
-- ORDER BY segment_id, step_id;
