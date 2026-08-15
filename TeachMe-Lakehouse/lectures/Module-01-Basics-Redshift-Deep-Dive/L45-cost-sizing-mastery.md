# L45 · Cost, Sizing and The Mastery Map

> **Module 01 · Lesson 45** · ~40 min · **end of module**

**Slide:** [`_render/L45-cost-sizing-mastery.html`](_render/L45-cost-sizing-mastery.html)

## Part 1 · What drives the bill

### Serverless vs provisioned

**Serverless** bills **RPU-seconds** — you set a base and a max RPU, and pay for what runs. There is a per-query minimum charge, and the workgroup auto-pauses when idle.

**Provisioned** bills **nodes by the hour**, whether or not anything is running. Reserved instances cut that substantially for a one- or three-year commitment.

| Workload | Cheaper on |
|---|---|
| Spiky, intermittent, a few hours a day | **Serverless** |
| Dev and test environments | **Serverless** — they auto-pause overnight |
| Running hard 16+ hours a day | **Provisioned**, and cheaper still reserved |
| Unpredictable, new project | **Serverless** — until you know the pattern |

**Start serverless.** Move to provisioned reserved once you have three months of usage data showing a steady baseline. Doing it the other way round means committing to a shape you have not measured.

### Where the money actually goes

1. **Compute** — RPU-seconds or node hours
2. **Managed storage** — per TB-month, billed separately from compute (L04)
3. **Concurrency scaling** beyond the accrued free credit (L41)
4. **Spectrum** — per TB scanned in S3 (L12)
5. **Cross-region snapshot transfer**

**Items 1 and 2 are almost the whole bill.** Do not spend time optimising 3–5 until you have looked at 1 and 2.

### Watch it

```sql
-- serverless: RPU-hours by period
SELECT DATE_TRUNC('day', end_time) AS d,
       SUM(charged_seconds) / 3600.0 AS rpu_hours
FROM   sys_serverless_usage
GROUP  BY 1 ORDER BY 1 DESC LIMIT 30;

-- which queries consumed the most compute yesterday
SELECT user_id, COUNT(*) AS queries,
       SUM(execution_time)/1e6/3600 AS exec_hours
FROM   sys_query_history
WHERE  start_time >= DATEADD('day', -1, GETDATE())
GROUP  BY 1 ORDER BY 3 DESC;

-- storage by table — the second half of the bill
SELECT "schema", "table", size AS mb, tbl_rows
FROM   svv_table_info ORDER BY size DESC LIMIT 30;
```

That second query is the useful one politically as well as technically: it tells you *whose* workload is driving the compute bill.

## Part 2 · Sizing

**Serverless:** start at **8 RPUs base**, set a **max** (this is your cost ceiling), and watch queue time. Raise the base if queries queue; raise the max if peaks are throttled.

**Provisioned:** `ra3.xlplus` for small, `ra3.4xlarge` mid, `ra3.16xlarge` large. Because RA3 separates compute from storage (L04), **size for compute and concurrency, not for data volume** — a common and expensive mistake carried over from DC2-era thinking.

**Two nodes minimum** for anything production — a single-node cluster has no redundancy.

### Five habits that save real money

1. **Set a serverless max-RPU ceiling and a CloudWatch billing alarm.** Without a ceiling, one runaway query can scale up hard.
2. **Give the workgroup a query timeout** (`max_query_execution_time`). An unbounded query is an unbounded bill.
3. **Materialize what every dashboard recomputes** (L11). Computing the same aggregate 400 times a day is 400× the cost of computing it once.
4. **Reserve capacity once the pattern is known** — not before.
5. **Delete the tables nobody has queried in a year.** Storage is billed per TB-month forever, and every warehouse accumulates abandoned tables.

For habit 5:

```sql
-- tables nobody has scanned recently (widen the window as your history allows)
SELECT t."schema", t."table", t.size AS mb
FROM   svv_table_info t
WHERE  t.size > 1000
  AND  NOT EXISTS (
         SELECT 1 FROM sys_query_history h
         WHERE  h.query_text ILIKE '%' || t."table" || '%'
           AND  h.start_time >= DATEADD('day', -30, GETDATE()))
ORDER  BY t.size DESC;
```

⚠️ That is a heuristic, not proof — a table referenced only inside a view or procedure will not appear in query text. Confirm before dropping anything, and snapshot first.

## Part 3 · The Mastery Map — the ten things

Forty-four lessons compress to about ten decisions. **If you only carry ten things out of this module, carry these.**

**1 · It is columnar and MPP.** Never `SELECT *`, never row-at-a-time. Reading one column of a billion rows is cheap; reading every column is not. → L01, L02

**2 · There are no indexes.** `DISTKEY` and `SORTKEY` are the entire physical design, and you choose them from how the table is queried. → L14, L15, L16, L20

**3 · Size every `VARCHAR` honestly.** Redshift allocates memory by declared width. Oversizing causes disk spill, which is the most common silent performance bug in the product. → L09

**4 · Constraints are hints.** Redshift does not enforce `PRIMARY KEY` or `UNIQUE`. Uniqueness is a test you write and run on every load. → L18

**5 · Load with `COPY` from S3.** Never a loop of `INSERT`s — that damages the cluster, not just the job. → L21, L39

**6 · Every load is idempotent for its batch date**, or it is not finished. Delete the slice and reload it, or `MERGE`. → L24, L26, L35

**7 · Hunt `DS_BCAST_INNER`.** Small dimensions go `DISTSTYLE ALL`. This one fix accounts for a large share of all Redshift speedups. → L28, L29

**8 · `ANALYZE` after every load.** It is the cheapest fix that exists and the answer to most "it was fine last week" reports. → L42

**9 · Store UTC. Convert once, at the reporting boundary.** Precompute the local business day at load time and make it the `SORTKEY`. → L32

**10 · Diagnose in order.** Queue → stats → broadcast → spill → scan → *then* the SQL. Rewriting the SQL is the last step, not the first. → L44

## Part 4 · The 90-day plan

**Days 1–14 — read and query.** Build the `ops` schema (L43). Run every diagnostic query in this module against a real cluster. Get comfortable reading `svv_table_info`.

**Days 15–30 — build one fact and two dimensions.** Choose the keys deliberately and write down *why* for each. Load them with `COPY`. Write the uniqueness tests. Make the load idempotent and prove it by running it three times.

**Days 31–60 — make it a pipeline.** Move the logic into stored procedures. Call them from Node via the Data API. Orchestrate with Step Functions. Add the run log and all three alerts. Break it deliberately and fix it.

**Days 61–90 — operate it.** Run the six-question playbook on real slow queries. Set up the maintenance schedule. Watch the cost. Then go back to your day-15 key choices and see which ones you would now make differently.

**That last exercise is the one that turns knowledge into judgement.**

## Where to go next

| Module | What it gives you |
|---|---|
| **Module 00 · Basics** | Warehouse vs lake vs lakehouse, the whole AWS data landscape, who can read and write what |
| **Module 02 · Foundation** | The medallion architecture and the Tamimi build in detail |
| **Module 03 · Foundation Architectures** | 35 architecture diagrams — the as-built and the target state |

Then build something and break it in dev. Nothing in this module substitutes for having watched `DS_BCAST_INNER` disappear from your own plan.

## Checklist

- [ ] I know whether we are serverless or provisioned, and why
- [ ] A max-RPU ceiling and a billing alarm exist
- [ ] The workgroup has a query timeout
- [ ] I can name the two line items that are most of the bill
- [ ] I have run the compute-by-user query and know who drives cost
- [ ] Repeated dashboard aggregates are materialized
- [ ] I can recite the ten things without looking
- [ ] I have a 90-day plan and a date in the calendar to revisit my key choices

## You've got it when you can…

…sit in a design review, be shown a proposed fact table, and ask the right four questions about it — distribution, sort, `VARCHAR` widths, and how the load reruns — before anyone has written a line of SQL.

---

**End of Module 01.** 45 lessons across seven parts: the mental model, the objects, physical design, loading, querying, code, and operations.

*Author: Surender Sara · Northbay Solutions*
