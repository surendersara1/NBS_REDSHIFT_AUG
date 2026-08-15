# L24 · MERGE and Idempotent Loads

> **Module 01 · Lesson 24** · ~45 min · ⭐ **the load pattern to internalise**

**Slide:** [`_render/L24-merge-idempotent-loads.html`](_render/L24-merge-idempotent-loads.html)

## The property you are buying

> **Re-running yesterday's load must produce exactly yesterday's table.**

That is idempotency, and it turns every incident into a **retry** instead of a **repair**. Sources are late, jobs die mid-run, someone needs a backfill — all routine if re-running is safe, all manual surgery if it is not.

Because nothing in Redshift enforces uniqueness (L18), an appending load run twice simply doubles the day. `MERGE` is what prevents that.

## 1 · A real merge key

One column that identifies a row **uniquely and identically every time it is computed**. Usually a hash of the natural key columns:

```sql
-- in the transform that builds staging
SELECT ...,
       MD5(receipt_no || '|' || line_no::VARCHAR || '|' || store_id) AS merge_key
FROM   raw.sales_line;
```

**Rules for a merge key:**

- Built only from **natural key** columns — never from a load timestamp or a row number
- Deterministic: same input row → same key, every run, forever
- `NOT NULL`, and part of the table from day one (retrofitting means a rebuild)

```sql
-- ❌ not a merge key — changes every run
MD5(receipt_no || GETDATE()::VARCHAR)

-- ❌ not a merge key — depends on ordering
ROW_NUMBER() OVER (ORDER BY sale_date)
```

## 2 · Stage, then merge

```sql
TRUNCATE staging.sales_line;

COPY staging.sales_line
FROM 's3://bucket/raw/sales/dt=2026-08-12/'
IAM_ROLE '...' FORMAT AS PARQUET;

-- validate before anything touches the live table
SELECT COUNT(*) AS rows,
       COUNT(DISTINCT merge_key) AS keys,
       SUM(CASE WHEN store_sk IS NULL THEN 1 ELSE 0 END) AS null_keys
FROM   staging.sales_line;
```

**Never `COPY` into the table people query.** Staging is where you count, validate and abandon cheaply.

## 3 · Deduplicate the source first

Two staging rows with the same key make `MERGE` **non-deterministic** — it is undefined which one wins.

```sql
CREATE TEMP TABLE sales_dedup AS
SELECT *
FROM (
  SELECT s.*,
         ROW_NUMBER() OVER (
           PARTITION BY merge_key
           ORDER BY     source_updated_at DESC, loaded_at DESC
         ) AS rn
  FROM   staging.sales_line s
)
WHERE rn = 1;
```

Pick the tie-breaker deliberately — usually "most recently updated at source".

## 4 · Merge in one transaction

```sql
BEGIN;

MERGE INTO gold.fct_sales_line AS t
USING sales_dedup AS s
   ON t.merge_key = s.merge_key
WHEN MATCHED THEN UPDATE SET
       sale_date  = s.sale_date,
       store_sk   = s.store_sk,
       product_sk = s.product_sk,
       quantity   = s.quantity,
       net_amount = s.net_amount,
       vat_amount = s.vat_amount,
       loaded_at  = SYSDATE
WHEN NOT MATCHED THEN INSERT (
       sale_date, store_sk, product_sk,
       quantity, net_amount, vat_amount, merge_key, loaded_at
) VALUES (
       s.sale_date, s.store_sk, s.product_sk,
       s.quantity, s.net_amount, s.vat_amount, s.merge_key, SYSDATE
);

COMMIT;
```

## The alternative: delete-then-insert

When the grain is a **whole partition** (a day, a store-day), this is often simpler and faster than `MERGE`:

```sql
BEGIN;
  DELETE FROM gold.fct_sales_line WHERE sale_date = '2026-08-12';
  INSERT INTO gold.fct_sales_line
  SELECT ... FROM sales_dedup WHERE sale_date = '2026-08-12';
COMMIT;
```

| Use `MERGE` when | Use delete-insert when |
|---|---|
| rows arrive scattered across dates | the load is one whole partition |
| updates are a minority of the batch | you replace the partition entirely |
| you need per-row upsert semantics | the partition boundary is clean |

Both are idempotent. Both must be in one transaction.

## In dbt

```sql
{{ config(
    materialized  = 'incremental',
    incremental_strategy = 'merge',
    unique_key    = 'merge_key',
    on_schema_change = 'fail',
    dist          = 'store_sk',
    sort          = ['sale_date']
) }}

SELECT ... FROM {{ ref('stg_sales_line') }}
{% if is_incremental() %}
WHERE sale_date >= (SELECT MAX(sale_date) FROM {{ this }})
{% endif %}
```

`unique_key` is the merge key. `on_schema_change='fail'` means an upstream column change is a decision, not a surprise.

## Test it — properly

**Run the load twice on purpose**, then diff:

```sql
-- before
SELECT COUNT(*) AS rows, COUNT(DISTINCT merge_key) AS keys,
       SUM(net_amount) AS total
FROM   gold.fct_sales_line WHERE sale_date = '2026-08-12';

-- ... run the whole load again ...

-- after: all three numbers must be identical
```

Do this at table two, not at table fifty. An idempotency claim nobody tested is a hope.

## Gotchas

- **Duplicate keys in the source make `MERGE` non-deterministic.** Dedup first, every time.
- **A merge key containing a timestamp is not a merge key.**
- **`MERGE` still generates deleted rows** for the updated ones — heavy merges need `VACUUM` (L42).
- **No `ON CONFLICT`.** `MERGE` or delete-insert, nothing else.
- **Retrofitting a merge key means a rebuild** — put it in the DDL on day one (L20).

## Checklist

- [ ] Every fact has a deterministic `merge_key`, from natural keys only
- [ ] `COPY` lands in staging, never in the live table
- [ ] The source is deduplicated with an explicit tie-breaker before merging
- [ ] The merge runs in one transaction
- [ ] I know when delete-insert is the better shape
- [ ] **I have run the load twice on purpose and diffed the result**
- [ ] dbt models set `unique_key` and `on_schema_change='fail'`

## You've got it when you can…

…be told at 7am that last night's load ran twice, check the merge key and the row/key/total triple, and say within a minute whether there is a problem at all.
