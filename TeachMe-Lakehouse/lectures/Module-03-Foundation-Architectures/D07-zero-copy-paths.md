# D07 · Zero-Copy Access Paths

> **Module 3 · Architecture 07** · ~15 min

**Diagram:** [`_render/D07-zero-copy-paths.html`](_render/D07-zero-copy-paths.html)

## What it shows

Four ways to query data you never loaded — and, for each, **who actually pays**.

> **None of them is free. Each one moves the bill somewhere else.**

"Zero-copy" is a statement about storage, not about cost. Teams who hear it as "zero-cost" build designs that demo beautifully and degrade quietly.

## The four doors

### Spectrum → S3
External schema over the Glue catalog. Reads Parquet, ORC, CSV, JSON, Avro — plus the transactional formats **Iceberg**, **Hudi Copy-on-Write** and **Delta Lake** (via symlink manifests).
**You pay:** bytes scanned in S3, on every query.
**Best for:** cold history you scan rarely.

### Federated query → a live database
External schema onto a live **RDS or Aurora PostgreSQL / MySQL**. Predicates are pushed down to the source; large scans are not.
**You pay:** load on the production database, every query.
**Best for:** small, live lookups only.

### Datashare → another warehouse
Live data across clusters, accounts and Regions. No copy, no ETL, no lag — and **writes are now possible** with `--allow-writes`.
**You pay:** the consumer's own compute, not yours.
**Best for:** another team's warehouse.

### Athena connectors → anything
Redshift, DynamoDB, Snowflake and more. **Two connector types** — only the Glue-connection kind registers as a federated catalog and supports Lake Formation fine-grained control. Prefer that one.
**You pay:** Athena scan cost plus the remote system.
**Best for:** one SQL door to everything.

## The decision framework

Four questions, in order:

1. **How often is it queried?** Many times a day → lean toward loading. Twice a month → point at it.
2. **Is it joined, or just filtered?** Heavy joins want co-located data and sort keys.
3. **How fresh must it be?** "Right now" narrows you to federated query or a datashare.
4. **Who pays, and do they know?** A pointer moves cost onto the querier — or onto someone else's production system.

> **Copy what you join hard and often. Point at what you scan rarely.
> Never point at production for a report that runs every hour.**

## The failure mode

Someone points at a source for a small lookup. The report gets popular. It goes from weekly to hourly. Six months later a production database is struggling and nobody connects it to the dashboard.

**The defence:** write down, per external schema, what it is for and roughly how often it should be hit — then alarm when reality diverges.

## Checklist

- [ ] I can name the four doors and what each reaches
- [ ] I can say who pays for each
- [ ] I know Spectrum reads Iceberg, Hudi CoW and Delta
- [ ] I know the two Athena connector types differ on governance
- [ ] I decide per table, not once for the platform
- [ ] Each external schema has a documented purpose

## You've got it when you can…

…be asked to "just point Redshift at production" for a daily report, explain what that does to production, and offer the right alternative instead.
