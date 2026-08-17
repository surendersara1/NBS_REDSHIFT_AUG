/*
======================================================================================
MODULE 28: DISTRIBUTION KEY ALIGNMENT (DS_DIST_NONE VS DS_DIST_BOTH)
======================================================================================
MAPPED BEST PRACTICES (from PROCEDURE_OPTIMIZATION_BEST_PRACTICES_MASTER_FILE.md):
- Practice 29: Align distribution keys across frequently-joined tables to avoid redistribution.
- Practice 34: Check EXPLAIN for DS_DIST_BOTH / DS_BCAST_INNER data movement.
- Practice 48: Choose a distribution key on the column most frequently used in joins (DISTSTYLE KEY).
- Practice 51: Distribute so rows spread evenly across slices — avoid data skew.

TARGET AUDIENCE: Application Developers transitioning to Redshift
BUSINESS SCENARIO: 
We are building a massive `fct_user_sales` table by joining `raw_sales_data` (200,000 rows) 
with `raw_user_sessions` (500,000 rows) on `user_id`.

THE PROBLEM:
In transactional databases (PostgreSQL/MySQL), joins happen within a single memory space. 
In Redshift, data is physically partitioned across multiple compute nodes and slices. 
If Table A is distributed on `DISTKEY (sale_id)` and Table B is distributed on `DISTKEY (session_id)`, 
joining on `user_id` forces Redshift to re-hash and transmit **millions of rows over the cluster network**.
In the `EXPLAIN` plan, this appears as `DS_DIST_BOTH` (redistributing both tables) or `DS_DIST_INNER`. 
Network shuffle is the #1 cause of slow join performance in MPP data warehouses.

THE GOAL:
1. Align distribution keys on the join column (`DISTSTYLE KEY DISTKEY (user_id)`).
2. Achieve `DS_DIST_NONE` (Collocated Join) where each compute slice joins only local disk data.
3. Compare `EXPLAIN` plans: `DS_DIST_BOTH` vs. `DS_DIST_NONE`.
======================================================================================
*/

-- ===================================================================================
-- 1. DATA GENERATION BLOCK (Run this to set up the scenario)
-- ===================================================================================

-- (A) MISALIGNED TABLES (Even / Misaligned Keys):
DROP TABLE IF EXISTS bad_sales CASCADE;
CREATE TABLE bad_sales (
    sale_id BIGINT NOT NULL ENCODE az64,
    user_id BIGINT NOT NULL ENCODE az64,
    sale_amount DECIMAL(12,2) NOT NULL ENCODE az64
)
DISTSTYLE EVEN; -- Spreads rows blindly across slices

DROP TABLE IF EXISTS bad_sessions CASCADE;
CREATE TABLE bad_sessions (
    session_id BIGINT NOT NULL ENCODE az64,
    user_id BIGINT NOT NULL ENCODE az64,
    ip_address VARCHAR(45) NOT NULL ENCODE zstd
)
DISTSTYLE KEY
DISTKEY (session_id); -- Key is session_id, NOT user_id!

-- (B) ALIGNED TABLES (Collocated Keys on user_id):
DROP TABLE IF EXISTS good_sales CASCADE;
CREATE TABLE good_sales (
    sale_id BIGINT NOT NULL ENCODE az64,
    user_id BIGINT NOT NULL ENCODE az64,
    sale_amount DECIMAL(12,2) NOT NULL ENCODE az64
)
DISTSTYLE KEY
DISTKEY (user_id); -- Distkey is user_id!

DROP TABLE IF EXISTS good_sessions CASCADE;
CREATE TABLE good_sessions (
    session_id BIGINT NOT NULL ENCODE az64,
    user_id BIGINT NOT NULL ENCODE az64,
    ip_address VARCHAR(45) NOT NULL ENCODE zstd
)
DISTSTYLE KEY
DISTKEY (user_id); -- Distkey is ALSO user_id!

-- Populate with 100,000 sales and 200,000 sessions
INSERT INTO bad_sales (sale_id, user_id, sale_amount)
SELECT s.n, (s.n % 10000 + 1), (10.00 + (s.n % 100))::DECIMAL(12,2)
FROM (SELECT ROW_NUMBER() OVER () as n FROM (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) a, (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) b, (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) c, (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) d, (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) e LIMIT 100000) s;

INSERT INTO good_sales SELECT * FROM bad_sales;

INSERT INTO bad_sessions (session_id, user_id, ip_address)
SELECT s.n, (s.n % 10000 + 1), '192.168.1.' || (s.n % 255)::VARCHAR
FROM (SELECT ROW_NUMBER() OVER () as n FROM (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) a, (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) b, (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) c, (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) d, (SELECT 0 UNION SELECT 1) e, (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) f LIMIT 200000) s;

INSERT INTO good_sessions SELECT * FROM bad_sessions;

ANALYZE bad_sales;
ANALYZE bad_sessions;
ANALYZE good_sales;
ANALYZE good_sessions;

DROP TABLE IF EXISTS target_user_sales CASCADE;
CREATE TABLE target_user_sales (
    sale_id BIGINT NOT NULL,
    user_id BIGINT NOT NULL,
    sale_amount DECIMAL(12,2) NOT NULL,
    session_id BIGINT NOT NULL
)
DISTSTYLE KEY
DISTKEY (user_id);


-- ===================================================================================
-- 2. THE "BAD" PROCEDURE (The Misaligned Network Shuffle Anti-Pattern)
-- ===================================================================================
/*
WHY IT'S SLOW:
- Joins `bad_sales` (EVEN) to `bad_sessions` (KEY on session_id) on `user_id`.
- Compute nodes must dynamically hash and broadcast data over the internal network fabric.
- In `EXPLAIN`, this produces `DS_DIST_BOTH` or `DS_DIST_INNER`.
*/
CREATE OR REPLACE PROCEDURE prc_bad_join_sales()
LANGUAGE plpgsql
AS $$
DECLARE
    v_rows BIGINT := 0;
BEGIN
    TRUNCATE TABLE target_user_sales;
    
    INSERT INTO target_user_sales (sale_id, user_id, sale_amount, session_id)
    SELECT s.sale_id, s.user_id, s.sale_amount, sess.session_id
    FROM bad_sales s
    INNER JOIN bad_sessions sess ON s.user_id = sess.user_id;
    
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RAISE INFO 'Bad misaligned join complete: % rows loaded.', v_rows;
END;
$$;


-- ===================================================================================
-- 3. THE "GOOD" PROCEDURE (The Collocated Zero-Network-Shuffle Best Practice)
-- ===================================================================================
/*
WHY IT'S 10x FASTER:
- Both `good_sales` and `good_sessions` are distributed on `DISTKEY (user_id)`.
- User 500 in `good_sales` sits on the EXACT same compute slice as User 500 in `good_sessions`.
- Every slice joins its own local RAM/NVMe data with **ZERO NETWORK DATA MOVEMENT**.
- In `EXPLAIN`, this produces `DS_DIST_NONE` (Collocated Join).
*/
CREATE OR REPLACE PROCEDURE prc_good_join_sales()
LANGUAGE plpgsql
AS $$
DECLARE
    v_rows BIGINT := 0;
BEGIN
    TRUNCATE TABLE target_user_sales;
    
    -- Collocated set-based join
    INSERT INTO target_user_sales (sale_id, user_id, sale_amount, session_id)
    SELECT s.sale_id, s.user_id, s.sale_amount, sess.session_id
    FROM good_sales s
    INNER JOIN good_sessions sess ON s.user_id = sess.user_id;
    
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RAISE INFO 'Good collocated join complete: % rows loaded with DS_DIST_NONE.', v_rows;

EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'prc_good_join_sales failed: %', SQLERRM;
END;
$$;


-- ===================================================================================
-- 4. USAGE, VERIFICATION & EXPLAIN PLAN PROOF
-- ===================================================================================

-- (a) Compare Execution Plans (EXPLAIN):

-- MISALIGNED (Bad): Notice `DS_DIST_BOTH` or `DS_DIST_INNER` in the plan!
EXPLAIN
SELECT s.sale_id, s.user_id, s.sale_amount, sess.session_id
FROM bad_sales s
INNER JOIN bad_sessions sess ON s.user_id = sess.user_id;

-- ALIGNED (Good): Notice `DS_DIST_NONE` in the plan!
EXPLAIN
SELECT s.sale_id, s.user_id, s.sale_amount, sess.session_id
FROM good_sales s
INNER JOIN good_sessions sess ON s.user_id = sess.user_id;

-- (b) Run procedures:
-- CALL prc_bad_join_sales();
-- CALL prc_good_join_sales();
