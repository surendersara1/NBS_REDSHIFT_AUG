# L03 · Provisioned vs Serverless

> **Module 01 · Lesson 03** · ~35 min

**Slide:** [`_render/L03-provisioned-vs-serverless.html`](_render/L03-provisioned-vs-serverless.html)

## What it is

Two ways to buy the same engine. Same SQL, same features — you are choosing how capacity is purchased.

- **Provisioned** — you pick a node type and a node count. It runs until you stop it. Predictable cost, manual sizing.
- **Serverless** — you pick a capacity range. It scales with load and pauses when idle. **This is what we use.**

## The four terms you will see daily

### Namespace — *the data*
Databases, schemas, tables, users, snapshots. Everything that persists. It exists whether or not anything is running.

### Workgroup — *the compute*
Capacity, VPC placement, security groups, the endpoint you connect to. **You connect to a workgroup; it reads a namespace.**

One namespace can be read by more than one workgroup — which is how you give a heavy ETL job and a light BI workload separate compute over the same data.

### RPU — Redshift Processing Unit
The unit of Serverless capacity, billed per second while queries run. You set a **base** capacity and a **maximum**. The maximum is a cost ceiling, not a target.

### Node type — *provisioned only*
If you meet a provisioned cluster, the node type decides slices per node and whether storage scales separately. **RA3** uses Redshift Managed Storage (L04); older **DC2** has fixed local storage.

## Try it

```sql
-- where am I, and as whom?
SELECT current_database(), current_user, version();

-- what has Serverless actually been doing?
SELECT start_time, end_time, compute_seconds, compute_capacity
FROM   sys_serverless_usage
ORDER  BY end_time DESC
LIMIT  50;

-- which queries burned the most time today?
SELECT query_id,
       elapsed_time / 1000000.0 AS secs,
       LEFT(query_text, 100)    AS sql,
       user_id
FROM   sys_query_history
WHERE  start_time > DATEADD(day, -1, GETDATE())
ORDER  BY elapsed_time DESC
LIMIT  20;
```

That last query is the one to run when someone says "Redshift is expensive". It usually names a single dashboard.

## The cost trap

**Serverless is not free when idle.** It pauses when *nothing is running* — but a dashboard polling every minute, a monitoring check, or a BI tool with auto-refresh keeps it awake all night at base capacity.

Before you conclude Serverless is expensive, find out what queries at 3am:

```sql
SELECT DATE_TRUNC('hour', start_time) AS hr,
       COUNT(*)                       AS queries,
       SUM(elapsed_time) / 1000000.0  AS total_secs
FROM   sys_query_history
WHERE  start_time > DATEADD(day, -3, GETDATE())
GROUP  BY 1
ORDER  BY 1;
```

Hours with queries but no humans awake are the finding.

## Which to choose

| Choose Serverless when | Choose Provisioned when |
|---|---|
| load is spiky or unknown | load is steady and predictable |
| there are quiet periods | it runs hot 24/7 |
| you do not want to size anything | you want reserved-instance pricing |
| you are starting out | you have measured and know your shape |

For a nightly-batch retail warehouse with daytime reporting, Serverless is almost always right.

## Gotchas

- **Max RPU is a ceiling, not a goal.** Setting it very high does not make queries faster; it removes the cap on what a runaway query can cost.
- **Base RPU sets the floor** for what an idle-but-not-paused workgroup costs.
- **Snapshots belong to the namespace**, not the workgroup — deleting a workgroup does not delete data.

## Checklist

- [ ] I can explain namespace vs workgroup without hesitating
- [ ] I know what an RPU is and how it is billed
- [ ] I have run `sys_serverless_usage` on a real workgroup
- [ ] I know how to find what queries outside working hours
- [ ] I know max RPU is a cost ceiling

## You've got it when you can…

…be told "the Redshift bill went up" and find the cause in two queries — the hourly query profile and the top queries by elapsed time.
