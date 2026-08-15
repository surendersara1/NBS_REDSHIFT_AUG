/*
======================================================================================
MODULE 62: THE ULTIMATE REDSHIFT PROCEDURAL & PROGRAMMING LANGUAGE MASTERCLASS
======================================================================================
MAPPED BEST PRACTICES (from PROCEDURE_OPTIMIZATION_BEST_PRACTICES_MASTER_FILE.md):
- Practice 18: Input validation and failing early with RAISE EXCEPTION.
- Practice 21: Idempotency and re-runnable procedural pipelines.
- Practice 22: Transaction control (COMMIT / ROLLBACK) inside procedures.
- Practice 27, 74: Set-based processing vs procedural loop anti-patterns.
- Practice 41, 77: Safe Dynamic SQL (EXECUTE, QUOTE_IDENT, QUOTE_LITERAL) vs SQL injection.
- Practice 42, 73: Exception handling, SQLERRM, and diagnostic logging (GET DIAGNOSTICS).
- Practice 75: Managing cursor limits (1 concurrent cursor estate-wide).
- Practice 76: Variable scoping, %TYPE anchoring, and clean memory teardown.

TARGET AUDIENCE: Database Engineers, Application Developers (Java, Python, C#), Data Architects
BUSINESS PURPOSE: 
Teach developers transitioning from Oracle PL/SQL, SQL Server T-SQL, and PostgreSQL the full 
spectrum of Amazon Redshift PL/pgSQL procedural language features, engine limits, and production patterns.

======================================================================================
THE TOP 30 REDSHIFT PROGRAMMING & PROCEDURAL FEATURES AT A GLANCE
======================================================================================
┌─────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│  MODULE 1: VARIABLES, TYPES & ASSIGNMENT (Features 1 - 4)                                                   │
│    1. Variable Declaration & Default Initialization (`DECLARE`, `:=`, `DEFAULT`)                            │
│    2. Column Type Anchoring (`%TYPE`)                                                                        │
│    3. Table Row Type Anchoring (`%ROWTYPE`)                                                                  │
│    4. Unstructured Composite Record Types (`RECORD`)                                                        │
├─────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│  MODULE 2: CONDITIONAL BRANCHING & LOGIC (Features 5 - 6)                                                   │
│    5. Multi-Branch Conditional Evaluation (`IF ... THEN ... ELSIF ... ELSE ... END IF;`)                    │
│    6. Procedural Switch-Case Logic (`CASE ... WHEN ... THEN ... ELSE ... END CASE;`)                         │
├─────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│  MODULE 3: LOOPS, CURSORS & ITERATION CONTROL (Features 7 - 12)                                             │
│    7. Unconditional Loop with Exit Guard (`LOOP ... EXIT WHEN ... END LOOP;`)                               │
│    8. Conditional While Loops for Macro-Batching (`WHILE condition LOOP ... END LOOP;`)                      │
│    9. Numeric Integer Range Loops (`FOR i IN 1..10 LOOP ... END LOOP;`)                                     │
│   10. Reverse Integer Range Loops (`FOR i IN REVERSE 10..1 LOOP ... END LOOP;`)                             │
│   11. Query Result Cursor Loops (`FOR rec IN (SELECT ...) LOOP ... END LOOP;`)                              │
│   12. Loop Flow Control Guards (`CONTINUE`, `CONTINUE WHEN`, and Nested Loop Labels)                        │
├─────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│  MODULE 4: DYNAMIC SQL, QUERY INGESTION & DIAGNOSTICS (Features 13 - 17)                                    │
│    13. Dynamic DDL/DML Execution (`EXECUTE ...;`)                                                           │
│    14. SQL Injection Sanitization (`QUOTE_IDENT`, `QUOTE_LITERAL`, and `FORMAT`)                            │
│    15. Single-Row Query Ingestion (`SELECT ... INTO ... FROM ...`)                                          │
│    16. Strict Query Assertion (`SELECT ... INTO STRICT ... FROM ...`)                                       │
│    17. Execution Diagnostics (`GET DIAGNOSTICS v_rows = ROW_COUNT;`)                                        │
├─────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│  MODULE 5: TRANSACTIONS, AUDITING & ERROR HANDLING (Features 18 - 22)                                       │
│    18. Explicit Transaction Management (`COMMIT;` & `ROLLBACK;` inside Procedures)                          │
│    19. Multi-Tier Messaging & Auditing (`RAISE INFO`, `RAISE NOTICE`, `RAISE WARNING`)                      │
│    20. Custom Exception Raising (`RAISE EXCEPTION` with String Interpolation)                                │
│    21. Structured Block Exception Trapping (`BEGIN ... EXCEPTION WHEN OTHERS THEN ... END;`)                │
│    22. Forensic Error Metadata Capture (`SQLERRM`, `SQLSTATE`)                                              │
├─────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│  MODULE 6: ADVANCED PROCEDURES, SECURITY CONTEXTS & UDFs (Features 23 - 30)                                 │
│    23. IN, OUT, and INOUT Parameter Signatures                                                              │
│    24. Dynamic Result Set Returns via Refcursors (`INOUT REFCURSOR`)                                        │
│    25. Security Privilege Execution Contexts (`SECURITY INVOKER` vs `SECURITY DEFINER`)                    │
│    26. Stored Procedure Nesting and Call Chaining                                                           │
│    27. Session-Scoped Variables & Context Settings (`SET session.key` & `current_setting()`)                │
│    28. Stored Procedure Temporary Table Lifecycles (`#temp_table`, `ON COMMIT DROP`)                        │
│    29. SQL Scalar User-Defined Functions (`CREATE FUNCTION ... LANGUAGE sql`)                              │
│    30. Python Vectorized User-Defined Functions (`CREATE FUNCTION ... LANGUAGE plpythonu`)                  │
└─────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
======================================================================================
*/

-- ===================================================================================
-- SETUP: SAMPLE REFERENCE TABLES FOR DEMONSTRATIONS
-- ===================================================================================
DROP TABLE IF EXISTS dev_customer_orders CASCADE;
CREATE TABLE dev_customer_orders (
    order_id BIGINT IDENTITY(1,1) NOT NULL,
    customer_id BIGINT NOT NULL,
    order_status VARCHAR(20) NOT NULL,
    order_amount NUMERIC(12,2) NOT NULL,
    order_date DATE NOT NULL,
    PRIMARY KEY (order_id)
)
DISTSTYLE KEY
DISTKEY (customer_id)
SORTKEY (order_date);

-- Seed with 1,000 baseline records:
INSERT INTO dev_customer_orders (customer_id, order_status, order_amount, order_date)
SELECT 
    (s.n % 100 + 1),
    CASE WHEN s.n % 3 = 0 THEN 'COMPLETED' WHEN s.n % 3 = 1 THEN 'PENDING' ELSE 'CANCELLED' END,
    (25.50 + (s.n % 500)),
    DATEADD(day, -(s.n % 60), '2026-08-15'::DATE)
FROM (
    SELECT ROW_NUMBER() OVER () as n
    FROM (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) a,
         (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) b,
         (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) c
    LIMIT 1000
) s;

ANALYZE dev_customer_orders;


-- ===================================================================================
-- MODULE 1: VARIABLES, TYPES & ASSIGNMENT (FEATURES 1 - 4)
-- ===================================================================================

CREATE OR REPLACE PROCEDURE prc_demo_module1_variables()
LANGUAGE plpgsql
AS $$
DECLARE
    -- Feature 1: Variable Declaration with Types, Defaults, and Assignment
    v_user_name     VARCHAR(50)  := 'Surender';
    v_batch_size    INT          DEFAULT 5000;
    v_is_active     BOOLEAN      := TRUE;
    v_created_ts    TIMESTAMP    DEFAULT SYSDATE;

    -- Feature 2: Column Type Anchoring (%TYPE)
    -- Inherits datatype directly from the underlying table schema dynamically!
    v_order_amount  dev_customer_orders.order_amount%TYPE;
    v_cust_id       dev_customer_orders.customer_id%TYPE;

    -- Feature 3: Table Row Type Anchoring (%ROWTYPE)
    -- Encapsulates an entire table row structure into a single composite variable!
    v_order_row     dev_customer_orders%ROWTYPE;

    -- Feature 4: Unstructured Composite Record Type (RECORD)
    -- Dynamic record type capable of binding to arbitrary projection schemas!
    v_generic_rec   RECORD;
BEGIN
    RAISE INFO '--- MODULE 1: VARIABLES & TYPES ---';
    RAISE INFO 'Feature 1: User = %, Batch = %, Active = %, TS = %', 
        v_user_name, v_batch_size, v_is_active, v_created_ts;

    -- Assignment using %TYPE:
    v_order_amount := 1250.75;
    v_cust_id := 101;
    RAISE INFO 'Feature 2 (%%TYPE): CustID = %, Amount = %', v_cust_id, v_order_amount;

    -- Querying into %ROWTYPE:
    SELECT * INTO v_order_row 
    FROM dev_customer_orders 
    WHERE order_status = 'COMPLETED' 
    LIMIT 1;
    RAISE INFO 'Feature 3 (%%ROWTYPE): Order ID = %, Amount = %, Status = %', 
        v_order_row.order_id, v_order_row.order_amount, v_order_row.order_status;

    -- Querying arbitrary joined fields into RECORD:
    SELECT order_id, order_amount * 1.05 AS amount_with_tax
    INTO v_generic_rec
    FROM dev_customer_orders
    LIMIT 1;
    RAISE INFO 'Feature 4 (RECORD): Order ID = %, Taxed Amount = %', 
        v_generic_rec.order_id, v_generic_rec.amount_with_tax;
END;
$$;


-- ===================================================================================
-- MODULE 2: CONDITIONAL BRANCHING & LOGICAL CONTROL (FEATURES 5 - 6)
-- ===================================================================================

CREATE OR REPLACE PROCEDURE prc_demo_module2_conditionals(p_sla_hours INT, p_region VARCHAR(10))
LANGUAGE plpgsql
AS $$
DECLARE
    v_sla_tier VARCHAR(20);
    v_region_cluster VARCHAR(30);
BEGIN
    RAISE INFO '--- MODULE 2: CONDITIONAL BRANCHING ---';

    -- Feature 5: Multi-Branch Conditional Logic (IF ... ELSIF ... ELSE)
    IF p_sla_hours <= 1 THEN
        v_sla_tier := 'CRITICAL_URGENT';
    ELSIF p_sla_hours BETWEEN 2 AND 4 THEN
        v_sla_tier := 'HIGH_PRIORITY';
    ELSIF p_sla_hours BETWEEN 5 AND 24 THEN
        v_sla_tier := 'STANDARD_BUSINESS';
    ELSE
        v_sla_tier := 'BATCH_LOW';
    END IF;

    RAISE INFO 'Feature 5 (IF/ELSIF): SLA Hours % -> Assigned Tier %', p_sla_hours, v_sla_tier;

    -- Feature 6: Procedural Switch-Case Logic (CASE ... WHEN ... THEN ... END CASE)
    CASE UPPER(p_region)
        WHEN 'US' THEN
            v_region_cluster := 'redshift-cluster-us-east-1';
        WHEN 'EU' THEN
            v_region_cluster := 'redshift-cluster-eu-central-1';
        WHEN 'APAC' THEN
            v_region_cluster := 'redshift-cluster-ap-southeast-1';
        ELSE
            v_region_cluster := 'redshift-cluster-global-fallback';
    END CASE;

    RAISE INFO 'Feature 6 (CASE): Region % -> Routed to %', p_region, v_region_cluster;
END;
$$;


-- ===================================================================================
-- MODULE 3: LOOPS, CURSORS & ITERATION CONTROL (FEATURES 7 - 12)
-- ===================================================================================

CREATE OR REPLACE PROCEDURE prc_demo_module3_loops()
LANGUAGE plpgsql
AS $$
DECLARE
    v_counter INT := 0;
    v_while_val INT := 1;
    v_rec RECORD;
BEGIN
    RAISE INFO '--- MODULE 3: LOOPS & CONTROL FLOW ---';

    -- Feature 7: Unconditional Loop with EXIT WHEN guard
    LOOP
        v_counter := v_counter + 1;
        EXIT WHEN v_counter >= 3;
    END LOOP;
    RAISE INFO 'Feature 7 (LOOP..EXIT WHEN): Counter reached %', v_counter;

    -- Feature 8: While Loop (Ideal for date-range macro-batching)
    WHILE v_while_val < 4 LOOP
        RAISE INFO 'Feature 8 (WHILE): Current while value = %', v_while_val;
        v_while_val := v_while_val + 1;
    END LOOP;

    -- Feature 9: Numeric Range FOR Loop (Forward 1 to 3)
    FOR i IN 1..3 LOOP
        RAISE INFO 'Feature 9 (FOR 1..3): Forward iteration %', i;
    END LOOP;

    -- Feature 10: Numeric Range FOR Loop (Reverse 3 down to 1)
    FOR i IN REVERSE 3..1 LOOP
        RAISE INFO 'Feature 10 (FOR REVERSE): Countdown iteration %', i;
    END LOOP;

    -- Feature 11: Cursor Query Loop (FOR rec IN SELECT ...)
    -- CAUTION: Opens an implicit cursor. Only 1 concurrent cursor is permitted per session!
    FOR v_rec IN (
        SELECT order_status, COUNT(1) AS order_cnt 
        FROM dev_customer_orders 
        GROUP BY order_status 
        ORDER BY order_status
    ) LOOP
        RAISE INFO 'Feature 11 (CURSOR FOR): Status % has % orders', v_rec.order_status, v_rec.order_cnt;
    END LOOP;

    -- Feature 12: Loop Flow Control with CONTINUE and Loop Labels
    <<outer_label>>
    FOR i IN 1..5 LOOP
        IF i = 2 THEN
            CONTINUE; -- Skips rest of body for iteration 2
        END IF;
        
        IF i = 4 THEN
            EXIT outer_label; -- Terminates the labeled loop entirely
        END IF;
        
        RAISE INFO 'Feature 12 (CONTINUE/LABEL): Processed item %', i;
    END LOOP outer_label;
END;
$$;


-- ===================================================================================
-- MODULE 4: DYNAMIC SQL, QUERY INGESTION & DIAGNOSTICS (FEATURES 13 - 17)
-- ===================================================================================

CREATE OR REPLACE PROCEDURE prc_demo_module4_dynamic_sql(p_schema VARCHAR(50), p_status_filter VARCHAR(20))
LANGUAGE plpgsql
AS $$
DECLARE
    v_sql          VARCHAR(MAX);
    v_safe_schema  VARCHAR(100);
    v_safe_status  VARCHAR(100);
    v_total_amount NUMERIC(14,2);
    v_strict_id    BIGINT;
    v_rows_scanned BIGINT := 0;
BEGIN
    RAISE INFO '--- MODULE 4: DYNAMIC SQL & DIAGNOSTICS ---';

    -- Feature 14: SQL Injection Prevention (QUOTE_IDENT & QUOTE_LITERAL)
    v_safe_schema := QUOTE_IDENT(p_schema);
    v_safe_status := QUOTE_LITERAL(p_status_filter);

    -- Feature 13: Dynamic SQL Execution (EXECUTE)
    v_sql := 'CREATE TEMP TABLE #temp_dynamic_summary ON COMMIT DROP AS ' ||
             'SELECT order_status, SUM(order_amount) as total_amt ' ||
             'FROM ' || v_safe_schema || '.dev_customer_orders ' ||
             'WHERE order_status = ' || v_safe_status || ' ' ||
             'GROUP BY order_status;';
    
    RAISE INFO 'Executing Dynamic SQL: %', v_sql;
    EXECUTE v_sql;

    -- Feature 15: Single-Row Query Ingestion (SELECT ... INTO)
    SELECT total_amt INTO v_total_amount 
    FROM #temp_dynamic_summary;
    RAISE INFO 'Feature 15 (SELECT INTO): Filtered Status % Total Amount = %', p_status_filter, v_total_amount;

    -- Feature 16: Strict Query Assertion (SELECT ... INTO STRICT)
    -- Throws NO_DATA_FOUND if 0 rows, or TOO_MANY_ROWS if > 1 row matches!
    SELECT order_id INTO STRICT v_strict_id
    FROM dev_customer_orders
    WHERE order_id = 1;
    RAISE INFO 'Feature 16 (SELECT INTO STRICT): Verified single unique order ID = %', v_strict_id;

    -- Feature 17: Execution Diagnostics (GET DIAGNOSTICS ROW_COUNT)
    GET DIAGNOSTICS v_rows_scanned = ROW_COUNT;
    RAISE INFO 'Feature 17 (GET DIAGNOSTICS): Last SQL statement affected % rows', v_rows_scanned;
END;
$$;


-- ===================================================================================
-- MODULE 5: TRANSACTIONS, LOGGING & ERROR HANDLING (FEATURES 18 - 22)
-- ===================================================================================

CREATE OR REPLACE PROCEDURE prc_demo_module5_transactions_and_errors(p_simulate_error BOOLEAN)
LANGUAGE plpgsql
AS $$
DECLARE
    v_err_msg   VARCHAR(MAX);
    v_err_state VARCHAR(50);
BEGIN
    RAISE INFO '--- MODULE 5: TRANSACTIONS & ERROR TRAPPING ---';

    -- Feature 19: Multi-Tier Logging
    RAISE INFO    'Feature 19A: [INFO] Pipeline step initialized successfully.';
    RAISE NOTICE  'Feature 19B: [NOTICE] Informational notice dispatched.';
    RAISE WARNING 'Feature 19C: [WARNING] High memory watermark warning.';

    -- Feature 18: Explicit Transaction Commit inside Stored Procedure
    -- Redshift stored procedures support autonomous COMMIT to release lock queues!
    COMMIT;
    RAISE INFO 'Feature 18: [COMMIT] Stored procedure transaction checkpoint committed.';

    -- Feature 21: Structured Exception Block (BEGIN ... EXCEPTION WHEN OTHERS)
    BEGIN
        IF p_simulate_error THEN
            -- Feature 20: Raising Custom Exceptions with Parameter Interpolation
            RAISE EXCEPTION 'Simulated business rule validation failure for code %', 404;
        END IF;

        RAISE INFO 'Transaction block completed with zero errors.';

    EXCEPTION WHEN OTHERS THEN
        -- Feature 22: Forensic Error Capture (SQLERRM & SQLSTATE)
        v_err_msg := SQLERRM;
        v_err_state := SQLSTATE;
        RAISE INFO 'Feature 21 & 22 (EXCEPTION TRAP): Caught Error [%]: %', v_err_state, v_err_msg;
        
        -- Safe rollback / graceful recovery
        ROLLBACK;
        RAISE INFO 'Feature 18: [ROLLBACK] Transaction rolled back safely.';
    END;
END;
$$;


-- ===================================================================================
-- MODULE 6: ADVANCED SIGNATURES, SECURITY, CONTEXTS & UDFs (FEATURES 23 - 30)
-- ===================================================================================

-- Feature 23: IN, OUT, and INOUT Parameter Signatures
CREATE OR REPLACE PROCEDURE prc_demo_module6_signatures(
    IN    p_cust_id     BIGINT,
    OUT   p_order_count INT,
    INOUT p_discount    NUMERIC(5,2)
)
LANGUAGE plpgsql
AS $$
BEGIN
    -- Populate OUT parameter:
    SELECT COUNT(1) INTO p_order_count
    FROM dev_customer_orders
    WHERE customer_id = p_cust_id;

    -- Modify INOUT parameter:
    IF p_order_count > 5 THEN
        p_discount := p_discount + 0.15; -- Add 15% VIP discount
    END IF;

    RAISE INFO 'Feature 23 (IN/OUT/INOUT): Cust % -> Orders = %, Final Discount = %', 
        p_cust_id, p_order_count, p_discount;
END;
$$;

-- Feature 24: Returning Dynamic Result Sets via Refcursors
CREATE OR REPLACE PROCEDURE prc_demo_module6_refcursor(p_rs INOUT REFCURSOR)
LANGUAGE plpgsql
AS $$
BEGIN
    -- Open dynamic cursor to return tabular results to JDBC / Python / BI clients:
    OPEN p_rs FOR 
        SELECT order_status, COUNT(1) AS status_count, SUM(order_amount) AS total_revenue
        FROM dev_customer_orders
        GROUP BY order_status;
    RAISE INFO 'Feature 24 (REFCURSOR): Dynamic cursor opened for caller.';
END;
$$;

-- Feature 25: Procedure Security Execution Contexts (SECURITY INVOKER vs SECURITY DEFINER)
CREATE OR REPLACE PROCEDURE prc_demo_module6_security_context()
LANGUAGE plpgsql
SECURITY DEFINER -- Executes with the elevated permissions of the PROCEDURE OWNER
AS $$
BEGIN
    RAISE INFO 'Feature 25 (SECURITY DEFINER): Executing with elevated owner privileges.';
END;
$$;

-- Feature 26: Stored Procedure Nesting and Call Chaining
CREATE OR REPLACE PROCEDURE prc_demo_module6_orchestrator()
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE INFO 'Feature 26 (ORCHESTRATION): Calling child stored procedures in pipeline sequence...';
    CALL prc_demo_module1_variables();
    CALL prc_demo_module2_conditionals(2, 'US');
    RAISE INFO 'Feature 26 (ORCHESTRATION): All child procedures completed.';
END;
$$;

-- Feature 29: SQL Scalar User-Defined Function (SQL UDF)
CREATE OR REPLACE FUNCTION fn_calculate_sales_tax(p_amount NUMERIC(12,2), p_rate NUMERIC(4,3))
RETURNS NUMERIC(12,2)
STABLE
AS $$
    SELECT ROUND(p_amount * (1.0 + p_rate), 2);
$$ LANGUAGE sql;

-- Feature 30: Python User-Defined Function (Python UDF for complex regex/parsing)
-- CREATE OR REPLACE FUNCTION py_extract_domain(p_url VARCHAR(500))
-- RETURNS VARCHAR(100)
-- IMMUTABLE
-- AS $$
--     import urllib.parse
--     if not p_url:
--         return None
--     parsed = urllib.parse.urlparse(p_url)
--     return parsed.netloc or parsed.path.split('/')[0]
-- $$ LANGUAGE plpythonu;


-- ===================================================================================
-- SECTION 7: EXECUTABLE VERIFICATION OF ALL 30 FEATURES
-- ===================================================================================

-- (1) Test Module 1: Variables, %TYPE, %ROWTYPE, RECORD
CALL prc_demo_module1_variables();

-- (2) Test Module 2: IF/ELSIF/ELSE and CASE statements
CALL prc_demo_module2_conditionals(3, 'EU');

-- (3) Test Module 3: Loops, WHILE, FOR 1..3, FOR REVERSE, Cursor FOR, CONTINUE
CALL prc_demo_module3_loops();

-- (4) Test Module 4: Dynamic SQL, QUOTE_IDENT, SELECT INTO, STRICT, GET DIAGNOSTICS
CALL prc_demo_module4_dynamic_sql('public', 'COMPLETED');

-- (5) Test Module 5: Transactions, COMMIT, ROLLBACK, RAISE, EXCEPTION Trapping
CALL prc_demo_module5_transactions_and_errors(TRUE);

-- (6) Test Module 6: Parameter signatures (IN, OUT, INOUT)
-- In Redshift, call with literal for INOUT:
-- CALL prc_demo_module6_signatures(1, NULL, 0.05);

-- (7) Test Module 6: Master Orchestration Chaining
CALL prc_demo_module6_orchestrator();

-- (8) Test Feature 27 & 28: Session context & Temp table lifecycle
SET session.current_pipeline_batch_id = 'BATCH_20260815_01';
SELECT current_setting('session.current_pipeline_batch_id') AS active_batch;

-- (9) Test Feature 29: SQL Scalar UDF
SELECT order_id, order_amount, fn_calculate_sales_tax(order_amount, 0.085) AS total_with_tax
FROM dev_customer_orders
LIMIT 5;
