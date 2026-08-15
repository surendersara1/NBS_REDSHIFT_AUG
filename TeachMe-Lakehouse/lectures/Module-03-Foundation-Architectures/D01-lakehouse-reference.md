# D01 · The Lakehouse Reference Architecture

> **Module 3 · Architecture 01** · ~15 min

**Diagram:** [`_render/D01-lakehouse-reference.html`](_render/D01-lakehouse-reference.html)

## What it shows

The five-stop road that every other diagram in this module sits inside: **sources → ingest → lake → warehouse → consume**, with a cross-cutting band underneath that runs beneath all five, all of the time.

If you only ever draw one diagram on a whiteboard, draw this one.

## The five columns

**Sources.** On-prem databases, SaaS APIs and file drops — five different *classes*, not eight different problems (D19 in Module 0, D16 here). On-prem access arrives over VPN or Direct Connect, which is procurement with weeks of lead time, not a coding task.

**Ingest.** Glue for batch, DMS for CDC, zero-ETL where it fits, Transfer Family for files, Firehose if anything ever streams. One connector class per source class; one spec per table.

**Lake — S3 + Iceberg.** `raw/` lands immutable and is never edited. `bronze/` is typed and deduplicated. `silver/` is conformed and joined. All on S3 Tables, all MERGE-loaded on a key, all governed through the catalog. **One copy of the data.**

**Warehouse.** Redshift Serverless holds `gold/` — modelled facts and dimensions built by dbt. Spectrum reads silver *in place* rather than loading it. The control plane records what happened.

**Consume.** Power BI and QuickSight read reporting views, never base tables. Athena is for the questions nobody anticipated. `UNLOAD` publishes gold back to S3 so cheaper engines can read it without touching the warehouse.

## The band underneath

| Layer | Service |
|---|---|
| Catalog | **Glue Data Catalog**, federated (D06) |
| Access control | **Lake Formation** — catalog / database / table / column |
| Orchestration | **Step Functions + EventBridge** (D25) |
| Observability | **CloudWatch** (D26) |
| All of it, as code | **Terraform** (D13) |

These are not a footnote. They are what makes five columns a platform rather than five projects sharing a bucket.

## How to read it in a meeting

Left to right is the **data path**. Bottom to top is the **control path**. Almost every question is one of four:

- *"Where does X land?"* → a column
- *"Who can see it?"* → Lake Formation
- *"How do I know it ran?"* → orchestration and observability
- *"What happens when it breaks?"* → isolation (D24 in Module 0) plus idempotency

Being able to point at the right box is most of the job.

## Checklist

- [ ] I can draw the five columns from memory
- [ ] I can name three services in each
- [ ] I can name the five cross-cutting layers
- [ ] I know which layer is loaded into Redshift and which is pointed at
- [ ] I can answer the four common questions by pointing

## You've got it when you can…

…draw this on a whiteboard in five minutes and answer "where would a new source go?" by pointing rather than thinking.
