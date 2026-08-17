/*
======================================================================================
MODULE 71: LATERAL JOINS, ARRAY UNNESTING & CORRELATED SUBQUERY REPLACEMENT
======================================================================================
MAPPED BEST PRACTICES (from PROCEDURE_OPTIMIZATION_BEST_PRACTICES_MASTER_FILE.md):
- Practice 25: "Replace correlated subqueries with joins or window functions."
  LATERAL is the third option — purpose-built for row-dependent subqueries.
- Practice 27: "Set-based, not row-by-row."
- Practice 58: "Prefer relational columns over SUPER/JSON where schema is known."

TARGET AUDIENCE: SQL Engineers, Application Developers transitioning to Redshift
BUSINESS SCENARIO:
A product analytics team stores user activity as SUPER arrays in a denormalized table.
Each row contains a user and their array of page views: { "views": ["/home", "/cart", "/pay"] }.
The team needs to "explode" each array element into its own row for funnel analysis.

Without lateral unnesting: They write cursors or multi-step procedures to unnest arrays.
With it: A single SQL statement unnests arrays efficiently and in parallel.

READ THIS FIRST — TERMINOLOGY vs SYNTAX:
Redshift gives you LATERAL *semantics* (a right-hand expression that sees each row of
the left) through PartiQL unnesting: `FROM tbl t, t.super_array AS elem`. It does NOT
give you the `LATERAL` *keyword* — that is absent from the documented FROM-clause
grammar and is a syntax error. Everywhere this module says "lateral", it means the
PartiQL form shown below, never `LATERAL ( ... )`.

ARCHITECTURE:
┌──────────────────────────────────────────────────────────────────────────────┐
│                        LATERAL JOIN MECHANICS                                │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  Regular JOIN:                        LATERAL JOIN:                          │
│  ┌─────────┐   ┌─────────┐           ┌─────────┐   ┌──────────────┐       │
│  │ Table A  │ × │ Table B  │           │ Table A  │──▶│ Subquery B   │       │
│  │ (left)   │   │ (right)  │           │ (left)   │   │ (can see A's │       │
│  │          │   │ no access│           │ per row  │   │  current row)│       │
│  │          │   │ to A     │           │          │   │              │       │
│  └─────────┘   └─────────┘           └─────────┘   └──────────────┘       │
│                                                                              │
│  Regular: B cannot reference A's columns                                    │
│  LATERAL: B CAN reference A's columns — it "sees" each row of A            │
│                                                                              │
│  USE CASES:                                                                 │
│  1. Unnest SUPER arrays into rows (the #1 use case)                        │
│  2. Top-N per group without window functions                                │
│  3. Row-dependent subqueries (replace correlated subqueries)                │
│  4. Table-generating functions applied per row                              │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘

======================================================================================
*/

-- These schemas are referenced throughout this module but are not created by
-- sql/01 (staging, analytics, admin) or sql/07 (rpt). Without these lines every
-- qualified reference below fails with 'schema does not exist'.
CREATE SCHEMA IF NOT EXISTS lab;


-- ============================================================================
-- SECTION 1: DATA GENERATION
-- ============================================================================

-- Table with SUPER arrays (denormalized user activity):
CREATE TABLE IF NOT EXISTS lab.user_activity (
    user_id         INT         NOT NULL,
    activity_date   DATE        NOT NULL,
    page_views      SUPER,          -- Array: ["/home", "/products", "/cart"]
    purchase_items  SUPER,          -- Array of objects: [{"sku":"A1","qty":2}, ...]
    tags            SUPER           -- Array: ["vip", "mobile", "returning"]
)
DISTSTYLE KEY DISTKEY (user_id)
SORTKEY (activity_date);

-- Insert sample data with SUPER arrays:
INSERT INTO lab.user_activity VALUES
(1, '2026-08-14', JSON_PARSE('["/home", "/products", "/cart", "/checkout"]'),
    JSON_PARSE('[{"sku":"SKU001","qty":2,"price":29.99}, {"sku":"SKU002","qty":1,"price":49.99}]'),
    JSON_PARSE('["vip", "mobile"]')),
(2, '2026-08-14', JSON_PARSE('["/home", "/search", "/products"]'),
    JSON_PARSE('[{"sku":"SKU003","qty":1,"price":9.99}]'),
    JSON_PARSE('["new_user", "desktop"]')),
(3, '2026-08-14', JSON_PARSE('["/home"]'),
    JSON_PARSE('[]'),
    JSON_PARSE('["returning", "mobile"]')),
(4, '2026-08-15', JSON_PARSE('["/home", "/products", "/cart", "/checkout", "/confirmation"]'),
    JSON_PARSE('[{"sku":"SKU001","qty":5,"price":29.99}, {"sku":"SKU004","qty":2,"price":99.99}]'),
    JSON_PARSE('["vip", "desktop", "bulk_buyer"]'));


-- ============================================================================
-- SECTION 2: THE "BAD" WAY — CURSOR-BASED ARRAY UNNESTING
-- ============================================================================
-- IMPLEMENTS: applied_redshift.md §2 (The "Bad" Procedure — The App Dev Way)

-- ❌ ANTI-PATTERN: Using a cursor to unnest arrays row by row
-- The app developer thinks: "I need a loop to iterate through each array element"
--
-- CREATE OR REPLACE PROCEDURE lab.sp_unnest_bad()
-- LANGUAGE plpgsql AS $$
-- DECLARE
--     rec RECORD;
--     i   INT;
--     arr_len INT;
-- BEGIN
--     FOR rec IN SELECT user_id, page_views FROM lab.user_activity LOOP
--         arr_len := JSON_ARRAY_LENGTH(rec.page_views);
--         FOR i IN 0..arr_len-1 LOOP
--             INSERT INTO lab.user_pages (user_id, page_url)
--             VALUES (rec.user_id, JSON_EXTRACT_ARRAY_ELEMENT_TEXT(rec.page_views, i));
--         END LOOP;
--     END LOOP;
-- END; $$;
--
-- PROBLEMS:
--   1. Row-by-row INSERT inside nested loops → Leader Node bottleneck
--   2. Each INSERT is a separate transaction → serialized disk writes
--   3. O(n × m) single-row operations instead of one set-based operation


-- ============================================================================
-- SECTION 3: THE "GOOD" WAY — LATERAL JOIN FOR ARRAY UNNESTING
-- ============================================================================
-- IMPLEMENTS: Best Practice #25, #27

-- ✅ GOOD: Unnest page_views array using LATERAL + PartiQL unnesting
SELECT
    u.user_id,
    u.activity_date,
    page_index,
    pv::VARCHAR AS page_url   -- page_views holds SCALAR strings, so cast the element
                              -- itself. There is no pv.page_url attribute to reach for.
FROM lab.user_activity u,
     u.page_views AS pv AT page_index    -- PartiQL array unnesting syntax
WHERE u.activity_date = '2026-08-14';

-- EXPLANATION:
-- "u.page_views AS pv" is Redshift's PartiQL syntax for LATERAL unnesting.
-- It takes each element of the page_views SUPER array and produces a row.
-- "AT page_index" optionally gives you the 0-based array index.
-- This runs in PARALLEL across all slices — no cursor, no loop, no bottleneck.


-- ============================================================================
-- SECTION 4: UNNESTING ARRAYS OF OBJECTS (NESTED STRUCTURES)
-- ============================================================================

-- Unnest purchase_items (array of objects) into rows with typed columns:
SELECT
    u.user_id,
    u.activity_date,
    pi.sku::VARCHAR         AS sku,
    pi.qty::INT             AS quantity,
    pi.price::DECIMAL(10,2) AS unit_price,
    (pi.qty::INT * pi.price::DECIMAL(10,2)) AS line_total
FROM lab.user_activity u,
     u.purchase_items AS pi                 -- Each object becomes a row
WHERE u.activity_date >= '2026-08-14';

-- This replaces: JSON_EXTRACT_ARRAY_ELEMENT_TEXT + manual looping.
-- One parallel, set-based query does what the cursor loop does row-by-row.


-- ============================================================================
-- SECTION 5: TOP-N PER GROUP (WITHOUT A LATERAL KEYWORD — REDSHIFT HAS NONE)
-- ============================================================================

-- IMPORTANT CORRECTION TO A COMMON ASSUMPTION:
-- Redshift does NOT support the explicit LATERAL keyword. Its documented FROM-clause
-- grammar admits only: a WITH subquery, a table, a parenthesised subquery, the join
-- types, PIVOT / UNPIVOT, PartiQL unnesting -- (super_expression.attr) AS alias [AT idx]
-- -- and UNNEST [WITH OFFSET]. "LATERAL ( ... )" is a syntax error here.
--
-- The correlated behaviour people reach for LATERAL to get is already provided by
-- PartiQL unnesting: "u.purchase_items AS pi" IS evaluated per row of u. So for
-- Top-N per group, unnest and then rank.

SELECT user_id, activity_date, sku, max_price
FROM (
    SELECT
        u.user_id,
        u.activity_date,
        pi.sku::VARCHAR         AS sku,
        pi.price::DECIMAL(10,2) AS max_price,
        ROW_NUMBER() OVER (
            PARTITION BY u.user_id, u.activity_date
            ORDER BY pi.price::DECIMAL(10,2) DESC
        ) AS rn
    FROM lab.user_activity u,
         u.purchase_items AS pi
)
WHERE rn = 1;                    -- Top-1 most expensive item per user per day

-- Change rn = 1 to rn <= 3 for Top-3. This runs fully in parallel across slices.


-- ============================================================================
-- SECTION 6: REPLACING CORRELATED SUBQUERIES WITH LATERAL
-- ============================================================================
-- IMPLEMENTS: Best Practice #25

-- ❌ BAD: Correlated subquery (re-executes for every outer row)
-- SELECT
--     o.order_id,
--     o.customer_id,
--     (SELECT MAX(p.payment_date)
--      FROM payments p
--      WHERE p.order_id = o.order_id) AS last_payment_date
-- FROM orders o;

-- ✅ GOOD: pre-aggregate once, then join. Redshift has no LATERAL keyword, so this --
-- not LATERAL -- is the replacement for a correlated subquery over real tables.
-- SELECT
--     o.order_id,
--     o.customer_id,
--     lp.last_payment_date
-- FROM orders o
-- LEFT JOIN (
--     SELECT order_id, MAX(payment_date) AS last_payment_date
--     FROM payments
--     GROUP BY order_id
-- ) lp ON lp.order_id = o.order_id;

-- Both return the same result, but the pre-aggregated join scans payments ONCE and
-- hash-joins in parallel, instead of re-executing a subquery per outer row.
-- (For SUPER arrays the per-row behaviour you want is already what PartiQL
--  unnesting does -- see Sections 3 to 5.)


-- ============================================================================
-- SECTION 7: UNNESTING TAGS ARRAY FOR FILTERING
-- ============================================================================

-- Find all VIP users who visited the cart:
SELECT DISTINCT
    u.user_id,
    u.activity_date
FROM lab.user_activity u,
     u.tags AS tag,
     u.page_views AS pv
WHERE tag::VARCHAR = 'vip'
  AND pv::VARCHAR = '/cart';

-- Multi-array unnesting produces a cross-product of array elements.
-- Here: tags × page_views. Use DISTINCT or restructure if needed.


-- ============================================================================
-- SECTION 8: LATERAL vs. ALTERNATIVES DECISION MATRIX
-- ============================================================================
/*
┌──────────────────────┬──────────────────┬──────────────────┬──────────────────┐
│ Technique            │ Best For         │ Limitations      │ Performance      │
├──────────────────────┼──────────────────┼──────────────────┼──────────────────┤
│ PartiQL unnest       │ SUPER arrays     │ SUPER type only  │ Excellent        │
│ (u.array AS elem)    │ Simple unnesting │                  │ (parallel)       │
├──────────────────────┼──────────────────┼──────────────────┼──────────────────┤
│ Pre-aggregated join  │ Top-N per group  │ Extra staging    │ Excellent        │
│ (LATERAL keyword is  │ Row-dependent    │ step vs LATERAL  │ (parallel)       │
│  NOT supported)      │ calculations     │                  │                  │
├──────────────────────┼──────────────────┼──────────────────┼──────────────────┤
│ Window functions     │ Rank/row_number  │ Cannot filter    │ Excellent        │
│ (ROW_NUMBER, RANK)   │ within groups    │ in same step     │ (parallel)       │
├──────────────────────┼──────────────────┼──────────────────┼──────────────────┤
│ Correlated subquery  │ Simple lookups   │ Nested loop plan │ Poor at scale    │
│ (avoid if possible)  │                  │ Re-executes N×   │ (Leader Node)    │
├──────────────────────┼──────────────────┼──────────────────┼──────────────────┤
│ Cursor loop          │ NEVER use for    │ Row-by-row       │ Terrible         │
│ (anti-pattern)       │ unnesting        │ 100-1000x slower │ (anti-pattern)   │
└──────────────────────┴──────────────────┴──────────────────┴──────────────────┘
*/
