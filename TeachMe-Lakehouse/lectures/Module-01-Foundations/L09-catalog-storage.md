# L09 · Where the Data Actually Lives
> **Module 1 · Lesson 09** · ~45 min · slide: `L09-catalog-storage.png`

## The point
Three different things get called "the database". They are **not** the same, and mixing them up is the most common beginner error.

## Key ideas
- **The catalog** (`s3tablescatalog`) is an *index*. It knows which tables exist and where — it holds **no data**.
- **The table format** (Apache Iceberg) is the *rulebook* that turns a pile of Parquet files into something with schema, atomic writes and updates.
- **The storage** (S3) is just *files*. Cheap, dumb, durable.
- **S3 Tables** = AWS running Iceberg for you — it manages compaction and maintenance on the physical bucket.
- **Writers** (Glue/Spark) and **readers** (Redshift) both go through the catalog to find the table, then touch the data directly.
- We use **no Glue Crawlers** — the federated catalog auto-mounts the S3 Tables buckets.
- Athena, Hive and Presto are **not used here**. Redshift is the query engine.

## Words you'll hear
| Term | Means |
|---|---|
| Catalog | The index of tables (Glue Data Catalog) |
| Federated catalog | A catalog that mounts another system's tables |
| Table format | The metadata rules over the files (Iceberg) |
| Manifest / snapshot | Iceberg's list of files and point-in-time version |
| Managed bucket | The physical S3 bucket AWS owns for S3 Tables |

## In this repo
- `infra/modules/catalog_federation/` — the federated Glue catalog + Lake Formation grants
- `infra/modules/s3-data-lake/main.tf:11,30` — the bronze + silver table buckets
- `src/glue/glue_engine/writers/s3_tables.py` — the Iceberg read/write layer
- `infra/modules/s3/main.tf` — the plain S3 buckets (raw, artifacts, audit)

## Do this
In `s3_tables.py`, find where a table's fully-qualified name is built. Explain which part is the catalog, which is the namespace and which is the table.

## You've got it when you can...
Explain, without using the word "database", what happens when Redshift is asked for a Silver table it has never seen before.
