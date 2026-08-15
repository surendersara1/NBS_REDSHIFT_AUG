# Applied Redshift Masterclass: Curriculum & Implementation Guide (Files 19-50)

## 1. Context and Pedagogical Goal
This document defines the blueprint for generating 32 advanced Redshift SQL modules (`19_` through `50_`). The target audience is highly experienced software engineers (e.g., Node.js, Java, Python) who are experts in application development but are essentially "Day 0" with Redshift data warehousing. They have been assigned to optimize, rewrite, and maintain thousands of complex Redshift stored procedures. 

To bridge this gap, these modules will not merely teach SQL syntax; they will teach **Redshift architecture through SQL**. Each script will map directly to the 112 best practices outlined in the `PROCEDURE_OPTIMIZATION_BEST_PRACTICES_MASTER_FILE.md`.

## 2. Standard Pattern for Each Module
To maximize learning, every file (from 19 to 50) will follow a strict structural pattern simulating a real-world enterprise scenario:

1. **The Business Scenario**: A complex, relatable problem (e.g., "We need to process 50 million late-arriving clickstream events into a massive fact table without breaking downstream reporting").
2. **Data Generation Block**: Scripts to dynamically generate massive amounts of mock data (using `GENERATE_SERIES`, random distributions, and deliberate data skews) so that running the procedure actually triggers realistic execution plans and performance bottlenecks.
3. **The "Bad" Procedure (The App Dev Way)**: An anti-pattern implementation. We will explicitly write the code the way a Node.js developer might naturally think:
   - Row-by-row processing (`FOR r IN SELECT ... LOOP`).
   - Extensive use of variables instead of set-based logic.
   - Non-sargable functions in `WHERE` clauses (e.g., `DATE_TRUNC`).
   - Implicit data type conversions that break sort keys.
4. **The "Good" Procedure (The Redshift Way)**: The highly optimized, scalable solution.
   - Set-based massive data movement.
   - Intelligent use of staging tables with `DISTSTYLE KEY`.
   - `MERGE` statements or optimized `DELETE/INSERT` combos.
   - Window functions in place of correlated subqueries.
5. **Deep Commentary & Execution Plan Analysis**: Exhaustive inline comments detailing *why* the bad way fails at scale, and how the planner handles the good way (referencing `EXPLAIN` plans and system views).

## 3. Core Feature Coverage
Across these 32 modules, we will force the application of:
*   **Postgres/Redshift specific features**: CTEs (`WITH` clauses), Temp Tables (and when to analyze them), Identity columns.
*   **Complex Grouping & Aggregation**: `GROUPING SETS`, `ROLLUP`, Window Functions (`RANK`, `DENSE_RANK`, `LAG`, `LEAD`, `FIRST_VALUE`, `LISTAGG`).
*   **Date Operations**: Extensive use of `DATEADD`, `DATEDIFF`, `EXTRACT`, and handling timezone offsets in big data.
*   **Procedural Constructs**: Proper use of `EXCEPTION` blocks, dynamic SQL (`EXECUTE`), looping (specifically for batch chunking, not row processing), and logging to audit tables.

---

## 4. Curriculum Outline: Modules 19 - 50

### Phase 1: Mindset, Validation, & Idempotency
*Focus: Shifting from app dev state to data engineering pipelines.*
*   **19_input_validation_and_failing_early.sql**: Validating procedure parameters (dates, boundaries). Preventing full-table scans by enforcing max-date ranges.
*   **20_reproduce_measure_and_audit.sql**: Establishing a custom audit logging framework. How to benchmark runtimes within a procedure.
*   **21_idempotency_and_watermarks.sql**: The golden rule of data pipelines. Designing a load that can be safely run 10 times in a row without duplicating rows.
*   **22_transaction_blocks_and_rollbacks.sql**: Keeping the data warehouse consistent. Handling exceptions cleanly so users never see half-loaded data.

### Phase 2: The Sins of Query Writing
*Focus: How application logic destroys columnar warehouse performance.*
*   **23_set_based_vs_row_by_row.sql**: The ultimate anti-pattern. Comparing a `FOR` loop cursor approach to a single `INSERT ... SELECT`.
*   **24_sargable_predicates.sql**: Why wrapping a column in `UPPER()` or `DATE_TRUNC()` before filtering forces Redshift to scan the entire disk, and how to use half-open ranges instead.
*   **25_exists_vs_in_and_massive_lists.sql**: Handling memory blowouts when checking against a 5-million row subquery.
*   **26_cte_vs_temp_tables.sql**: When `WITH` clauses run out of memory. Moving complex intermediate steps into explicit `#TEMP` tables.

### Phase 3: Joins, Network Shuffle, & Architecture
*Focus: Data distribution across nodes.*
*   **27_exploding_joins_and_grain.sql**: Debugging cartesian products and missing join keys.
*   **28_distribution_key_alignment.sql**: Simulating network bottleneck. Showing the difference between `DS_DIST_NONE` and `DS_DIST_BOTH` in the execution plan.
*   **29_broadcast_dimensions.sql**: Using `DISTSTYLE ALL` for small lookup tables (e.g., status codes, simple mappings) to speed up massive fact joins.
*   **30_filtering_before_joins.sql**: Pushdown predicates. Why applying `WHERE` before the `JOIN` saves terabytes of network shuffle.

### Phase 4: State Management & Merging Data
*Focus: Handling updates in an append-optimized system.*
*   **31_the_merge_statement.sql**: Using Redshift's `MERGE` vs the legacy `DELETE` + `INSERT` pattern.
*   **32_late_arriving_data.sql**: Lookback windows. Updating historical records without reprocessing the entire dataset.
*   **33_staged_loads_and_stats.sql**: Why you *must* run `ANALYZE` on a heavily populated temp table before joining it to a massive base table inside a procedure.
*   **34_handling_duplicates_deterministically.sql**: Using `ROW_NUMBER()` to enforce first-writer-wins or last-writer-wins during bulk upserts.
*   **35_batching_massive_loads.sql**: When a single transaction is too big. Using loops to safely chunk a 10-billion row load by month.

### Phase 5: Deep Analytics & Feature Utilization
*Focus: Doing the heavy lifting in the DB, not in the Node.js application.*
*   **36_complex_date_math.sql**: Fiscal calendars, overlapping intervals, and generating sequence dates natively.
*   **37_multi_level_grouping.sql**: Using `GROUPING SETS` to generate sub-totals and grand-totals in one pass.
*   **38_conditional_aggregations.sql**: `SUM(CASE WHEN...)` pivoting versus slow, multi-join patterns.
*   **39_time_series_gap_filling.sql**: Using a numbers/tally table to fill in missing days for continuous time-series reporting.
*   **40_advanced_string_and_json.sql**: Parsing JSON using Redshift's `SUPER` type natively vs string manipulation.

### Phase 6: Advanced Procedure Mechanics
*Focus: Mastering PL/pgSQL within Redshift constraints.*
*   **41_dynamic_sql_in_procedures.sql**: Building and executing `EXECUTE` statements safely for generic, reusable loaders.
*   **42_exception_handling_and_context.sql**: Trapping errors, logging SQL states, and returning meaningful business errors.
*   **43_vacuum_and_maintenance_in_code.sql**: When to embed `VACUUM DELETE ONLY` within a pipeline.
*   **44_managing_locks_and_blocking.sql**: Designing procedures that don't block concurrent bi-layer queries.
*   **45_temporary_tables_lifecycle.sql**: Understanding session scope, temp table cleanup, and avoiding catalog bloat.

### Phase 7: Real-World Scenarios (The Grand Finale)
*Focus: Putting it all together into production-grade pipelines.*
*   **46_medallion_bronze_to_silver.sql**: Cleansing raw JSON landing data, type casting safely, and nullification.
*   **47_medallion_silver_to_gold_scd2.sql**: Building a Slowly Changing Dimension (Type 2) procedure. Managing effective/expiration dates natively.
*   **48_medallion_silver_to_gold_fact.sql**: Massive fact table generation with surrogate key lookups and late-arriving dimension handling.
*   **49_orchestration_and_control_tables.sql**: Building a meta-procedure that reads from a config table and drives the execution of other procedures.
*   **50_the_master_optimized_pipeline.sql**: The capstone. A heavily commented, flawless procedure that incorporates validation, set-based logic, temp tables, idempotency, error logging, and explicit commit boundaries.

---

## 5. Implementation Strategy for Authors
When generating files 19-50 based on this document, authors must ensure:
1. **Data generation comes first**: Provide the exact SQL to create the schemas and seed millions of rows.
2. **Comment density is high**: Explain the Redshift internals. For example: *"Notice how we don't use `IN (SELECT...)` here. The Node developer instinct is to do this, but Redshift will materialize that into the leader node's memory. Instead, we use `INNER JOIN`..."*
3. **Execution context**: Continually remind the reader to check `SVV_TABLE_INFO` and the `EXPLAIN` plan.
