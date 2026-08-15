# L07 · Apache Iceberg: Snapshots, MERGE, Time Travel

> **Module 1 · Lesson 07** · ~45 min
> Slide: [`_render/L07-apache-iceberg.html`](_render/L07-apache-iceberg.html)

## The point

A folder of Parquet files can't be updated safely — two writers collide, a reader mid-scan sees half a write, and there is no `UPDATE`. Iceberg fixes all of that with one idea: **data files are immutable, and the "table" is just a pointer to a list of them.** Every write publishes a new list and moves the pointer in one atomic step. That single mechanism is where atomic writes, upserts, rollback and safe schema change all come from.

## Key ideas

- **Data files are write-once.** An UPDATE never edits a Parquet file; it writes a new one and marks the old rows deleted.
- **Metadata + manifests are the table.** They list which files are in the table *right now*, plus per-file row counts and min/max stats so a scan can skip whole files.
- **A snapshot is a pointer.** Commit = write new files → write new manifest → move one pointer. Nothing is ever half-applied.
- **Readers hold the old pointer**, so a long query is never disturbed by a concurrent write. No locks, no dirty reads.
- **`MERGE INTO` is the upsert.** Re-running the same input produces the *same* row count — replays and Glue auto-retries stop being dangerous.
- **Rollback and time travel are free**, because the old snapshots still exist. You point at an older one.
- **Snapshots must be expired.** Every commit adds one; unbounded metadata slows query planning. Data-file compaction is a separate concern (S3 Tables does it for us — see L08).

## Words you'll hear

| Term | Means |
|---|---|
| Snapshot | One immutable version of the whole table — a pointer to one metadata file |
| Manifest | The list of data files (+ stats) that make up a snapshot |
| Commit | Publishing a new snapshot by atomically moving the pointer |
| `MERGE INTO` | Upsert: update matched rows on a key, insert the rest |
| Merge key | The natural/primary key the MERGE matches on |
| Idempotent | Running it twice gives the same result as running it once |
| Time travel | Reading the table as of an older snapshot |
| Expire snapshots | Deleting old snapshots so metadata stops growing |

## In this repo

| Path | What it shows |
|---|---|
| `src/glue/glue_engine/writers/s3_tables.py:175` | `append` — adds rows; falls back to CREATE on first write |
| `src/glue/glue_engine/writers/s3_tables.py:193` | `merge_into` — the real `MERGE INTO … WHEN MATCHED THEN UPDATE SET * …`, plus the CDC delete arm |
| `src/glue/glue_engine/writers/s3_tables.py:326` | `full_refresh` — replaces every row via one atomic `overwrite(lit(True))`, never a DROP |
| `src/glue/glue_engine/writers/s3_tables.py:407` | `expire_snapshots` — `CALL … system.expire_snapshots(older_than, retain_last=100)` |
| `src/glue/glue_engine/writers/s3_tables.py:539` | `_dedupe_latest` — collapses duplicate keys so MERGE can't hit a cardinality violation |
| `src/glue/glue_engine/jobs/bronze_pull.py:298-314` | The caller: specs that declare a `merge_key` upsert; everything else appends |

**The war story to tell:** `bronze.sap.zncr01` held **446,611** rows against **438,645** at source. Cause: `append` on a full-snapshot re-pull. Fix: `merge_into` on the natural key. That is the entire business case for Iceberg in one number.

## Do this

Open `writers/s3_tables.py` and read `merge_into` (line 193) top to bottom. Then answer, without running anything: **what happens if the same Glue job runs three times in a row on identical source data — with `append`, and with `merge_into`?** Now find the branch in `bronze_pull.py` that decides between them, and say what in the YAML spec flips it.

## You've got it when you can...

Explain why a reader that started a query *before* a write, and finished *after* it, never sees a partially-written table — using only the words *files*, *manifest* and *pointer*.
