# L41 · Workload Management and Concurrency

> **Module 01 · Lesson 41** · ~40 min · **Part G begins**

**Slide:** [`_render/L41-wlm-concurrency.html`](_render/L41-wlm-concurrency.html)

## What it is

Redshift runs **a handful of queries at once, on purpose**. Everything else queues. WLM is how you decide who waits.

This is the fact that surprises application developers most. In an OLTP database you scale by adding connections. Here, adding connections adds queue depth and nothing else.

**Memory is the scarce resource, not CPU.** A slot is a share of memory. More slots means smaller shares and more spilling to disk (L28). **Fewer, larger slots almost always beat many small ones.**

## 1 · Auto WLM — leave it on

Redshift sizes memory and concurrency per query from its own execution history. It gets this right far more often than a hand-tuned configuration, and it adapts when your workload changes.

**Manual WLM is for a problem you can prove auto cannot solve.** In practice that is rare, and if you are new to Redshift it is never your first move.

```sql
-- what auto WLM has been deciding
SELECT service_class,
       COUNT(*)                            AS queries,
       AVG(queue_time)  / 1e6              AS avg_queue_secs,
       MAX(queue_time)  / 1e6              AS max_queue_secs,
       AVG(execution_time) / 1e6           AS avg_exec_secs
FROM   sys_query_history
WHERE  start_time >= DATEADD('day', -1, GETDATE())
GROUP  BY 1 ORDER BY 1;
```

## 2 · Queues and query priority

Route by **user group** or **query group**, then set a priority per queue. The one separation worth making on almost every cluster:

| Queue | Members | Priority |
|---|---|---|
| `etl` | the load service account | `high` during the batch window |
| `bi` | the Power BI / dashboard account | `normal` |
| `adhoc` | analysts | `low` |

**A dashboard should not sit behind a backfill.** That is the whole argument.

Query groups let a session label itself:

```sql
SET query_group TO 'etl';
CALL etl.run_nightly('2026-08-10');
RESET query_group;
```

Priorities are `highest`, `high`, `normal`, `low`, `lowest`. Use `highest` sparingly — if everything is highest, nothing is.

## 3 · Query Monitoring Rules — rules that act

A QMR watches a metric and takes an action: **log**, **hop** (move to another queue), or **abort**.

Rules worth having from day one:

| Rule | Predicate | Action |
|---|---|---|
| Runaway dashboard query | `query_execution_time > 900` in the `bi` queue | `abort` |
| Enormous scan | `scan_row_count > 1e10` | `log` then `abort` |
| Nested loop | `nested_loop_join_row_count > 1e6` | `abort` |
| Heavy spill | `query_temp_blocks_to_disk > 100000` | `log` |

The nested-loop rule is the best value in the table. A nested loop over a million rows is almost always the accidental cross join from L29, and aborting it in the first minute saves an hour.

**This is how you stop one bad query ruining a morning** — and it is much better than an engineer noticing and cancelling by hand.

## 4 · Concurrency scaling

Extra clusters spin up automatically to handle **queued read queries**, and results come back as if they ran on the main cluster.

It is a **WLM queue setting** (or a workgroup setting on Serverless), configured in the parameter group or console — not a session `SET`. Facts to hold on to:

- You accrue **one hour of free concurrency-scaling credit per day** of main-cluster runtime, up to a cap. Beyond that it bills at the per-second on-demand rate.
- It helps **reads**. Write-heavy workloads see nothing.
- It is not a fix for a badly designed query. It is a fix for **too many acceptable queries at once**.

```sql
-- how much am I using?
SELECT DATE_TRUNC('hour', start_time) AS hr,
       SUM(CASE WHEN concurrency_scaling_status = 1 THEN 1 ELSE 0 END) AS on_scaling,
       COUNT(*) AS total
FROM   sys_query_history
WHERE  start_time >= DATEADD('day', -7, GETDATE())
GROUP  BY 1 ORDER BY 1;
```

On **Serverless**, this is mostly moot — RPU auto-scaling handles burst, and you set base and max RPUs instead of queues. `max_query_execution_time` on the workgroup is your equivalent of the runaway rule.

## Am I queuing, or just slow?

The first question to ask about any "Redshift is slow" report:

```sql
SELECT query_id,
       LEFT(query_text, 60)      AS sql,
       queue_time / 1e6          AS queue_secs,
       execution_time / 1e6      AS exec_secs,
       service_class,
       status
FROM   sys_query_history
WHERE  start_time >= DATEADD('hour', -2, GETDATE())
ORDER  BY queue_time DESC
LIMIT  20;
```

- **`queue_secs` high, `exec_secs` low** → a concurrency problem. WLM, priorities, or concurrency scaling.
- **`queue_secs` low, `exec_secs` high** → a query problem. Go to L44; WLM will not help you.

Getting this diagnosis backwards is the most common waste of an afternoon in Redshift operations.

## Gotchas

- **More slots is not more throughput.** It is less memory each and more disk spill.
- **A big `pg` pool does not buy concurrency.** Ten queries in flight is ten queries in flight regardless of a hundred open connections (L39).
- **Concurrency scaling never helps writes.**
- **`highest` priority for everything is no priority.**
- **QMR `abort` kills the query with an error the user sees.** Tell people the rules exist, or the abort looks like a bug.
- **Manual WLM memory percentages must sum to 100** and a wrong split can starve a queue completely.
- **Short-query acceleration** helps dashboards but can mask a genuinely slow query in the averages.
- **`SET query_group` is per session** — and Data API calls may not share a session (L39).
- **Fix the query before you tune the queue.** Tuning WLM around a broadcast join is treating a symptom.

## Try it

1. Run the queue-vs-exec query for the last 24 hours. Classify your ten slowest queries into "queuing" and "slow".
2. Set up `etl` / `bi` / `adhoc` query groups and route a session into each.
3. Add the nested-loop QMR rule, then run the accidental cross join from L29 and watch it get aborted.
4. Fire 50 concurrent dashboard queries and watch `queue_time` rise, then enable concurrency scaling and compare.
5. Find out whether your cluster has ever had a quiet period — it determines whether auto vacuum is running at all (L42).

## Checklist

- [ ] Auto WLM left on unless there is a proven reason
- [ ] ETL, BI and ad-hoc separated into queues with sensible priorities
- [ ] QMR rules for nested loops, huge scans and runaway dashboard queries
- [ ] Concurrency scaling enabled for the BI queue, and its usage monitored
- [ ] I check `queue_time` vs `execution_time` before touching anything
- [ ] `pg` pools sized to WLM reality, not to request volume
- [ ] The team knows QMR aborts exist and what they mean

## You've got it when you can…

…hear "Redshift is slow this morning", run one query, and say within a minute whether it is a concurrency problem or a query problem — and be right.
