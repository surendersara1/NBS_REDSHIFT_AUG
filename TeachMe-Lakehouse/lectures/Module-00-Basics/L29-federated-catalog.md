# L29 · The Catalog Is Now Federated

> **Module 0 · Lesson 29** · ~45 min · **most people's mental model here is out of date**

**Slide:** [`_render/L29-federated-catalog.html`](_render/L29-federated-catalog.html)

## What it is

The Glue Data Catalog is **no longer one flat list of databases**. If your mental model is "a place that remembers table schemas so Athena can query S3", it is several years behind.

It is now a **three-level hierarchy**:

```
catalog  .  database  .  table
```

with **nested catalogs** allowed, so the hierarchy can mirror the shape of the system underneath.

## Two kinds of catalog

### Managed catalog
A catalog you create. The data is managed for you, stored in either **Amazon S3** or **Redshift Managed Storage (RMS)**.

### Federated catalog
**Mounts an existing data source in place, without copying anything.** The tables appear in the catalog and become queryable; the bytes never move and the source system remains the system of record.

## What you can mount

| Source | |
|---|---|
| Amazon Redshift | Amazon DynamoDB |
| Amazon DocumentDB | MySQL |
| PostgreSQL | SQL Server |
| **Oracle** | Aurora MySQL |
| Aurora PostgreSQL | Google BigQuery |
| Snowflake | Microsoft Azure SQL |

Plus **Amazon S3 Tables**, which appears as `s3tablescatalog`.

Note **Oracle** on that list. For Apparel Group that means Oracle reference and lookup data could be *mounted* rather than ingested — a genuine third option alongside a Glue pipeline and zero-ETL (Lesson 21), and one worth considering per table rather than per source.

## One governance plane

**AWS Lake Formation** grants at **catalog → database → table → column** level, and — this is the part that makes it worth the complexity — the grant is **enforced by every engine that reads through the catalog**. Athena, Spark, EMR and Redshift Spectrum all honour it.

Define the permission once; it applies everywhere. Compare that to the alternative, which is the same rule re-implemented in four places and drifting apart.

## Any Iceberg-compatible engine

Because the catalog and the table format are open, you query in place from whichever engine suits the job — Athena for exploration, Redshift for reporting, Spark for heavy transformation — against **one copy** of the data.

This is the **SageMaker Lakehouse architecture**: S3 data lakes and Redshift warehouses unified into one catalog.

> ⚠️ Product naming in this area has moved recently (SageMaker Lakehouse, SageMaker Unified Studio, DataZone). Check the current names against AWS documentation before quoting them in a client deck.

## Gotchas

- **Lowercase identifiers.** The lakehouse architecture currently supports lowercase table, column and database names. Plan naming conventions accordingly — retrofitting this is painful.
- **Prefer declarative registration to crawlers.** A crawler infers schema by sampling, which means the schema can change because the data changed, silently. Mature platforms register tables explicitly so that a schema change is a pull request.
- **Partition projection beats crawling.** If partitions follow a predictable pattern, configure projection so the engine computes locations rather than listing or crawling them. Faster, cheaper, and it cannot fall behind.

## Checklist

- [ ] I can state the three levels of the hierarchy
- [ ] I know the difference between a managed and a federated catalog
- [ ] I can name at least six sources that can be mounted federated
- [ ] I know Lake Formation grants are enforced across engines
- [ ] I know the lowercase-identifier constraint
- [ ] I know why crawlers are avoided on mature platforms
- [ ] I would re-verify the product naming before quoting it externally

## You've got it when you can…

…be asked "how do we get the Oracle reference tables into the lake?" and offer three real options — ingest, replicate, or mount as a federated catalog — with the trade-offs of each.
