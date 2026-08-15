# L32 · The Whole Thing, On One Slide

> **Module 0 · Lesson 32** · ~40 min

**Slide:** [`_render/L32-reference-architecture.html`](_render/L32-reference-architecture.html)

## What it is

Eight sources on the left, a dashboard on the right, and the name of an AWS service on every arrow between them.

Everything in this module appears somewhere on this slide. If a service on it is unfamiliar, the lesson number is on the diagram.

## The five columns

### Sources
Oracle RMS · Oracle SIM · Oracle XStore · Epsilon · MoEngage · Magento · Vemco · Irisys

On-prem, SaaS and files — **five different classes** (Lesson 19). On-prem access arrives over VPN or Direct Connect, which is procurement, not code, and belongs on the week-one critical path.

### Ingest
AWS Glue (Spark) · AWS DMS (CDC) · Zero-ETL integrations · Transfer Family · AppFlow · Firehose if streaming.

**One connector per class, one spec per table** (Lesson 20). The variety lives in configuration.

### Lake — S3 + Iceberg
- `raw/` — immutable landing, exactly as received
- `bronze/` — Iceberg, typed, deduplicated
- `silver/` — Iceberg, conformed, joined

On **Amazon S3 Tables** (managed Iceberg). Lifecycle moves cold partitions hot → IA → Glacier IR. Loads **MERGE on a key**, never blind append.

**One copy of the data; every engine reads it through the catalog.**

### Warehouse
Redshift Serverless holds `gold/` — facts and dimensions, built by dbt and MERGE-loaded, with materialized views for BI. **Spectrum reads silver in place** rather than loading it. RLS and CLS protect sensitive columns.

**Load what you join hard; point at the rest** (Lesson 18).

### Consume
Power BI · QuickSight · Athena for ad-hoc · SageMaker for ML · the ops console · `UNLOAD` back to S3 for other engines.

**BI reads views, never the underlying fact tables** (Lesson 15).

## Underneath all five columns, all of the time

| Layer | Service |
|---|---|
| Catalog | **Glue Data Catalog** (federated) |
| Access control | **Lake Formation** (catalog / database / table / column) |
| Orchestration | **Step Functions + EventBridge** |
| Observability | **CloudWatch** |
| Everything above, as code | **Terraform** |

These are not a footnote. They are what makes the five columns a platform rather than five projects that happen to share a bucket.

## How to read this diagram in an interview or a client meeting

Left to right is the **data path**. Bottom to top is the **control path**. Almost every question someone asks is one of:

- *"Where does X land?"* — a column
- *"Who is allowed to see it?"* — Lake Formation
- *"How do I know it ran?"* — orchestration and observability
- *"What happens when it breaks?"* — isolation (Lesson 24) plus idempotency (Lesson 11)

Being able to point at the right box is most of the job.

## Checklist

- [ ] I can draw the five columns from memory
- [ ] I can name at least three services in each column
- [ ] I can name the five cross-cutting layers
- [ ] I know which layer is loaded into Redshift and which is pointed at
- [ ] I can say where governance is enforced and by what
- [ ] I can answer the four common questions by pointing at a box

## You've got it when you can…

…draw this on a whiteboard from memory in five minutes, and answer "where would a new source go?" by pointing rather than by thinking.
