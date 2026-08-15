# L08 · Plan Table Maintenance on Day One

> **Module 2 · Lesson 08** · ~45 min
> **Slide:** [`_render/L08-table-maintenance.html`](_render/L08-table-maintenance.html)

---

## The decision

**Who compacts, and who expires the snapshots?**

Every write to a modern table format leaves two kinds of litter behind: **small data files**, and **a longer history**. Neither is a bug. Both are the direct consequence of committing frequently, which is exactly what a daily pipeline across eight sources does.

Somebody has to sweep up. The decision you are making is not *whether* — it is **who, and when do we wire it**.

| | Wire it later | **Ship the schedule with the pipeline** |
|---|---|---|
| When it gets done | never, because nothing fails | in the same pull request as the load |
| What prompts it | a performance complaint, twelve months in | the definition of done |
| Who can do it then | whoever can prove it is safe to delete history | the person who just wrote the table |
| Symptom in the meantime | queries slowly getting worse | none |

Choose **ship the schedule with it**. The reason this decision is worth a whole lesson is the entry in the third column: maintenance is the one part of a data platform with **no error message**. If nobody owns it on day one, nobody notices it is missing, and the platform degrades for a year before anyone connects the symptom to the cause.

## Do this

1. **Split "maintenance" into three named jobs.** The word is useless as a single item on a backlog. There are three distinct activities with three distinct owners:

   | Job | What it does | Typically owned by |
   |---|---|---|
   | **Compaction** | Rewrites many small data files into fewer large ones | the storage platform, if it offers managed maintenance |
   | **Snapshot expiry** | Drops old table versions so metadata stops growing | **you** — this is the one that gets forgotten |
   | **Unreferenced-file removal** | Deletes objects no snapshot points at any more | the platform, but *you* configure it |

2. **Write down which of the three the platform runs for you, and which one you own.** Put it in the repo, next to the storage module, in a table exactly like the one above with a real owner in each row. Managed compaction is common on modern managed table storage; **scheduled snapshot expiry rarely is**. If you delegate compaction, also decide *not* to schedule your own compaction job — two compactors fighting over the same files is worse than none.

3. **Schedule snapshot expiry weekly, with a retain floor.** Expiry needs two parameters and both matter:

   ```
   expire_snapshots(older_than_days=7, retain_last=100)
   ```

   `older_than_days` is the age cut. `retain_last` is the safety net: it guarantees a minimum number of recent snapshots survive regardless of age, so time travel and rollback still work, and so a long-running query that resolved an older snapshot is not reading files you are deleting underneath it. Shape: a weekly cron → a job that iterates every table in every namespace → build a writer → call expire.

4. **Declare unreferenced-file removal on the bucket, in infrastructure code, at creation.** This is a bucket-level setting, so it belongs in Terraform next to the bucket itself — shorter for the hot, high-churn zone, longer for the conformed zone. Declared, not clicked:

   ```hcl
   unreferenced_days = 7   # bronze
   unreferenced_days = 30  # silver
   ```

   Note the structural trap: if your tables register themselves on first write from a job (rather than being declared in Terraform), there is **no Terraform resource on which to set per-table maintenance**. Those settings stay at the service default and nobody notices. Know which of your settings are per-bucket and which are per-table, and know which ones you have no declarative place to put.

5. **Ship the schedule in the same pull request as the pipeline.** This is the whole lesson compressed into one habit. A maintenance job that is "the next ticket" is a maintenance job that does not exist. Add the observability with it: count snapshots per table weekly, and alarm when the count **stops falling** — that is the signal that your expiry job died silently, and it is the only signal you will get.

**Worked example of the pattern:** the Tamimi platform delegates compaction to managed storage maintenance, declares `iceberg_unreferenced_file_removal` per table bucket in `infra/modules/s3-data-lake/main.tf` (7 days on Bronze, 30 on Silver), and implements `expire_snapshots(older_than_days=7, retain_last=100)` in `writers/s3_tables.py`. Read it as three separate concerns with three separate homes — that separation is the pattern to copy.

## Why

Frequent small writes are the cause, and they are unavoidable. Every cycle, every table, a Bronze load commits a new version; a Silver transform commits another. Each commit produces new data files and a new entry in the table's metadata chain. Eight sources × dozens of tables × daily × months is thousands of small files and a metadata history that only ever grows.

**Query planning walks that metadata chain before it reads a single row of data.** That is where the cost lands. The engine opens the table's root metadata, resolves the current snapshot, reads the manifest inventory, prunes on statistics — and all of that gets slower as the chain lengthens and the file count rises. Then the scan itself pays per-file overhead on thousands of tiny files instead of hundreds of large ones.

Note what does *not* happen: **nothing fails.** There is no exception, no failed job, no alarm, no log line. The symptom is "the dashboard feels slower than it used to", reported by a business user, twelve months after the cause was introduced. That is the worst possible failure shape — it survives indefinitely because nothing surfaces it.

One related trap worth carrying with you: because managed compaction **rewrites files**, the last-modified timestamp on a storage object is not a build timestamp. It can read newer than your last real write. Triage data staleness from your job-run history or your control plane, never from an object timestamp.

**What breaks if you don't:** reads decay for a year and nothing fails — there is no log line anyone can grep for.

## On Apparel Group

**XStore and SIM decay first.** Rank the eight sources by commit frequency, because commit frequency — not data volume — is what drives metadata growth:

| Source | Commit cadence | Maintenance priority |
|---|---|---|
| **Oracle XStore** | Every cycle, high volume | **First.** Biggest tables *and* frequent commits. On the weekly expiry job before go-live. |
| **Oracle SIM** | Every cycle, high churn | **First.** Inventory positions change constantly; the metadata chain grows fastest here. |
| **Vemco / Irisys Footfall** | Frequent small files | **The classic small-file source.** Tiny payloads, many writes. Exactly the shape managed compaction exists for — confirm it is actually enabled on their tables. |
| **Magento** | Daily, moderate | Standard weekly expiry. |
| **Epsilon / MoEngage** | Daily API or file drop | Standard weekly expiry. Note that PII deletion obligations interact with snapshot retention — old snapshots still contain deleted rows. Decide the retention number with that in mind. |
| **Oracle Retail RMS** | Masters refreshed rarely | Lowest priority. Full-refresh masters commit less often and can wait. |

Two Apparel-Group-specific calls:

- **Enable and verify managed compaction on the footfall tables specifically.** They are optional, small, and therefore the ones most likely to be set up quickly and never checked. They are also the ones that generate the most files per byte.
- **Set the expiry window with Epsilon in mind.** Snapshot history is a copy of deleted rows. A retention window that is fine for sales data is a compliance question for loyalty data — decide it once, deliberately, with whoever owns data protection.

## Checklist

- [ ] "Maintenance" is written down as three named jobs, never as one word
- [ ] Each of the three has a named owner: the platform, infrastructure code, or a person
- [ ] Snapshot expiry runs on a schedule that exists **now**, not in a ticket
- [ ] Expiry has both an age cut and a `retain_last` floor, and I can say what the floor defends
- [ ] I am not running my own compaction against managed compaction
- [ ] Unreferenced-file removal is declared in infrastructure code, per bucket, at creation
- [ ] I know which settings have no declarative home because tables self-register
- [ ] Snapshot counts per table are recorded weekly, with an alarm when the count stops falling
- [ ] Staleness triage uses job-run history, never an object's last-modified timestamp
- [ ] The maintenance job shipped in the same pull request as the pipeline

## You've got it when you can…

…split "maintenance" into **compaction / unreferenced-file removal / snapshot expiry**, name the owner of each on your platform without looking it up, state what `retain_last` is protecting and from what, and describe the symptom of skipping expiry as **"query planning gets slower the longer a table lives"** rather than as any error a person would find in a log.
