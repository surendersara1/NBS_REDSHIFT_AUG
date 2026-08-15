# L26 · Staging Patterns

> **Module 01 · Lesson 26** · ~40 min

**Slide:** [`_render/L26-staging-patterns.html`](_render/L26-staging-patterns.html)

## What it is

**Land it, check it, then move it.** The validation gate between staging and the live table is the cheapest quality control you will ever build — and the only place where abandoning a bad batch is free.

## The four steps

### 1 · Land

```sql
-- staging inherits the target's physical design
CREATE TABLE IF NOT EXISTS staging.sales_line (LIKE gold.fct_sales_line);

TRUNCATE staging.sales_line;

COPY staging.sales_line
FROM 's3://bucket/raw/sales/dt=2026-08-12/'
IAM_ROLE 'arn:aws:iam::...:role/rs-loader'
FORMAT AS PARQUET;
```

`CREATE TABLE LIKE` matters: staging inherits the distribution, sort and encodings, so the eventual move is cheap and does not redistribute.

### 2 · Validate — the gate

```sql
-- one query, four checks
SELECT
  COUNT(*)                                              AS rows,
  COUNT(DISTINCT merge_key)                             AS distinct_keys,
  SUM(CASE WHEN store_sk   IS NULL THEN 1 ELSE 0 END)   AS null_store,
  SUM(CASE WHEN sale_date  IS NULL THEN 1 ELSE 0 END)   AS null_date,
  SUM(net_amount)                                       AS total_net,
  MIN(sale_date)                                        AS min_date,
  MAX(sale_date)                                        AS max_date
FROM staging.sales_line;
```

**Stop the load if any of these fail:**

| Check | Fails when |
|---|---|
| `rows` in expected range | a truncated or duplicated extract |
| `rows = distinct_keys` | duplicates in the source |
| `null_store = 0` | a join or mapping broke upstream |
| `min_date`/`max_date` as expected | the wrong partition was loaded |
| `total_net` within tolerance of source | data loss or double counting |

That last one — reconciling a business total against the source system — is the check that catches what row counts miss.

### 3 · Move, in one transaction

**Scattered rows → `MERGE`** (L24).

**Full rebuild → rename swap:**

```sql
CREATE TABLE gold.fct_sales_line_new (LIKE gold.fct_sales_line);

INSERT INTO gold.fct_sales_line_new
SELECT * FROM staging.sales_line;

BEGIN;
  ALTER TABLE gold.fct_sales_line     RENAME TO fct_sales_line_old;
  ALTER TABLE gold.fct_sales_line_new RENAME TO fct_sales_line;
COMMIT;

DROP TABLE gold.fct_sales_line_old;
```

Readers see the old table or the new one, never neither. The swap is two catalogue updates — effectively instant.

### 4 · Clean up

```sql
TRUNCATE staging.sales_line;
```

**Keep the table**, empty it. Recreating staging every night loses its design *and* its grants — and then a reader loses access for reasons nobody connects to the load.

## Temp tables vs a staging schema

| | `CREATE TEMP TABLE` | `staging.` schema |
|---|---|---|
| Lifetime | the session | persistent |
| Visible to others | no | yes |
| Survives a failure for inspection | ❌ | ✅ |
| Needs cleanup | no | `TRUNCATE` |

**Use a staging schema for anything scheduled.** When a nightly load fails at 3am you want the staged data still sitting there to look at. A temp table vanished with the session.

Temp tables are right for intermediate steps inside one job — like the dedup step in L24.

## Gotchas

- **A rename swap breaks bound views.** Use `WITH NO SCHEMA BINDING` (L11) on anything pointing at a table you swap.
- **Grants follow the table, not the name.** After a swap, the new table has the *new* table's grants. Re-grant, or make the grant schema-level with `ALTER DEFAULT PRIVILEGES` (L13).
- **`TRUNCATE` commits immediately** — it cannot be part of a rollback (L25).
- **Do not validate after moving.** The point is to fail before anyone sees it.

## Checklist

- [ ] Staging built with `CREATE TABLE LIKE`
- [ ] `TRUNCATE` before every load, never `DELETE`
- [ ] A validation gate that can stop the load
- [ ] A business total reconciled against the source, not just row counts
- [ ] The move is one transaction
- [ ] Staging is emptied, not dropped
- [ ] Views over swapped tables are late-binding
- [ ] Grants verified after the first swap

## You've got it when you can…

…design a load that fails safely at 3am — leaving the live table untouched, the staged data available to inspect, and one alarm that says which check failed.
