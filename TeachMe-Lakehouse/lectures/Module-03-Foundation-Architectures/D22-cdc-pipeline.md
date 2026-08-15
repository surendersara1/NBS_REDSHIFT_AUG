# D22 · CDC — Reading The Log, Not The Table

> **Module 3 · Architecture 22 · deep dive** · ~20 min

**Diagram:** [`_render/D22-cdc-pipeline.html`](_render/D22-cdc-pipeline.html)

## What this pattern is for

Continuous replication out of a relational source, with **almost no query load on that source** and — the part that decides it — **deletes that actually propagate**.

Choose it when the source hard-deletes rows, when you need minutes rather than hours, or when the source DBA will not tolerate a nightly full-table scan.

## The ten steps

**1 · Oracle writes its redo log.** Every relational engine already logs every change so it can recover from a crash. CDC does not ask the database for anything new — it reads a file the database was writing anyway.

**2 · A private network path.** Direct Connect or Site-to-Site VPN. This is procurement, not code, and it has weeks of lead time. It is on the critical path from day one (D18).

**3 · DMS runs a full load.** One task, first phase: copy the table as it stands, and record the log position at which that copy was consistent. You do not coordinate this handover yourself — that is the point of using one task.

**4 · The same task switches to CDC.** From the recorded position onward, DMS streams every insert, update and delete. There is no gap between the two phases, which is exactly the bug you would introduce hand-rolling this.

**5 · Change records land on S3.** Not the current state of the table — a stream of *change events*, each tagged I, U or D. Keep them; they are the audit trail of how the table got to where it is.

**6 · Replication lag is the metric.** Not "did the task run" — **how far behind is it**. A CDC task that is running but four hours behind is failing silently, and only this metric shows it. Alarm on it before go-live, not after the first incident.

**7 · Glue MERGEs into Iceberg.** Insert, update and delete applied against the natural key. Because it is a MERGE, replaying the same change file twice is harmless — which you will need on the day the task restarts.

**8 · Iceberg v2 writes delete files.** A deleted row is not removed from the data file; a small delete file records it and readers apply it. Fast writes, slightly slower reads.

**9 · Compaction reconciles them.** ⭐ This is the step teams forget. Without scheduled compaction the delete files accumulate, every read gets slower, and storage grows for data that is logically gone. **CDC without compaction degrades quietly for months.**

**10 · Redshift builds gold.** dbt reads the Iceberg tables and the deleted rows are correctly absent — which is the whole reason you chose CDC over a watermarked pull.

## Against the alternative

Module 2 teaches watermarked batch pulls, and for many sources that is the right, simpler answer. The question that separates them:

> **"Does this source ever hard-delete a row?"**

Ask it of someone who knows, of every relational source, on day one. A timestamp-based pull asks *"what changed since?"* — and a deleted row does not answer, because it is simply absent. It stays in your warehouse forever, and nothing tells you.

## What breaks if you skip a piece

- **No lag alarm** — the pipeline is "green" and four hours stale.
- **No compaction** — reads slow month over month with no obvious cause.
- **No schema-drift policy** — a new upstream column becomes a 6am surprise instead of a decision.
- **Append instead of MERGE** — a task restart doubles the day.

## On Apparel Group

This is the credible alternative to Glue JDBC for **Oracle SIM and XStore**, and D17 sets the three options side by side. The deciding evidence is the answer to step-9's question and the hard-delete question — not a preference.

## Checklist

- [ ] Confirmed whether the source hard-deletes, from someone who knows
- [ ] Network path requested in week one
- [ ] Full load and CDC are one task, not two
- [ ] Replication **lag** is alarmed, not just task state
- [ ] Loads MERGE on the natural key
- [ ] Compaction is scheduled and monitored
- [ ] Schema-drift policy decided before drift happens

## You've got it when you can…

…be shown a "healthy" CDC pipeline and find the two things that make it unhealthy anyway — the lag it is not alarming on, and the compaction nobody scheduled.
