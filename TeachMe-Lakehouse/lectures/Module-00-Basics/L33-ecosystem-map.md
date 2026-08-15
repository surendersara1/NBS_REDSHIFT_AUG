# L33 · The Whole AWS Analytics Stack

> **Module 0 · Lesson 33** · ~35 min · **the poster for the wall**

**Slide:** [`_render/L33-ecosystem-map.html`](_render/L33-ecosystem-map.html)

## What it is

Every service in this module, grouped by **what it is for**, each with a one-line "use this when".

Nobody memorises forty AWS services. You memorise **eight jobs**, and then look up which tool does the job you actually have today.

## The eight groups

### 1. Storage
Amazon S3 · S3 Tables (managed Iceberg) · Redshift Managed Storage · storage classes from hot to archive.
**Use when:** always. Everything ends up here.

### 2. Catalog & governance
Glue Data Catalog (federated) · Lake Formation · AWS RAM for cross-account shares · SageMaker Lakehouse.
**Use when:** more than one engine or more than one team reads the data. Which is immediately.

### 3. Ingest
AWS Glue · EMR for batch ETL · AWS DMS for CDC · zero-ETL integrations · AppFlow · Transfer Family · DataSync.
**Use when:** data has to move at all — see the decision table in Lesson 20.

### 4. Streaming
Kinesis Data Streams · Amazon MSK / Kafka · Data Firehose · Managed Flink · Glue streaming ETL.
**Use when:** seconds genuinely change a decision. Rarely, in retail reporting.

### 5. Query & compute
Amazon Redshift · Athena (serverless, reads **and** writes) · EMR and Glue Spark for heavy transforms · Spectrum and federated query for reading in place.
**Use when:** someone asks a question.

### 6. Orchestration
Step Functions · MWAA (Airflow) · Glue workflows · EventBridge.
**Use when:** more than one step has to run in a defined order — which is from the second job onward.

### 7. Consumption
Power BI and Tableau via JDBC · Amazon QuickSight · SageMaker and Redshift ML · Redshift Data API for applications.
**Use when:** a human or an application needs the answer.

### 8. Operations
CloudWatch for metrics, logs and alarms · CloudTrail for who did what · Cost Explorer and budgets · **Terraform for every box above, as code**.
**Use when:** from day one, not after go-live.

## How to actually use this

When you meet a new requirement, do not start from services. Start from the **job**:

1. Which of the eight groups does this need touch?
2. Within that group, what are the two or three candidates?
3. What separates them — latency, cost model, how managed, who operates it?

That sequence turns "which of forty services?" into "which of three?", every time.

## The one to notice

**Operations is a group, not an afterthought.** It is listed eighth because that is where teams put it, and it belongs first. A platform with no observability is not finished; it is undelivered with the invoice already sent.

## Checklist

- [ ] I can name the eight groups
- [ ] I can name three services in each group
- [ ] I know which group each service in this module belongs to
- [ ] I start from the job, not from the service
- [ ] I have this slide printed or saved somewhere I will see it
- [ ] I treat observability as part of the build, not a follow-up

## You've got it when you can…

…be given a requirement you have never seen and narrow it to two or three candidate services in under a minute — by naming the group first.
