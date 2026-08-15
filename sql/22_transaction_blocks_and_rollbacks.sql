/*
======================================================================================
MODULE 22: TRANSACTION BLOCKS AND ROLLBACKS
======================================================================================
MAPPED BEST PRACTICES (from PROCEDURE_OPTIMIZATION_BEST_PRACTICES_MASTER_FILE.md):
- Practice 80: Use transactions to keep target data consistent when multiple statements form one logical load.
- Practice 81: Keep transactions reasonably short — long transactions increase lock pressure.
- Practice 82: Design every operation to be retry-safe — a failed job should be safely restartable.
- Practice 83: Avoid partial target loads — users should never see half-completed Gold data.
- Practice 86: Handle exceptions intentionally — return useful errors rather than swallowing failures.
- Practice 87: Preserve failure context in errors — include procedure name and batch info.

TARGET AUDIENCE: Application Developers transitioning to Redshift
BUSINESS SCENARIO: 
We are updating sensitive HR compensation data in `dim_employee` and recording 
an immutable audit event in `employee_salary_history`. 
This is a multi-statement business transaction that must satisfy ACID semantics.

THE PROBLEM:
In an application framework (Node.js/Spring Boot), developers sometimes execute 
multiple queries in autocommit mode without wrapping them in an atomic transaction. 
If Step 1 (updating salary) succeeds, but Step 2 (logging salary history) crashes due to a 
divide-by-zero or lock timeout, the database is left in a corrupted, half-loaded state. 
Salaries changed, but there is zero audit trail.

THE GOAL:
1. Demonstrate how Redshift handles PL/pgSQL transaction blocks and atomicity.
2. Teach the rule of Redshift transactions: **No subtransactions / SAVEPOINTs exist in procedures**.
3. Catch failures, preserve error context with `SQLSTATE`/`SQLERRM`, and cleanly rollback.
======================================================================================
*/

-- ===================================================================================
-- 1. DATA GENERATION BLOCK (Run this to set up the scenario)
-- ===================================================================================
DROP TABLE IF EXISTS dim_employee CASCADE;
CREATE TABLE dim_employee (
    emp_id INT NOT NULL ENCODE az64,
    emp_name VARCHAR(100) NOT NULL ENCODE zstd,
    department VARCHAR(50) NOT NULL ENCODE bytedict,
    salary DECIMAL(12,2) NOT NULL ENCODE az64,
    updated_at TIMESTAMP NOT NULL ENCODE az64
)
DISTSTYLE KEY
DISTKEY (emp_id)
COMPOUND SORTKEY (emp_id);

INSERT INTO dim_employee VALUES 
(1, 'Alice Smith', 'Engineering', 140000.00, '2026-01-01 00:00:00'),
(2, 'Bob Jones', 'Engineering', 125000.00, '2026-01-01 00:00:00'),
(3, 'Charlie Brown', 'Marketing', 95000.00, '2026-01-01 00:00:00');

DROP TABLE IF EXISTS employee_salary_history CASCADE;
CREATE TABLE employee_salary_history (
    history_id BIGINT IDENTITY(1,1) NOT NULL ENCODE az64,
    emp_id INT NOT NULL ENCODE az64,
    old_salary DECIMAL(12,2) NOT NULL ENCODE az64,
    new_salary DECIMAL(12,2) NOT NULL ENCODE az64,
    change_pct DECIMAL(5,2) NOT NULL ENCODE az64,
    changed_at TIMESTAMP NOT NULL ENCODE az64
)
DISTSTYLE KEY
DISTKEY (emp_id)
COMPOUND SORTKEY (emp_id, changed_at);

DROP TABLE IF EXISTS stg_salary_updates CASCADE;
CREATE TABLE stg_salary_updates (
    emp_id INT NOT NULL,
    new_salary DECIMAL(12,2) NOT NULL
)
DISTSTYLE KEY
DISTKEY (emp_id);

-- Incoming pay adjustments:
INSERT INTO stg_salary_updates VALUES 
(1, 155000.00),
(2, 138000.00);


-- ===================================================================================
-- 2. THE "BAD" PROCEDURE (The App Dev Way / Anti-Pattern)
-- ===================================================================================
/*
WHY IT'S BAD:
- Swallows exceptions with empty or non-propagating error handlers.
- In manual multi-statement client scripts without BEGIN/COMMIT, Step 1 persists while Step 2 dies.
- Leaves tables out of sync, violating Practice 83 (no partial target loads).
*/
CREATE OR REPLACE PROCEDURE prc_bad_update_salaries()
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE INFO 'Starting un-guarded salary update...';

    -- Step 1: Update current salary in dim_employee
    UPDATE dim_employee
    SET salary = s.new_salary,
        updated_at = SYSDATE
    FROM stg_salary_updates s
    WHERE dim_employee.emp_id = s.emp_id;

    -- Step 2: Attempt history insert with an intentional runtime error (divide by zero)
    -- Simulating a dirty data crash (e.g. division by 0 in change_pct)
    INSERT INTO employee_salary_history (emp_id, old_salary, new_salary, change_pct, changed_at)
    SELECT 
        e.emp_id, 
        e.salary, 
        s.new_salary,
        ((s.new_salary - e.salary) / 0)::DECIMAL(5,2), -- <--- RUNTIME CRASH!
        SYSDATE
    FROM dim_employee e
    JOIN stg_salary_updates s ON e.emp_id = s.emp_id;

    RAISE INFO 'Salary update complete.';
END;
$$;


-- ===================================================================================
-- 3. THE "GOOD" PROCEDURE (The Redshift MPP Way / Best Practice)
-- ===================================================================================
/*
WHY IT'S GOOD:
- Executes within an atomic transaction boundary.
- Uses `NULLIF` / safe numeric arithmetic to prevent zero-division crashes.
- Catches unexpected errors, records the procedure failure context, and re-raises
  the exception so the entire transaction automatically rolls back.
- Guarantees that users never see partial salary changes without history.
*/
CREATE OR REPLACE PROCEDURE prc_good_update_salaries(p_batch_id VARCHAR(50))
LANGUAGE plpgsql
AS $$
DECLARE
    v_proc_name     VARCHAR(100) := 'prc_good_update_salaries';
    v_rows_updated  BIGINT := 0;
    v_rows_logged   BIGINT := 0;
    v_err_msg       VARCHAR(1000);
BEGIN
    RAISE INFO 'Starting atomic compensation pipeline for batch %...', p_batch_id;

    -- Step 1: Log history BEFORE or alongside the update using existing salary
    INSERT INTO employee_salary_history (emp_id, old_salary, new_salary, change_pct, changed_at)
    SELECT 
        e.emp_id, 
        e.salary, 
        s.new_salary,
        ROUND(((s.new_salary - e.salary) / NULLIF(e.salary, 0)) * 100, 2),
        SYSDATE
    FROM dim_employee e
    INNER JOIN stg_salary_updates s ON e.emp_id = s.emp_id;
    GET DIAGNOSTICS v_rows_logged = ROW_COUNT;

    -- Step 2: Update the dimension table
    UPDATE dim_employee
    SET salary = s.new_salary,
        updated_at = SYSDATE
    FROM stg_salary_updates s
    WHERE dim_employee.emp_id = s.emp_id;
    GET DIAGNOSTICS v_rows_updated = ROW_COUNT;

    -- Step 3: Consistency assertion (Practice 5, 85)
    IF v_rows_logged != v_rows_updated THEN
        RAISE EXCEPTION 'Consistency Failure: Logged % history rows but updated % employee rows.',
            v_rows_logged, v_rows_updated;
    END IF;

    RAISE INFO 'Salary update succeeded atomically: % updated, % logged.', 
        v_rows_updated, v_rows_logged;

EXCEPTION WHEN OTHERS THEN
    v_err_msg := SUBSTRING(SQLERRM, 1, 990);
    -- Re-raise immediately: Redshift automatically rolls back the entire procedure execution!
    RAISE EXCEPTION '[FATAL %] Batch % aborted: %', v_proc_name, p_batch_id, v_err_msg;
END;
$$;


-- ===================================================================================
-- 4. USAGE, VERIFICATION & TRANSACTION ROLLBACK PROOF
-- ===================================================================================

-- (a) Verify initial state:
-- SELECT * FROM dim_employee ORDER BY emp_id;

-- (b) Test Bad Procedure (Fails at Step 2):
-- CALL prc_bad_update_salaries(); 
-- --> Throws ERROR: division by zero. 
-- Because this was executed inside a procedure call, Redshift aborts the transaction,
-- proving that dim_employee is NOT partially modified.

-- (c) Test Good Procedure (Atomic success):
-- CALL prc_good_update_salaries('COMP_REVIEW_2026_Q3');

-- (d) Verify synchronized final state:
-- SELECT * FROM dim_employee ORDER BY emp_id;
-- SELECT * FROM employee_salary_history ORDER BY emp_id, changed_at DESC;

-- (e) Explain Plan and Catalog Transaction Verification:
EXPLAIN
UPDATE dim_employee
SET salary = s.new_salary, updated_at = SYSDATE
FROM stg_salary_updates s
WHERE dim_employee.emp_id = s.emp_id;

-- Inspect transaction commit status in query history:
SELECT query_id, transaction_id, status, elapsed_time, error_message
FROM sys_query_history
WHERE query_text LIKE '%prc_good_update_salaries%'
ORDER BY start_time DESC LIMIT 5;
