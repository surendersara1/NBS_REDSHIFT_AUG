# L18 · Constraints Are Hints, Not Rules

> **Module 01 · Lesson 18** · ~35 min · ⭐ **the one that causes real production bugs**

**Slide:** [`_render/L18-constraints-are-hints.html`](_render/L18-constraints-are-hints.html)

## What it is

```sql
CREATE TABLE gold.dim_store (
  store_sk BIGINT PRIMARY KEY,
  store_id VARCHAR(20) UNIQUE,
  region   VARCHAR(32) NOT NULL
);

INSERT INTO gold.dim_store VALUES (1, 'S001', 'WEST');
INSERT INTO gold.dim_store VALUES (1, 'S001', 'WEST');
-- both succeed. no error. no warning.

SELECT COUNT(*) FROM gold.dim_store;   -- 2
```

**Only `NOT NULL` is enforced.** `PRIMARY KEY`, `UNIQUE` and `FOREIGN KEY` are informational.

## Why

Enforcing uniqueness means checking every slice on every insert — a cross-node round trip per row. In an MPP system that would destroy the bulk-load performance the whole design exists to provide.

Redshift declines that trade and hands the responsibility to you. It is a deliberate engineering decision, not an omission.

## Declare them anyway — but only if they are true

The optimiser **trusts** these declarations. It uses them to eliminate redundant joins and choose plans.

That cuts both ways:

> **A `PRIMARY KEY` you declared but did not enforce can cause wrong results**, because the planner may drop a join it believes cannot change the row count.

So: declare them where they are genuinely true, and **test that they stay true**.

## The tests you actually run

```sql
-- 1. duplicate keys in a dimension
SELECT store_sk, COUNT(*) AS n
FROM   gold.dim_store
GROUP  BY 1
HAVING COUNT(*) > 1;

-- 2. duplicate merge keys in a fact — the load-ran-twice check
SELECT merge_key, COUNT(*) AS n
FROM   gold.fct_sales_line
WHERE  sale_date = '2026-08-12'
GROUP  BY 1
HAVING COUNT(*) > 1
LIMIT  20;

-- 3. orphaned foreign keys — rows pointing at a dimension member that is gone
SELECT COUNT(*) AS orphans
FROM   gold.fct_sales_line f
LEFT   JOIN gold.dim_store s USING (store_sk)
WHERE  s.store_sk IS NULL;

-- 4. the fast smoke test: does the row count match the distinct key count?
SELECT COUNT(*)                  AS rows,
       COUNT(DISTINCT merge_key) AS distinct_keys
FROM   gold.fct_sales_line;
```

Test 4 is the cheapest and catches most incidents. If those two numbers differ, you have duplicates.

## In dbt

This is where it belongs — a test that runs after every build:

```yaml
models:
  - name: dim_store
    columns:
      - name: store_sk
        tests: [unique, not_null]
      - name: region
        tests: [not_null]

  - name: fct_sales_line
    columns:
      - name: merge_key
        tests: [unique, not_null]
      - name: store_sk
        tests:
          - not_null
          - relationships:
              to: ref('dim_store')
              field: store_sk
```

`relationships` is your foreign key. It is a test, not a constraint — which is the correct shape for this database.

## Where duplicates come from

Almost always one of three:

1. **A load ran twice** — the fix is an idempotent `MERGE` on a key (L24), not a manual delete.
2. **A join fanned out** — a many-to-many you thought was one-to-many. Check the dimension for duplicates first.
3. **A Type 2 dimension without `is_current`** — multiple versions of a row are correct; joining without filtering is not.

## Gotchas

- **No error is ever raised.** You find out from a doubled number in a report.
- **A wrong declaration is worse than none** — it can change results, not just performance.
- **`NOT NULL` *is* enforced**, so use it generously on key columns.
- **`IDENTITY` columns are not gap-free** across slices. Do not use them as a business key.

## Checklist

- [ ] I know only `NOT NULL` is enforced
- [ ] Every dimension has a uniqueness test that runs after each load
- [ ] Every fact has a uniqueness test on its merge key
- [ ] Foreign keys are tested with `relationships`, not trusted
- [ ] I declare constraints only where I have verified they hold
- [ ] The `COUNT(*)` vs `COUNT(DISTINCT key)` check is in my routine

## You've got it when you can…

…be told a dashboard number doubled overnight, run one query to confirm duplicates, and name the three likely causes before looking at any code.
