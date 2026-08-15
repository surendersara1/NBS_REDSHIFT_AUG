# L11 · Three Things Called "View"

> **Module 01 · Lesson 11** · ~35 min

**Slide:** [`_render/L11-views-and-materialized.html`](_render/L11-views-and-materialized.html)

## What it is

Three objects, three behaviours. Choosing wrong makes deployments painful in a way that is hard to diagnose later.

## 1 · Ordinary view — bound at create time

```sql
CREATE VIEW rpt.sales_daily AS
SELECT sale_date, SUM(net_amount) AS net
FROM   gold.fct_sales_line
GROUP  BY 1;
```

Re-runs its query every time. **It depends on the tables underneath**, so:

```sql
DROP TABLE gold.fct_sales_line;
-- ERROR: cannot drop table because other objects depend on it
```

That is fatal for a nightly rebuild pattern where the table is dropped and recreated.

## 2 · Late-binding view — resolved at query time

```sql
CREATE VIEW rpt.sales_daily AS
SELECT sale_date, SUM(net_amount) AS net
FROM   gold.fct_sales_line
GROUP  BY 1
WITH NO SCHEMA BINDING;
```

The view no longer depends on the table. You can drop and rebuild anything beneath it freely — which is exactly what a nightly load does.

**This is the default choice for anything BI connects to.** It makes the view a *contract*: the shape stays stable while you restructure underneath.

The trade: if the underlying table is genuinely missing, you find out **at query time**, not at deploy time.

## 3 · Materialized view — stores the answer

```sql
CREATE MATERIALIZED VIEW rpt.mv_sales_daily
AUTO REFRESH YES
AS
SELECT sale_date, store_sk, SUM(net_amount) AS net
FROM   gold.fct_sales_line
GROUP  BY 1, 2;

-- or refresh it yourself, at the end of the load
REFRESH MATERIALIZED VIEW rpt.mv_sales_daily;
```

Fast to read, and **exactly as stale as its last refresh**. It occupies storage. It is a cache, with everything that implies.

Where the query shape allows, Redshift refreshes **incrementally** — only the changed rows. Complex shapes fall back to a full recompute, so check which you are getting if refresh cost matters.

## Which to use

| Need | Use |
|---|---|
| A stable contract for BI | **late-binding view** |
| An expensive aggregation queried all day | **materialized view** |
| Something inside a load, over stable tables | ordinary view is fine |
| Data that must be exactly current | neither — query the table |

## Try it

```sql
-- what views exist and are they late-binding?
SELECT schemaname, viewname, definition
FROM   pg_views
WHERE  schemaname NOT IN ('pg_catalog', 'information_schema');

-- materialized views and their freshness
SELECT database_name, schema_name, name,
       is_stale, autorefresh, last_refresh_time
FROM   svv_mv_info
ORDER  BY last_refresh_time;

-- what does a late-binding view break on?
SELECT * FROM rpt.sales_daily LIMIT 1;   -- fails here, not at deploy
```

`svv_mv_info.is_stale` and `last_refresh_time` are what you alarm on.

## The failure that does not announce itself

**A stale materialized view is a wrong dashboard** — the query succeeds, returns fast, and gives yesterday's answer.

Alarm on **refresh age**, not just refresh failure:

```sql
SELECT name,
       last_refresh_time,
       DATEDIFF(hour, last_refresh_time, GETDATE()) AS hours_old
FROM   svv_mv_info
WHERE  DATEDIFF(hour, last_refresh_time, GETDATE()) > 26;
```

A refresh that quietly stopped running three days ago and never errored is far more dangerous than one that failed loudly.

## Gotchas

- **BI must never point at base tables.** Point it at views and you can restructure freely.
- **`AUTO REFRESH` costs compute you did not schedule.** Fine, but know it is happening.
- **Not every query can be materialized** — some constructs are rejected at create time.
- **Late-binding views hide typos** until someone runs them.

## Checklist

- [ ] Everything BI touches is a view, never a base table
- [ ] Views exposed to BI are `WITH NO SCHEMA BINDING`
- [ ] I know which MVs refresh incrementally and which do not
- [ ] I alarm on MV refresh **age**, not just failure
- [ ] I can list stale MVs in one query

## You've got it when you can…

…be shown a dashboard returning yesterday's numbers with no errors anywhere, and check `svv_mv_info.last_refresh_time` first.
