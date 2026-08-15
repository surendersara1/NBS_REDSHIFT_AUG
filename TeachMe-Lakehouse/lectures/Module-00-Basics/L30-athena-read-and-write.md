# L30 · Athena Also Writes

> **Module 0 · Lesson 30** · ~40 min

**Slide:** [`_render/L30-athena-read-and-write.html`](_render/L30-athena-read-and-write.html)

## What it is

Athena is serverless SQL over the Glue Data Catalog. No cluster to start, no capacity to size, and you pay **per byte scanned**.

That pricing model is the single most important fact about it: **partitioning and Parquet are cost controls, not just performance tuning**. A badly shaped query is expensive, not merely slow, and that changes how people write SQL.

**"Athena is read-only" is the most common wrong belief in this whole stack.** It writes.

## What it reads

Anything in the catalog: S3 files, Iceberg tables, and — through connectors — Redshift, DynamoDB, Snowflake and others.

## What it writes

### CTAS — `CREATE TABLE AS SELECT`

```sql
CREATE TABLE silver.store_daily
WITH (format = 'PARQUET', partitioned_by = ARRAY['dt'])
AS SELECT ... FROM bronze.sales_line ...;
```

Writes a whole new table **and its files**. This is how people build lake tables without ever standing up Spark — a genuinely underused capability on smaller platforms.

### `INSERT INTO`

Appends to an existing table.

### Iceberg DML

On Iceberg tables you also get **`UPDATE`, `DELETE`, `MERGE` and time travel** — full row-level SQL against data in the lake.

### The write limits — know these before you design

- **100 partitions per CTAS or INSERT statement.** A backfill across two years of daily partitions cannot be one statement; it has to be chunked.
- **Not supported for bucketed tables.**

The 100-partition limit is the one that bites. It is not a reason to avoid Athena writes — it is a reason to write the loop.

## The two connector types — and the difference matters

Athena federated query comes in two flavours, and they are not equivalent:

| Type | How it works | Governance |
|---|---|---|
| **Athena data catalog federated connector** | a **Lambda function in your account** | cannot register as a Glue federated catalog → **no Lake Formation fine-grained control** |
| **Glue Data Catalog federated connector** | uses a **Glue connection** | registers as a federated catalog → **full Lake Formation control** |

**Prefer the Glue-connection type.** If governance matters at all — and on a platform holding PII it does — the Lambda-based type puts your access control outside the system that is supposed to own it.

## Cost governance

**Workgroups** let you cap bytes scanned per query and per workgroup, route results to a specific S3 location, and separate teams for cost attribution.

Set a per-query limit. It converts "someone ran an accidental cross join over the whole lake" from an invoice into an error message.

## In practice

- Athena is how you **inspect the lake by hand** — the first tool you reach for when investigating a number.
- Workgroups cap bytes scanned per query.
- It reads the **same catalog** as Glue, Redshift and EMR, so what you see in Athena is what the pipeline sees.

## Checklist

- [ ] I know Athena writes via CTAS and INSERT INTO
- [ ] I know Iceberg tables get full DML and time travel
- [ ] I know the 100-partition-per-statement limit
- [ ] I know there are two connector types and which one supports Lake Formation
- [ ] I have a per-query scan limit set on my workgroup
- [ ] I understand why per-byte pricing changes how SQL gets written

## You've got it when you can…

…be told "we need Spark to build that table" for a modest transformation, and correctly identify that a CTAS would do it — including whether the partition count fits in one statement.
