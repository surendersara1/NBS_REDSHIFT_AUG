# L14 · Getting Data In

> **Module 0 · Lesson 14** · ~40 min

**Slide:** [`_render/L14-getting-data-in.html`](_render/L14-getting-data-in.html)

## What it is

Eleven write paths group into **four families**, and they are not interchangeable. Each family trades freshness against control:

> **The more managed the path, the less you get to change the data in flight.**

That sentence is the whole lesson. Say it before choosing.

## The four families

### 1. Bulk — hours

`COPY` from files staged on S3.

- Full transformation control: whatever wrote the files decided the shape
- Cheapest per row by a wide margin
- The default for anything above a few million rows
- Latency is however often you run it

### 2. Programmatic — seconds, small volumes

Redshift Data API, JDBC/ODBC, SQL issued by applications and orchestrators.

- Correct for small volumes: reference data, control-plane updates, a single corrected row
- Wrong for large volumes — see Lesson 11 on why row-by-row loading is fatal
- The **Data API** is the right choice from Lambda and Step Functions: no driver, no connection to hold open, no VPC plumbing

### 3. Managed replication — minutes to an hour

AWS DMS and zero-ETL integrations.

- Continuous, no code to write, no cluster to size
- Tables arrive **source-shaped** — you get what the source has, including its column names and its quirks
- **You give up the chance to transform on the way.** Any shaping happens after landing, inside the target

### 4. Streaming — seconds

Amazon Data Firehose and Redshift streaming ingestion.

- **Firehose** stages through S3 and then issues `COPY` — simple, no code, slight buffering delay
- **Streaming ingestion** maps a materialized view directly onto Kinesis or MSK with **no S3 staging at all** — lower latency, and the object you get is an MV (Lesson 12)

## Picking by latency

| Requirement | Mechanism |
|---|---|
| Daily or hourly batch | Glue → S3 → `COPY` |
| Continuous replication | DMS or zero-ETL |
| Seconds | Redshift streaming ingestion |
| A handful of rows from an app | Data API |

**Never:** an application writing rows one at a time into a warehouse. If an application needs to record events, it writes to a queue or a stream, and something else lands them in bulk.

## The trade to state out loud

Managed paths are genuinely attractive — no pipeline to build, nothing to page you at 3am. But they hand you the source's shape, and source shapes are rarely what a report wants.

The honest question is not "which is easiest?" but **"where does the transformation happen, and who owns it?"** With a managed path, the answer is "after landing, in the warehouse, in SQL." That may be fine. It is just a different place to put the work, not less work.

## In practice

- Glue writes Iceberg; **dbt builds gold**. Redshift is loaded by dbt, not directly by ingestion jobs.
- **One writer role.** Nothing else in the account holds `INSERT` on gold tables.
- That is deliberate: one way in means one place to look when a number is wrong.

## Checklist

- [ ] I can name the four families and their latencies
- [ ] I can state the freshness-versus-control trade in one sentence
- [ ] I know why the Data API beats JDBC from Lambda
- [ ] I know the difference between Firehose and streaming ingestion
- [ ] I would push back on an application writing rows directly
- [ ] I know which role is allowed to write our gold tables

## You've got it when you can…

…be given a new source and a freshness requirement, pick the family in under a minute, and explain what transformation control you are giving up by choosing it.
