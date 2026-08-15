# D06 · The Federated Catalog

> **Module 3 · Architecture 06** · ~15 min

**Diagram:** [`_render/D06-federated-catalog.html`](_render/D06-federated-catalog.html)

## What it shows

Three layers: **engines on top, storage underneath, and one governed catalog in between** — which can now mount systems it does not own.

If your mental model of the Glue Data Catalog is "a place that remembers table schemas so Athena can query S3", it is several years out of date.

## Three levels, not one flat list

```
catalog . database . table
```

With **nested catalogs** allowed, so the hierarchy can mirror the shape of the system underneath.

## Two kinds of catalog

**Managed catalog** — one you create. AWS manages the data, stored in **S3** or **Redshift Managed Storage**. You own the tables and the storage.

**Federated catalog** — mounts a system that already exists. The tables appear and become queryable; **the bytes never move** and it remains the system of record. Someone else owns the storage.

## What you can mount

Amazon Redshift · DynamoDB · DocumentDB · MySQL · PostgreSQL · SQL Server · **Oracle** · Aurora MySQL · Aurora PostgreSQL · Google BigQuery · Snowflake · Microsoft Azure SQL — plus **S3 Tables** as `s3tablescatalog`.

**Oracle on that list matters for us.** It means Apparel Group's Oracle reference and lookup data could be *mounted* rather than ingested — a third option alongside a Glue pipeline and zero-ETL (D17), worth considering per table rather than per source.

## One governance plane

Lake Formation grants at **catalog → database → table → column**, and the grant is **enforced by every engine that reads through the catalog** — Athena, Spark, EMR, Redshift Spectrum. Define once, applies everywhere.

Compare the alternative: the same rule re-implemented in four places, drifting apart, with nobody able to say which one is authoritative.

## Any Iceberg-compatible engine

Because both the catalog and the table format are open, you query from whichever engine suits the job against **one copy** of the data. Athena to explore, Redshift to report, Spark to transform — no exports, no drift.

This is the **SageMaker Lakehouse architecture**: S3 data lakes and Redshift warehouses unified into one catalog.

> ⚠️ Naming in this area has moved recently (SageMaker Lakehouse / Unified Studio / DataZone). Check current AWS documentation before quoting product names in a client deck.

## Two gotchas

- **Lowercase identifiers.** The lakehouse architecture currently supports lowercase table, column and database names. Plan naming conventions accordingly — retrofitting is painful.
- **Prefer declarative registration to crawlers.** A crawler infers schema by sampling, so your table definition can change because the *data* changed, silently. Register explicitly and a schema change becomes a pull request.

## Checklist

- [ ] I can state the three levels
- [ ] I know the difference between managed and federated catalogs
- [ ] I can name at least six mountable sources
- [ ] I know Lake Formation grants are enforced across engines
- [ ] I know about the lowercase constraint
- [ ] I know why mature platforms avoid crawlers

## You've got it when you can…

…be asked "how do we get the Oracle reference tables into the lake?" and offer three real options — ingest, replicate, or mount — with the trade-offs of each.
