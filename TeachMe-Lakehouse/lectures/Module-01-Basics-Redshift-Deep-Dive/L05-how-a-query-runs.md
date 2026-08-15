# L05 · How A Query Actually Runs

> **Module 01 · Lesson 05** · ~35 min

**Slide:** [`_render/L05-how-a-query-runs.html`](_render/L05-how-a-query-runs.html)

## What it is

Redshift does not interpret your SQL row by row. It **compiles your query into C++** and ships the binary to the slices, where every slice runs it against its own share of the data.

That is why your first run is slow and every run after it is not — and why benchmarking a first run is meaningless.

## The five stages

**1 · Parse** — on the leader. Syntax and object resolution.

**2 · Plan** — on the leader. The planner uses **table statistics** to choose join order and how data will be moved. Stale statistics produce a bad plan; that is what `ANALYZE` is for (L42).

**3 · Compile** — the plan becomes compiled C++ segments. This costs real time on the first execution of a given query *shape*. The result is cached, so later runs skip it.

**4 · Execute** — every slice runs the same code over its own data, in parallel. If a join needs rows that live on another slice, they get **moved** — and moving data is the expensive part (L29).

**5 · Return** — the leader merges partial results and streams them to you. A query returning millions of rows makes the leader the bottleneck.

## Try it — see the compile cost yourself

```sql
-- run this once, note the time
SELECT store_sk, SUM(net_amount)
FROM   gold.fct_sales_line
WHERE  sale_date >= '2026-01-01'
GROUP  BY 1;

-- run the identical statement again — usually much faster
```

Then look at what actually happened:

```sql
SELECT query_id,
       elapsed_time / 1000000.0        AS total_secs,
       queue_time  / 1000000.0         AS queued_secs,
       execution_time / 1000000.0      AS exec_secs,
       compile_time / 1000000.0        AS compile_secs,
       status,
       LEFT(query_text, 90)            AS sql
FROM   sys_query_history
WHERE  user_id = current_user_id
ORDER  BY start_time DESC
LIMIT  10;
```

`compile_secs` on the first run and near zero on the second is the whole lesson, visible.

> **Times in `sys_query_history` are microseconds.** Divide by 1,000,000. Forgetting this is how people report a 3-second query as 3 million.

## What counts as "the same shape"

The compile cache keys on the **shape** of the query, not its literals. So:

```sql
-- these two share a compiled plan
SELECT * FROM sales WHERE sale_date = '2026-01-01';
SELECT * FROM sales WHERE sale_date = '2026-02-14';

-- this one does not — different shape
SELECT * FROM sales WHERE sale_date BETWEEN '2026-01-01' AND '2026-02-14';
```

This is a strong argument for **parameterised queries** from application code: they reuse the cache. String-concatenated SQL that varies its structure recompiles constantly.

## Why the leader can be a bottleneck

```sql
-- bad: leader must merge and stream 20 million rows to you
SELECT * FROM gold.fct_sales_line;

-- good: the compute nodes do the work, the leader returns one row
SELECT COUNT(*), SUM(net_amount) FROM gold.fct_sales_line;
```

If you genuinely need millions of rows out, use `UNLOAD` to S3 (L27) rather than dragging them through the leader and over the wire.

## Gotchas

- **Never benchmark a first run.** Run it at least twice and quote the second.
- **A cluster restart or version upgrade clears the compile cache**, so the "first slow run" returns.
- **Queue time is not execution time.** A "slow" query may have spent most of its life waiting for a WLM slot (L41) — `sys_query_history` separates them, so check before you optimise SQL that was never the problem.

## Checklist

- [ ] I can name the five stages
- [ ] I know why the first run is slow
- [ ] I always run a query twice before judging it
- [ ] I know times in `sys_query_history` are microseconds
- [ ] I check `queue_time` before optimising `execution_time`
- [ ] I use parameterised queries so the compile cache is reused

## You've got it when you can…

…be shown a "slow query" and determine in one query whether it was slow because of compilation, queuing, or actual execution — before changing a single line of SQL.
