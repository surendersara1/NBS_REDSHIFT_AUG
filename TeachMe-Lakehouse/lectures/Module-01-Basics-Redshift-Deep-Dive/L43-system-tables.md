# L43 · The System Tables You Actually Use

> **Module 01 · Lesson 43** · ~40 min · **the reference lesson**

**Slide:** [`_render/L43-system-tables.html`](_render/L43-system-tables.html)

## What it is

There are hundreds of system views. **You need about twelve.** Learn these and the warehouse stops being opaque.

### The families

| Prefix | What it is | Note |
|---|---|---|
| **`SYS_`** | The modern monitoring interface | Works on **provisioned and serverless**. Start here. |
| `SVV_` | Views over system tables, current state | `svv_table_info` is the most valuable view in Redshift |
| `STL_` | Logged history, persisted to disk | Detailed, older, leader-node only |
| `STV_` | Live snapshots of transient state | Locks, in-flight queries |
| `SVL_` | Views joining logs for convenience | `svl_query_summary` is the one you need |

**Prefer `SYS_` when it has what you need**, then drop to `SVV_`/`STL_`/`SVL_` for detail it does not expose. On Serverless, several `STL_`/`STV_` views are unavailable — another reason to reach for `SYS_` first.

## The four you will open every week

### 1 · `sys_query_history` — what ran

```sql
SELECT query_id,
       user_id,
       queue_time     / 1e6 AS queue_secs,
       execution_time / 1e6 AS exec_secs,
       elapsed_time   / 1e6 AS total_secs,
       result_cache_hit,
       status,
       LEFT(query_text, 80) AS sql
FROM   sys_query_history
WHERE  start_time >= DATEADD('hour', -4, GETDATE())
ORDER  BY execution_time DESC
LIMIT  20;
```

**The first place you look for anything at all.** Queue time, execution time, cache hits, status, the SQL itself.

### 2 · `svv_table_info` — one row per table, every number that matters

```sql
SELECT "schema", "table",
       size                 AS mb,
       tbl_rows,
       diststyle,
       sortkey1,
       skew_rows,           -- max/min rows per slice. >4 is bad
       unsorted,            -- % outside sort order
       stats_off,           -- % staleness
       vacuum_sort_benefit,
       max_varchar
FROM   svv_table_info
ORDER  BY size DESC;
```

**If you memorise one view, this is it.** It answers "is this table designed correctly", "is it maintained", and "is it skewed" in a single row.

### 3 · `stl_load_errors` — why `COPY` failed, per row

```sql
SELECT starttime, filename, line_number, colname, type, raw_field_value, err_reason
FROM   stl_load_errors
ORDER  BY starttime DESC
LIMIT  20;
```

The offending line, the column, the raw value, and the reason. **Never guess at a load failure again** (L22).

### 4 · `svl_query_summary` — what actually happened, step by step

```sql
SELECT stm, seg, step, label, rows, bytes, is_diskbased, workmem/1024/1024 AS workmem_mb
FROM   svl_query_summary
WHERE  query = 123456
ORDER  BY stm, seg, step;
```

`EXPLAIN` predicts; this reports. **`is_diskbased = 't'` on any step is your answer** (L28, L44).

## The rest of the twelve

```sql
-- 5. how much am I actually paying for (serverless)
SELECT * FROM sys_serverless_usage ORDER BY end_time DESC LIMIT 24;

-- 6. did a load succeed, and how many files
SELECT query, filename, curtime, status FROM stl_load_commits
WHERE query = 123456 ORDER BY curtime;

-- 7. how selective was the scan (step 5 of L44)
SELECT slice, tbl, rows, rows_pre_filter, is_rrscan
FROM   stl_scan WHERE query = 123456 AND userid > 1;

-- 8. what is blocking my session, right now
SELECT * FROM stv_locks;
SELECT * FROM svv_transactions;

-- 9. column definitions, encodings, keys
SELECT * FROM pg_table_def WHERE schemaname = 'gold' AND tablename = 'fct_sales_line';
-- ⚠️ needs the schema on the search_path to return anything. SVV_COLUMNS does not.

-- 10. materialized view freshness
SELECT * FROM svv_mv_info;

-- 11. is Redshift itself recommending a change
SELECT * FROM svv_alter_table_recommendations;

-- 12. is automatic maintenance actually running
SELECT * FROM svl_auto_worker_action ORDER BY eventtime DESC LIMIT 50;

-- and one more worth knowing: every schema, including external and shared
SELECT * FROM svv_all_schemas;
```

Number 11 is underused. Redshift's advisor writes its own suggestions there — sort key changes, distribution changes — based on your real workload.

## Save them as views

Type these once, not every time:

```sql
CREATE SCHEMA IF NOT EXISTS ops;

CREATE OR REPLACE VIEW ops.v_slow_queries AS
SELECT query_id, user_id,
       queue_time/1e6 AS queue_secs, execution_time/1e6 AS exec_secs,
       result_cache_hit, status, LEFT(query_text, 100) AS sql
FROM   sys_query_history
WHERE  start_time >= DATEADD('day', -1, GETDATE())
  AND  execution_time > 10e6;

CREATE OR REPLACE VIEW ops.v_table_health AS
SELECT "schema", "table", size AS mb, tbl_rows, diststyle, sortkey1,
       skew_rows, unsorted, stats_off, vacuum_sort_benefit, max_varchar
FROM   svv_table_info;

CREATE OR REPLACE VIEW ops.v_needs_maintenance AS
SELECT * FROM ops.v_table_health
WHERE  stats_off > 10 OR (unsorted > 20 AND vacuum_sort_benefit > 20)
ORDER  BY mb DESC;

GRANT USAGE ON SCHEMA ops TO ROLE analyst;
GRANT SELECT ON ALL TABLES IN SCHEMA ops TO ROLE analyst;
```

**Build the `ops` schema on day one of a new cluster.** It pays for itself the first time something is slow.

## Gotchas

- **Times are microseconds.** Divide by `1e6`. Reporting a query as "40,000,000 seconds slow" is a rite of passage.
- **History is retained for days, not months.** If you want to trend performance, `UNLOAD` a daily snapshot to S3.
- **`STL_` and `STV_` are leader-node only** and some are unavailable on Serverless. `SYS_` is the portable choice.
- **`userid > 1` filters out Redshift's own internal queries** in the older views — without it, results are full of system noise.
- **A non-superuser sees only their own rows** in most views. Grant `SYSLOG ACCESS UNRESTRICTED` deliberately, to the people who need it.
- **`pg_table_def` needs the schema on the `search_path`** or it silently returns nothing. `svv_columns` does not have this problem and is the better choice in a script.
- **`query` vs `query_id`** — older views use `query`, `SYS_` views use `query_id`. Joining across families needs care.
- **`skew_rows` above 4** means your `DISTKEY` is on a low-cardinality or badly skewed column (L15).

## Try it

1. Create the `ops` schema and all three views on a real cluster.
2. Run `ops.v_needs_maintenance`. Fix the worst row.
3. Find your slowest query in the last day and pull its `svl_query_summary`. Identify the slowest step.
4. Break a `COPY` deliberately and read `stl_load_errors` until the error makes sense without help.
5. Run `svv_alter_table_recommendations` and evaluate each suggestion — do not apply blindly, but understand why each was made.
6. Set up an `UNLOAD` of yesterday's `sys_query_history` to S3, so in three months you can answer "was this always slow?".

Exercise 6 is the one nobody does and everybody wishes they had.

## Checklist

- [ ] `SYS_` first, older families for detail
- [ ] Times divided by `1e6`
- [ ] `ops` schema with saved views exists
- [ ] I can find: what ran, why it was slow, why a load failed, what is locked
- [ ] `svv_table_info` reviewed on a schedule
- [ ] Query history unloaded to S3 for long-term trending
- [ ] `svl_auto_worker_action` checked
- [ ] `userid > 1` in older-view queries

## You've got it when you can…

…answer "why was the 6 a.m. report slow yesterday?" from the system views alone, three days later, without having been watching at the time.
