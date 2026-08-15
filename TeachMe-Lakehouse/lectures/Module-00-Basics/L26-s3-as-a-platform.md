# L26 · S3 Is Not A Filesystem

> **Module 0 · Lesson 26** · ~40 min

**Slide:** [`_render/L26-s3-as-a-platform.html`](_render/L26-s3-as-a-platform.html)

## What it is

S3 is a **key-value store of objects**. There are no directories — only very long keys that happen to contain slashes.

```
raw/xstore/sales_line/dt=2026-08-11/part-0000.parquet
```

That is **one flat key**, not four folders. The console draws a folder tree because humans find it comforting; the underlying store has no such concept.

Almost every data-lake mistake starts with forgetting this.

## Four consequences of that one fact

### 1. Objects are whole

You cannot change one row inside an object. You replace the object. This is precisely why table formats exist (Lesson 28) — Iceberg gives you row-level updates by adding metadata *around* immutable files, not by editing them.

### 2. Partitions are prefixes

`dt=2026-08-11` is a **convention** that query engines understand. When you filter on the partition column, the engine can skip entire prefixes without reading a single byte of them.

This is the cheapest performance work you will ever do — and the hardest to change afterwards, because changing it means rewriting every key and every downstream reference.

### 3. File size is a design choice

Thousands of tiny files is the classic lake killer: all request overhead, no throughput. Each file carries a fixed cost to open, and a query over 50,000 small files spends its life on round trips rather than on reading data.

**Aim for 128 MB to 1 GB per file.** If your producer naturally emits small files, run a compaction step. (S3 Tables handles this for you, which is one of the main reasons to use it.)

### 4. Listing is expensive

Asking S3 "what is in this prefix?" costs time and money, and gets slower as the prefix grows. The catalog exists so that engines rarely have to ask — they look up the partitions they need in metadata instead.

This is also why **partition projection** (Lesson 29) is worth knowing: it lets the engine compute partition locations from a pattern rather than listing or crawling them.

## Rules of thumb

- **Partition by what you filter on** — for retail, that is almost always date
- **Compact small files** on a schedule, or let S3 Tables do it
- **Write new, then swap** — never modify in place
- **Never partition on something high-cardinality** — partitioning by customer ID creates millions of tiny prefixes and is worse than not partitioning at all

## In practice

```
raw/<source>/<table>/dt=YYYY-MM-DD/
```

- One prefix shape for every source, with no exceptions.
- Bucket policy **denies unencrypted writes**, so encryption is not something anyone has to remember.
- **The prefix is the contract.** Downstream tooling, lifecycle rules and access grants are all written against that shape.

## Checklist

- [ ] I can explain why S3 has no folders and why it matters
- [ ] I know partitions are a prefix convention, not a storage feature
- [ ] I know the target file-size range and why
- [ ] I know why listing is expensive and what avoids it
- [ ] I would never partition on a high-cardinality column
- [ ] I know our prefix convention and treat it as a contract

## You've got it when you can…

…be shown a slow Athena query, look at the S3 prefix layout and the file sizes, and predict whether the problem is partitioning or small files — before running an explain.
