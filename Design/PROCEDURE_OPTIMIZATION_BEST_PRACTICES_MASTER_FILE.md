# Master Data Engineering & Redshift Best Practices

Consolidated from the four files in this folder:
`data_engineering_stored_procedure_50_best_practices.md`,
`DE_BEST_PRACTICES.md`, `redshift_best_practices.md`, and
`redshift-optimization-best-practices.md`.

Overlapping practices across the source files have been merged into a
single entry; nothing unique has been dropped. Result: **112 practices**
across 15 themed sections.

> **The two rules above all:**
> 1. **Measure before you change anything** — never optimize by guessing.
> 2. **Correctness is the gate** — output must be identical after; a faster wrong answer is still wrong.

---

## A. Method & Mindset — do this first, every time

1. **Reproduce reliably** — get a repeatable case with fixed inputs before touching anything.
2. **Measure before you change anything** — capture baseline runtime and the query plan (`EXPLAIN`).
3. **Understand before changing** — map the inputs, steps, and outputs; comment the sections.
4. **Chase the 80/20** — fix only the 2–3 slowest steps; optimizing cheap steps yields near-zero gain.
5. **Correctness is the gate** — diff output row counts/checksums before vs. after every change.
6. **Change one thing at a time** — edit, re-measure, keep or revert; batched changes hide what helped or broke.
7. **Fix approach before micro-tuning syntax** — 10x wins come from rethinking logic/data flow, not tweaks.
8. **Keep the original safe** — copy into version control before editing; never touch the source directly.
9. **Leave code more readable than you found it** — someone has to maintain this.
10. **Measure continuously, not just once** — use execution plans, scan volume, runtime, and row counts to target real bottlenecks, not assumed ones.

## B. Input Validation (Stored Procedures)

11. **Validate required parameters** — reject `NULL` for required inputs such as date ranges.
12. **Validate date ranges** — ensure `p_from_date <= p_to_date`.
13. **Limit excessively large ranges** — prevent accidental full-history reprocessing when only incremental loads are expected.
14. **Validate parameter data types** — use appropriate `DATE`, `TIMESTAMP`, and numeric types.
15. **Fail early** — validate before expensive scans, deletes, joins, or inserts.

## C. Query Writing & Filtering

16. **Never `SELECT *`** — list only the columns you need; columnar warehouses charge per column read.
17. **Filter as early as possible** — push `WHERE` predicates before joins/aggregations so less data flows downstream.
18. **Never wrap filtered/join/sort-key columns in functions or casts** (`::DATE`, `UPPER()`, `DATE_TRUNC()`) — this disables zone-map pruning and forces full scans.
19. **Use half-open timestamp ranges** (`>= start AND < end`) instead of `BETWEEN` with casts, to avoid boundary errors and keep pruning intact.
20. **Avoid recomputing the same expression repeatedly** — materialize it once into a temp/staging table and reuse it.
21. **Match join/filter column data types exactly** — implicit casts disable efficient plans and defeat sort keys.
22. **Use `EXISTS`/`NOT EXISTS` instead of `IN`/`NOT IN`** for large subqueries — `IN` can materialize a huge in-memory list.
23. **Drop unneeded `DISTINCT`/`ORDER BY`** — sorting and dedup are expensive and often accidental.
24. **Use `UNION ALL` instead of `UNION`** unless de-duplication is genuinely required.
25. **Replace correlated subqueries with joins or window functions.**
26. **Break complex multi-join, multi-aggregation queries into staged temp tables** with explicit dist/sort keys.
27. **Set-based, not row-by-row** — replace loops/cursors with one SQL statement over all rows; row-by-row is often 100–1000x slower.

## D. Joins

28. **Confirm join keys are unique at the expected grain** — avoid exploding joins that blow up row counts.
29. **Align distribution keys across frequently-joined tables** to avoid redistribution.
30. **Filter both sides of a join before joining, not after** — reduces rows shuffled.
31. **Use `ALL`/broadcast distribution for small lookup/dimension tables** (roughly a few million rows or fewer).
32. **Watch for nested loop joins in `EXPLAIN`** — usually signals a missing or poor join predicate.
33. **Avoid Cartesian products and cross joins** — check `EXPLAIN` for warning signs.
34. **Check `EXPLAIN` for `DS_DIST_ALL_INNER` / `DS_DIST_BOTH` / `DS_BCAST_INNER`** — these signal costly data movement.

## E. Execution Plans & Diagnostics

35. **Read the `EXPLAIN` plan before and after every change** — it shows exactly where time and cost go.
36. **Watch for disk spill** — if a step spills to disk, shrink the data or split the step; spilling is an orders-of-magnitude slowdown.
37. **Check `STL_ALERT_EVENT_LOG` for planner-flagged issues** — missing stats, broadcast/nested-loop joins, and other red flags surface here first.
38. **Benchmark actual runtime via `SYS_QUERY_HISTORY`/`SVL_QUERY_METRICS`** rather than trusting `EXPLAIN` cost estimates alone; separate queue wait time from execution time — they need different fixes.

## F. Incremental Loading & Idempotency

39. **Prefer incremental processing over full-history rebuilds** — process only new or changed data.
40. **Use a reliable watermark** — track the last successfully processed timestamp, ID, or batch.
41. **Handle late-arriving data** with a deliberate lookback/reprocessing window.
42. **Make loads idempotent** — re-running the same date range should produce the same final result.
43. **Avoid duplicate records on retries** — use deterministic keys, deduplication, or merge logic.
44. **Prefer `MERGE`/upsert over `DELETE`+`INSERT`** where supported — reduces ghost rows and extra scans; if using `DELETE`+`INSERT`, follow with `VACUUM DELETE ONLY`.
45. **Process very large loads in manageable batches** (time or key ranges).
46. **Don't advance watermarks/pipeline state until the target load has actually succeeded.**
47. **Keep incremental logic deterministic** — the same source state and parameters should always produce the same result.

## G. Table Design, Distribution & Sort Keys

48. **Choose a distribution key on the column most frequently used in joins** to avoid redistribution (`DISTSTYLE KEY`).
49. **Use `DISTSTYLE ALL` for small, frequently-joined dimension tables.**
50. **Use `DISTSTYLE EVEN`/`AUTO` only when no clear join key exists** — avoid it on large, frequently-joined tables.
51. **Distribute so rows spread evenly across slices** — avoid data skew, which turns one slice into the bottleneck.
52. **Set sort keys on columns used in `WHERE`/`JOIN`/`GROUP BY`**, typically date/timestamp — enables block-skipping.
53. **Use compound sort keys for a consistent leading filter column; reserve interleaved sort keys** for multiple, equally-important filter columns (costly to maintain).
54. **Partition large datasets logically, commonly by date**, especially for Spectrum/external tables over S3.
55. **Avoid over-partitioning** — too many tiny partitions/files hurts performance.
56. **Use the smallest correct data type** — `SMALLINT`/`INT` over `BIGINT`, right-sized `VARCHAR` instead of `VARCHAR(MAX)`/`VARCHAR(65535)`.
57. **Avoid over-normalizing schemas** — Redshift favors wider, denormalized fact tables over many small joins.
58. **Prefer relational columns over `SUPER`/JSON** where the schema is known and stable — JSON parsing costs more per row.
59. **Design keys intentionally** — define business keys, surrogate keys, and uniqueness rules clearly.
60. **Use columnar formats (e.g., Parquet)** for analytical scans in lakehouse storage.
61. **Control small-file problems in lakehouses** — compact files when frequent small writes degrade read performance.

## H. Statistics & Maintenance

62. **Run `ANALYZE` (or confirm auto-analyze) after big loads** — the planner needs fresh stats for good plans.
63. **Run `ANALYZE COMPRESSION` on new tables** and apply recommended column encodings; rely on `COPY`'s automatic compression where possible.
64. **Run `VACUUM` (or confirm auto-vacuum) to reclaim space and re-sort rows** after deletes/updates.
65. **Use targeted `VACUUM DELETE ONLY` / `VACUUM SORT ONLY`** instead of a full `VACUUM` when only one concern applies.
66. **Monitor `SVV_TABLE_INFO`** for `stats_off`, `unsorted` %, `size`, and `skew_rows` to catch degradation early.
67. **Schedule `VACUUM`/`ANALYZE` during low-traffic windows** if not relying on automatic features.

## I. Loading & Unloading

68. **Bulk-load with `COPY` from S3** (ideally Parquet) — never row-by-row `INSERT`.
69. **Use a few large files rather than many tiny ones**, and multiple files to parallelize `COPY` across slices.
70. **Load data pre-sorted to match the target sort key** where possible, to reduce post-load `VACUUM SORT` cost.
71. **Use `UNLOAD` to S3 for large exports** instead of pulling large result sets through a client connection.
72. **Use `TRUNCATE` instead of `DELETE` when clearing an entire table** — avoids ghost rows and transaction log entries.
73. **Batch large `INSERT`/`UPDATE` operations** rather than issuing many small transactions.

## J. Procedure / PL/pgSQL Specifics

74. **Avoid row-by-row loops** (`FOR ... LOOP` with single-row `INSERT`/`UPDATE`/`DELETE`) — rewrite as one set-based statement.
75. **Avoid cursors for bulk operations.**
76. **Batch `COMMIT`s** — committing inside a loop ends the transaction block and serializes work; commit every N rows or once at the end.
77. **Avoid dynamic SQL (`EXECUTE`) inside loops** — each call re-plans and re-compiles the statement.
78. **Avoid excessive `RAISE NOTICE`/`RAISE INFO` logging inside hot loops** — overhead adds up at scale.
79. **Stage into temp tables rather than repeatedly re-scanning base tables**, and `ANALYZE` the temp table immediately after populating it, before querying it again.

## K. Transactions & Reliability

80. **Use transactions to keep target data consistent** when multiple statements form one logical load.
81. **Keep transactions reasonably short** — long transactions increase locking and resource pressure.
82. **Design every operation to be retry-safe** — a failed job should be safely restartable.
83. **Avoid partial target loads** — users should never see half-completed Gold data.
84. **Use staging tables for complex loads** — transform and validate before touching the final target.
85. **Validate staged data before publishing** — check row counts, keys, nulls, and business rules.
86. **Handle exceptions intentionally** — return useful errors rather than swallowing failures.
87. **Preserve failure context in errors** — include procedure name, batch/date range, and relevant identifiers.

## L. Data Modeling & Schema Design

88. **Define the grain explicitly before modeling** — state "one row = one ___."
89. **Use a star schema for analytics** — facts (events/measures) plus dimensions (context).
90. **Denormalize for analytical reads** — OLTP-style normalization is slow for analytics.
91. **Follow medallion layering** — Bronze (raw) → Silver (clean) → Gold (business) — isolates concerns and keeps reprocessing safe.
92. **Use consistent naming conventions** that communicate layer and purpose (e.g., `sp_load_orders_from_silver`).
93. **Plan for schema change** — handle new, renamed, or removed source columns gracefully.
94. **Decide slowly-changing-dimension (SCD) handling per dimension** — overwrite vs. keep history — don't default to blind overwrites.

## M. Orchestration, Observability & Monitoring

95. **Orchestrate dependencies, schedules, and retries with a workflow tool** (e.g., Airflow/MWAA) rather than manual runs.
96. **Validate at ingestion** — check counts, nulls, and reconcile against source before trusting new data.
97. **Record rows inserted/updated/deleted** (e.g., `ROW_COUNT`) for every load.
98. **Log execution duration** to track performance trends and regressions over time.
99. **Log the processed date/batch window** so every execution is traceable.
100. **Add data-quality checks** — nulls, duplicates, valid ranges, and business rules.
101. **Emit metrics/logs and alarm on failures** — a silent pipeline failure just means stale data nobody notices.
102. **Comment the reason, not the obvious SQL** — explain non-obvious decisions, such as why a reload window exists.

## N. Compute & Workload Management

103. **Use Auto WLM instead of manual queues** unless there's a specific reason to hand-tune.
104. **Separate ETL/batch workloads from BI/dashboard queues** to avoid contention.
105. **Enable concurrency scaling for bursty ad hoc workloads.**
106. **Right-size compute (RPUs / cluster / node type) to the workload**; consider Serverless with auto-pause/auto-scale for unpredictable or spiky workloads.
107. **Use elastic resize or RA3 node scaling ahead of known heavy batch windows.**
108. **Lean on result caching for identical repeat queries** — avoid volatile SQL (e.g., `now()`) that defeats it.

## O. Safety & Verification

109. **Snapshot or back up before destructive operations** — one bad `DELETE` shouldn't be permanent.
110. **Test on a small subset first, then scale up** — cheap feedback, contained blast radius.
111. **Diff output row counts/checksums before vs. after every optimization** — correctness is non-negotiable.
112. **Optimize incrementally** — fix the single biggest bottleneck, re-measure, then move to the next; don't change five things at once and lose the ability to attribute the improvement.

---

## Quick-reference checklists

**Before a design:**
Grain (§L) → medallion layer (§L) → facts vs. dimensions (§L) → load pattern: full or incremental, idempotent? (§F) → distribution + sort keys for the real query pattern (§G) → types and naming (§G, §L) → schema change and SCD handling (§L) → validation, orchestration, monitoring planned (§M).

**Before an issue/optimization:**
Can I reproduce it with fixed inputs? (§A) → baseline captured (runtime + `EXPLAIN`)? (§A, §E) → do I understand the steps before editing? (§A) → which 2–3 steps dominate the time? (§A) → red flags in the plan — nested loops, disk spill, stale stats, huge scans? (§E, §H) → is it row-by-row, recomputing, or `SELECT *`? (§C, §J) → are dist/sort keys and skew right for this query? (§G) → fix one thing, re-measure, diff the output for correctness (§A, §O).
