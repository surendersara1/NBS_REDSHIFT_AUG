# L12 · External Schemas

> **Module 01 · Lesson 12** · ~35 min

**Slide:** [`_render/L12-external-schemas.html`](_render/L12-external-schemas.html)

## What it is

An external schema is a **pointer, not a copy**. The table appears in Redshift and you query it with ordinary SQL, joined to local tables in one statement — but the bytes never move.

Which means: **the cost moves, it does not vanish.** You have swapped a storage bill and a load job for a per-query bill somewhere else.

## Two kinds

### Spectrum → S3

```sql
CREATE EXTERNAL SCHEMA lake_ext
FROM DATA CATALOG
DATABASE 'silver'
IAM_ROLE 'arn:aws:iam::123456789012:role/redshift-spectrum';
```

Reads files in the lake through the Glue Data Catalog. Formats: Parquet, ORC, CSV, JSON, Avro — plus the transactional table formats **Iceberg**, **Hudi Copy-on-Write** and **Delta Lake** (via symlink manifests).

### Federated → a live database

```sql
CREATE EXTERNAL SCHEMA live_pg
FROM POSTGRES
DATABASE 'orders' SCHEMA 'public'
URI 'my-aurora.cluster-abc123.eu-west-1.rds.amazonaws.com'
IAM_ROLE   'arn:aws:iam::...:role/redshift-federated'
SECRET_ARN 'arn:aws:secretsmanager:...:secret:orders-ro';
```

Reads a live RDS or Aurora **PostgreSQL or MySQL** database as it is right now, with filters pushed down to the source.

## Then join it like anything else

```sql
SELECT f.sale_date, s.region, SUM(f.net_amount) AS net
FROM   gold.fct_sales_line f
JOIN   lake_ext.dim_store  s USING (store_sk)
WHERE  f.sale_date >= '2026-01-01'
GROUP  BY 1, 2;
```

One statement, two storage systems. That is the whole appeal.

## Governance moves too

This is the part that produces the most confusing bugs:

| Object | Governed by |
|---|---|
| Redshift-native tables | Redshift `GRANT` |
| Anything read via the catalog | **AWS Lake Formation** |

*"It works in Athena but not in Redshift"* — or the reverse — is almost always these two systems disagreeing. When you debug an access problem, first establish **which system owns the object**.

## Try it

```sql
-- what external schemas exist, and where do they point?
SELECT schemaname, esoptions
FROM   svv_external_schemas;

-- what tables are visible through them?
SELECT schemaname, tablename, location, input_format
FROM   svv_external_tables
ORDER  BY 1, 2;

-- how much did that external query actually scan?
SELECT query, SUM(s3_scanned_bytes) / 1024 / 1024 AS mb_scanned,
       SUM(s3scanned_rows)                        AS rows_scanned
FROM   svl_s3query_summary
WHERE  query = pg_last_query_id()
GROUP  BY 1;
```

That last query is the one that turns "Spectrum is free" into a number.

## When to point rather than load

| Point at it | Load it |
|---|---|
| scanned rarely | joined hard and often |
| very large, cold history | the reporting layer |
| you want one copy | you need sort keys and co-location |

**Copy what you join hard. Point at what you scan rarely.** And never point a federated query at a production database for a report that runs hourly — you have just made someone else's OLTP system your reporting engine.

## Gotchas

- **Spectrum's write support is narrow and format-dependent.** Read support is broad; do not assume symmetry. Verify before promising anyone a write path.
- **External tables have no zone maps of their own** — performance depends entirely on how the files are partitioned and formatted.
- **Predicate pushdown works on federated queries**, but a large scan is still a large scan against production.
- **The IAM role needs both catalog and S3 permissions**, and a KMS grant if the bucket is encrypted.

## Checklist

- [ ] I can write both `CREATE EXTERNAL SCHEMA` forms
- [ ] I know which grant system governs which kind of object
- [ ] I can measure what a Spectrum query scanned
- [ ] I would refuse a federated query behind an hourly report
- [ ] I verify write support rather than assuming it

## You've got it when you can…

…be asked to "just point Redshift at the production orders database" for a daily report, explain precisely what that does to production, and offer the right alternative.
