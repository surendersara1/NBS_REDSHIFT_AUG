# L20 · Six Ways To Move Data

> **Module 0 · Lesson 20** · ~45 min · **the table you will argue from**

**Slide:** [`_render/L20-six-ways-to-move-data.html`](_render/L20-six-ways-to-move-data.html)

## The decision table

| Mechanism | AWS service | Latency | Choose it when |
|---|---|---|---|
| **Batch ETL** | AWS Glue · EMR (Spark) | hours | you need to transform on the way and control the shape |
| **CDC replication** | AWS DMS | minutes | continuous replication between two different engines |
| **Zero-ETL** | managed integration | minutes – 1 hr | you want the table in the target with **no pipeline at all** |
| **Federated query** | Redshift · Athena | live | a small lookup against a live database, with no copy |
| **Streaming** | Kinesis · MSK · Firehose | seconds | genuinely event-driven data, where seconds change a decision |
| **File transfer** | Transfer Family · DataSync · AppFlow | scheduled | SFTP drops, NAS sync and SaaS connectors you would rather not code |

## The rule

> **Pick the latency you actually need, then take the most managed option that still gives you it.**

Latency improves down the list. The control you keep gets worse. Those two facts move together and there is no configuration that separates them.

## Notes on each

### Batch ETL — the default for a medallion lakehouse
You own the code, so you own the shape. This is why bronze and silver can be conformed, deduplicated and typed rather than mirroring source quirks. Cheapest per row at volume.

### CDC replication — reads the log, not the tables
DMS reads the source's redo/WAL/binlog, so it adds almost no query load to the source. It catches hard deletes, which a watermark pull cannot. Lesson 22.

### Zero-ETL — far broader than most people know
Oracle, SQL Server, MySQL, PostgreSQL, DynamoDB, SAP OData, Salesforce, ServiceNow and more. Targets include Redshift, S3, S3 Tables and RMS. Lesson 21 has the full matrix and the limits — read it before you rule this out.

### Federated query — live, but the source pays
Filters push down. Large scans do not. Fine for a lookup, dangerous for a report. Lesson 16.

### Streaming — most retail reporting does not need this
Kept in the course so you can recognise the minority of cases that genuinely do. Lesson 23.

### File transfer — the boring one that quietly works
Transfer Family for SFTP, DataSync for filesystem sync, AppFlow for SaaS objects. No cluster, no code, and it will still be running unattended in three years.

## How to use this in a design review

Work down the columns in this order:

1. **What latency does the decision actually need?** Not what someone asked for — what the decision being made needs. "Real-time" usually means "not yesterday's".
2. **Does the shape need to change on the way?** If yes, managed replication is out for that source.
3. **Who operates it at 3am?** A path with no code has no code to debug, and that has real value.
4. **What does it cost when volume triples?** Per-row costs scale differently from always-on costs.

## In practice

For the Apparel Group build, the interesting comparison is **batch ETL versus zero-ETL for the three Oracle sources**. That is a real decision with real arguments on both sides, and Lesson 21 sets it out properly.

## Checklist

- [ ] I can reproduce the six-row table from memory
- [ ] I can state the latency-versus-control rule in one sentence
- [ ] I know which mechanism reads the source's log rather than its tables
- [ ] I know zero-ETL supports Oracle and SAP, not just Aurora
- [ ] I ask "what latency does the decision need" before "what latency was requested"
- [ ] I consider who operates it at 3am

## You've got it when you can…

…sit in a design review where someone has already picked a mechanism, ask the four questions above, and either confirm the choice with reasons or change it — in under ten minutes.
