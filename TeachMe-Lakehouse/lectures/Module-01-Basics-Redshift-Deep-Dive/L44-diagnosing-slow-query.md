# L44 · Diagnosing A Slow Query ⭐

> **Module 01 · Lesson 44** · ~50 min · **the playbook**

**Slide:** [`_render/L44-diagnosing-slow-query.html`](_render/L44-diagnosing-slow-query.html)

## What it is

**Six questions, in order.** Answer them in sequence and you will find the cause almost every time without guessing once.

Almost everyone starts by rewriting the SQL. **That is question six.** The first five are cheaper, faster to check, and usually where the answer is.

Print this page. Put it on the wall.

---

## Step 0 · Get the query_id and set up an honest measurement

```sql
-- find it
SELECT query_id, user_id, start_time,
       queue_time/1e6 AS q, execution_time/1e6 AS e, status,
       LEFT(query_text, 120) AS sql
FROM   sys_query_history
WHERE  start_time >= DATEADD('hour', -6, GETDATE())
ORDER  BY execution_time DESC
LIMIT  20;

-- then, before you time anything (L34)
SET enable_result_cache_for_session TO off;
```

Discard the first run — that is compilation. Compare the median of runs 2 and 3.

---

## Question 1 · Did it queue, or did it run slowly?

```sql
SELECT query_id, queue_time/1e6 AS queue_secs, execution_time/1e6 AS exec_secs, service_class
FROM   sys_query_history WHERE query_id = 123456;
```

| Result | Meaning | Go to |
|---|---|---|
| High queue, low exec | **A concurrency problem** | L41 — WLM, priorities, concurrency scaling. Stop here. |
| Low queue, high exec | A query problem | Question 2 |
| Both high | Two problems | Fix the query first; it shortens the queue |

**A queuing problem is not a SQL problem.** Rewriting the query will not help, and this is the most commonly misdiagnosed case in Redshift.

---

## Question 2 · Are the statistics stale?

```sql
SELECT "schema", "table", size AS mb, tbl_rows, stats_off
FROM   svv_table_info
WHERE  "table" IN ('fct_sales_line', 'dim_store', 'dim_product')
ORDER  BY stats_off DESC;
```

**`stats_off > 10` → `ANALYZE` and re-measure.** This is the cheapest fix that exists and it is the answer more often than anything else — especially for "it was fine last week".

```sql
ANALYZE gold.fct_sales_line (sale_date, store_sk);
```

The evidence that this was the problem: run `EXPLAIN` before and after and compare the **estimated row counts**. If the estimate was out by orders of magnitude, the planner was choosing badly on bad information.

---

## Question 3 · Is anything being broadcast?

```sql
EXPLAIN <the query>;
```

Search the plan for **`DS_BCAST_INNER`**. That is the whole table being copied to every node (L28).

```
XN Hash Join DS_BCAST_INNER  (cost=...)     ← found it
```

**The fix, in order (L29):**

1. `ANALYZE` — already done in question 2
2. `ALTER TABLE gold.dim_store ALTER DISTSTYLE ALL;` — if it is a small dimension
3. Align the `DISTKEY`s of two large tables on the join column
4. Check the join key types match exactly — a cast silently defeats co-location

Step 2 solves it most of the time and takes one statement.

---

## Question 4 · Is it spilling to disk?

```sql
SELECT stm, seg, step, label, rows, bytes,
       is_diskbased, workmem/1024/1024 AS workmem_mb
FROM   svl_query_summary
WHERE  query = 123456
ORDER  BY stm, seg, step;
```

**Any `is_diskbased = 't'` is your answer.** Memory ran out and the step went to disk, which is orders of magnitude slower.

Three causes, in order of likelihood:

1. **A broadcast** blew up the row count — go back to question 3
2. **Oversized `VARCHAR`s.** Redshift allocates by declared width, not actual content. A `VARCHAR(65535)` holding 20 characters still reserves 64 KB per row in memory (L09):
   ```sql
   SELECT "table", max_varchar FROM svv_table_info WHERE max_varchar > 1000 ORDER BY 2 DESC;
   ```
3. **Too many WLM slots** — each query got a smaller memory share (L41)

Also visible in query history:

```sql
SELECT query_id, LEFT(query_text,60) FROM sys_query_history
WHERE  start_time >= DATEADD('day',-1,GETDATE())
ORDER  BY execution_time DESC LIMIT 10;
-- then check svl_query_summary for each
```

---

## Question 5 · Is it scanning more than it needs?

```sql
SELECT slice, tbl, rows, rows_pre_filter,
       ROUND(100.0 * rows / NULLIF(rows_pre_filter,0), 1) AS pct_kept,
       is_rrscan
FROM   stl_scan
WHERE  query = 123456 AND userid > 1
ORDER  BY rows_pre_filter DESC;
```

**`rows_pre_filter` is how many rows were read; `rows` is how many survived.** A ratio of 1% means you read 100× more than you used — the zone maps are not pruning (L16).

Causes:

- **A function wraps the sort column** in the `WHERE` — `DATE_TRUNC('month', sale_date) = ...` (L32). Rewrite as a bare-column range.
- **The `SORTKEY` is on the wrong column** for how the table is actually queried.
- **The table is badly unsorted** — check `unsorted` and `vacuum_sort_benefit` (L42).

Also check **skew** while you are here:

```sql
SELECT "table", skew_rows FROM svv_table_info WHERE skew_rows > 4 ORDER BY 2 DESC;
```

`skew_rows > 4` means one slice holds four times the rows of another, so one node does most of the work while the rest wait. A bad `DISTKEY` (L15).

---

## Question 6 · Only now, rewrite the SQL

If questions 1–5 all came back clean, the query itself is the problem. In rough order of payoff:

- **Aggregate before joining.** Join two million-row summaries, not two billion-row facts.
- **Filter earlier**, inside the CTE that scans the table (L31).
- **Remove correlated subqueries** — they become per-row loops (L31).
- **Replace self-joins with window functions** (L30).
- **`NOT EXISTS` instead of `NOT IN`** (L31).
- **Select only the columns you need.** `SELECT *` on a columnar store reads every column (L01).
- **Consider a materialized view** if this is a repeated dashboard query (L11).

**Confirm with `EXPLAIN`, not a stopwatch.** A faster time with an identical plan is noise or cache.

---

## The whole playbook as one script

```sql
-- ============ REDSHIFT SLOW QUERY PLAYBOOK · substitute your query_id ============
\set qid 123456

-- 1. queue or execution?
SELECT query_id, queue_time/1e6 q_secs, execution_time/1e6 e_secs, service_class, status
FROM   sys_query_history WHERE query_id = :qid;

-- 2. stale stats?
SELECT "schema","table",size mb,tbl_rows,stats_off,unsorted,skew_rows,max_varchar,
       vacuum_sort_benefit
FROM   svv_table_info
WHERE  stats_off > 5 OR unsorted > 10 OR skew_rows > 4
ORDER  BY size DESC;

-- 3. broadcast?  -> run EXPLAIN and grep for DS_BCAST_INNER

-- 4. spill?
SELECT stm,seg,step,label,rows,is_diskbased,workmem/1024/1024 wm_mb
FROM   svl_query_summary WHERE query = :qid ORDER BY stm,seg,step;

-- 5. scan efficiency?
SELECT tbl,SUM(rows) kept,SUM(rows_pre_filter) read,
       ROUND(100.0*SUM(rows)/NULLIF(SUM(rows_pre_filter),0),1) pct
FROM   stl_scan WHERE query = :qid AND userid > 1 GROUP BY tbl;

-- 6. only now, the SQL.
```

Save it as `ops/slow-query.sql` in the repo.

## The four causes, ranked by how often they are the answer

From experience across real clusters, roughly:

1. **Stale statistics** — `ANALYZE`
2. **A broadcast join** — `DISTSTYLE ALL` on the small side
3. **Disk spill from oversized `VARCHAR`s** — fix the DDL
4. **A non-sargable date predicate** — rewrite as a bare-column range

**All four are fixed without touching the query's logic.** That is why question 6 is last.

## Gotchas

- **The first run includes compilation.** Time the second, with the result cache off.
- **Change one thing at a time and re-measure.** Two changes at once tells you nothing.
- **Confirm with `EXPLAIN`.** A better time with the same plan is not a fix.
- **`userid > 1`** in `stl_scan` or you will drown in system rows.
- **Times are microseconds.**
- **The plan can change under you** — an `ANALYZE` between two `EXPLAIN`s is a variable, so note when you ran it.
- **A query that is slow only in production** is usually a data-volume or concurrency difference, not a SQL difference.
- **Do not tune around a broken design.** If a fact table is `DISTSTYLE EVEN` and joined constantly on `store_sk`, no amount of query tuning fixes it — rebuild it (L42).

## Try it

Do this as a group exercise, on a real slow query:

1. One person drives, everyone else watches the six questions in order.
2. Write down the answer to each question before moving on.
3. Whoever suggests rewriting the SQL before question 6 buys the coffee.
4. When you find the cause, fix it, re-measure with the cache off, and confirm with `EXPLAIN`.
5. Write the diagnosis in a one-paragraph note in the repo — what was slow, what the cause was, what fixed it.

That last step builds the institutional memory that stops the same problem recurring.

## Checklist

- [ ] I have the six questions memorised, in order
- [ ] Result cache off before any measurement
- [ ] First run discarded
- [ ] Question 1 answered before touching the SQL
- [ ] `ops/slow-query.sql` saved in the repo
- [ ] One change at a time, re-measured each time
- [ ] Every fix confirmed with `EXPLAIN`
- [ ] Diagnoses written down where the team can find them

## You've got it when you can…

…be handed a query that got slow, work the six questions out loud in front of the team, and reach the cause without once saying "let me try changing this and see".
