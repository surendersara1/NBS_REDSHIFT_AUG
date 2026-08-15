# L16 · Sort Keys and Zone Maps

> **Module 01 · Lesson 16** · ~45 min

**Slide:** [`_render/L16-sort-keys-zone-maps.html`](_render/L16-sort-keys-zone-maps.html)

## What it is

Redshift automatically stores the **min and max value for every 1MB block**. That metadata is a *zone map*.

When you filter, Redshift checks the zone map first. If a block's range cannot possibly satisfy your `WHERE` clause, **it is never read**. Sorting the table on the column you filter is what makes those ranges narrow enough to be useful.

This is the mechanism that replaces `CREATE INDEX` on your `WHERE` clause.

## Compound vs interleaved

### Compound — the default, and usually right

```sql
CREATE TABLE gold.fct_sales_line (...)
COMPOUND SORTKEY (sale_date, store_sk);
```

Sorted by the columns **in order**, exactly like a composite index. It helps when your filter starts with the first column:

```sql
WHERE sale_date >= '2026-01-01'                       -- ✅ excellent
WHERE sale_date >= '2026-01-01' AND store_sk = 4471   -- ✅ excellent
WHERE store_sk = 4471                                 -- ❌ no help at all
```

**Put the column you always filter on first.** For retail facts that is the date.

### Interleaved — rarely worth it

```sql
CREATE TABLE t (...) INTERLEAVED SORTKEY (a, b, c);
```

Gives equal weight to every column, so filtering on any one works reasonably. The cost is real: maintenance is expensive and requires `VACUUM REINDEX`.

**Use only when filter patterns genuinely vary and you have measured that compound is not enough.** Most teams that reach for it did not need it.

## Prove it works

```sql
-- run a filtered query
SELECT SUM(net_amount)
FROM   gold.fct_sales_line
WHERE  sale_date BETWEEN '2026-01-01' AND '2026-01-07';

-- then see what it actually read
SELECT SUM(blocks_read)    AS blocks_read,
       SUM(blocks_skipped) AS blocks_skipped,
       ROUND(100.0 * SUM(blocks_skipped)
             / NULLIF(SUM(blocks_read) + SUM(blocks_skipped), 0), 1) AS pct_skipped
FROM   stl_scan
WHERE  query = pg_last_query_id();
```

High `pct_skipped` on a date-filtered query is your zone maps working. **Near zero means something is wrong** — either the table is not sorted on that column, or it has drifted unsorted.

## The drift problem

New rows are appended **unsorted**. As unsorted rows accumulate, block ranges widen and skipping stops working.

```sql
SELECT "table", sortkey1, unsorted, tbl_rows, size AS mb
FROM   svv_table_info
WHERE  unsorted > 10
ORDER  BY tbl_rows DESC;
```

`unsorted > 10` means zone maps are degrading. The fix is `VACUUM` (L42) — or, for a table loaded in date order, the drift is naturally small because new rows already belong at the end.

> **Design tip:** sorting on an ever-increasing column like `sale_date` means new data lands where it belongs. Sorting on something random means every load fragments the table.

## The mistake that silently defeats it

```sql
-- ❌ zone maps cannot help: the function hides the column
WHERE DATE_TRUNC('month', sale_date) = '2026-01-01'
WHERE EXTRACT(year FROM sale_date)   = 2026
WHERE sale_date::VARCHAR LIKE '2026-01%'

-- ✅ a plain range on the raw column
WHERE sale_date >= '2026-01-01' AND sale_date < '2026-02-01'
```

**Never wrap the sort key in a function in a `WHERE` clause.** This is the single most common way people accidentally turn a fast query into a full scan, and it looks completely innocent.

## Try it

```sql
-- 1. what is each table sorted on?
SELECT "table", sortkey1, sortkey_num, unsorted
FROM   svv_table_info
WHERE  "schema" = 'gold'
ORDER  BY unsorted DESC;

-- 2. compare a good filter with a bad one, checking stl_scan after each
SELECT COUNT(*) FROM gold.fct_sales_line
WHERE sale_date >= '2026-01-01' AND sale_date < '2026-02-01';

SELECT COUNT(*) FROM gold.fct_sales_line
WHERE DATE_TRUNC('month', sale_date) = '2026-01-01';
```

Run both, check `stl_scan` after each, and look at the difference in `blocks_skipped`. That contrast is worth doing once by hand — it makes the lesson stick.

## Gotchas

- **A sort key you never filter on** costs you on every load and buys nothing.
- **Interleaved needs `VACUUM REINDEX`**, which is expensive.
- **Only the first sort-key column** gets you good skipping in a compound key.
- **`unsorted` climbing after every load** means either wrong sort column or missing maintenance.

## Checklist

- [ ] Every fact is sorted on the column it is filtered by, usually date
- [ ] The most-filtered column is **first** in a compound key
- [ ] I default to compound and only consider interleaved after measuring
- [ ] I never wrap the sort key in a function in `WHERE`
- [ ] I check `unsorted` regularly
- [ ] I have proved skipping with `stl_scan` at least once myself

## You've got it when you can…

…take a slow query with `DATE_TRUNC` in the `WHERE`, rewrite it as a range, and show with `stl_scan` that the second version skipped 95% of the blocks the first one read.
