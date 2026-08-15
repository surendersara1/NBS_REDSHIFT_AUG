# L34 · Result Caching and Compiled Code

> **Module 01 · Lesson 34** · ~25 min · **closes Part E**

**Slide:** [`_render/L34-result-caching.html`](_render/L34-result-caching.html)

## What it is

The second run of a query is often a hundred times faster than the first. Knowing **why** stops you drawing the wrong conclusion when you benchmark a rewrite.

There are **two separate caches** and they explain different things.

## 1 · The result cache — on the leader node

If the leader has already computed this exact answer and nothing has changed, it hands the answer straight back. Zero compute nodes touched, single-digit milliseconds, **zero cost on serverless** (no RPUs are consumed).

**A hit needs all of these:**

- The **same SQL text** — matched after whitespace and case normalisation, so reformatting is fine but changing a literal is not
- The **same user**, with the same permissions
- **No change to any referenced table** since the result was cached
- **No volatile function** in the query
- The **same session-level configuration** that could affect the result

**Never cached:**

- Anything containing `GETDATE()`, `SYSDATE`, `CURRENT_DATE`, `RANDOM()`, `TIMEOFDAY()` — the answer would be wrong tomorrow
- Queries over **temp tables** — they are session-scoped
- Queries over **external tables** (Spectrum, external schemas) — Redshift cannot know if the S3 files changed
- Anything that writes

**Invalidated by:** any write to any referenced table. One `COPY` into your fact table clears every cached result that reads it.

## 2 · The compiled-code cache

Redshift compiles query segments to **C++ machine code** on first execution (L05). That compilation is real work — seconds, sometimes tens of seconds — and it is why a brand-new query shape can be slow *even on tiny data*.

The compiled objects are cached **per query shape**, and Redshift also uses a **cluster-external, service-wide** compilation cache: a segment your cluster has never compiled may still be fetched already-built because another cluster compiled the same shape. This is why "first run" penalties are much smaller than they used to be, and why they are unpredictable.

Two consequences:

- A **parameterised** query keeps one shape across many values, so it compiles once. String-concatenating literals into SQL from Node produces a new shape per value and recompiles endlessly. Use parameters (L06).
- After a **cluster resize, patch, or restart**, the local cache is cold. The first run of each query shape pays again.

## 3 · Benchmark honestly

This is the practical point of the lesson. If you time a rewrite without turning the cache off, **you are timing the cache**:

```sql
-- turn it off for this session only
SET enable_result_cache_for_session TO off;

-- ... run variant A three times, variant B three times ...

SET enable_result_cache_for_session TO on;      -- or just reconnect
```

**Method:**

1. `SET enable_result_cache_for_session TO off`
2. Run variant A three times. Discard the first (compilation), take the median of runs 2 and 3.
3. Run variant B three times. Same.
4. Compare medians.
5. Re-check with `EXPLAIN` that the plan actually changed — a faster time with an identical plan is noise.

## 4 · Did it hit? Check the system view

```sql
SELECT query_id,
       LEFT(query_text, 60)  AS sql,
       elapsed_time / 1000000.0 AS seconds,
       result_cache_hit,
       compile_time  / 1000000.0 AS compile_seconds
FROM   sys_query_history
WHERE  user_id = current_user_id
ORDER  BY start_time DESC
LIMIT  20;
```

`result_cache_hit = true` with `elapsed_time` in the milliseconds is the tell. **A 40-second query that reruns in 8 ms did not run at all.**

Cache hit rate over a day, which tells you how much of your dashboard traffic is free:

```sql
SELECT DATE_TRUNC('hour', start_time)                       AS hr,
       COUNT(*)                                             AS queries,
       SUM(CASE WHEN result_cache_hit THEN 1 ELSE 0 END)    AS hits,
       ROUND(100.0 * SUM(CASE WHEN result_cache_hit THEN 1 ELSE 0 END)
             / NULLIF(COUNT(*), 0), 1)                      AS hit_pct
FROM   sys_query_history
WHERE  start_time >= DATEADD('day', -1, GETDATE())
GROUP  BY 1 ORDER BY 1;
```

## 5 · The cache is not a performance strategy

The pattern that matters: **a dashboard opened after the nightly load never hits the cache.** The load invalidated everything. Every morning, the first user of every dashboard pays full price.

If you need that to be fast, the cache cannot help you. Use a **materialized view** (L11) refreshed at the end of the load, so the expensive work happens once, in the batch window, before anyone is looking.

```
result cache        → the same question, asked twice, with no writes in between
materialized view   → the expensive answer, computed once per load, on purpose
```

The first is a free accident. The second is engineering.

## Gotchas

- **You cannot benchmark with the cache on.** Turn it off first, every time.
- **Whitespace and case changes still hit** — so "I changed the query" is not proof you re-ran it. Change a literal, or turn the cache off.
- **A different user gets a different cache entry**, so testing as an admin does not prove anything about the BI service account.
- **External tables and temp tables are never cached.**
- **`enable_result_cache_for_session` is per session.** In the Data API each call may be a new session, so set it in the same statement batch or accept the default.
- **Serverless auto-pause does not clear the result cache**, but it does mean the first query after a pause pays a start-up delay that has nothing to do with caching. Do not confuse the two.

## Try it

```sql
-- 1. cold
SET enable_result_cache_for_session TO off;
SELECT s.region, SUM(f.net_amount)
FROM gold.fct_sales_line f JOIN gold.dim_store s USING (store_sk) GROUP BY 1;

-- 2. warm
SET enable_result_cache_for_session TO on;
SELECT s.region, SUM(f.net_amount)
FROM gold.fct_sales_line f JOIN gold.dim_store s USING (store_sk) GROUP BY 1;

-- 3. now invalidate it
INSERT INTO gold.fct_sales_line SELECT * FROM gold.fct_sales_line LIMIT 1;

-- 4. run the SELECT again — full price
```

Then read all four back from `sys_query_history` and look at the `result_cache_hit` column. Seeing your own timings line up with that flag is worth more than the explanation.

## Checklist

- [ ] I know the two caches are different things
- [ ] I turn the result cache off before timing anything
- [ ] I discard the first run — that is compilation
- [ ] I confirm a rewrite with `EXPLAIN`, not just a stopwatch
- [ ] I use parameters from Node so query shapes stay stable
- [ ] I know a load invalidates every cached result over that table
- [ ] Dashboards that must be fast after a load use a materialized view

## You've got it when you can…

…watch a colleague declare their rewrite "50× faster", ask whether they turned the result cache off, and be right about the answer.

---

**Part E complete.** L28–L34 covered reading plans, joins and distribution, windows, CTEs, time, the four warehouse patterns, and caching. Part F turns to code: procedures, UDFs, and calling Redshift from Node.
