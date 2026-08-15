# L28 · Reading An EXPLAIN Plan

> **Module 01 · Lesson 28** · ~45 min · ⭐ **the diagnostic skill**

**Slide:** [`_render/L28-reading-explain.html`](_render/L28-reading-explain.html)

## What it is

`EXPLAIN` shows the route the query will take. **Read it bottom-up, and look for the letters `DS_`.**

The cost numbers are relative units, not seconds — ignore them until you know what you are doing. The **data-movement operators** are what tell you whether the physical design is right.

## The four operators that matter

| Operator | Means | Verdict |
|---|---|---|
| **`DS_DIST_NONE`** | both sides already co-located | ✅ ideal |
| **`DS_DIST_ALL_NONE`** | other side is `DISTSTYLE ALL` | ✅ good |
| **`DS_DIST_INNER`** | one side redistributed across the network | ⚠️ acceptable if small |
| **`DS_BCAST_INNER`** | a whole table copied to **every** node | 🔴 hunt this |

`DS_BCAST_INNER` on a hundred rows is nothing. On a million rows it is the classic cause of a slow join — and it will not show up as an error, only as time.

## The workflow

```sql
-- 1. what is the plan?
EXPLAIN
SELECT s.region, SUM(f.net_amount)
FROM   gold.fct_sales_line f
JOIN   gold.dim_store      s USING (store_sk)
WHERE  f.sale_date >= '2026-01-01'
GROUP  BY 1;
```

Look for `DS_BCAST` or `DS_DIST`. Then run it and look at what actually happened:

```sql
-- 2. the actuals
SELECT query, stm, seg, step, label,
       rows, bytes, is_diskbased, workmem/1024/1024 AS mem_mb
FROM   svl_query_summary
WHERE  query = pg_last_query_id()
ORDER  BY stm, seg, step;

-- 3. did anything spill?
SELECT step, label, is_diskbased, rows
FROM   svl_query_summary
WHERE  query = pg_last_query_id() AND is_diskbased = 't';

-- 4. how many blocks did the scan actually read vs skip?
SELECT SUM(blocks_read) AS read, SUM(blocks_skipped) AS skipped
FROM   stl_scan
WHERE  query = pg_last_query_id();
```

Those four steps, in that order, diagnose most slow queries without changing a line of SQL.

## `is_diskbased = true`

The step ran out of memory and spilled to disk. Three usual causes:

1. **Oversized `VARCHAR`s** (L09) — memory is reserved per row based on declared width, not actual content
2. **A hash join whose build side is too large** — often because of a broadcast
3. **A sort or aggregation over more rows than expected** — often a fan-out from a duplicated dimension row

Anything with `is_diskbased = 't'` is worth fixing. It is usually the single largest contributor to elapsed time.

## Stale statistics produce plausible bad plans

The planner chooses join order and strategy from statistics. If they are stale it will make a *reasonable-looking* wrong choice — typically broadcasting a table it believes is small.

```sql
SELECT "table", stats_off, tbl_rows
FROM   svv_table_info
WHERE  stats_off > 10
ORDER  BY tbl_rows DESC;

ANALYZE gold.fct_sales_line;
```

**Always check `stats_off` before rewriting SQL.** This is the closest thing Redshift has to a missing index (L14).

## Worked example: finding the broadcast

```
XN HashAggregate  (cost=...)
  ->  XN Hash Join DS_BCAST_INNER  (cost=...)     ← here
        Hash Cond: (f.store_sk = s.store_sk)
        ->  XN Seq Scan on fct_sales_line f
        ->  XN Hash
              ->  XN Seq Scan on dim_store s
```

`dim_store` is being broadcast to every node. Two possible fixes, cheapest first:

1. **`ALTER TABLE gold.dim_store ALTER DISTSTYLE ALL`** — it is a small dimension; give every node its own copy permanently. The plan becomes `DS_DIST_ALL_NONE`.
2. **Align the `DISTKEY`s** — only if the dimension is too large for `ALL`.

## Gotchas

- **Cost units are not seconds** and are not comparable between queries.
- **`EXPLAIN` does not execute.** For real numbers you must run the query.
- **The first run includes compilation** (L05) — run twice before drawing conclusions.
- **`svl_query_summary` has a retention window.** Query it while the run is fresh.

## Checklist

- [ ] I read plans bottom-up and search for `DS_` first
- [ ] I know all four movement operators and their verdicts
- [ ] I check `stats_off` before touching SQL
- [ ] I check `is_diskbased` on every slow query
- [ ] I know cost units are not seconds
- [ ] I run a query twice before judging it

## You've got it when you can…

…take a slow join, find the `DS_BCAST_INNER` in its plan, name which table is being broadcast, and fix it with a distribution change rather than a rewrite.
