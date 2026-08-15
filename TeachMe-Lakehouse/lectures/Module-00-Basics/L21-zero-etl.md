# L21 · Zero-ETL: No Pipeline At All

> **Module 0 · Lesson 21** · ~45 min · **the lesson most likely to change a design decision**

**Slide:** [`_render/L21-zero-etl.html`](_render/L21-zero-etl.html)

## What it is

A **fully managed integration** that replicates transactional data **and schemas** from a source into a target, continuously and in near real time.

There is no job, no cluster, no code and nothing to schedule. You configure an integration between a source and a target, and AWS keeps them in step. That is the entire operational surface.

The reason this lesson matters is that most people's mental model of zero-ETL stopped at "Aurora to Redshift". It is now far broader than that.

## Sources — three families

### AWS databases
- Aurora MySQL
- Aurora PostgreSQL
- RDS MySQL
- **Amazon DynamoDB**
- **Oracle Database@AWS (ODB)**

### Self-managed databases — via AWS DMS
- **Oracle**
- SQL Server
- MySQL
- PostgreSQL

Your own instances, wherever they run.

### SaaS applications
- Salesforce
- Salesforce Marketing Cloud Account Engagement
- **SAP OData**
- ServiceNow
- Zendesk
- Zoho CRM
- Facebook Ads · Instagram Ads

## Targets

- **Amazon Redshift** data warehouse
- **Amazon S3** general-purpose bucket
- **Amazon S3 Tables**
- **Redshift Managed Storage**

The last three go via the **SageMaker Lakehouse architecture** — which means zero-ETL is not only a warehouse-loading tool. It can land into the lake.

## The limits that decide the design

Three of them, and each one can rule the option out:

1. **Self-managed database sources can replicate only to a Redshift data warehouse.** Not to S3, S3 Tables or RMS. If your architecture lands everything in the lake first, this is a genuine constraint.
2. **Application (SaaS) sources have a minimum latency of one hour.** If someone specified "near real-time" for a Salesforce feed, this is the number to put in front of them.
3. **It replicates. It does not transform.** Tables arrive source-shaped, with the source's column names, types and quirks. All shaping happens after landing.

## Why this matters to us

**Three of Apparel Group's eight sources are Oracle**, and self-managed Oracle → Redshift is now supported.

That makes zero-ETL a *credible alternative* to hand-building JDBC pipelines for those three sources, and the team should be able to argue it honestly rather than defaulting either way.

**Arguments for zero-ETL here:**
- No pipeline to build, test, deploy or operate for three large sources
- No watermark logic, and therefore no watermark bugs
- Near-real-time instead of daily, at no extra engineering cost

**Arguments for keeping Glue:**
- **Medallion layering.** Zero-ETL puts source-shaped tables in Redshift; our architecture wants typed, conformed Iceberg in the lake first. And self-managed sources cannot target S3 Tables.
- **Transformation control.** Business rules — the XStore receipt logic, VAT splitting, pack-size parsing — have to run somewhere. In a zero-ETL design they run in Redshift SQL instead of Spark, which is a different skill set and a different cost profile.
- **Cost at volume.** XStore is the giant. Continuous replication of a very large, high-churn table has an ongoing cost that a nightly batch does not.
- **One engine to operate.** A platform that is mostly Glue plus three zero-ETL integrations has two operational models, two monitoring stories and two failure vocabularies.

**The honest conclusion:** it is worth a spike on one Oracle source before committing either way. Do not decide it in a slide.

## Checklist

- [ ] I can name all three source families and give examples of each
- [ ] I know all four targets
- [ ] I know self-managed sources can only target Redshift
- [ ] I know SaaS sources have a one-hour minimum latency
- [ ] I know it replicates but does not transform
- [ ] I can argue both sides of zero-ETL versus Glue for an Oracle source

## You've got it when you can…

…be told "we'll build a Glue pipeline for Oracle" and raise zero-ETL as a real option with its actual limits attached — then help the team decide on evidence rather than on habit.
