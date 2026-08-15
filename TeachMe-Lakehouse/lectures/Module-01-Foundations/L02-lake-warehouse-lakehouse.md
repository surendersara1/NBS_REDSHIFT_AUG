# L02 · Lake vs Warehouse vs Lakehouse
> **Module 1 · Lesson 02** · ~45 min

## The point
A lake is cheap and dumb, a warehouse is fast and strict, and a lakehouse is the folder of files that has been taught to behave like a database — which is what we built.

## Key ideas
- **Data lake** = files on object storage. Cheapest, accepts anything, no schema until something reads it — and slow, because answering anything means scanning whole files.
- **Data warehouse** = a database that owns its bytes. Fastest and best governed, but you pay for storage *and* compute, and it can only answer questions about data you loaded into it first.
- **Lakehouse** = open files in the lake + a table layer on top + engines that can read them. Lake storage price, warehouse-shaped reads.
- The trade-off axes worth memorising: **cost · flexibility · speed · schema · governance**.
- We use all three ideas at once: **S3 Tables** for lake economics, **Redshift Serverless** for warehouse speed, **Iceberg** as the bridge that lets Redshift read files it does not own.
- Bronze and Silver stay open files on S3 Tables; Gold is materialised as native Redshift tables because that last hop is where speed is bought.
- The cost of a lakehouse is operational: more moving parts (catalog, table format, grants) than a single database.

## Words you'll hear
| Term | Means |
|---|---|
| Object storage | S3 — cheap, durable, dumb; you PUT and GET whole files |
| Table format | the metadata layer that makes a folder of files act like a table (Lesson 06/07) |
| Catalog | the directory that tells engines which tables exist and where |
| MPP | massively parallel processing — many nodes answering one query |
| Open format | data readable by any engine, not locked inside one vendor |

## In this repo
- `infra/modules/s3-data-lake/main.tf` — the Bronze and Silver **S3 Tables** buckets: lake economics with AWS-managed Iceberg maintenance.
- `infra/modules/redshift-serverless/` — the warehouse that serves Gold and Power BI.
- `infra/modules/catalog_federation/` — the federated Glue catalog that lets Redshift see lake tables.
- `src/glue/glue_engine/writers/s3_tables.py` — where we actually write lakehouse tables.
- `src/dbt/models/marts/gold/` — the part that lives *inside* the warehouse.

## Do this
Open `infra/modules/s3-data-lake/main.tf` and `infra/modules/redshift-serverless/main.tf` side by side, and say out loud which layer of our pipeline each one stores.

## You've got it when you can...
Name one question you would answer from S3 Tables and one you would answer from Redshift — and say why putting either in the other place would cost more or run slower.
