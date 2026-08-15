# L22 · Change Data Capture

> **Module 0 · Lesson 22** · ~40 min

**Slide:** [`_render/L22-cdc-and-dms.html`](_render/L22-cdc-and-dms.html)

## What it is

> A watermark pull asks *"what changed since?"* — CDC is **told**, by the database itself.

Every relational database already writes a log of every change so it can recover from a crash. CDC reads that log instead of querying your tables.

**On AWS: AWS DMS**, with Redshift, S3 and others as targets.

## How it works

### 1. Read the log

DMS reads the engine's change log — Oracle redo, PostgreSQL WAL, MySQL binlog — so it adds almost no query load to the source system. That alone is often the deciding factor when the source is a production system with no capacity to spare.

### 2. Full load, then CDC

One task, two phases. It copies the table, notes the log position at which the copy was consistent, and then streams every change from that position onward. You do not have to coordinate the handover yourself.

### 3. It catches deletes

**This is usually what decides the choice.**

A timestamp-based watermark pull asks the source for rows where `modified_at > last_run`. A row that was *deleted* does not match that query — it is simply absent, and absence is indistinguishable from "nothing changed". The row stays in your warehouse forever.

CDC sees the delete in the log, because the log records it.

The same applies to out-of-order updates, and to any update that does not touch the modification timestamp — which happens more often than people expect when the timestamp is set by the application rather than by the database.

### 4. Schema drift

A new column appears upstream. What should happen?

That should be **a decision you made in advance**, not a surprise at 6am. Options are: ignore unknown columns, add them automatically, or fail the task loudly. All three are defensible; having no answer is not.

## When to use it

**Use CDC when:**
- You need continuous replication at low latency
- The source hard-deletes rows
- The engines at each end are different

**Do not use it when:**
- You must transform the data on the way. CDC replicates; shaping happens after landing.

## Against the alternative

Module 2 teaches **watermarked batch pulls** in depth — reading a modification column and tracking the high-water mark. That approach is simpler, cheaper, and entirely correct *when the source does not hard-delete and the watermark column is trustworthy*.

Know both, and know the question that separates them:

> **"Does this source ever hard-delete a row?"**

Ask it of every relational source, on day one, of someone who actually knows. "I don't think so" is not an answer; check the schema for a soft-delete flag, or check the log.

## In practice

- Module 2's engine is built around watermarked pulls.
- CDC is the alternative you should be able to argue for when the source demands it.
- **Deletes usually force the decision.** Everything else is a preference; deletes are a correctness issue.

## Checklist

- [ ] I can explain what a transaction log is and why CDC reads it
- [ ] I can explain full-load-then-CDC as one task in two phases
- [ ] I can explain precisely why a watermark pull misses hard deletes
- [ ] I ask about hard deletes on every relational source
- [ ] I have a schema-drift policy decided before the drift happens
- [ ] I can argue CDC versus watermark pull on the merits

## You've got it when you can…

…be shown a warehouse table with more rows than the source, work out in one question that the source hard-deletes, and explain why the nightly pull will never fix it on its own.
