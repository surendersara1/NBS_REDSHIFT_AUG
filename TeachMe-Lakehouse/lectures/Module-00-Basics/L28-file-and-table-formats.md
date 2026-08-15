# L28 · Two Different Things Called "Format"

> **Module 0 · Lesson 28** · ~40 min

**Slide:** [`_render/L28-file-and-table-formats.html`](_render/L28-file-and-table-formats.html)

## What it is

**Parquet is a file format. Iceberg is a table format.** They stack on top of each other, and people conflate them constantly — including in job descriptions and architecture documents.

- A **file format** decides what **one file** looks like inside.
- A **table format** decides what **a set of files** collectively means.

You choose both, and they are independent decisions.

## File formats — what one file looks like

### CSV · JSON
Readable, untyped, uncompressed. Fine for landing raw data exactly as received. Never for anything you query repeatedly — every query re-parses text and reads every column.

### Parquet
**Columnar, typed, compressed.** The default for the lake. Because it stores columns separately and keeps per-column statistics, a query touching a few columns with a selective filter can cut bytes scanned by **10–100×**.

Given that Athena is billed per byte scanned, that is not a performance number — it is a bill.

### ORC
Also columnar, with similar properties. Common in Hive estates. Parquet is the AWS default; either works, and mixing them within one table does not.

### Avro
Row-based with an embedded schema. Good for streaming records and message payloads, where you write whole rows and read whole rows. Poor for analytical scans, for the same reason row storage is always poor for them.

## Table formats — what a set of files means

### What they add

- **ACID commits** — a write becomes visible in its entirety or not at all
- **Schema evolution** — add, rename, drop columns without rewriting data
- **Row-level UPDATE and DELETE** — on storage that cannot edit files
- **Time travel** — query the table as of an earlier snapshot
- **Safe concurrency** — two writers no longer corrupt each other

### Apache Iceberg
The AWS default. **S3 Tables is managed Iceberg**, with AWS running compaction and snapshot maintenance.

**v2** introduced *delete files*: rather than rewriting a whole data file to remove a row, Iceberg writes a small file recording the deletion, and readers apply it. Fast writes, slightly slower reads, and compaction reconciles the two later. That trade is worth understanding because it explains why maintenance is not optional.

### Apache Hudi
Two variants: **Copy-on-Write** (rewrites files on update — fast reads, slower writes) and **Merge-on-Read** (writes deltas — fast writes, slower reads). Strong on high-frequency streaming upserts.

### Delta Lake
Databricks' format. **Redshift Spectrum reads it through symlink manifest tables** — a generated manifest that lists the current files, which Spectrum then reads as an external table.

## How to talk about this correctly

> "Iceberg tables stored as Parquet files on S3."

That sentence has all three layers in the right order: table format, file format, storage. If someone says "Parquet versus Iceberg" as if it were a choice between two things, they have the layers confused — and it is worth gently untangling, because the confusion leads to real design errors.

## Checklist

- [ ] I can state the difference between a file format and a table format
- [ ] I know why columnar plus compression is the biggest cost lever in a lake
- [ ] I can name the five things a table format adds
- [ ] I know what Iceberg v2 delete files are and why compaction matters
- [ ] I know Delta is read via symlink manifests in Spectrum
- [ ] I would correct "Parquet versus Iceberg" in a design document

## You've got it when you can…

…read an architecture document that says "we'll use Parquet or Iceberg" and explain, without condescension, that those are two different layers and you almost certainly want both.
