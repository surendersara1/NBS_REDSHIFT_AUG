# L31 · One Query, Three Systems

> **Module 0 · Lesson 31** · ~40 min

**Slide:** [`_render/L31-external-schemas.html`](_render/L31-external-schemas.html)

## What it is

An **external schema is a pointer**. The table appears in your database and the bytes stay where they were.

Once you have four kinds of pointer, a single SQL statement can span the warehouse, the lake and a production database:

```sql
SELECT  s.region, d.month, SUM(f.net_amount), COUNT(DISTINCT c.customer_id)
FROM        gold.fct_sales_line   f            -- Redshift, loaded
JOIN        lake_ext.dim_store    s  USING (store_sk)   -- S3 / Iceberg, pointed at
JOIN        gold.dim_date         d  USING (date_sk)
LEFT JOIN   live_pg.customers     c  USING (customer_id) -- live Aurora, federated
GROUP BY 1, 2;
```

Three storage systems, one statement, no ETL between them. It is genuinely powerful and genuinely easy to misuse.

## Four doors

| Door | Reaches | Mechanism |
|---|---|---|
| **Redshift → S3** | the lake, via the catalog | Redshift Spectrum |
| **Redshift → live database** | RDS / Aurora PostgreSQL or MySQL | federated query, with predicate pushdown |
| **Athena → anything** | Redshift, DynamoDB, Snowflake and more | federated connectors (Lesson 30) |
| **Redshift → Redshift** | another warehouse, live | datashares, cross-account and cross-Region |

All four look like an ordinary schema in SQL. That is the point, and also the risk — nothing in the query text tells you which door you just opened.

## Who actually pays

| Door | The bill lands on |
|---|---|
| **Spectrum** | bytes scanned in S3, per query |
| **Federated query** | the production database, per query |
| **Datashare** | the consumer's own compute |
| **Athena connector** | Athena scan cost, plus the remote system |

**Never assume a pointer makes the work free.** The work still happens; it happens somewhere else, and often on someone else's budget or someone else's production system.

This is worth making explicit in design reviews, because the cost of a zero-copy design is invisible in the design and highly visible in month three.

## Spectrum's write support — flagged honestly

Spectrum's **read** support is broad and well documented: Parquet, ORC, CSV, JSON, Avro, plus Iceberg, Hudi Copy-on-Write and Delta Lake via symlink manifests.

Its **write** support is narrow and format-dependent. Before you promise anyone a write path through Spectrum, verify it for the specific format and table type you have — do not assume symmetry with reads.

The general pattern to prefer: **write with the engine that owns the table** (Glue/Spark or Athena for lake tables, Redshift for warehouse tables), and use external schemas for reading.

## In practice

- An external schema exposes S3 Tables data inside Redshift, so Redshift reads Iceberg it never loaded.
- **Gold is loaded, silver is pointed at** — which is Lesson 18's rule applied.
- Every external schema has a documented purpose and an expected query frequency, so that "someone pointed a dashboard at production" is caught in review rather than in an incident.

## Checklist

- [ ] I can name the four doors and what each reaches
- [ ] I can say who pays for each
- [ ] I can write an external schema definition for Spectrum and for federated query
- [ ] I know Spectrum's read formats, including the three table formats
- [ ] I would verify Spectrum write support rather than assume it
- [ ] I document what each external schema is for

## You've got it when you can…

…write a query spanning the warehouse, the lake and a live database — and then explain to the person paying the bill exactly which part of it costs what, and what would happen if it ran hourly.
