-- =========================================================================
-- 13 — Constraints are hints, not rules
--
-- WHAT IS ENFORCED, AND WHAT IS NOT
--
--   NOT NULL                  ENFORCED. The only one. A NULL into a NOT NULL
--                             column fails the statement. Use it on every
--                             key column, deliberately.
--
--   PRIMARY KEY / UNIQUE      NOT ENFORCED. Informational. Insert the same
--   FOREIGN KEY               key twice and both rows are stored. No error,
--                             no warning, and a doubled number in a report
--                             tomorrow.
--
--   DECLARE THEM ANYWAY       The planner uses them to eliminate joins and
--                             choose plans. But a WRONG declaration is worse
--                             than none — it can produce wrong results.
--
--   TEST INSTEAD              Uniqueness becomes a test that runs after
--                             every load, not a promise the database makes.
--                             That is the habit to build on day one.
-- =========================================================================


-- =========================================================================
-- 13.1  PROVE IT — do not take this on faith
--
-- Run this whole block. Watch both inserts succeed.
-- =========================================================================
DROP TABLE IF EXISTS analytics.dim_store_proof;

CREATE TABLE analytics.dim_store_proof (
    store_sk  BIGINT      PRIMARY KEY,          -- not enforced
    store_id  VARCHAR(20) UNIQUE,               -- not enforced
    region    VARCHAR(32) NOT NULL              -- ENFORCED
);

INSERT INTO analytics.dim_store_proof VALUES (1, 'S001', 'WEST');
INSERT INTO analytics.dim_store_proof VALUES (1, 'S001', 'WEST');
-- Both succeed. No error. No warning.

SELECT COUNT(*) AS row_count FROM analytics.dim_store_proof;   -- 2

-- Now the one that IS enforced:
INSERT INTO analytics.dim_store_proof VALUES (2, 'S002', NULL);
-- ERROR:  Cannot insert a NULL value into column region
--
-- That contrast, in one table, is the entire lesson. NOT NULL stopped you.
-- PRIMARY KEY did not.

SELECT store_sk, store_id, region, COUNT(*) AS copies
FROM   analytics.dim_store_proof
GROUP  BY 1,2,3;


-- =========================================================================
-- 13.2  Why — it is a deliberate engineering decision, not an omission
--
-- Enforcing uniqueness means checking every slice on every insert: a
-- cross-node round trip per row. In an MPP system that would destroy the
-- bulk-load performance the whole design exists to provide.
--
-- Redshift declines that trade and hands the responsibility to you.
--
-- Say this out loud to the team, because the instinct from OLTP is to read
-- the behaviour as a bug. It is not. It is the price of loading a billion
-- rows in minutes, and it is the right price — as long as somebody tests.
-- =========================================================================


-- =========================================================================
-- 13.3  A wrong declaration can produce WRONG RESULTS
--
-- The optimiser TRUSTS these declarations. It may drop a join it believes
-- cannot change the row count. If your "unique" key is not actually unique,
-- the plan it chooses is invalid — and you get a silently wrong number
-- rather than an error.
--
-- So: declare them where they are genuinely true, and test that they stay
-- true. Never declare one "for documentation".
-- =========================================================================
DROP TABLE IF EXISTS analytics.dim_bad_pk;
DROP TABLE IF EXISTS analytics.fct_probe;

CREATE TABLE analytics.dim_bad_pk (
    store_sk BIGINT PRIMARY KEY,      -- declared unique, will NOT be
    region   VARCHAR(32)
) DISTSTYLE ALL;

-- Deliberately violate the declaration.
INSERT INTO analytics.dim_bad_pk VALUES (1,'WEST'), (1,'WEST'), (2,'EMEA');

CREATE TABLE analytics.fct_probe (
    sale_id  BIGINT,
    store_sk BIGINT,
    amount   DECIMAL(14,2)
) DISTSTYLE EVEN;

INSERT INTO analytics.fct_probe VALUES (1,1,100.00), (2,1,200.00), (3,2,50.00);

ANALYZE analytics.dim_bad_pk;
ANALYZE analytics.fct_probe;

-- The honest answer is 350.00 across 3 fact rows. Compare:
SELECT SUM(f.amount) AS total, COUNT(*) AS rows_after_join
FROM   analytics.fct_probe f
JOIN   analytics.dim_bad_pk d USING (store_sk);
-- The duplicate dimension row fans out store 1's facts, so the total is
-- inflated. The planner believed store_sk was unique; it is not.

EXPLAIN
SELECT SUM(f.amount)
FROM   analytics.fct_probe f
JOIN   analytics.dim_bad_pk d USING (store_sk);

-- The lesson in one sentence: a PRIMARY KEY you declared but did not
-- enforce is not documentation, it is a landmine.


-- =========================================================================
-- 13.4  The tests you actually run
--
-- These four run after every load. They are cheap. Test 4 is the cheapest
-- and catches most incidents.
-- =========================================================================

-- 1. Duplicate keys in a dimension.
SELECT store_sk, COUNT(*) AS n
FROM   analytics.dim_store_proof
GROUP  BY 1
HAVING COUNT(*) > 1;

-- 2. Duplicate merge keys in a fact — the "did the load run twice?" check.
SELECT order_id, COUNT(*) AS n
FROM   analytics.fct_customer_orders
WHERE  order_date = '2024-03-01'
GROUP  BY 1
HAVING COUNT(*) > 1
LIMIT  20;

-- 3. Orphaned foreign keys — rows pointing at a dimension member that is
--    gone. A LEFT JOIN with a NULL test on the dimension side.
SELECT COUNT(*) AS orphans
FROM   analytics.fct_customer_orders f
LEFT   JOIN analytics.dim_country d ON d.country_code = f.country
WHERE  d.country_code IS NULL;

-- 4. THE FAST SMOKE TEST: does the row count match the distinct key count?
--    If these two numbers differ, you have duplicates. One query, whole
--    table, no GROUP BY over millions of groups.
SELECT COUNT(*)                  AS rows,
       COUNT(DISTINCT order_id)  AS distinct_keys,
       COUNT(*) - COUNT(DISTINCT order_id) AS duplicates
FROM   analytics.fct_customer_orders;


-- =========================================================================
-- 13.5  Make it a procedure that runs after every load
-- =========================================================================
CREATE OR REPLACE PROCEDURE analytics.sp_assert_unique(
    p_schema VARCHAR(128),
    p_table  VARCHAR(128),
    p_key    VARCHAR(128)
)
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
DECLARE
    v_rows BIGINT;
    v_keys BIGINT;
BEGIN
    EXECUTE 'SELECT COUNT(*), COUNT(DISTINCT ' || quote_ident(p_key) || ') ' ||
            'FROM ' || quote_ident(p_schema) || '.' || quote_ident(p_table)
    INTO v_rows, v_keys;

    INSERT INTO analytics.dq_results (check_name, severity, observed, threshold, passed)
    VALUES (p_schema || '.' || p_table || '.' || p_key || ' unique',
            'BLOCKING', v_rows - v_keys, 0, (v_rows = v_keys));

    IF v_rows <> v_keys THEN
        RAISE EXCEPTION 'sp_assert_unique: %.% has % duplicate %',
            p_schema, p_table, v_rows - v_keys, p_key;
    END IF;

    RAISE INFO 'sp_assert_unique: %.%(%) OK — % rows, all distinct',
        p_schema, p_table, p_key, v_rows;
END;
$$;

CALL analytics.sp_assert_unique('analytics','fct_customer_orders','order_id');
-- And the one that should fail, proving the test works:
-- CALL analytics.sp_assert_unique('analytics','dim_bad_pk','store_sk');


-- =========================================================================
-- 13.6  In dbt — where this belongs long-term
--
-- Uniqueness becomes a test that runs after every build, not a promise the
-- database makes:
--
--   # models/marts/core/core.yml
--   version: 2
--   models:
--     - name: fct_sales_line
--       columns:
--         - name: merge_key
--           tests:
--             - unique
--             - not_null
--         - name: store_sk
--           tests:
--             - not_null
--             - relationships:
--                 to: ref('dim_store')
--                 field: store_sk
--
-- `dbt test` then fails the build rather than shipping a doubled number.
-- The `relationships` test is the foreign key Redshift will not enforce.
-- =========================================================================


-- =========================================================================
-- 13.7  Checklist
--
--   [ ] NOT NULL on every key column — it is the only enforced constraint
--   [ ] PK/UNIQUE/FK declared only where genuinely true
--   [ ] Every declared key has a test that runs after every load
--   [ ] The row-count vs distinct-count smoke test is in the pipeline
--   [ ] Orphan checks exist for every declared foreign key
--
-- YOU HAVE GOT IT WHEN you can explain to a sceptical application developer
-- why Redshift does not enforce a primary key, and show them the four tests
-- you run instead.
-- =========================================================================
DROP TABLE IF EXISTS analytics.dim_bad_pk;
DROP TABLE IF EXISTS analytics.fct_probe;
DROP TABLE IF EXISTS analytics.dim_store_proof;
