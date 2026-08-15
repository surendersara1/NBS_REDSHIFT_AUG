# L08 · The Maintenance Problem

**Slide:** [`_render/L08-small-files-compaction.html`](_render/L08-small-files-compaction.html)

## The point

Every write to an Iceberg table leaves two kinds of litter behind: **small data files**, and **a longer history**. Somebody has to sweep up, or reads get slower and slower for no visible reason.

On this platform the split is:

- **Data files → AWS.** S3 Tables runs managed compaction, and ADR-0024 chose it precisely so we would not have to author ~6 maintenance Glue jobs. We deliberately do **not** schedule `rewrite_data_files` — it would fight the managed maintenance.
- **History → nobody.** `expire_snapshots()` exists in the writer. **It has no scheduled caller.** This is a real, open gap in the platform, and it is taught here as one.

This lesson is deliberately honest about that. You will be asked about it in week 1.

## Key ideas

- **Small files are a consequence of cadence, not of carelessness.** Bronze appends a delta every cycle; Silver MERGEs. Each write commits a new snapshot with a new manifest list. 48 tables × daily × months = thousands of small Parquet files and a metadata chain that only ever grows.
- **The cost shows up as slowness, never as an error.** Planning a query means walking the metadata chain first. Nothing fails; scans just get worse. That makes it the kind of problem that survives for a year unnoticed.
- **Compaction and snapshot expiry are different jobs.** Compaction rewrites many small data files into fewer big ones. Expiry drops old *snapshots* so the manifest list and metadata JSON stop growing. Managed compaction does not do the second one for us at the app level.
- **What Terraform actually configures.** Only bucket-level `iceberg_unreferenced_file_removal`: Bronze at 7 days, Silver at 30. That reclaims files nothing references any more — it is not compaction, and it is not snapshot expiry.
- **Per-table maintenance is never declared, and that is structural.** The table bucket and namespaces are Terraform's; **the tables are not** — they register themselves on first write from the Glue job. So no Terraform resource exists on which to set per-table maintenance, and those settings stay at the service default.
- **`expire_snapshots()` is real code.** It CALLs Iceberg's `system.expire_snapshots` stored procedure on the writer's own table, with `older_than_days=7` and `retain_last=100` (the retain floor is the time-travel/rollback safety net).
- **And nothing calls it.** The docstring says so in as many words: *"there is no automatic caller yet. This is intended to be invoked by a scheduled maintenance job (e.g. a weekly EventBridge-cron Glue job that instantiates a writer per table and calls this)."* The audit tracks it as **M-23, PARTIAL** — coded but unwired.
- **A related trap worth carrying with you:** because managed compaction rewrites files, `modifiedAt` on an S3 table is **not** a build timestamp. It has read hours newer than the last real write during a live incident. Use Glue `get-job-runs` to triage staleness, never the object timestamp.

## Words you'll hear

| Word | What it means here |
|---|---|
| Small-file problem | Many tiny Parquet files; per-file overhead dominates the scan |
| Compaction (`rewrite_data_files`) | Merge small data files into fewer large ones. Managed by AWS here |
| Snapshot expiry | Drop old snapshots so metadata stops growing. **Not scheduled here** |
| Unreferenced-file removal | Delete objects no snapshot references. Configured in Terraform, per bucket |
| `retain_last` | Minimum number of recent snapshots to keep regardless of age |
| Managed maintenance | The S3 Tables service doing the sweeping instead of a Glue job you wrote |
| M-23 | The audit finding for this gap — still open |

## In this repo

- [`src/glue/glue_engine/writers/s3_tables.py:407-449`](../../../tamimi-lakehouse/src/glue/glue_engine/writers/s3_tables.py) — `expire_snapshots`. The docstring (`:414-434`) explains why compaction is delegated and expiry is not; the **NOTE at `:431-434`** is the "no automatic caller" admission. The actual `CALL <catalog>.system.expire_snapshots(...)` is at `:444-449`.
- [`infra/modules/s3-data-lake/main.tf:11-47`](../../../tamimi-lakehouse/infra/modules/s3-data-lake/main.tf) — the two table buckets and the only maintenance we declare: `iceberg_unreferenced_file_removal`, `unreferenced_days = 7` (Bronze, `:14-22`) and `= 30` (Silver, `:33-41`). Line **8** is the load-bearing comment: *"individual tables are owned by the Glue jobs and not declared here."*
- [`docs/design-reference/decisions/0024-s3-tables-managed-iceberg.md`](../../../tamimi-lakehouse/docs/design-reference/decisions/0024-s3-tables-managed-iceberg.md) — the decision that removed ~6 maintenance Glue jobs from the backlog, and the honest "Cons" section.
- [`docs/handoff/audit-remediation-verification.md:79`](../../../tamimi-lakehouse/docs/handoff/audit-remediation-verification.md) — M-23 marked **PARTIAL**: *"`expire_snapshots()` added … but no scheduled caller"*. Note the line reference there (`s3_tables.py:345-387`) has drifted — the method is now at `:407-449`. Verify line numbers before you quote them.
- [`docs/handoff/remediation-proposals-nogo.md:249`](../../../tamimi-lakehouse/docs/handoff/remediation-proposals-nogo.md) — the proposed fix: wire a scheduled maintenance Glue job or Step Functions cron; file compaction stays delegated.
- [`docs/risks.md`](../../../tamimi-lakehouse/docs/risks.md) — R53, for the `modifiedAt`-is-not-a-build-time lesson, discovered during a real staleness triage.

## Do this

1. Open `expire_snapshots` and then `grep -rn "expire_snapshots" src/ infra/`. Confirm for yourself that the only hits are the definition and its own docstring. This is what "coded but unwired" looks like in a real codebase.
2. Count the snapshots on the busiest Dev Silver table (`SELECT count(*) FROM <fqn>.snapshots`). Multiply by your cadence and project 12 months out.
3. Sketch the missing job on paper: EventBridge weekly cron → Glue job → for each spec, build an `S3TablesWriter` and call `expire_snapshots`. What is the failure mode if it runs *while* a long Redshift Spectrum query is reading an old snapshot? (That is what `retain_last=100` is defending.)
4. Read ADR-0024's "Cons (honest)" section and be able to state one thing we gave up by choosing managed Iceberg.

## You've got it when you can…

…split "maintenance" into **compaction / unreferenced-file removal / snapshot expiry**, say who owns each one on this platform (AWS / Terraform-configured AWS / **nobody**), point at `s3_tables.py:407-449` plus the NOTE at `:431-434` as evidence, and describe the symptom of the gap as *"query planning gets slower the longer a table lives"* rather than as an error anybody would see in a log.
