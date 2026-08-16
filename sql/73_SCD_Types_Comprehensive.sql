/*
======================================================================================
MODULE 73: SCD TYPES COMPREHENSIVE — TYPE 1, 2, 3 & 6 PATTERNS
======================================================================================
MAPPED BEST PRACTICES (from PROCEDURE_OPTIMIZATION_BEST_PRACTICES_MASTER_FILE.md):
- Practice 94: "Decide slowly-changing-dimension (SCD) handling PER dimension —
  overwrite vs. keep history — don't default to blind overwrites."
- Practice 44: "Prefer MERGE/upsert over DELETE+INSERT."
- Practice 42: "Make loads idempotent."
- Practice 89: "Use a star schema for analytics — facts plus dimensions."

TARGET AUDIENCE: Data Modelers, ETL Engineers, Analytics Engineers
BUSINESS SCENARIO:
An e-commerce company tracks customer dimension changes over time:
  • Customer moves from New York to San Francisco (address change)
  • Customer upgrades from "Basic" to "Premium" membership tier
  • Customer changes their email address

Different business questions require different SCD strategies:
  • "What's the customer's CURRENT address?" → SCD Type 1 (overwrite)
  • "What was the customer's address WHEN they placed order #5000?" → SCD Type 2 (history)
  • "What was the customer's PREVIOUS tier before they upgraded?" → SCD Type 3 (prev/curr)

ARCHITECTURE:
┌──────────────────────────────────────────────────────────────────────────────┐
│                    SCD TYPE COMPARISON                                        │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  TYPE 1 (Overwrite):      TYPE 2 (History):       TYPE 3 (Prev/Curr):      │
│  ┌───────────────────┐   ┌───────────────────┐   ┌───────────────────┐     │
│  │ cust_id │ city    │   │ cust_key│ city    │   │ cust_id│ city    │     │
│  ├─────────┼─────────┤   │ is_curr │ eff_dt  │   │        │ prev_   │     │
│  │ 101     │ SF      │   │ exp_dt  │         │   │        │ city    │     │
│  │ (was NY,│         │   ├─────────┼─────────┤   ├────────┼─────────┤     │
│  │  now SF)│         │   │ 1001│NY │T│Jan│Dec│   │ 101│SF │ NY      │     │
│  └─────────┴─────────┘   │ 1002│SF │T│Dec│∞  │   └────────┴─────────┘     │
│                           └─────────┴─────────┘                             │
│  • Loses history          • Full history          • Only 1 prior version   │
│  • Simplest               • Most storage          • Moderate complexity    │
│  • Best for: email,       • Best for: address,    • Best for: tier,        │
│    phone, name fixes        membership, price       category changes       │
│                                                                              │
│  TYPE 6 (Hybrid 1+2+3): Combines all three into one row.                   │
│  ┌──────────────────────────────────────────────────────────────────┐       │
│  │ cust_key│ city_current│ city_original│ city_historical│ eff_dt  │       │
│  │ 1001    │ SF          │ NY           │ NY             │ Jan     │       │
│  │ 1002    │ SF          │ NY           │ SF             │ Dec     │       │
│  └──────────────────────────────────────────────────────────────────┘       │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘

======================================================================================
*/

-- ============================================================================
-- SECTION 1: DATA SETUP — SOURCE AND DIMENSION TABLES
-- ============================================================================

-- Source staging table (incoming changes from OLTP):
CREATE TABLE IF NOT EXISTS staging.stg_customers (
    customer_id     INT         NOT NULL,
    customer_name   VARCHAR(100) NOT NULL,
    email           VARCHAR(200),
    city            VARCHAR(100),
    state_code      CHAR(2),
    membership_tier VARCHAR(20),    -- Basic, Premium, Enterprise
    source_updated  TIMESTAMP   NOT NULL
)
DISTSTYLE KEY DISTKEY (customer_id)
SORTKEY (source_updated);

-- Seed sample changes:
INSERT INTO staging.stg_customers VALUES
(101, 'Alice Chen',     'alice@email.com',     'San Francisco', 'CA', 'Premium',    '2026-08-15 10:00:00'),
(102, 'Bob Martinez',   'bob.new@email.com',   'Chicago',       'IL', 'Basic',      '2026-08-15 10:00:00'),
(103, 'Carol Williams', 'carol@email.com',     'Austin',        'TX', 'Enterprise', '2026-08-15 10:00:00'),
(101, 'Alice Chen',     'alice.new@email.com', 'San Francisco', 'CA', 'Enterprise', '2026-08-15 14:00:00');


-- ============================================================================
-- SECTION 2: SCD TYPE 1 — OVERWRITE (LOSE HISTORY)
-- ============================================================================
-- IMPLEMENTS: Best Practice #94 (SCD per dimension), #44 (MERGE)
--
-- USE WHEN: History doesn't matter. You only need the current state.
-- EXAMPLES: Email corrections, name spelling fixes, phone number updates.

CREATE TABLE IF NOT EXISTS gold.dim_customer_type1 (
    customer_id     INT         NOT NULL,   -- Natural/business key
    customer_name   VARCHAR(100),
    email           VARCHAR(200),
    city            VARCHAR(100),
    state_code      CHAR(2),
    membership_tier VARCHAR(20),
    created_at      TIMESTAMP DEFAULT SYSDATE,
    updated_at      TIMESTAMP DEFAULT SYSDATE
)
DISTSTYLE ALL                               -- Small dimension, broadcast
SORTKEY (customer_id);

-- Type 1 MERGE: Simply overwrite changed columns
CREATE OR REPLACE PROCEDURE etl.sp_load_dim_customer_type1()
LANGUAGE plpgsql
AS $$
DECLARE
    v_merged INT;
BEGIN
    MERGE INTO gold.dim_customer_type1 AS tgt
    USING (
        -- Deduplicate: take the latest record per customer
        SELECT customer_id, customer_name, email, city, state_code,
               membership_tier, source_updated
        FROM (
            SELECT *, ROW_NUMBER() OVER (
                PARTITION BY customer_id ORDER BY source_updated DESC
            ) AS rn
            FROM staging.stg_customers
        )
        WHERE rn = 1
    ) AS src
    ON tgt.customer_id = src.customer_id

    WHEN MATCHED AND (
        tgt.customer_name   <> src.customer_name OR
        tgt.email           <> src.email OR
        tgt.city            <> src.city OR
        tgt.membership_tier <> src.membership_tier
    ) THEN UPDATE SET
        customer_name   = src.customer_name,
        email           = src.email,
        city            = src.city,
        state_code      = src.state_code,
        membership_tier = src.membership_tier,
        updated_at      = SYSDATE

    WHEN NOT MATCHED THEN INSERT (
        customer_id, customer_name, email, city, state_code,
        membership_tier, created_at, updated_at
    ) VALUES (
        src.customer_id, src.customer_name, src.email, src.city,
        src.state_code, src.membership_tier, SYSDATE, SYSDATE
    );

    GET DIAGNOSTICS v_merged = ROW_COUNT;
    RAISE INFO 'SCD Type 1: Merged % rows.', v_merged;
END;
$$;


-- ============================================================================
-- SECTION 3: SCD TYPE 2 — FULL HISTORY (NEW ROW PER CHANGE)
-- ============================================================================
-- IMPLEMENTS: Best Practice #94, #44, #42
--
-- USE WHEN: You need to know what the value was AT ANY POINT IN TIME.
-- EXAMPLES: Customer address (for order shipping analysis), product price history.
-- NOTE: This is covered in depth in Module 47. Here we show the complete pattern.

CREATE TABLE IF NOT EXISTS gold.dim_customer_type2 (
    customer_key    BIGINT IDENTITY(1,1),   -- Surrogate key (auto-increment)
    customer_id     INT         NOT NULL,   -- Natural/business key
    customer_name   VARCHAR(100),
    email           VARCHAR(200),
    city            VARCHAR(100),
    state_code      CHAR(2),
    membership_tier VARCHAR(20),
    effective_date  TIMESTAMP   NOT NULL,
    expiration_date TIMESTAMP   NOT NULL DEFAULT '9999-12-31',
    is_current      BOOLEAN     NOT NULL DEFAULT TRUE,
    row_hash        BIGINT                  -- Change detection hash
)
DISTSTYLE ALL
SORTKEY (customer_id, effective_date);

-- Type 2 procedure: Expire old rows + insert new rows for changes
CREATE OR REPLACE PROCEDURE etl.sp_load_dim_customer_type2()
LANGUAGE plpgsql
AS $$
DECLARE
    v_expired INT;
    v_inserted INT;
BEGIN
    -- Step 1: Identify changed records using hash comparison
    CREATE TEMP TABLE tmp_changes AS
    SELECT
        src.customer_id,
        src.customer_name,
        src.email,
        src.city,
        src.state_code,
        src.membership_tier,
        src.source_updated,
        CHECKSUM(src.customer_name || src.email || src.city
                 || src.state_code || src.membership_tier) AS new_hash
    FROM (
        SELECT *, ROW_NUMBER() OVER (
            PARTITION BY customer_id ORDER BY source_updated DESC
        ) AS rn
        FROM staging.stg_customers
    ) src
    LEFT JOIN gold.dim_customer_type2 tgt
        ON src.customer_id = tgt.customer_id AND tgt.is_current = TRUE
    WHERE src.rn = 1
      AND (tgt.customer_key IS NULL    -- New customer
           OR tgt.row_hash <> CHECKSUM(src.customer_name || src.email || src.city
                                       || src.state_code || src.membership_tier));

    -- Step 2: Expire existing current rows for changed customers
    UPDATE gold.dim_customer_type2
    SET expiration_date = SYSDATE,
        is_current      = FALSE
    WHERE customer_id IN (SELECT customer_id FROM tmp_changes)
      AND is_current = TRUE;
    GET DIAGNOSTICS v_expired = ROW_COUNT;

    -- Step 3: Insert new current rows
    INSERT INTO gold.dim_customer_type2 (
        customer_id, customer_name, email, city, state_code,
        membership_tier, effective_date, expiration_date, is_current, row_hash
    )
    SELECT
        customer_id, customer_name, email, city, state_code,
        membership_tier, source_updated, '9999-12-31', TRUE, new_hash
    FROM tmp_changes;
    GET DIAGNOSTICS v_inserted = ROW_COUNT;

    DROP TABLE IF EXISTS tmp_changes;

    RAISE INFO 'SCD Type 2: Expired % rows, Inserted % new versions.',
               v_expired, v_inserted;
END;
$$;

-- Point-in-time query: What was the customer's city when order #5000 was placed?
-- SELECT d.city
-- FROM gold.fact_orders f
-- JOIN gold.dim_customer_type2 d
--   ON f.customer_id = d.customer_id
--   AND f.order_date >= d.effective_date
--   AND f.order_date <  d.expiration_date   -- Half-open range!
-- WHERE f.order_id = 5000;


-- ============================================================================
-- SECTION 4: SCD TYPE 3 — PREVIOUS + CURRENT COLUMNS
-- ============================================================================
-- USE WHEN: You only need the immediately previous value (not full history).
-- EXAMPLES: Membership tier upgrades/downgrades, category reclassification.

CREATE TABLE IF NOT EXISTS gold.dim_customer_type3 (
    customer_id         INT PRIMARY KEY,
    customer_name       VARCHAR(100),
    email               VARCHAR(200),
    -- Current values:
    city_current        VARCHAR(100),
    state_current       CHAR(2),
    tier_current        VARCHAR(20),
    -- Previous values (one level of history):
    city_previous       VARCHAR(100),
    state_previous      CHAR(2),
    tier_previous       VARCHAR(20),
    -- Timestamps:
    current_since       TIMESTAMP,
    previous_since      TIMESTAMP,
    updated_at          TIMESTAMP DEFAULT SYSDATE
)
DISTSTYLE ALL
SORTKEY (customer_id);

-- Type 3 MERGE: Shift current → previous, then update current
CREATE OR REPLACE PROCEDURE etl.sp_load_dim_customer_type3()
LANGUAGE plpgsql
AS $$
DECLARE
    v_merged INT;
BEGIN
    MERGE INTO gold.dim_customer_type3 AS tgt
    USING (
        SELECT customer_id, customer_name, email, city, state_code,
               membership_tier, source_updated
        FROM (
            SELECT *, ROW_NUMBER() OVER (
                PARTITION BY customer_id ORDER BY source_updated DESC
            ) AS rn
            FROM staging.stg_customers
        ) WHERE rn = 1
    ) AS src
    ON tgt.customer_id = src.customer_id

    WHEN MATCHED AND (
        tgt.city_current    <> src.city OR
        tgt.tier_current    <> src.membership_tier
    ) THEN UPDATE SET
        -- Shift current → previous
        city_previous   = tgt.city_current,
        state_previous  = tgt.state_current,
        tier_previous   = tgt.tier_current,
        previous_since  = tgt.current_since,
        -- Set new current values
        city_current    = src.city,
        state_current   = src.state_code,
        tier_current    = src.membership_tier,
        current_since   = src.source_updated,
        customer_name   = src.customer_name,
        email           = src.email,
        updated_at      = SYSDATE

    WHEN NOT MATCHED THEN INSERT (
        customer_id, customer_name, email,
        city_current, state_current, tier_current,
        city_previous, state_previous, tier_previous,
        current_since, previous_since, updated_at
    ) VALUES (
        src.customer_id, src.customer_name, src.email,
        src.city, src.state_code, src.membership_tier,
        NULL, NULL, NULL,
        src.source_updated, NULL, SYSDATE
    );

    GET DIAGNOSTICS v_merged = ROW_COUNT;
    RAISE INFO 'SCD Type 3: Merged % rows.', v_merged;
END;
$$;

-- Query: "Which customers upgraded their tier?"
-- SELECT customer_id, customer_name,
--        tier_previous AS was, tier_current AS now
-- FROM gold.dim_customer_type3
-- WHERE tier_previous IS NOT NULL
--   AND tier_previous <> tier_current;


-- ============================================================================
-- SECTION 5: SCD TYPE 6 — HYBRID (1+2+3 COMBINED)
-- ============================================================================
-- USE WHEN: You need BOTH full history AND quick access to current + previous.
-- This is the most flexible but also most storage-intensive approach.

CREATE TABLE IF NOT EXISTS gold.dim_customer_type6 (
    customer_key        BIGINT IDENTITY(1,1),
    customer_id         INT         NOT NULL,
    customer_name       VARCHAR(100),
    -- Historical value (what it was during this row's effective period):
    city_historical     VARCHAR(100),
    tier_historical     VARCHAR(20),
    -- Current value (always the latest — updated across ALL rows):
    city_current        VARCHAR(100),
    tier_current        VARCHAR(20),
    -- Original value (the very first value ever recorded):
    city_original       VARCHAR(100),
    tier_original       VARCHAR(20),
    -- Type 2 versioning columns:
    effective_date      TIMESTAMP,
    expiration_date     TIMESTAMP   DEFAULT '9999-12-31',
    is_current          BOOLEAN     DEFAULT TRUE
)
DISTSTYLE ALL
SORTKEY (customer_id, effective_date);

-- Type 6 is operationally complex: when a change occurs, you must:
--   1. Expire the current row (like Type 2)
--   2. Insert a new row with historical=new value, current=new value (Type 2)
--   3. UPDATE ALL existing rows for this customer to set city_current=new value (Type 1)
-- This makes the "current" columns identical across all rows for the same customer.


-- ============================================================================
-- SECTION 6: SCD TYPE DECISION MATRIX
-- ============================================================================
/*
┌───────────────────┬──────────┬──────────┬──────────┬──────────┐
│ Criteria          │ Type 1   │ Type 2   │ Type 3   │ Type 6   │
├───────────────────┼──────────┼──────────┼──────────┼──────────┤
│ History Preserved │ None     │ Full     │ 1 prior  │ Full     │
│ Storage Growth    │ None     │ High     │ None     │ Highest  │
│ Query Complexity  │ Simple   │ Moderate │ Simple   │ Complex  │
│ Point-in-Time     │ No       │ Yes      │ No       │ Yes      │
│ Current + Prior   │ No       │ With CTE │ Yes      │ Yes      │
│ ETL Complexity    │ Low      │ Medium   │ Low      │ High     │
│ Fact Join Pattern │ biz_key  │ surr_key │ biz_key  │ surr_key │
│ Update Scope      │ 1 row    │ 2 rows   │ 1 row    │ N rows   │
├───────────────────┼──────────┼──────────┼──────────┼──────────┤
│ Best For          │ Fixes,   │ Address, │ Tier,    │ Complex  │
│                   │ typos    │ price    │ category │ audit    │
└───────────────────┴──────────┴──────────┴──────────┴──────────┘

RECOMMENDATION PER ATTRIBUTE:
  • customer_name: Type 1 (spelling corrections don't need history)
  • email: Type 1 (old emails are useless)
  • address/city: Type 2 (shipping analysis requires point-in-time)
  • membership_tier: Type 3 (upgrade/downgrade analysis needs prev + current)
  • product_price: Type 2 (revenue analysis requires historical price)
  • product_category: Type 3 (reclassification needs prev + current)
*/
