# D12 · Catalog And Storage Layers

> **Module 3 · Architecture 12 · as built** · ~15 min

**Diagram:** [`_render/D12-catalog-storage-layers.html`](_render/D12-catalog-storage-layers.html)

## What it shows

**Five layers between a SQL statement and a byte on disk.** When something does not work, knowing which of the five you are debugging is most of the job.

| Layer | What it is |
|---|---|
| **Engines** | Redshift · Athena · Glue · EMR — they all speak the same catalog |
| **External schema** | the pointer — `CREATE EXTERNAL SCHEMA … FROM DATA CATALOG` |
| **Federated catalog** | `s3tablescatalog / <bucket> / <namespace> / <table>` + Lake Formation |
| **Iceberg metadata** | snapshots, manifests, delete files — S3 Tables runs compaction and expiry |
| **S3 objects** | Parquet files — the only layer that is actually a file |

## Three places it bites

### The Spectrum mirror database
Spectrum resolves the catalog with the account baked in, so a federated catalog cannot be referenced directly. A **mirror database** is created for Redshift to point at instead.

This is not a workaround somebody invented; it is a documented consequence of how Spectrum resolves catalog IDs. It is also the single most confusing thing in the stack for a newcomer, because the table exists, the grant exists, and Redshift still cannot see it.

### Two grant systems, one table
Redshift `GRANT` governs Redshift-native tables. **Lake Formation** governs anything read through the catalog. *"Works in Athena, not in Redshift"* almost always starts here (Module 0 L17, D28).

### Maintenance is not optional
Iceberg v2 writes **delete files** rather than rewriting data files. Without compaction and snapshot expiry, reads get slower and storage grows for data that is logically gone. S3 Tables handles this — which is a large part of why it is worth using — but you still need to know it is happening.

## How to debug with this diagram

Work **down**, not sideways:

1. Can the engine see the schema? → external schema layer
2. Can it see the table? → catalog layer
3. Is it allowed to? → Lake Formation
4. Is the data actually there? → Iceberg metadata (check the snapshot)
5. Are the files present? → S3

Four of those five questions are answered without opening S3 at all. People who skip to step 5 spend a long time looking at objects that were never the problem.

## Supersedes

This diagram replaces the hand-drawn [`../../diagrams/catalog-storage-layers.drawio`](../../diagrams/catalog-storage-layers.drawio) — same content, real AWS icons, consistent with the rest of the pack.

## Checklist

- [ ] I can name the five layers in order
- [ ] I know why a Spectrum mirror database exists
- [ ] I know which grant system governs which kind of object
- [ ] I know Iceberg v2 uses delete files and why compaction matters
- [ ] I debug downward through the layers, not straight to S3

## You've got it when you can…

…be told "the table is there but Redshift cannot see it" and name the two most likely layers before opening anything.
