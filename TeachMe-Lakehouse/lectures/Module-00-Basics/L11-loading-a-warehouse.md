# L11 · Getting Rows In, Correctly

> **Module 0 · Lesson 11** · ~45 min

**Slide:** [`_render/L11-loading-a-warehouse.html`](_render/L11-loading-a-warehouse.html)

## What it is

Row-by-row `INSERT` is how you turn a warehouse into a very expensive, very slow database.

The reason is columnar storage. Every write touches and rewrites blocks. One `INSERT` of a million rows is cheap; a million `INSERT`s of one row is catastrophic. Application developers arrive with the opposite instinct, so this needs saying out loud.

Four patterns do it properly.

## 1. COPY — the bulk path

```sql
COPY stg_sales_line
FROM 's3://bucket/staging/sales_line/dt=2026-08-11/'
IAM_ROLE 'arn:aws:iam::...:role/redshift-loader'
FORMAT AS PARQUET;
```

Reads many files in parallel, one per slice. Orders of magnitude faster than `INSERT`, and the reason your landing job should produce *several* files rather than one enormous one.

`COPY` can also read from EMR, DynamoDB and a remote host over SSH — but S3 is the path you will use.

## 2. Stage first

Land into a **staging table**, validate it there, then move it. Never write half a load into a table someone is querying.

Staging also gives you somewhere to run your checks — row counts, null keys, unexpected values — while there is still an easy way to abandon the load.

## 3. MERGE — insert or update on a key

```sql
MERGE INTO fct_sales_line AS t
USING stg_sales_line AS s
ON t.merge_key = s.merge_key
WHEN MATCHED THEN UPDATE SET ...
WHEN NOT MATCHED THEN INSERT ...;
```

This is what makes a load **safe to run twice**. Without it, re-running yesterday's load doubles yesterday's data, and you find out from a dashboard.

## 4. One transaction

Wrap the move from staging into target in a single transaction so a reader never sees the table half-loaded. All of it, or none of it.

## Idempotency — the property that matters most

> **Re-running yesterday's load must produce exactly yesterday's table.**

Everything above exists to make that true. It matters because failures are normal: a source is late, a job dies mid-run, someone needs a backfill. If re-running is dangerous, every incident becomes a manual repair. If re-running is safe, incidents become a retry.

Test it deliberately: run a load twice on purpose and diff the result. Do it at table two, not table fifty.

## Rules of thumb

- `COPY` for bulk, `MERGE` for upsert
- Always stage, then merge or swap
- One transaction per load, not per row
- **Never** point an application at the warehouse as an OLTP store

## Maintenance

`VACUUM` reclaims space and re-sorts; `ANALYZE` refreshes statistics for the planner. Redshift automates much of this now, and Serverless more so — but "automated" is not "absent". Know that they exist, and check they are keeping up on your largest tables.

## In practice

- **dbt incremental models emit the `MERGE`** for you.
- `unique_key` in the model config is the merge key.
- Re-running a day is safe and expected — that is a design property we rely on, not a lucky accident.

## Checklist

- [ ] I can explain why row-by-row INSERT is wrong in a warehouse
- [ ] I can write a COPY from S3 and say why parallel files matter
- [ ] I always stage before touching a live table
- [ ] I can write a MERGE and explain what makes it idempotent
- [ ] I have actually tested that re-running a load is safe
- [ ] I know where `unique_key` is set in our dbt models

## You've got it when you can…

…be told at 7am that last night's load ran twice, check the merge key, and say with confidence whether there is a problem — rather than starting a manual reconciliation.
