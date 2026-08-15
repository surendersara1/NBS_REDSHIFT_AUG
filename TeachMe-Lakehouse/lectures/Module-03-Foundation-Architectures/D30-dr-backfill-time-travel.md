# D30 · Recovery, Backfill And Time Travel

> **Module 3 · Architecture 30 · deep dive** · ~20 min

**Diagram:** [`_render/D30-dr-backfill-time-travel.html`](_render/D30-dr-backfill-time-travel.html)

## What this pattern is for

**Three different "undo" buttons for three different disasters.** Knowing which one you need — and how far back it reaches — is the skill. Reaching for the wrong one under pressure is how a bad morning becomes a bad week.

| Undo | Reaches back | Use it for |
|---|---|---|
| **Iceberg snapshots** | minutes to days | a bad load this morning |
| **Replay from raw** | any age | a business rule that was wrong for months |
| **Cross-Region copy** | last replication | the Region is gone |

## The nine steps

**1 · Every write creates a snapshot.** Not a backup job you scheduled — a property of the table format. Iceberg records the exact set of files that constituted the table at that commit.

**2 · The snapshot is the table as it was.** Immutable, cheap (it references existing files rather than copying them), and available immediately.

**3 · Time travel queries it.** ⭐ `SELECT ... FOR TIMESTAMP AS OF ...` — the table as of this morning, before the bad load. This is how you *diagnose* before you decide, rather than restoring blind and hoping.

**4 · `expire_snapshots` must run.** ⭐ Snapshots retain the files they reference. Without expiry, storage grows forever and metadata gets slower. **Choose the retention window deliberately** — it is exactly how far back your fastest undo reaches, so "7 days" is a recovery decision, not a housekeeping one.

**5 · Storage is reclaimed.** Files no snapshot references are deleted. This is the moment your fastest undo stops reaching that far back — worth saying out loud when someone proposes shortening the window to save money.

**6 · `raw/` is intact, always.** ⭐ Written once, never edited, never expired within the retention period. This is the reason the medallion architecture insists raw is immutable: it is the second undo button, and it reaches back as far as your retention.

**7 · Replay rebuilds upward.** Bronze and silver are *derived*. If a business rule was wrong for six months, you fix the rule and reprocess from raw. Nothing was lost because nothing downstream was the only copy.

**8 · Backfill is a date range on the normal path.** ⭐ Not a separate script. The same job, the same MERGE, given different dates — which works precisely because loads are idempotent (Module 0 L11). A backfill mechanism that differs from the nightly path is one nobody trusts at 6am.

**9 · The drill is practised, not written.** ⭐ **A backup nobody has restored from is a folder, not a recovery plan.** Run the drill: restore a table from a snapshot, replay a day from raw, and time both. Those two numbers are your real RTO — everything else is an assumption.

## RTO and RPO — agreed, not assumed

- **RPO** (how much data you can afford to lose) is set by ingestion cadence. A nightly batch has an RPO of one day. Saying so plainly at design time avoids a difficult conversation later.
- **RTO** (how fast you can be back) is what the drill measures.

Both belong in writing, agreed with the business, before go-live. They are the two numbers everyone assumes are better than they are.

## What breaks if you skip a piece

- **No `expire_snapshots`** — storage grows forever, metadata slows, cost rises with no obvious cause.
- **Expiry too aggressive** — your fast undo no longer reaches the incident.
- **Raw not immutable** — the second undo button does not exist, and you did not find out until you needed it.
- **A separate backfill script** — rarely used, never tested, wrong when it matters.
- **No drill** — RTO is a guess, and it is optimistic.

## On Apparel Group

Set the snapshot retention window in **week one**, alongside the S3 lifecycle policy (D29) — the two interact, and both are painful to change once there is history.

Run the recovery drill **before go-live**, in QA, with the client team watching. It is also the most convincing single thing you can show at handover (M05): not that the platform works, but that it can be *fixed*.

## Checklist

- [ ] Snapshot retention window chosen deliberately and written down
- [ ] `expire_snapshots` scheduled and monitored
- [ ] `raw/` is immutable and its retention exceeds the replay window
- [ ] Backfill uses the normal path with a date range
- [ ] Cross-Region copy exists if the RPO requires it
- [ ] RTO and RPO agreed with the business, in writing
- [ ] The drill has been **run**, and both timings recorded

## You've got it when you can…

…be told at 8am that yesterday's load wrote bad data, and choose between time travel and a replay in under a minute — because you already know how far back each one reaches.
