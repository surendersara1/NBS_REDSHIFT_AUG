# L31 · CTEs, Subqueries and the Optimizer

> **Module 01 · Lesson 31** · ~35 min

**Slide:** [`_render/L31-ctes-and-optimizer.html`](_render/L31-ctes-and-optimizer.html)

## What it is

**`WITH` is readability, not materialisation.**

Redshift generally **inlines** a CTE into the surrounding query. That is usually good — the planner sees the whole thing and can optimise across it. But it means a CTE referenced three times may be *computed* three times.

That is how a tidy-looking query quietly does the expensive work repeatedly.

## Four rules of thumb

### 1 · Referenced once → use a CTE

Free readability. Name the steps and the SQL documents itself:

```sql
WITH recent AS (
    SELECT * FROM gold.fct_sales_line
    WHERE  sale_date >= '2026-01-01'
),
by_store AS (
    SELECT store_sk, SUM(net_amount) AS net
    FROM   recent GROUP BY 1
)
SELECT s.region, SUM(b.net)
FROM   by_store b JOIN gold.dim_store s USING (store_sk)
GROUP  BY 1;
```

### 2 · Referenced twice and expensive → materialise it yourself

```sql
CREATE TEMP TABLE daily
  DISTKEY (store_sk)              -- give it a key if you will join it
AS
SELECT sale_date, store_sk, SUM(net_amount) AS net
FROM   gold.fct_sales_line
WHERE  sale_date >= '2026-01-01'
GROUP  BY 1, 2;

ANALYZE daily;                    -- ⚠️ do not skip this

-- now every reference reads a computed result
SELECT ... FROM daily d1 JOIN daily d2 ON ...;
```

**`ANALYZE` the temp table.** It has no statistics until you do, and the planner will guess badly on the next join — this is one of the most common causes of a mysteriously slow query in an otherwise sensible script.

### 3 · Correlated subquery → rewrite it

A subquery referencing the outer row runs **per row**:

```sql
-- ❌ runs once per row of f
SELECT f.*,
       (SELECT MAX(net_amount) FROM gold.fct_sales_line x
        WHERE  x.store_sk = f.store_sk) AS store_max
FROM   gold.fct_sales_line f;

-- ✅ one pass, as a window
SELECT f.*,
       MAX(net_amount) OVER (PARTITION BY store_sk) AS store_max
FROM   gold.fct_sales_line f;
```

Almost every correlated subquery is a window function or a join in disguise.

### 4 · Filter early, inside the CTE

```sql
-- ❌ the predicate is applied after the whole table is scanned
WITH all_sales AS (SELECT * FROM gold.fct_sales_line)
SELECT * FROM all_sales WHERE sale_date >= '2026-01-01';

-- ✅ the predicate reaches the scan, so zone maps prune (L16)
WITH recent AS (
  SELECT * FROM gold.fct_sales_line WHERE sale_date >= '2026-01-01'
)
SELECT * FROM recent;
```

Redshift will often push the predicate down anyway — but not always, and it costs nothing to write it in the right place.

## EXISTS vs IN vs JOIN

```sql
-- IN with a subquery: fine for small lists, watch out for NULLs
WHERE store_sk IN (SELECT store_sk FROM gold.dim_store WHERE region = 'WEST')

-- EXISTS: usually the best for "does a match exist"
WHERE EXISTS (SELECT 1 FROM gold.dim_store s
              WHERE s.store_sk = f.store_sk AND s.region = 'WEST')

-- JOIN: use when you need columns from the other table
JOIN gold.dim_store s ON s.store_sk = f.store_sk AND s.region = 'WEST'
```

⚠️ **`NOT IN` with any `NULL` in the subquery returns no rows.** This catches everyone once. Use `NOT EXISTS` instead:

```sql
-- ❌ silently returns nothing if any store_sk is NULL
WHERE store_sk NOT IN (SELECT store_sk FROM gold.dim_store)

-- ✅ behaves as you expect
WHERE NOT EXISTS (SELECT 1 FROM gold.dim_store s WHERE s.store_sk = f.store_sk)
```

## Check what the plan actually did

```sql
EXPLAIN
WITH recent AS (SELECT * FROM gold.fct_sales_line WHERE sale_date >= '2026-01-01')
SELECT (SELECT COUNT(*) FROM recent), (SELECT SUM(net_amount) FROM recent);
```

Look for the scan on `fct_sales_line` appearing **twice**. If it does, the CTE was inlined into both references and you are paying twice — materialise it.

## Gotchas

- **A temp table without `ANALYZE`** gets a bad plan on the next join.
- **Give temp tables a `DISTKEY`** if you will join them; otherwise they are `EVEN` and every join redistributes.
- **`NOT IN` plus `NULL` returns nothing.** Use `NOT EXISTS`.
- **Temp tables live for the session** — in the Data API each statement may be a different session, so temp tables do not persist between calls (L06).
- **Deeply nested CTEs are hard to read**, which defeats the point. Three or four levels is usually the limit.

## Checklist

- [ ] CTEs for readability where referenced once
- [ ] Temp table where an expensive step is reused
- [ ] Every temp table gets `ANALYZE`, and a `DISTKEY` if joined
- [ ] No correlated subqueries — rewritten as windows or joins
- [ ] Filters written inside the CTE that scans the table
- [ ] `NOT EXISTS`, never `NOT IN`, against a nullable column
- [ ] I have checked a plan for a doubly-scanned CTE

## You've got it when you can…

…take a 200-line query with six CTEs, find the one that is scanned three times, materialise it with `ANALYZE`, and cut the runtime without changing a single result.
