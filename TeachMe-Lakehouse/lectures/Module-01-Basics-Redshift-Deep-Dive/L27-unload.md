# L27 · UNLOAD

> **Module 01 · Lesson 27** · ~30 min

**Slide:** [`_render/L27-unload.html`](_render/L27-unload.html)

## What it is

A **parallel write from every slice straight to S3** — the reverse of `COPY`, and the right way to move millions of rows out of Redshift.

The wrong way is to `SELECT` them through the leader node and over a client connection, which makes the leader the bottleneck (L05) and is slower by orders of magnitude.

## The statement

```sql
UNLOAD ('SELECT * FROM gold.fct_sales_line
         WHERE sale_date >= ''2026-08-01''')
TO 's3://bucket/published/sales/'
IAM_ROLE 'arn:aws:iam::123456789012:role/rs-unload'
FORMAT AS PARQUET
PARTITION BY (sale_date)
MANIFEST
CLEANPATH
MAXFILESIZE 256 MB;
```

Note the **doubled quotes** inside the query string — the whole query is a single-quoted literal.

## The options that matter

| Option | Why |
|---|---|
| `FORMAT AS PARQUET` | typed and columnar; types survive the round trip |
| `PARTITION BY (col)` | writes `col=value/` prefixes so Athena and Spectrum can prune |
| `PARALLEL ON` (default) | one file per slice — leave it on |
| `MAXFILESIZE 256 MB` | keeps files in the good range for re-reading (L21) |
| `MANIFEST` | lists exactly what was written |
| `CLEANPATH` | ⚠️ **deletes the target prefix first** |
| `HEADER` | CSV only |
| `GZIP` / `ZSTD` | CSV/text output compression |

`PARALLEL OFF` produces a single file and is dramatically slower. Only use it when something downstream genuinely cannot handle multiple files.

## Why this lesson exists

**Publishing gold back to S3 is what stops Redshift becoming the only door to the data.**

Once it is in Parquet on S3, Athena can query it, Spark can read it, a data scientist can open it in a notebook — none of which costs Redshift compute or a connection.

> **Every hand-maintained spreadsheet in a business is a door that was never built.**

When someone asks for "a weekly extract", the answer is a scheduled `UNLOAD` to a prefix they can read, not a CSV you email.

## Verify it

```sql
-- what did it write?
SELECT query, path, line_count, file_size
FROM   stl_unload_log
WHERE  query = pg_last_query_id()
ORDER  BY path;

-- total rows out
SELECT SUM(line_count) AS rows_unloaded
FROM   stl_unload_log
WHERE  query = pg_last_query_id();
```

## A scheduled publish

```sql
-- refresh yesterday's partition, replacing rather than appending
UNLOAD ('SELECT * FROM gold.fct_sales_line
         WHERE sale_date = CURRENT_DATE - 1')
TO 's3://bucket/published/sales/'
IAM_ROLE '...'
FORMAT AS PARQUET
PARTITION BY (sale_date)
ALLOWOVERWRITE;
```

`ALLOWOVERWRITE` replaces files at the same keys — which makes a re-run idempotent for that partition. `CLEANPATH` is the heavier hammer: it removes everything under the prefix first.

## Gotchas

- **`CLEANPATH` is a delete.** Point it at a dedicated prefix, never a shared one, and never at a bucket root. This is the most dangerous option in the statement.
- **Quotes inside the query must be doubled.** A single quote ends the literal.
- **Partition columns are removed from the file** and encoded in the path, which is normal but surprises people reading the Parquet directly.
- **The IAM role needs `s3:PutObject`**, plus `kms:GenerateDataKey` if the bucket is encrypted.
- **`UNLOAD` cannot write to a Redshift table.** It writes to S3 only.

## Checklist

- [ ] Large extracts use `UNLOAD`, never a client-side `SELECT`
- [ ] `FORMAT AS PARQUET` unless something downstream needs text
- [ ] `PARTITION BY` on the column consumers filter by
- [ ] `MAXFILESIZE` set so files are re-readable efficiently
- [ ] `CLEANPATH` only ever aimed at a dedicated prefix
- [ ] Gold is published back to S3 on a schedule
- [ ] Every recurring "please send me an extract" replaced by a prefix

## You've got it when you can…

…find someone maintaining a weekly CSV by hand, replace it with a scheduled `UNLOAD` to a prefix they can read directly, and explain why that is cheaper for everyone.
