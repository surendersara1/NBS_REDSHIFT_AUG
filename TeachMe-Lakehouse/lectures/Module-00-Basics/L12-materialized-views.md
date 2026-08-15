# L12 · Materialized Views

> **Module 0 · Lesson 12** · ~35 min

**Slide:** [`_render/L12-materialized-views.html`](_render/L12-materialized-views.html)

## What it is

A **view** re-runs its query every time you select from it. A **materialized view** stores the result and refreshes it.

That single difference turns a thirty-second dashboard query into a sub-second one — and hands you a cache-invalidation problem in exchange.

## Four things to know before you create one

### 1. It is a table

The result occupies storage and is exactly as stale as its last refresh. Treat it as derived data with an age, not as a view that happens to be fast.

### 2. AUTO REFRESH

```sql
CREATE MATERIALIZED VIEW mv_daily_sales
AUTO REFRESH YES
AS SELECT ...;
```

Redshift can refresh the view itself when the base tables change, rather than you scheduling it. Convenient — and worth knowing about, because a view refreshing on its own is a source of compute you did not schedule.

### 3. Incremental refresh

Where the query shape allows it, Redshift reprocesses only the changed rows rather than recomputing the whole result. Not every query qualifies; complex ones fall back to a full refresh. If refresh cost matters, check which one you are getting.

### 4. It can sit over the data lake

A materialized view can be defined on **external data lake tables** read through Spectrum, with incremental maintenance. That is a genuinely useful pattern: cache an expensive S3 scan inside the warehouse, and let dashboards hit the cache.

## Where this comes back

**Lesson 23**: the same object — a materialized view — is how Kinesis and Kafka data lands directly inside Redshift. Redshift streaming ingestion maps an MV straight onto a stream, with no S3 staging at all.

Worth flagging now so that when it appears in Part D it is a familiar object doing a new job, rather than a new concept.

## When to use it

**Use an MV for:**
- Expensive aggregations queried many times a day
- Dashboard queries that repeat unchanged
- Caching slow external-table scans

**Do not use it for:**
- Data that must be exactly current at the moment of reading

## The failure mode

**A stale materialized view is a wrong dashboard**, and it is wrong silently — the query succeeds, returns quickly, and gives yesterday's answer.

So: alarm on refresh age, not just on refresh failure. A refresh that stopped running three days ago and never errored is the dangerous case.

## In practice

- Power BI reads MVs, not raw fact tables.
- Refresh runs at the end of the gold build, as an explicit step.
- Refresh age is monitored, because a silent stale view is worse than an outage.

## Checklist

- [ ] I can explain the difference between a view and a materialized view
- [ ] I know what AUTO REFRESH does and what it costs
- [ ] I know incremental refresh is conditional on query shape
- [ ] I know an MV can sit over Spectrum external tables
- [ ] I monitor refresh **age**, not just refresh success
- [ ] I know an MV is the landing point for streaming ingestion (Lesson 23)

## You've got it when you can…

…be shown a dashboard returning yesterday's numbers with no errors anywhere, and check the materialized view's refresh age first — because you know that is the failure that does not announce itself.
