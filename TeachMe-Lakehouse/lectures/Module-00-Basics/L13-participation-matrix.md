# L13 · Everything That Touches Redshift

> **Module 0 · Lesson 13** · ~50 min · **the reference lesson — keep this one**

**Slide:** [`_render/L13-participation-matrix.html`](_render/L13-participation-matrix.html)

## What it is

Redshift is not a locked box with one door. It is a building with **eleven loading bays, eight exits, and windows it can see out of**.

Most people know two or three of these paths and assume the rest do not exist — which is how you end up building a Lambda that opens a JDBC connection, or exporting to CSV because nobody knew `UNLOAD` existed.

This is the full matrix. Blue writes, green reads.

## Writes into Redshift — eleven paths

| Path | What it is | Use it for |
|---|---|---|
| **`COPY`** | bulk load from S3, EMR, DynamoDB or a remote host | the main load path — anything above a few million rows |
| **`INSERT` · `MERGE` · `CTAS`** | ordinary SQL inside the warehouse | transformations between warehouse tables |
| **JDBC / ODBC** | clients and Query Editor v2 | manual fixes, small reference data — never bulk |
| **Redshift Data API** | HTTP/SDK, no held connection | Lambda, Step Functions, applications |
| **Glue · Spark · EMR connector** | writes DataFrames straight in | Spark ETL that ends in the warehouse |
| **AWS DMS** | Redshift as a target endpoint | full load, then continuous CDC (Lesson 22) |
| **Amazon Data Firehose** | stages to S3, then issues `COPY` | streaming, with no code |
| **Redshift streaming ingestion** | a materialized view on Kinesis or MSK | streaming with **no S3 staging** (Lesson 23) |
| **Zero-ETL integration** | fully managed replication | source tables you want mirrored, no pipeline (Lesson 21) |
| **Datashare with `--allow-writes`** | a consumer writes to producer data | cross-account write scenarios (Lesson 16) |
| **Amazon AppFlow** | scheduled SaaS objects | SaaS sources you would rather not code |

## Reads from Redshift — eight paths

| Path | What it is |
|---|---|
| **JDBC / ODBC** | humans, ad-hoc SQL, Query Editor v2 |
| **Redshift Data API** | applications and Lambda, without a driver |
| **`UNLOAD` to S3** | publish gold data back to the lake as Parquet |
| **Glue · Spark · EMR connector** | read frames out for ETL and ML |
| **Athena Redshift connector** | Athena queries Redshift tables |
| **Glue federated catalog over Redshift** | catalog engines read it, governed by Lake Formation |
| **Power BI · QuickSight · Tableau** | the consumption layer |
| **Redshift ML · SageMaker** | training reads; inference writes back |

## Redshift as a client — it reads other systems too

The direction people forget. Redshift is not only a destination.

| Path | Reaches |
|---|---|
| **Spectrum** | S3 external tables, through the catalog |
| **Federated query** | live RDS / Aurora PostgreSQL or MySQL |
| **Datashare** | another Redshift namespace, live |
| **Lambda UDF** | calls a function part-way through a query |

## Why this matters

Three practical consequences:

1. **You rarely need to invent a path.** If you are writing custom code to get data in or out, check this list first — the odds are good that a managed path exists.
2. **Security surface is bigger than "the database password".** Eleven ways in means eleven things to govern, which is Lesson 17.
3. **The zero-copy paths change architecture.** Spectrum, federated query and datashares mean "get the data into Redshift" is a *choice*, not a prerequisite — which is Lesson 18.

## Checklist

- [ ] I can name at least eight write paths without looking
- [ ] I can name at least six read paths
- [ ] I know Redshift can read S3, live databases and other warehouses
- [ ] I know `UNLOAD` exists and what it is for
- [ ] I know the Data API is the right choice from Lambda
- [ ] I have a photo or printout of this matrix

## You've got it when you can…

…be asked "how do we get X into Redshift?" and answer with the *right* mechanism and the reason — including the cases where the answer is "we don't; we point at it instead."
