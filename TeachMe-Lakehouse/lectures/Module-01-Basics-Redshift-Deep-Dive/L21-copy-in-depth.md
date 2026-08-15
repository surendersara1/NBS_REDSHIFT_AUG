# L21 · COPY In Depth

> **Module 01 · Lesson 21** · ~45 min

**Slide:** [`_render/L21-copy-in-depth.html`](_render/L21-copy-in-depth.html)

## What it is

`COPY` is the only load path that scales. Every slice reads its **own file** in parallel — which is why the number of files matters as much as the SQL.

One enormous file is read by one slice while the rest idle. That is the most common reason a load is slow, and it has nothing to do with Redshift.

## File count and size — the biggest factor

| | Result |
|---|---|
| 1 file, 16 slices | 1 slice works, 15 idle |
| 16 files, 16 slices | all 16 work |
| 160 files, 16 slices | all work, 10 rounds — fine |
| 100,000 tiny files | overhead dominates, slower than one big file |

**Target:** a multiple of your slice count, each roughly **100 MB – 1 GB compressed**.

```sql
SELECT COUNT(*) AS slices FROM stv_slices WHERE type = 'D';
```

## The formats

### Parquet — prefer this

```sql
COPY staging.sales_line
FROM 's3://bucket/raw/sales/dt=2026-08-12/'
IAM_ROLE 'arn:aws:iam::123456789012:role/rs-loader'
FORMAT AS PARQUET;
```

Typed and columnar, so there is no parsing, no delimiter ambiguity and no date-format guessing. Column names must match, and types must be compatible.

### CSV — needs more said out loud

```sql
COPY staging.sales_line
FROM 's3://bucket/raw/sales/dt=2026-08-12/'
IAM_ROLE 'arn:aws:iam::123456789012:role/rs-loader'
CSV
IGNOREHEADER 1
GZIP
DATEFORMAT   'auto'
TIMEFORMAT   'auto'
BLANKSASNULL
EMPTYASNULL
TRUNCATECOLUMNS;
```

| Option | Why |
|---|---|
| `CSV` | understands quoting — use this, not `DELIMITER ','` |
| `IGNOREHEADER 1` | skip the header row |
| `GZIP` / `BZIP2` / `ZSTD` | compressed input |
| `BLANKSASNULL` | an empty field becomes `NULL`, not `''` |
| `EMPTYASNULL` | same for empty strings |
| `TRUNCATECOLUMNS` | ⚠️ silently truncates over-long values — survey only |
| `MAXERROR n` | ⚠️ tolerate n bad rows — survey only |

### JSON

```sql
COPY bronze.orders (payload)
FROM 's3://bucket/orders/dt=2026-08-12/'
IAM_ROLE '...'
FORMAT AS JSON 'auto'
SERIALIZETOJSON;
```

## A manifest, for exactness

A prefix loads **whatever happens to be there**. A manifest names the exact files:

```json
{
  "entries": [
    {"url": "s3://bucket/raw/sales/part-0000.parquet", "mandatory": true},
    {"url": "s3://bucket/raw/sales/part-0001.parquet", "mandatory": true}
  ]
}
```

```sql
COPY staging.sales_line
FROM 's3://bucket/manifests/2026-08-12.json'
IAM_ROLE '...'
FORMAT AS PARQUET
MANIFEST;
```

**This is what makes a load reproducible.** If someone drops an extra file into the prefix, a prefix-based load silently includes it; a manifest-based load does not.

## Automatic compression — first load only

`COPY` into an **empty** table with no declared encodings samples the incoming data and applies compression. Into a populated table, it does not (L17).

So the pattern for a new table is: create it, `COPY` once into it empty, then check what encodings it picked.

## Verify every load

```sql
-- what did the load actually do?
SELECT query, filename, lines_scanned, is_partial
FROM   stl_load_commits
WHERE  query = pg_last_query_id()
ORDER  BY filename;

-- row count sanity
SELECT COUNT(*) FROM staging.sales_line;

-- how long, and how much was queued?
SELECT elapsed_time/1000000.0 AS secs, queue_time/1000000.0 AS queued
FROM   sys_query_history
WHERE  query_id = pg_last_query_id();
```

## Gotchas

- **`COPY` is not idempotent.** Running it twice loads the rows twice. Always stage, then `MERGE` (L24).
- **Never `COPY` straight into a live table.** A partial failure leaves nothing, but a *successful duplicate* leaves a mess.
- **A prefix picks up files you did not expect** — use a manifest for anything that matters.
- **`MAXERROR` and `TRUNCATECOLUMNS` hide problems.** Use them to survey a new feed, never in production.
- **The IAM role needs `kms:Decrypt`** if the bucket is encrypted, not just `s3:GetObject`.

## Checklist

- [ ] File count is a multiple of the slice count
- [ ] Files are roughly 100 MB – 1 GB compressed
- [ ] Parquet where I control the producer
- [ ] `CSV` option, not `DELIMITER`, for delimited files
- [ ] `BLANKSASNULL` and `EMPTYASNULL` set for CSV
- [ ] Manifest used where reproducibility matters
- [ ] No `MAXERROR` or `TRUNCATECOLUMNS` in production
- [ ] `COPY` targets staging, never a live table

## You've got it when you can…

…be told a load takes four hours, ask two questions — how many files, and how many slices — and fix it before looking at anything else.
