# L03 · The Data Lake

> **Module 0 · Lesson 03** · ~40 min

**Slide:** [`_render/L03-data-lake.html`](_render/L03-data-lake.html)

## What it is

A data lake is cheap storage that accepts data in whatever shape it arrives, and defers the decision about what it means until someone queries it. That is **schema on read**.

What you are actually buying is *optionality*: the right to ask, in two years, a question nobody has thought of yet — because you still have the raw data to answer it with.

**On AWS: S3 + Glue Data Catalog + Athena + Lake Formation.** All four, not just the first one. A lake that is only S3 is a folder.

## How it works

### Object storage

S3 holds files at cents per GB per month, with eleven nines of durability and no capacity to plan or provision. "Keep everything" stopped being reckless when storage got this cheap.

### Schema on read

Nothing validates the file when it lands. A column that changed type upstream lands happily and breaks a query three weeks later. That is the cost of the flexibility, and it is why Lesson 24 is about landing conventions.

### The catalog

The **Glue Data Catalog** is what turns a folder of files into a *named table with columns* that a person can discover and an engine can query. Without it, the only way to find anything is to know the S3 path — which means the knowledge lives in people's heads.

Lesson 29 covers what the catalog has become, which is considerably more than a list of tables.

### Governance

**Lake Formation** decides who can see which table, and which **columns** inside it, enforced consistently across every engine that reads through the catalog.

## The swamp

The failure mode has a name. A **data swamp** is a lake with no catalog and no owner: the data is all there, and nobody can use any of it. Every file is technically retrievable and practically lost.

It is not caused by bad storage. It is caused by skipping the third and fourth pieces above because the first two were enough to demo.

## When to use it

**Use a lake for:**
- Raw data you must retain for years for audit or regulatory reasons
- Schemas you do not control — SaaS exports, logs, third-party feeds
- Data science and exploration on unmodelled data
- Anything where "we might need it" is a real answer

**Do not use it for:**
- Numbers the CFO signs off on. Those go through the warehouse.

## In practice

On our platforms:
- `raw/` and `bronze/` prefixes on S3 are the lake.
- **Every file lands immutable, exactly once.** Nothing is ever edited in place.
- Re-reading is cheap, which is why we can afford to reprocess history when a rule changes.

The property to internalise: *cheap to keep, cheap to re-read.* Both halves matter. Storage you cannot afford to re-read is an archive, not a lake.

## Checklist

- [ ] I can explain schema-on-read and name one risk it creates
- [ ] I can name all four components of a real lake, not just S3
- [ ] I can explain what a data swamp is and what causes it
- [ ] I know which prefixes on our platform are the lake
- [ ] I understand why files are never edited in place

## You've got it when you can…

…be shown an S3 bucket full of Parquet and say precisely what is missing before it can honestly be called a data lake — and what will go wrong if those pieces are never added.
