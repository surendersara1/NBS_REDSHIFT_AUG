# L10 · Creating Tables In Redshift

> **Module 0 · Lesson 10** · ~45 min · **best taught as a lab**

**Slide:** [`_render/L10-building-in-redshift.html`](_render/L10-building-in-redshift.html)

## What it is

Redshift's DDL looks like PostgreSQL, which is exactly why people get caught out. In a warehouse, **physical layout is part of the schema**. In an application database the engine hides where rows live; in Redshift you choose it, and that choice is most of your query performance.

Four decisions in every `CREATE TABLE`.

## 1. Distribution — how rows spread across slices

| Style | Behaviour | Use for |
|---|---|---|
| `DISTSTYLE KEY` | rows with the same key land on the same slice | large fact tables, on the busiest join column |
| `DISTSTYLE ALL` | a full copy on every node | small dimensions (roughly under a few million rows) |
| `DISTSTYLE EVEN` | round-robin | staging tables, or when nothing joins |
| `DISTSTYLE AUTO` | Redshift chooses and may change it | the sane default until you have a measured reason |

The point of `KEY` is **co-location**: if the fact and the dimension are distributed on the same key, the join happens on each slice locally instead of shuffling data across the network.

## 2. Sort key — physical order on disk

Redshift stores per-block min/max values. If a block cannot possibly satisfy your `WHERE` clause, it is skipped without being read.

Sort on **what you filter by** — for almost all retail facts, that is the date. A fact table sorted by date and filtered by date reads only the relevant blocks.

## 3. Encoding — per-column compression

`ENCODE AUTO` is genuinely good. Choosing deliberately (`az64` for numerics and dates, `zstd` for text) matters on very large fact tables, where the difference is measured in terabytes scanned.

## 4. Constraints are hints — the one that catches everyone

```sql
CREATE TABLE dim_store (
  store_sk   BIGINT PRIMARY KEY,   -- <- NOT enforced
  store_id   VARCHAR(20),
  ...
);
```

**`PRIMARY KEY`, `UNIQUE` and `FOREIGN KEY` are informational only in Redshift.** They inform the query planner. They do **not** prevent you inserting duplicates.

This surprises every SQL developer in the room, and it is the source of a whole family of production bugs: a load runs twice, duplicates appear, the constraint says nothing, and a dashboard doubles.

**The consequence:** if you need uniqueness, you must *test* for it. In dbt that is a `unique` test on the model. Not a constraint, a test.

## Worked shape

```sql
CREATE TABLE fct_sales_line (
  sale_date     DATE       NOT NULL,
  store_sk      BIGINT     NOT NULL,
  product_sk    BIGINT     NOT NULL,
  receipt_no    VARCHAR(32),
  quantity      DECIMAL(12,3),
  net_amount    DECIMAL(14,2),
  vat_amount    DECIMAL(14,2)
)
DISTKEY (store_sk)
SORTKEY (sale_date);
```

## Rules of thumb

- **DISTKEY** on the biggest join column of the biggest table
- **DISTSTYLE ALL** for small dimensions — the copy is cheaper than the shuffle
- **SORTKEY** on what you filter by, which is usually date
- **Never** assume a `PRIMARY KEY` stops duplicates

## In practice

- dbt config sets `dist` and `sort` per model, so the physical design lives beside the SQL and is reviewed with it.
- Facts get `DISTKEY` on the busiest foreign key.
- Dimensions under roughly 5M rows get `DISTSTYLE ALL`.
- **Uniqueness is tested in dbt, not declared in DDL.**

## Checklist

- [ ] I can explain all four distribution styles and when each applies
- [ ] I can explain block skipping and why sort key matters
- [ ] I know that constraints are not enforced, and what I do instead
- [ ] I can write a `CREATE TABLE` for a fact with sensible dist and sort
- [ ] I know where dist and sort live in our dbt models

## You've got it when you can…

…look at a slow Redshift query, name which of the four decisions was made wrong, and predict what changing it would do — before you run the experiment.
