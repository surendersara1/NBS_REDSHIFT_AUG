# L15 · Distribution Styles

> **Module 01 · Lesson 15** · ~45 min

**Slide:** [`_render/L15-distribution-styles.html`](_render/L15-distribution-styles.html)

## What it is

Where each row physically lands across the slices. **The largest single lever on join performance**, and the hardest thing to change afterwards.

A join is fast when both sides are already on the same slice. If they are not, Redshift moves rows between nodes mid-query — and that movement, not the comparison, is what makes a join slow.

## The four styles

### `DISTSTYLE KEY` — for big fact tables

```sql
CREATE TABLE gold.fct_sales_line (...)
DISTSTYLE KEY DISTKEY (store_sk);
```

Rows with the same key value land on the same slice. Two tables distributed on the **same** key join locally with no movement at all.

**Choose:** the column this table is most often joined on, with **high cardinality**.

### `DISTSTYLE ALL` — for small dimensions

```sql
CREATE TABLE gold.dim_store (...) DISTSTYLE ALL;
```

A full copy on every node, so any join to it is local. Costs storage × node count and slows writes.

**Choose:** dimensions under roughly a few million rows that change slowly. `dim_store`, `dim_date`, `dim_currency`.

### `DISTSTYLE EVEN` — round robin

No skew, no co-location. Right when nothing joins on the table, or when no column is a sensible key. **Staging tables are usually EVEN.**

### `DISTSTYLE AUTO` — the default

Redshift starts a small table as `ALL` and converts it to `EVEN` or `KEY` as it grows. A sane default — and **not a substitute for deciding on a big fact table**, where you know the join pattern and Redshift is guessing.

## Choosing a DISTKEY

Three tests, in order:

**1 · Is it the column you join on most?** Not the primary key by reflex — the column that appears in the most, or the most expensive, joins.

**2 · Is the cardinality high enough?**

```sql
SELECT COUNT(DISTINCT store_sk) AS distinct_vals,
       COUNT(*)                 AS rows,
       COUNT(*)::FLOAT / NULLIF(COUNT(DISTINCT store_sk), 0) AS rows_per_value
FROM   gold.fct_sales_line;
```

Distinct values should comfortably exceed your slice count. Fewer distinct values than slices leaves slices empty.

**3 · Is the distribution even?** A key with one dominant value (a `NULL`, a default, a catch-all `-1` "unknown" member) puts a huge share on one slice.

```sql
-- find a dominant value before you commit to the key
SELECT store_sk, COUNT(*) AS rows
FROM   gold.fct_sales_line
GROUP  BY 1
ORDER  BY 2 DESC
LIMIT  10;
```

## Verify after loading

```sql
SELECT "table", diststyle, skew_rows, tbl_rows, size AS mb
FROM   svv_table_info
WHERE  tbl_rows > 1000000
ORDER  BY skew_rows DESC NULLS LAST;
```

`skew_rows > 4` means rethink the key. See L02.

## What "movement" looks like in a plan

```sql
EXPLAIN
SELECT s.region, SUM(f.net_amount)
FROM   gold.fct_sales_line f
JOIN   gold.dim_store      s USING (store_sk)
GROUP  BY 1;
```

| Plan operator | Means |
|---|---|
| `DS_DIST_NONE` | ✅ co-located — no movement |
| `DS_DIST_ALL_NONE` | ✅ the other side is `DISTSTYLE ALL` |
| `DS_DIST_INNER` | ⚠️ inner table redistributed |
| `DS_BCAST_INNER` | 🔴 inner table **broadcast to every node** |

`DS_BCAST_INNER` on a large table is the classic disaster. L28 covers reading plans properly.

## Changing it later

You cannot `ALTER` a `DISTKEY`. The pattern is create-load-swap:

```sql
CREATE TABLE gold.fct_sales_line_new (LIKE gold.fct_sales_line);
ALTER TABLE gold.fct_sales_line_new ALTER DISTKEY product_sk;   -- or recreate with new DDL

INSERT INTO gold.fct_sales_line_new SELECT * FROM gold.fct_sales_line;

BEGIN;
  ALTER TABLE gold.fct_sales_line     RENAME TO fct_sales_line_old;
  ALTER TABLE gold.fct_sales_line_new RENAME TO fct_sales_line;
COMMIT;

DROP TABLE gold.fct_sales_line_old;
```

Note the rename swap inside a transaction — readers see one table or the other, never neither.

## Gotchas

- **A low-cardinality `DISTKEY` causes skew** and is worse than no key at all.
- **`DISTSTYLE ALL` on a large table** multiplies storage by node count and slows every write.
- **Join key types must match.** `VARCHAR` joined to `INT` forces a cast and defeats co-location.
- **`NULL`s all hash to the same slice.** A nullable `DISTKEY` concentrates them.

## Checklist

- [ ] Every large fact has an explicit `DISTKEY`, not `AUTO`
- [ ] The key is the busiest join column, with high cardinality
- [ ] I checked for a dominant value before committing
- [ ] Small slow-changing dimensions are `DISTSTYLE ALL`
- [ ] Staging tables are `EVEN`
- [ ] I verified `skew_rows` after the first real load
- [ ] Join key types match on both sides

## You've got it when you can…

…look at an `EXPLAIN` showing `DS_BCAST_INNER`, say which table is being broadcast and why, and name the distribution change that would remove it.
