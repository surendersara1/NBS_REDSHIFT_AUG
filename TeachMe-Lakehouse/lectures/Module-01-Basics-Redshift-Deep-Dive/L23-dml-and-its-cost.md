# L23 · INSERT, UPDATE, DELETE — And Their Cost

> **Module 01 · Lesson 23** · ~35 min

**Slide:** [`_render/L23-dml-and-its-cost.html`](_render/L23-dml-and-its-cost.html)

## What it is

**Rows are never modified in place.** An `UPDATE` marks the old row deleted and appends a new one. A `DELETE` only flags rows — the space is not returned until `VACUUM` runs.

For a Node developer this is the second-biggest adjustment after "no indexes". In Postgres you update a row and it is updated. Here you have created a new row and left the old one behind.

## What each statement costs

### Single-row `INSERT` — never in a loop

Every insert touches blocks across every column of the table. A million of them takes hours and leaves the table badly fragmented.

```sql
-- ❌ what an ORM does
INSERT INTO gold.fct_sales_line VALUES (...);   -- × 1,000,000

-- ✅ one set-based statement
INSERT INTO gold.fct_sales_line
SELECT sale_date, store_sk, product_sk, net_amount, merge_key
FROM   staging.sales_line;
```

**If you are writing a loop that issues SQL, stop and write a `SELECT` instead.**

### `UPDATE` = delete + insert

The old version is flagged and a new row appended — **unsorted**. Updating a large fraction of a big table therefore wrecks its sort order and doubles its space until maintenance runs.

```sql
-- for a large fraction of a table, rebuild instead of updating
CREATE TABLE gold.fct_new (LIKE gold.fct_sales_line);

INSERT INTO gold.fct_new
SELECT sale_date, store_sk, product_sk,
       net_amount * 1.05 AS net_amount,     -- the "update"
       merge_key
FROM   gold.fct_sales_line;

BEGIN;
  ALTER TABLE gold.fct_sales_line RENAME TO fct_old;
  ALTER TABLE gold.fct_new        RENAME TO fct_sales_line;
COMMIT;

DROP TABLE gold.fct_old;
```

Rebuild-and-swap gives you a perfectly sorted, freshly compressed table and an atomic cutover. For anything above roughly 20% of the rows it is usually faster than the `UPDATE`.

### `DELETE` just flags

```sql
DELETE FROM gold.fct_sales_line WHERE sale_date < '2024-01-01';
-- rows are marked. storage and scan cost stay until VACUUM.
```

```sql
-- how much dead space am I carrying?
SELECT "table", size AS mb, tbl_rows, pct_used, unsorted
FROM   svv_table_info
WHERE  size > 500
ORDER  BY pct_used ASC
LIMIT  20;
```

Low `pct_used` on a large table means deleted rows awaiting reclamation (L42).

### `TRUNCATE` is instant

```sql
TRUNCATE staging.sales_line;
```

Frees space immediately and costs almost nothing. **This is how you empty a staging table** — never `DELETE FROM`.

⚠️ `TRUNCATE` commits immediately and **cannot be rolled back**, even inside a transaction. That surprises people who expect Postgres behaviour.

## Deleting a partition, the cheap way

If a table is sorted by date and you delete by date, the delete is cheap to find but still leaves flagged rows. For repeated partition-style deletes, prefer:

```sql
-- delete-then-insert in one transaction (the "delete/insert" upsert)
BEGIN;
  DELETE FROM gold.fct_sales_line
  WHERE  sale_date = '2026-08-12';

  INSERT INTO gold.fct_sales_line
  SELECT * FROM staging.sales_line
  WHERE  sale_date = '2026-08-12';
COMMIT;
```

This is idempotent for a whole day and is often simpler than a `MERGE` when the grain is a full partition. L24 covers when to use which.

## Try it

```sql
-- 1. see the cost of row-at-a-time (do this in dev only, small n)
CREATE TEMP TABLE t (i INT);
-- compare timing of 1000 single inserts vs one INSERT ... SELECT

-- 2. watch unsorted grow after an UPDATE
SELECT "table", unsorted, tbl_rows FROM svv_table_info
WHERE "table" = 'fct_sales_line';

UPDATE gold.fct_sales_line SET net_amount = net_amount
WHERE  sale_date = '2026-08-12';

SELECT "table", unsorted, tbl_rows FROM svv_table_info
WHERE "table" = 'fct_sales_line';
```

That second experiment is worth doing once. Watching `unsorted` jump after a no-op `UPDATE` makes the lesson permanent.

## Gotchas

- **`TRUNCATE` cannot be rolled back.** Not even in a transaction.
- **A big `UPDATE` wrecks sort order** and needs `VACUUM` afterwards.
- **`DELETE` does not free space** — check `pct_used`.
- **No `UPSERT` / `ON CONFLICT`** like Postgres. Use `MERGE` (L24) or delete-then-insert.
- **An ORM will do all of this wrong.** Do not point one at a warehouse.

## Checklist

- [ ] I never issue row-at-a-time DML in a loop
- [ ] I use `TRUNCATE`, not `DELETE`, to empty staging
- [ ] I know `TRUNCATE` commits and cannot be rolled back
- [ ] For large-fraction changes I rebuild and swap
- [ ] I check `unsorted` and `pct_used` after heavy DML
- [ ] I know there is no `ON CONFLICT` here

## You've got it when you can…

…be shown a nightly job that `UPDATE`s 80% of a fact table, explain what it does to sort order and space, and replace it with a rebuild-and-swap that runs faster and leaves the table in better shape.
