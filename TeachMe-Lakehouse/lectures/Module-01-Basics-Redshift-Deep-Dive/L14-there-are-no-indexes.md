# L14 · There Are No Indexes

> **Module 01 · Lesson 14** · ~45 min · ⭐ **the hardest habit to unlearn**

**Slide:** [`_render/L14-there-are-no-indexes.html`](_render/L14-there-are-no-indexes.html)

## What it is

```sql
CREATE INDEX idx_sales_date ON sales (sale_date);
-- ERROR:  syntax error at or near "INDEX"
```

There is no `CREATE INDEX` in Redshift. Not a limitation to work around — a different design.

**An index exists to help you find a few rows without a full scan.** A warehouse query reads a great many rows on purpose. So instead of building an extra structure to look rows up in, Redshift makes the scan itself cheap.

## The four mechanisms that replace it

### 1 · Sort key → zone maps

Redshift stores **min and max per 1MB block**. If the table is sorted on `sale_date` and you filter on a week, it reads only the blocks whose range could contain that week and skips the rest without touching them.

That is the direct replacement for `CREATE INDEX ON sales (sale_date)`.

### 2 · Dist key → no data movement

Two tables distributed on the same key join **slice-locally**. The alternative is shipping rows between nodes mid-query — which is usually the single largest cost in a slow join (L29).

This is what replaces an index on a foreign key.

### 3 · Columnar + compression → fewer bytes

You only read the columns you name, and they are compressed. Three columns of two hundred is 1.5% of the table before compression helps at all.

### 4 · Statistics → a good plan

The planner needs to know table sizes and value distribution to choose a join strategy. **Stale statistics are the closest thing Redshift has to a "missing index"** — the plan collapses and nothing tells you why.

```sql
SELECT "table", stats_off, unsorted, tbl_rows
FROM   svv_table_info
WHERE  stats_off > 10
ORDER  BY tbl_rows DESC;

ANALYZE gold.fct_sales_line;
```

## The translation

```sql
-- what you would have written in Postgres
CREATE INDEX ON sales (sale_date);   -- the filter
CREATE INDEX ON sales (store_id);    -- the join

-- what you write here, once, at CREATE time
CREATE TABLE gold.fct_sales_line (...)
DISTKEY (store_sk)      -- the join
SORTKEY (sale_date);    -- the filter
```

**DIST for joins. SORT for filters.**

## The constraint that hurts

You get **one sort key and one distribution key per table** — not fifteen indexes. There is no adding another one later when a new query pattern appears.

This is why table design is a real design activity here (L20), and why it happens before you load rather than after you notice a problem.

## Prove it to yourself

```sql
-- 1. how much of the table is actually being read?
EXPLAIN
SELECT SUM(net_amount)
FROM   gold.fct_sales_line
WHERE  sale_date BETWEEN '2026-01-01' AND '2026-01-07';

-- 2. run it, then see how many blocks were skipped
SELECT slice, col, num_values, blocks_read, blocks_skipped
FROM   stl_scan
WHERE  query = pg_last_query_id()
  AND  blocks_read > 0
ORDER  BY blocks_skipped DESC
LIMIT  20;
```

A high `blocks_skipped` relative to `blocks_read` is your zone maps working. If `blocks_skipped` is near zero on a date-filtered query, either the table is not sorted on that column, or it has drifted unsorted and needs `VACUUM` (L42).

```sql
-- is the sort actually in effect?
SELECT "table", sortkey1, unsorted, tbl_rows
FROM   svv_table_info
WHERE  "schema" = 'gold'
ORDER  BY unsorted DESC;
```

`unsorted > 10` means zone maps are degrading.

## Gotchas

- **`unsorted` rows lose you zone maps entirely.** A table sorted on `sale_date` that has had a month of unsorted appends stops skipping blocks.
- **A `SORTKEY` you never filter on is wasted**, and costs you on every load.
- **A `DISTKEY` on a low-cardinality column causes skew** (L02) — worse than no `DISTKEY` at all.
- **You cannot `ALTER` either one.** Changing them means create-load-swap.

## Checklist

- [ ] I no longer reach for `CREATE INDEX`
- [ ] I can name the four mechanisms that replace it
- [ ] **DIST for joins, SORT for filters** is automatic
- [ ] I know I get one of each, chosen at create time
- [ ] I can prove zone maps are working with `stl_scan`
- [ ] I check `unsorted` and `stats_off` before blaming SQL

## You've got it when you can…

…be handed a slow warehouse query by a developer who wants to add an index, and instead show them — with `stl_scan` — how many blocks were read versus skipped, and what the table's design should have been.
