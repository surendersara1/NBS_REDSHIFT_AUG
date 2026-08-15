# L04 · The Lakehouse

> **Module 0 · Lesson 04** · ~40 min · **this is the one that describes what we build**

**Slide:** [`_render/L04-lakehouse.html`](_render/L04-lakehouse.html)

## What it is

A lakehouse gives you lake economics with warehouse behaviour. The bridge that makes it possible is an **open table format** — a metadata layer that sits on top of ordinary files and makes a pile of them behave like a table.

The files do not change. What changes is that something now tracks *which files belong to the table right now*, and can change that answer atomically.

**On AWS: Amazon S3 Tables (managed Apache Iceberg) + Glue Data Catalog + Redshift + Athena + EMR.**

## How it works

### The problem it solves

Plain files on S3 cannot do three things a database takes for granted:

1. **Update a row.** Objects are replaced whole, never edited.
2. **Roll back.** Once you have overwritten a file, the previous state is gone.
3. **Two writers at once.** Concurrent writes to the same prefix corrupt each other; there is no transaction.

Every one of those is fatal for a table people report from.

### What the table format adds

Apache Iceberg keeps a metadata tree beside the data files. That gives you:

- **ACID commits** — a write either becomes visible in its entirety, or not at all
- **Schema evolution** — add, rename or drop a column without rewriting the data
- **Row-level updates and deletes** — Iceberg v2 uses *delete files* rather than rewriting whole data files
- **Snapshots and time travel** — query the table as it was at any earlier point

### Many engines, one copy

Athena, Redshift, EMR and Glue all read the same Iceberg table through the catalog. There is no export step, no nightly copy, and therefore no drift between what two teams see.

This is the property people underestimate. Most "our numbers do not match" incidents are two copies of the same data that diverged.

## When to use it

**Use a lakehouse when:**
- You need updates and deletes on data that lives in the lake
- More than one engine reads the same table
- You want one copy of the truth, not five extracts

**Do not use it when:**
- The data is small. A plain database is simpler and you will be happier.

## In practice

On our platforms:
- **S3 Tables** is AWS-managed Iceberg — AWS handles compaction and snapshot maintenance that you would otherwise operate yourself.
- **Bronze and silver are Iceberg tables**, not raw files.
- Loads **MERGE on a key**. They never blindly append, which is what makes re-running a day safe.

## Checklist

- [ ] I can name the three things plain files cannot do
- [ ] I can explain what a table format adds, without saying "it's like a database"
- [ ] I know what a snapshot is and what time travel is for
- [ ] I can explain why one copy read by many engines beats many extracts
- [ ] I know which layers of our platform are Iceberg

## You've got it when you can…

…explain to someone who understands S3 but not Iceberg why adding a metadata layer over unchanged Parquet files is enough to give you transactions, updates and rollback — and why that was worth building.
