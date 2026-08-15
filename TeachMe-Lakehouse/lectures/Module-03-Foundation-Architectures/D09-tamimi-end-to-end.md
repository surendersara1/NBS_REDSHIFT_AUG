# D09 · Tamimi, End To End

> **Module 3 · Architecture 09 · as built** · ~15 min

**Diagram:** [`_render/D09-tamimi-end-to-end.html`](_render/D09-tamimi-end-to-end.html)

## What it shows

The platform **that exists today** — not a target state. This is the handover record: if the team changes, this diagram is what a new joiner reads first.

## The SAP boundary

The most important thing on this diagram is on the left.

**SAP pushes to a SQL Server database on RDS. We never poll SAP directly.**

That is a deliberate boundary, and it is why SAP's upgrade windows do not become our outages. Everything from that staging database rightwards is ours to design, operate and change; everything to the left of it is theirs.

The earlier **OData pull is retired** — drawn dashed on the diagram so nobody re-proposes it in a design session six months from now. It is history, and marking history as history on the diagram is cheaper than explaining it repeatedly.

## The rest of the path

**Ingest** — Glue P1 (`source_download`, JDBC, watermarked) and P2 (`bronze_pull`, MERGE into Iceberg), sequenced by Step Functions with a barrier between them (D10), triggered nightly by EventBridge.

**Lake** — S3 raw as an immutable landing zone; S3 Tables holding Iceberg v2 bronze and silver; the federated Glue catalog (`s3tablescatalog`); Lake Formation grants.

**Warehouse** — Redshift Serverless for gold, built by dbt with incremental MERGE. An external schema lets Spectrum read silver in place rather than loading it. The control plane records what happened.

**Consume** — Power BI reads views only; Athena for investigation; the ops console for run state per environment; CloudWatch for metrics and alarms.

## How to use this diagram

Three situations:

1. **Onboarding.** New joiner, day one. Walk left to right, then point at the band underneath.
2. **Incident.** "Where did it break?" — point at the column, then open D10 for the phase detail.
3. **Change request.** "Can we add X?" — find which column it lands in, then check D12 for the catalog implications.

## What it deliberately does not show

Failure paths, retries and barriers — those are D10. Environments — that is D13. This diagram answers *what is connected to what*, and nothing else. A diagram that tries to show everything shows nothing.

## Checklist

- [ ] I can explain the SAP push boundary and why it exists
- [ ] I know the OData pull is retired and would not re-propose it
- [ ] I can name what P1 and P2 each do
- [ ] I know which layers are Iceberg and which is Redshift
- [ ] I know Power BI reads views, not tables
- [ ] I can walk this diagram for a new joiner without notes

## You've got it when you can…

…hand this to someone on their first morning, walk it in ten minutes, and have them able to ask a sensible question about where their work will land.
