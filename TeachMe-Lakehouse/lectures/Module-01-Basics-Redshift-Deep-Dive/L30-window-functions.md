# L30 · Window Functions

> **Module 01 · Lesson 30** · ~45 min · **the warehouse workhorse**

**Slide:** [`_render/L30-window-functions.html`](_render/L30-window-functions.html)

## What it is

A calculation across related rows **without collapsing them**.

`GROUP BY` reduces many rows to one. A window keeps every row and adds the group calculation alongside — which is what reporting almost always needs.

> **If you are about to write a loop over rows in Node, it is a window function.**

## The anatomy

```sql
function(...) OVER (
  PARTITION BY <the group>
  ORDER BY     <the sequence>
  ROWS BETWEEN <the frame>
)
```

- **`PARTITION BY`** — the group. Omit it and the whole result set is one group.
- **`ORDER BY`** — the sequence within the group. Required for anything positional.
- **frame** — which rows in the partition count. Defaults are subtle; be explicit when it matters.

## 1 · ROW_NUMBER — deduplication

The most useful five lines in this module. It is the dedup step every load needs (L24):

```sql
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

**Always break ties explicitly.** With a non-deterministic `ORDER BY`, "which row wins" changes between runs and your load stops being reproducible.

## 2 · LAG and LEAD — the previous row

Day-on-day change without joining a table to itself:

```sql
SELECT sale_date,
       store_sk,
       net,
       LAG(net) OVER (PARTITION BY store_sk ORDER BY sale_date)      AS prev_net,
       net - LAG(net) OVER (PARTITION BY store_sk ORDER BY sale_date) AS delta,
       LAG(net, 7) OVER (PARTITION BY store_sk ORDER BY sale_date)   AS same_day_last_week
FROM   gold.agg_sales_daily;
```

## 3 · SUM OVER — running totals and shares

```sql
SELECT sale_date, store_sk, net,

       -- running total within the store, by date
       SUM(net) OVER (PARTITION BY store_sk ORDER BY sale_date
                      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS running_net,

       -- the store's total for the whole period (no ORDER BY = whole partition)
       SUM(net) OVER (PARTITION BY store_sk) AS store_total,

       -- this day's share of the store's total, in one pass
       net / NULLIF(SUM(net) OVER (PARTITION BY store_sk), 0) AS pct_of_store,

       -- 7-day moving average
       AVG(net) OVER (PARTITION BY store_sk ORDER BY sale_date
                      ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) AS ma7
FROM   gold.agg_sales_daily;
```

That `pct_of_store` line is the one to internalise. In Node you would have queried the total, then looped. Here it is one expression.

## 4 · RANK vs DENSE_RANK — ties matter

```sql
SELECT store_sk, net,
       ROW_NUMBER() OVER (ORDER BY net DESC) AS rn,    -- 1,2,3,4
       RANK()       OVER (ORDER BY net DESC) AS rnk,   -- 1,2,2,4  (gap)
       DENSE_RANK() OVER (ORDER BY net DESC) AS drnk   -- 1,2,2,3  (no gap)
FROM   gold.agg_sales_by_store;
```

**Pick deliberately.** "Top 10 stores" means something different under each, and the business does care which.

## Top-N per group — the pattern

```sql
-- top 3 products per store by revenue
SELECT *
FROM (
  SELECT store_sk, product_sk, net,
         ROW_NUMBER() OVER (PARTITION BY store_sk ORDER BY net DESC) AS rn
  FROM   gold.agg_sales_by_store_product
)
WHERE rn <= 3
ORDER BY store_sk, rn;
```

## Gotchas

- **You cannot filter on a window function in `WHERE`.** Wrap it in a subquery or CTE first — the window is computed after `WHERE`.
- **A non-deterministic `ORDER BY` gives you random rows** on every run. Always add a tie-breaker.
- **Frame defaults differ** between `ROWS` and `RANGE`. Be explicit for running totals.
- **`ORDER BY` inside `OVER` is not the query's `ORDER BY`** — you still need one at the end for output ordering.
- **Windows over huge partitions can spill** — check `is_diskbased` (L28).

## Checklist

- [ ] I reach for a window before writing a loop
- [ ] Dedup is `ROW_NUMBER` with an explicit tie-breaker
- [ ] I know `LAG`/`LEAD` replace self-joins
- [ ] I can compute a share of group total in one pass
- [ ] I know why `WHERE` cannot filter a window
- [ ] I choose between `RANK` and `DENSE_RANK` deliberately

## You've got it when you can…

…be shown Node code that fetches rows, loops, and computes running totals in JavaScript — and replace the whole thing with one query that returns the finished answer.
