# L33 · Warehouse SQL Patterns

> **Module 01 · Lesson 33** · ~50 min · **the four shapes**

**Slide:** [`_render/L33-warehouse-sql-patterns.html`](_render/L33-warehouse-sql-patterns.html)

## What it is

Application SQL is mostly lookups by key. Warehouse SQL is a **small number of shapes applied over and over** — and each one is a window function underneath.

Learn them as patterns and you stop solving them from scratch every time someone asks a question in a slightly new way.

## Pattern 1 · Deduplication

**The question:** "the latest row per key". **The shape:** `ROW_NUMBER`, keep `rn = 1`.

```sql
-- reusable as a view over any staging table
CREATE OR REPLACE VIEW staging.v_sales_line_latest AS
SELECT *
FROM (
  SELECT s.*,
         ROW_NUMBER() OVER (
           PARTITION BY merge_key
           ORDER BY     source_updated_at DESC, source_op_seq DESC, loaded_at_utc DESC
         ) AS rn
  FROM   staging.sales_line s
)
WHERE rn = 1;
```

The tie-breaker chain matters. `source_updated_at` alone is not enough when a source system stamps two changes in the same second — add a sequence, an offset, anything monotonic.

**Diagnostic version** — how bad is the duplication?

```sql
SELECT COUNT(*)                          AS rows_in,
       COUNT(DISTINCT merge_key)         AS keys,
       COUNT(*) - COUNT(DISTINCT merge_key) AS dupes
FROM   staging.sales_line;
```

## Pattern 2 · SCD Type 2 history

**The question:** "what was this store's region *in March*?" **The shape:** `valid_from` / `valid_to` / `is_current`.

A Type 1 dimension overwrites and loses the past. A Type 2 dimension keeps it: close the old row, open a new one. A report run for March then still shows March's prices, regions and hierarchy.

```sql
CREATE TABLE gold.dim_store (
    store_sk        BIGINT   IDENTITY(1,1),   -- surrogate: one per VERSION
    store_id        VARCHAR(20) NOT NULL,     -- natural key: stable across versions
    store_name      VARCHAR(120),
    region          VARCHAR(60),
    valid_from_utc  TIMESTAMP NOT NULL,
    valid_to_utc    TIMESTAMP NOT NULL DEFAULT '9999-12-31',
    is_current      BOOLEAN   NOT NULL DEFAULT TRUE,
    row_hash        VARCHAR(32) NOT NULL      -- MD5 of the tracked attributes
)
DISTSTYLE ALL
SORTKEY (store_id, valid_from_utc);
```

Two keys, and the distinction is the whole idea: **`store_id` identifies the store; `store_sk` identifies one version of it.** Facts join on `store_sk`, so a fact row is permanently attached to the version of the store that was true when it happened.

`valid_to_utc` uses `'9999-12-31'` rather than `NULL` so that `BETWEEN` works without special-casing.

### The load — close, then open

```sql
BEGIN;

-- 1. what arrived, deduped, with a hash of the tracked attributes
CREATE TEMP TABLE incoming DISTKEY (store_id) AS
SELECT store_id, store_name, region,
       MD5(COALESCE(store_name,'') || '|' || COALESCE(region,'')) AS row_hash,
       :batch_ts::TIMESTAMP AS effective_utc
FROM   staging.v_store_latest;

ANALYZE incoming;

-- 2. close any current row whose attributes actually changed
UPDATE gold.dim_store d
SET    valid_to_utc = i.effective_utc,
       is_current   = FALSE
FROM   incoming i
WHERE  d.store_id  = i.store_id
  AND  d.is_current
  AND  d.row_hash <> i.row_hash;

-- 3. open a new version for changed rows AND brand-new stores
INSERT INTO gold.dim_store
       (store_id, store_name, region, valid_from_utc, valid_to_utc, is_current, row_hash)
SELECT i.store_id, i.store_name, i.region, i.effective_utc, '9999-12-31', TRUE, i.row_hash
FROM   incoming i
LEFT   JOIN gold.dim_store d
       ON  d.store_id = i.store_id AND d.is_current
WHERE  d.store_id IS NULL          -- new store, or the row we just closed
   OR  d.row_hash <> i.row_hash;

COMMIT;
```

**The `row_hash` is what makes this idempotent.** Rerun the same batch and step 2 closes nothing (hashes match) and step 3 inserts nothing. Without it you get a new version every run, forever. Note that step 2 runs before step 3 inside one transaction, so the row closed in step 2 is no longer `is_current` when step 3's `LEFT JOIN` looks — which is why the `d.store_id IS NULL` branch catches it.

### Querying it

```sql
-- current view: what most reports want
SELECT * FROM gold.dim_store WHERE is_current;

-- as-at: what was true on a given date
SELECT * FROM gold.dim_store
WHERE  '2026-03-15' >= valid_from_utc AND '2026-03-15' < valid_to_utc;
```

### The test you run every load

```sql
-- 1. exactly one current row per natural key
SELECT store_id, COUNT(*) FROM gold.dim_store
WHERE is_current GROUP BY 1 HAVING COUNT(*) > 1;

-- 2. no overlapping validity ranges
SELECT a.store_id, a.store_sk, b.store_sk
FROM   gold.dim_store a
JOIN   gold.dim_store b
       ON  a.store_id = b.store_id
       AND a.store_sk < b.store_sk
       AND a.valid_from_utc < b.valid_to_utc
       AND b.valid_from_utc < a.valid_to_utc;

-- 3. no gaps in the timeline
SELECT store_id, valid_to_utc AS gap_from,
       LEAD(valid_from_utc) OVER (PARTITION BY store_id ORDER BY valid_from_utc) AS gap_to
FROM   gold.dim_store
QUALIFY gap_to IS NOT NULL AND gap_to <> valid_to_utc;
```

⚠️ **Overlapping ranges double-count history and nothing errors.** An as-at query hits two rows, the join fans out, and the total is quietly wrong. Run test 2 on every load — this is the single most important test in the whole warehouse.

> `QUALIFY` filters on a window function without a subquery. If your Redshift version rejects it, wrap the `LEAD` in a subquery and filter outside — same result.

## Pattern 3 · Gaps and islands

**The question:** "which days did this store not sell anything?" or "how long did that promotion actually run?" **The shape:** `date − ROW_NUMBER()` is constant within a consecutive run.

```sql
WITH selling_days AS (
    SELECT DISTINCT store_sk, sale_date AS d
    FROM   gold.fct_sales_line
    WHERE  sale_date >= '2026-01-01'
),
marked AS (
    SELECT store_sk, d,
           -- the trick: subtracting a dense counter from a dense date
           -- gives the same value for every day in a consecutive run
           DATEADD('day',
             -ROW_NUMBER() OVER (PARTITION BY store_sk ORDER BY d), d) AS grp
    FROM   selling_days
)
SELECT store_sk,
       MIN(d)   AS run_start,
       MAX(d)   AS run_end,
       COUNT(*) AS days
FROM   marked
GROUP  BY store_sk, grp
ORDER  BY store_sk, run_start;
```

That is the **islands**. For the **gaps** — the days that are missing — you need a spine, because *missing rows cannot report themselves*:

```sql
SELECT s.store_sk, dd.date_key AS missing_day
FROM   gold.dim_date dd
CROSS  JOIN (SELECT DISTINCT store_sk FROM gold.dim_store WHERE is_current) s
LEFT   JOIN gold.fct_sales_line f
       ON f.sale_date = dd.date_key AND f.store_sk = s.store_sk
WHERE  dd.date_key BETWEEN '2026-01-01' AND '2026-08-10'
  AND  NOT dd.is_public_holiday
  AND  f.store_sk IS NULL
ORDER  BY 1, 2;
```

This is the query that catches a store whose feed silently stopped. **Build it, schedule it, alert on it** — it finds problems that no row-count check will.

Same trick with `LAG` for "time since the previous event":

```sql
SELECT store_sk, d,
       DATEDIFF('day', LAG(d) OVER (PARTITION BY store_sk ORDER BY d), d) AS days_since_prev
FROM   selling_days;
```

## Pattern 4 · Pivot and unpivot

**Rows to columns** for a report:

```sql
-- explicit CASE: works everywhere, and you control the labels
SELECT store_sk,
       SUM(CASE WHEN channel = 'RETAIL'    THEN net_amount ELSE 0 END) AS retail,
       SUM(CASE WHEN channel = 'ONLINE'    THEN net_amount ELSE 0 END) AS online,
       SUM(CASE WHEN channel = 'WHOLESALE' THEN net_amount ELSE 0 END) AS wholesale
FROM   gold.fct_sales_line
GROUP  BY 1;

-- PIVOT: shorter, same result
SELECT * FROM (
    SELECT store_sk, channel, net_amount FROM gold.fct_sales_line
) PIVOT (
    SUM(net_amount) FOR channel IN ('RETAIL', 'ONLINE', 'WHOLESALE')
);
```

Both require you to **list the columns**. There is no dynamic pivot in SQL — if the channel list changes, the query changes. That is a good reason to pivot in the BI tool rather than in the warehouse, and to keep the gold table long-and-narrow.

**Columns to rows** to normalise a wide source file — a spreadsheet with one column per month is the classic:

```sql
SELECT store_id, month_label, amount
FROM   staging.wide_budget
UNPIVOT (amount FOR month_label IN (jan, feb, mar, apr, may, jun));
```

## Gotchas

- **Overlapping SCD2 validity ranges double-count history**, and nothing errors. Test every run.
- **Gaps need a date spine.** Missing rows cannot report themselves.
- **A dedup without a deterministic tie-breaker** picks a different winner each run.
- **`MD5` over concatenated columns needs `COALESCE`** — one `NULL` makes the whole hash `NULL`, so every row looks changed. And use a separator, or `'AB'||'C'` and `'A'||'BC'` hash the same.
- **Adding a column to the SCD2 hash** makes every row look changed on the next run and doubles the dimension. Plan that migration.
- **`PIVOT` needs a literal column list.** No dynamic pivot exists.
- **`CROSS JOIN` against a spine multiplies rows.** Bound the date range.

## Try it

1. Write the dedup view over one staging table and count the duplicates it removes.
2. Load `dim_store` twice with the same input. Prove the second run inserts zero rows — if it does not, your hash is wrong.
3. Change one store's region in staging, load again, and read the two versions with an as-at query for a date before and after.
4. Run the overlap test. Get zero rows.
5. Run the gap query for one store and explain each missing day: holiday, closure, or broken feed.

## Checklist

- [ ] A dedup view exists per staging table, with a deterministic tie-breaker
- [ ] I know why `store_sk` and `store_id` are different columns
- [ ] SCD2 loads are hash-driven and therefore idempotent
- [ ] The overlap test and the one-current-row test run on every load
- [ ] `COALESCE` and a separator in every hash expression
- [ ] `dim_date` used as the spine for gap detection
- [ ] The gap query is scheduled and alerts on a silent feed
- [ ] Pivots kept in BI, gold tables kept long and narrow

## You've got it when you can…

…be handed "our March report changed" and know it is either an SCD2 overlap or a Type 1 dimension that overwrote its history — and have the query that tells you which, before you have finished reading the ticket.
