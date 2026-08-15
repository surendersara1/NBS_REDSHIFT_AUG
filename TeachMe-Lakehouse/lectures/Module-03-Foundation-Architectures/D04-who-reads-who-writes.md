# D04 · Who Writes, Who Reads

> **Module 3 · Architecture 04** · ~15 min · **the reference diagram**

**Diagram:** [`_render/D04-who-reads-who-writes.html`](_render/D04-who-reads-who-writes.html)

## What it shows

Every path into and out of Redshift on one canvas: **eleven ways in, twelve ways out — and four the warehouse opens itself.**

Most people know three or four of these and assume the rest do not exist. That is how you end up with a Lambda holding a JDBC connection, or a weekly CSV export that somebody maintains by hand.

## Eleven ways in

`COPY` · `INSERT`/`MERGE` · JDBC/ODBC · Redshift Data API · Glue/Spark/EMR connector · AWS DMS · Data Firehose · streaming ingestion · zero-ETL · datashare with `--allow-writes` · Transfer Family and AppFlow

Two worth singling out:
- **Data API** — HTTP, no held connection, no driver. The right choice from Lambda and Step Functions, and the one people reach for JDBC instead of.
- **Streaming ingestion** — a materialized view mapped straight onto Kinesis or MSK, with **no S3 hop at all**.

## Twelve ways out

JDBC/ODBC · Data API · `UNLOAD` · Glue/Spark · Athena connector · Glue federated catalog · Power BI/QuickSight · SageMaker and Redshift ML — plus the four below.

**`UNLOAD` is the most overlooked thing on this diagram.** Publishing gold back to S3 as Parquet is what stops Redshift becoming the only door to the data. Every unofficial spreadsheet in an organisation started life as a missing exit.

## Four it opens itself

The direction people forget — Redshift is not only a destination:

| | Reaches |
|---|---|
| **Spectrum** | S3 external tables, through the catalog |
| **Federated query** | live RDS / Aurora PostgreSQL or MySQL |
| **Datashare** | another warehouse, live |
| **Lambda UDF** | a function, mid-query |

These are what make "get the data into Redshift" a *choice* rather than a prerequisite (D07).

## Three consequences

1. **You rarely need to invent a path.** If you are writing custom code to move data in or out, check this picture first.
2. **The security surface is bigger than the database password.** Eleven ways in means eleven things to govern (D19, D28).
3. **Zero-copy changes architecture.** Spectrum, federated query and datashares mean loading is a decision with a cost, not a default.

## Checklist

- [ ] I can name at least eight write paths
- [ ] I can name at least six read paths
- [ ] I know Redshift can read S3, live databases and other warehouses
- [ ] I know `UNLOAD` exists and what it prevents
- [ ] I use the Data API from Lambda, not JDBC
- [ ] I have this diagram somewhere I will see it

## You've got it when you can…

…be asked "how do we get X into Redshift?" and answer with the right mechanism and the reason — including the cases where the answer is "we don't; we point at it".
