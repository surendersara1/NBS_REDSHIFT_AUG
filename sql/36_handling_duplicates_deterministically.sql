/*
======================================================================================
MODULE 36: HANDLING DUPLICATES DETERMINISTICALLY (ROW_NUMBER & TIE-BREAKING)
======================================================================================
MAPPED BEST PRACTICES (from PROCEDURE_OPTIMIZATION_BEST_PRACTICES_MASTER_FILE.md):
- Practice 43: Avoid duplicate records on retries — use deterministic deduplication logic.
- Practice 23: Drop unneeded DISTINCT/ORDER BY — distinct on entire rows is expensive.
- Practice 47: Keep incremental logic deterministic — same input must produce identical output.
- Practice 59: Design keys intentionally — define business keys and uniqueness rules clearly.

TARGET AUDIENCE: Application Developers transitioning to Redshift
BUSINESS SCENARIO: 
We receive an uncurated stream of customer address changes in `stg_raw_user_updates`. 
Due to distributed network retries from mobile clients, the staging table contains duplicate 
updates for the same `user_id` with identical or slightly different timestamps.

THE PROBLEM:
App developers often try:
1. `SELECT DISTINCT *` (does not solve duplicates where one field like `ingested_at` differs).
2. `GROUP BY user_id` without deterministic tie-breaking (picks arbitrary values for other columns).
3. If two records have the exact same `updated_at` timestamp, non-deterministic sorting 
   flips back and forth between runs, breaking pipeline reproducibility.

THE GOAL:
1. Deduplicate using `ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY updated_at DESC, sequence_id DESC)`.
2. Implement deterministic tie-breaking (e.g. Last-Writer-Wins vs First-Writer-Wins).
3. Contrast `ROW_NUMBER()` filter performance against raw `DISTINCT` scans.
======================================================================================
*/

-- ===================================================================================
-- 1. DATA GENERATION BLOCK (Run this to set up the scenario)
-- ===================================================================================
DROP TABLE IF EXISTS stg_raw_user_updates CASCADE;
CREATE TABLE stg_raw_user_updates (
    sequence_id BIGINT NOT NULL ENCODE az64,
    user_id BIGINT NOT NULL ENCODE az64,
    email VARCHAR(100) NOT NULL ENCODE zstd,
    address VARCHAR(150) NOT NULL ENCODE zstd,
    updated_at TIMESTAMP NOT NULL ENCODE az64
)
DISTSTYLE KEY
DISTKEY (user_id);

-- Insert duplicates with identical user_id and timestamps:
INSERT INTO stg_raw_user_updates VALUES 
(1, 101, 'alice@old.com', '123 Pine St', '2026-08-15 10:00:00'),
(2, 101, 'alice@new.com', '456 Oak Ave',  '2026-08-15 10:05:00'), -- Latest update for 101
(3, 102, 'bob@test.com',  '789 Elm St',   '2026-08-15 10:00:00'),
(4, 102, 'bob@work.com',  '789 Elm St',   '2026-08-15 10:00:00'); -- Exact same timestamp as seq 3! (Tie-breaker required)

-- Add 50,000 generated records with synthetic duplicates:
INSERT INTO stg_raw_user_updates (sequence_id, user_id, email, address, updated_at)
SELECT 
    (100 + s.n) AS sequence_id,
    (s.n % 10000 + 1) AS user_id,
    'user_' || (s.n % 10000 + 1)::VARCHAR || '@example.com' AS email,
    'Street Address ' || s.n::VARCHAR AS address,
    DATEADD(minute, (s.n % 1440), '2026-08-15 00:00:00'::TIMESTAMP) AS updated_at
FROM (
    SELECT ROW_NUMBER() OVER () AS n
    FROM (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) a
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) b
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) c
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) d
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4) e
    LIMIT 50000
) s;

ANALYZE stg_raw_user_updates;

DROP TABLE IF EXISTS dim_curated_users CASCADE;
CREATE TABLE dim_curated_users (
    user_id BIGINT NOT NULL,
    email VARCHAR(100) NOT NULL,
    address VARCHAR(150) NOT NULL,
    updated_at TIMESTAMP NOT NULL,
    PRIMARY KEY (user_id)
)
DISTSTYLE KEY
DISTKEY (user_id)
COMPOUND SORTKEY (user_id);


-- ===================================================================================
-- 2. THE "BAD" PROCEDURE (The Non-Deterministic Anti-Pattern)
-- ===================================================================================
/*
WHY IT'S FLAWED:
- Uses `DISTINCT ON` (which is not supported in Redshift) or non-deterministic `MAX()` aggregations.
- If timestamps match (like User 102), ordering without a tie-breaker produces random winner 
  selection on different runs depending on slice scan order.
*/
CREATE OR REPLACE PROCEDURE prc_bad_dedup_users()
LANGUAGE plpgsql
AS $$
BEGIN
    TRUNCATE TABLE dim_curated_users;
    
    -- Incomplete / Non-deterministic query
    INSERT INTO dim_curated_users (user_id, email, address, updated_at)
    SELECT user_id, MAX(email), MAX(address), MAX(updated_at)
    FROM stg_raw_user_updates
    GROUP BY user_id;
    
    RAISE INFO 'Non-deterministic dedup finished (email and address might belong to different rows!).';
END;
$$;


-- ===================================================================================
-- 3. THE "GOOD" PROCEDURE (Deterministic Window Function Deduplication)
-- ===================================================================================
/*
WHY IT'S 100% REPRODUCIBLE & ROBUST:
1. WINDOW RANKING: `ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY updated_at DESC, sequence_id DESC)`
2. TIE-BREAKING: When `updated_at` is identical, `sequence_id DESC` provides a deterministic tie-breaker.
3. WHOLE-ROW INTEGRITY: Keeps email, address, and timestamp strictly from the winning physical row.
*/
CREATE OR REPLACE PROCEDURE prc_good_deterministic_dedup()
LANGUAGE plpgsql
AS $$
DECLARE
    v_rows_inserted BIGINT := 0;
BEGIN
    TRUNCATE TABLE dim_curated_users;

    INSERT INTO dim_curated_users (user_id, email, address, updated_at)
    WITH ranked_updates AS (
        SELECT 
            user_id,
            email,
            address,
            updated_at,
            ROW_NUMBER() OVER (
                PARTITION BY user_id 
                ORDER BY updated_at DESC, sequence_id DESC -- Deterministic tie-breaker!
            ) AS row_num
        FROM stg_raw_user_updates
    )
    SELECT user_id, email, address, updated_at
    FROM ranked_updates
    WHERE row_num = 1;

    GET DIAGNOSTICS v_rows_inserted = ROW_COUNT;
    RAISE INFO 'Deterministic deduplication complete: % unique users curated.', v_rows_inserted;

EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'prc_good_deterministic_dedup failed: %', SQLERRM;
END;
$$;


-- ===================================================================================
-- 4. USAGE, VERIFICATION & TIE-BREAKER PROOF
-- ===================================================================================

-- (a) Execute deterministic deduplication:
-- CALL prc_good_deterministic_dedup();

-- (b) Check User 101 (Latest timestamp won):
-- SELECT * FROM dim_curated_users WHERE user_id = 101;
-- Output: 101 | alice@new.com | 456 Oak Ave | 2026-08-15 10:05:00

-- (c) Check User 102 (Tie-breaker sequence_id=4 won deterministically):
-- SELECT * FROM dim_curated_users WHERE user_id = 102;
-- Output: 102 | bob@work.com | 789 Elm St | 2026-08-15 10:00:00

-- (d) Check total distinct count:
-- SELECT COUNT(1) FROM dim_curated_users; -- Exactly 10,002 unique users!

-- (e) Explain Plan Verification: Distributed Window Partitioning
EXPLAIN
WITH ranked_updates AS (
    SELECT user_id, email, address, updated_at,
           ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY updated_at DESC, sequence_id DESC) AS row_num
    FROM stg_raw_user_updates
)
SELECT user_id, email, address, updated_at
FROM ranked_updates
WHERE row_num = 1;
