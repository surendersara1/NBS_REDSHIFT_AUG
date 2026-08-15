# L29 · Joins and Data Distribution

> **Module 01 · Lesson 29** · ~40 min

**Slide:** [`_render/L29-joins-and-distribution.html`](_render/L29-joins-and-distribution.html)

## What it is

**The same join, on the same data, can be a hundred times slower.** What changes is not the SQL — it is where the rows were physically sitting.

You do not choose the join algorithm. You choose the distribution and sort keys; the planner chooses the algorithm from those.

## The three algorithms

### Merge join — the fastest, and rare

Needs both tables **distributed and sorted** on the join column. Then it is a single pass down two ordered streams, with no hash table and no movement.

Worth engineering for on the one or two joins that dominate your workload:

```sql
CREATE TABLE gold.fct_sales_line (...)
DISTKEY (store_sk) SORTKEY (store_sk);      -- both on the join column

CREATE TABLE gold.dim_store (...)
DISTKEY (store_sk) SORTKEY (store_sk);
```

Note the trade: sorting the fact on `store_sk` rather than `sale_date` costs you zone-map pruning on date filters (L16). Only do this where the join genuinely dominates.

### Hash join — the normal one

Builds a hash table from the smaller side, then probes it. Perfectly good, and what you will see most of the time.

It goes wrong when the **build side is too big for memory** and spills to disk — usually because it was broadcast, or because `VARCHAR`s are oversized (L09).

### Nested loop — almost always a bug

```
XN Nested Loop DS_BCAST_INNER
```

Usually means a **missing or non-equality join condition** — an accidental cross join. Rows multiply and the query never finishes.

```sql
-- ❌ the classic: a comma join with the condition in WHERE, and a typo
SELECT * FROM fct_sales_line f, dim_store s
WHERE  f.store_sk = f.store_sk;          -- joined to itself

-- ✅ explicit JOIN makes the mistake impossible to miss
SELECT * FROM fct_sales_line f
JOIN   dim_store s ON f.store_sk = s.store_sk;
```

**Always use explicit `JOIN … ON`.** A comma join hides a missing condition.

## The fix hierarchy — in this order

**1 · `ANALYZE`.** Stale statistics cause bad plans. Cheapest possible fix.

```sql
SELECT "table", stats_off FROM svv_table_info WHERE stats_off > 10;
ANALYZE gold.dim_store;
```

**2 · Make the small side `DISTSTYLE ALL`.** Turns a broadcast into `DS_DIST_ALL_NONE` permanently.

```sql
ALTER TABLE gold.dim_store ALTER DISTSTYLE ALL;
```

**3 · Align the `DISTKEY`s.** For two large tables joined constantly, distribute both on the join column (L15). This means a rebuild.

**4 · Only then rewrite the SQL.** Filter earlier, aggregate before joining, reduce the row count going into the join.

Most people start at step 4. Steps 1 and 2 are faster to try and usually enough.

## The silent killer: mismatched key types

```sql
-- dim_store.store_sk  BIGINT
-- fct.store_code      VARCHAR(20)

SELECT * FROM fct f JOIN dim_store s ON f.store_code = s.store_sk::VARCHAR;
```

The cast defeats co-location entirely, and nothing warns you. **Match your key types exactly** — same type, same width — on both sides of every join.

```sql
-- audit join key types across a schema
SELECT tablename, "column", type
FROM   pg_table_def
WHERE  schemaname = 'gold' AND "column" LIKE '%_sk'
ORDER  BY "column", tablename;
```

Any `_sk` column with two different types across tables is a bug waiting to happen.

## The fan-out

A duplicated dimension row multiplies the fact rows joined to it. The symptom is a total that is suddenly too high; the cause is upstream.

```sql
-- always check the dimension first
SELECT store_sk, COUNT(*) FROM gold.dim_store
GROUP BY 1 HAVING COUNT(*) > 1;
```

This is why L18's uniqueness tests exist. A join cannot fan out against a genuinely unique dimension.

## Try it

```sql
-- 1. plan before
EXPLAIN SELECT s.region, SUM(f.net_amount)
FROM gold.fct_sales_line f JOIN gold.dim_store s USING (store_sk)
GROUP BY 1;

-- 2. change the dimension distribution
ALTER TABLE gold.dim_store ALTER DISTSTYLE ALL;

-- 3. plan after — DS_BCAST_INNER should become DS_DIST_ALL_NONE
EXPLAIN SELECT s.region, SUM(f.net_amount)
FROM gold.fct_sales_line f JOIN gold.dim_store s USING (store_sk)
GROUP BY 1;
```

Doing that once, on a real table, is worth more than reading about it.

## Gotchas

- **Comma joins hide missing conditions.** Use explicit `JOIN`.
- **Mismatched key types silently defeat co-location.**
- **A duplicated dimension row fans out the fact** and inflates totals.
- **`DISTSTYLE ALL` on a large dimension** costs storage × nodes and slows writes.
- **Sorting a fact on the join key** trades away date pruning — deliberate only.

## Checklist

- [ ] Always explicit `JOIN … ON`, never comma joins
- [ ] All `_sk` columns have identical types everywhere
- [ ] I follow the fix hierarchy: analyze → ALL → align → rewrite
- [ ] I check the dimension for duplicates before blaming the join
- [ ] I check `is_diskbased` on any slow join
- [ ] I have watched `DS_BCAST_INNER` become `DS_DIST_ALL_NONE` myself

## You've got it when you can…

…be handed a join that got slow overnight and work through the hierarchy in order — finding, most of the time, that it was stale statistics rather than anything you wrote.
