# D23 · Zero-ETL — And Where It Stops

> **Module 3 · Architecture 23 · deep dive** · ~20 min

**Diagram:** [`_render/D23-zero-etl-deep-dive.html`](_render/D23-zero-etl-deep-dive.html)

## What this pattern is for

Getting a source table into an analytical target **with no pipeline at all** — no job, no cluster, no code, nothing to schedule. You configure an integration; AWS keeps the two in step.

The most important thing on the diagram is the **red dashed arrow that stops short**. Knowing where zero-ETL cannot reach is what makes it usable rather than a trap.

## The eight steps

**1 · Pick a source.** Three families: AWS databases (Aurora MySQL/PostgreSQL, RDS MySQL, DynamoDB, Oracle Database@AWS), self-managed databases via DMS (Oracle, SQL Server, MySQL, PostgreSQL), and SaaS applications (Salesforce, SAP OData, ServiceNow, Zendesk, Zoho, Meta Ads).

**2 · Configure the integration.** Source authorisation on one side, an integration on the other. That is the whole operational surface — there is no code artefact to version and no cluster to size.

**3 · Data and schemas replicate.** Not just rows: **the schema comes too**. New columns appear without you doing anything, which is convenient and is also something to be aware of before it surprises a downstream model.

**4 · It lands in Redshift, source-shaped.** Column names, types and quirks exactly as the source has them. Zero-ETL replicates; it does not transform.

**5 · The limit that decides your architecture.** ⭐ **Self-managed database sources can only target a Redshift data warehouse** — not S3, not S3 Tables, not RMS. If your architecture lands everything in the lake first and models afterwards, this constraint may rule the option out for exactly the sources you most wanted it for.

**6 · AWS-native and SaaS sources have more targets.** Those can land in S3, S3 Tables or Redshift Managed Storage via the SageMaker Lakehouse architecture — so the same feature behaves quite differently depending on which family your source is in.

**7 · Shaping happens after landing, in SQL.** The transformation work does not disappear; it moves. Instead of Spark in the middle it becomes dbt on the other side. That may be a better fit for your team — it is a different place to put the work, not less work.

**8 · SaaS sources have a one-hour floor.** If someone wrote "near real-time" against a Salesforce or SAP feed, this is the number to put in front of them before the design is signed.

## When to choose it

**Choose zero-ETL when** the source shape is close enough to useful, the target is Redshift, and the value of never operating a pipeline outweighs the loss of in-flight control.

**Do not choose it when** you need medallion layering in the lake for a self-managed source, when the volume makes continuous replication expensive, or when heavy business logic has to run during ingestion.

## On Apparel Group

Three of eight sources are Oracle, and self-managed Oracle → Redshift is supported. That makes this a **real** alternative to hand-building Glue pipelines — see D17 for the three-way comparison.

The honest recommendation is a **spike on one Oracle source, measured**, before committing either way. XStore's volume argues for Glue; a small slow-changing reference table argues for zero-ETL, or for not ingesting it at all and mounting it as a federated catalog (D06).

## Checklist

- [ ] I know which of the three source families each source belongs to
- [ ] I know the target restriction for self-managed sources
- [ ] I have stated the SaaS latency floor to whoever wrote the requirement
- [ ] I have decided where transformation happens, and who owns it
- [ ] The choice was made per source, not once for the platform

## You've got it when you can…

…hear "let's just use zero-ETL for Oracle" and immediately name the one constraint that decides whether that is even possible for our architecture.
