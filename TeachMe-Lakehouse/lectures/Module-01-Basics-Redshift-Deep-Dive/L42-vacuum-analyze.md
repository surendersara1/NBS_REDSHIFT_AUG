# L42 · VACUUM, ANALYZE and Auto Maintenance

> **Module 01 · Lesson 42** · ~35 min

**Slide:** [`_render/L42-vacuum-analyze.html`](_render/L42-vacuum-analyze.html)

## What it is

Two different jobs that people confuse constantly:

- **`VACUUM`** reclaims space from deleted rows and restores sort order.
- **`ANALYZE`** refreshes the statistics the planner uses.

**A slow query is far more often stale statistics than unsorted data.** If you only ever do one, do `ANALYZE`.

## Why they are needed at all

`DELETE` does not remove a row — it marks it deleted (L23). `UPDATE` is a delete plus an insert. And every `INSERT` lands in the **unsorted region** at the end of the table, outside the sort order.

So after a month of loads:

- The table is larger than its data, and every scan reads the dead space.
- New rows are not in sort-key order, so zone maps cannot prune them (L16).
- Row counts and value distributions no longer match what the planner believes.

## Check, do not assume

Two numbers tell you everything:

```sql
SELECT "schema", "table",
       size            AS mb,          -- 1 MB blocks
       tbl_rows,
       unsorted,                       -- % of rows outside the sort order
       stats_off,                      -- % staleness of the statistics
       vacuum_sort_benefit             -- estimated % scan improvement from vacuuming
FROM   svv_table_info
WHERE  unsorted > 10 OR stats_off > 10
ORDER  BY size DESC;
```

- **`stats_off > 10`** → run `ANALYZE`. Cheap, safe, do it now.
- **`unsorted > 10`** *and* **`vacuum_sort_benefit`** meaningfully above zero → consider `VACUUM`.

`vacuum_sort_benefit` is the column that stops you vacuuming pointlessly. A table can be 40% unsorted and gain almost nothing, because nothing filters on its sort key.

## ANALYZE

```sql
ANALYZE gold.fct_sales_line;                              -- whole table
ANALYZE gold.fct_sales_line (sale_date, store_sk);        -- just the predicate columns — faster
ANALYZE;                                                   -- everything, rarely what you want
ANALYZE VERBOSE gold.fct_sales_line;                       -- tells you what it did
```

**Put it at the end of every load procedure** (L35). It is cheap and it prevents the most common cause of a mysteriously slow morning:

```sql
INSERT INTO gold.fct_sales_line SELECT ...;
ANALYZE gold.fct_sales_line (sale_date, store_sk);
```

Analyzing only the columns that appear in `WHERE`, `JOIN` and `GROUP BY` is markedly faster than the whole table and gives the planner everything it needs.

**Temp tables get no statistics at all until you analyze them** (L31). This is worth repeating because it is invisible: the query is correct, it is just planned as though the temp table had a default row count.

```sql
-- what has been analyzed, and when
SELECT * FROM svv_table_info WHERE stats_off > 0 ORDER BY stats_off DESC;
```

## VACUUM

```sql
VACUUM gold.fct_sales_line;                        -- FULL: reclaim + resort
VACUUM DELETE ONLY gold.fct_sales_line;            -- reclaim space, do not resort
VACUUM SORT ONLY gold.fct_sales_line;              -- resort, do not reclaim
VACUUM REINDEX gold.dim_store;                     -- interleaved sort keys only
VACUUM FULL gold.fct_sales_line TO 95 PERCENT;     -- stop at 95% sorted — much faster
```

**`TO 95 PERCENT` is the practical option.** The last 5% of sorting costs a disproportionate share of the time and buys very little.

⚠️ **`VACUUM` takes a lock that blocks writes on that table.** Never during the load window. And **only one `VACUUM` runs at a time cluster-wide**, so a queue of them serialises.

It is also restartable — if you cancel it, the work done so far is kept.

## What is automatic

| Feature | What it does | Catch |
|---|---|---|
| **Auto vacuum delete** | Reclaims space from deleted rows | Runs in idle periods |
| **Auto table sort** | Incrementally restores sort order | Runs in idle periods |
| **Auto analyze** | Refreshes stats after significant change | Runs in idle periods |
| **Auto vacuum sort** | Sorts the highest-benefit tables | Prioritises by `vacuum_sort_benefit` |

**The catch is the same in every row: idle periods.** On a busy cluster that never goes quiet, these may never get their turn — and Redshift will not tell you. That is why you still check `svv_table_info`.

```sql
-- has automatic maintenance actually been running?
SELECT * FROM svl_auto_worker_action ORDER BY eventtime DESC LIMIT 50;
```

An empty or stale result on a busy cluster is your answer, and the fix is either a quieter window or explicit maintenance.

## The deep copy — rebuild instead of repair

A badly unsorted large table **rebuilds faster than it vacuums**:

```sql
BEGIN;

CREATE TABLE gold.fct_sales_line_new (LIKE gold.fct_sales_line);

INSERT INTO gold.fct_sales_line_new
SELECT * FROM gold.fct_sales_line
ORDER BY sale_date, store_sk;              -- load in sort-key order

ALTER TABLE gold.fct_sales_line     RENAME TO fct_sales_line_old;
ALTER TABLE gold.fct_sales_line_new RENAME TO fct_sales_line;

COMMIT;

ANALYZE gold.fct_sales_line;
DROP TABLE gold.fct_sales_line_old;        -- after you have verified
```

`LIKE` copies the distribution and sort keys. Two notes: `LIKE` does not carry `IDENTITY` behaviour, so a table with an identity column needs an explicit DDL; and keep the old table until you have checked the row count, then drop it — the space is not released until you do.

This is also how you **change a `SORTKEY`** on a large table, and how you clean up a table someone loaded with a million single-row inserts (L39).

## Gotchas

- **`VACUUM` blocks writes on that table.** Not during the load window.
- **Only one `VACUUM` at a time, cluster-wide.**
- **`DELETE` without `VACUUM` grows the table forever.** A daily "delete then reload the slice" pattern needs `VACUUM DELETE ONLY` on a schedule.
- **`TRUNCATE` and `DROP` need no vacuum** — they release space immediately. Prefer `TRUNCATE` to `DELETE` when clearing a whole table (L23).
- **Auto maintenance needs idle time.** Verify with `svl_auto_worker_action`.
- **Temp tables have no stats until analyzed.**
- **`ANALYZE` on a table with no changes still costs something** — `svv_table_info.stats_off` tells you whether it is worth it.
- **A deep copy needs room for two copies** of the table.
- **`vacuum_sort_benefit` near zero means do not bother**, however ugly `unsorted` looks.
- **Sort order does not matter for a table nothing filters on.** Do not vacuum for tidiness.

## Try it

1. Run the `svv_table_info` query on a real cluster. Sort by size. Write down every table with `stats_off > 10`.
2. Take the slowest of those, `EXPLAIN` a typical query, run `ANALYZE`, `EXPLAIN` again. Compare the estimated row counts in the plan — that difference *is* the bug.
3. `DELETE` a third of a test table's rows and watch `size` in `svv_table_info` not move. Then `VACUUM DELETE ONLY` and watch it drop.
4. Check `svl_auto_worker_action`. Decide whether your cluster is actually getting maintenance.
5. Deep-copy a table with a different `SORTKEY` and compare a filtered query before and after.

Exercise 2 is the one that teaches why stats matter.

## Checklist

- [ ] `ANALYZE` at the end of every load procedure, on the predicate columns
- [ ] `ANALYZE` after every temp-table creation
- [ ] `svv_table_info` reviewed weekly for `unsorted` and `stats_off`
- [ ] `VACUUM` scheduled outside the load window, `TO 95 PERCENT`
- [ ] `VACUUM DELETE ONLY` scheduled if the load pattern deletes slices
- [ ] `TRUNCATE` used instead of `DELETE` for whole-table clears
- [ ] `svl_auto_worker_action` checked — I know whether auto maintenance runs here
- [ ] Deep copy used for big resorts and sort-key changes
- [ ] I check `vacuum_sort_benefit` before vacuuming anything large

## You've got it when you can…

…be told a report got slower over three months, check two columns of `svv_table_info`, and fix it with an `ANALYZE` before the meeting ends.
