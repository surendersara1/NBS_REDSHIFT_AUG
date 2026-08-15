# L06 · What's Actually on Disk

**Slide:** [`_render/L06-opening-an-iceberg-table.html`](_render/L06-opening-an-iceberg-table.html)

## The point

Module 1 told you "Silver is Iceberg on S3 Tables". This lesson opens the box. An Iceberg table is **not** a database and it is **not** a folder of Parquet — it is a short chain of pointer files, and a commit is one swap at the top of that chain.

Read it top-down, the way an engine does:

`metadata.json` → **manifest list** (one per snapshot) → **manifests** (the file inventory) → **data files** (Parquet).

Everything you will debug in the next three lessons — cardinality errors, small files, schema drift — is a consequence of that shape.

## Key ideas

- **`metadata.json` is the table.** It holds the current schema, the partition spec, the full list of snapshots, and which snapshot id is *current*. Point a reader at a different `metadata.json` and it sees a different table.
- **One snapshot = one manifest list.** The manifest list names the manifests that make up that snapshot, plus their partition ranges, so a planner can skip whole manifests before it reads them.
- **Manifests are the inventory, and they carry statistics** — row counts, null counts, min/max per column. Most "why is this query fast" answers live here: the engine prunes files on stats without opening them.
- **Data files are immutable.** Nothing is edited in place. An update writes new Parquet and a new snapshot that stops referring to the old file. That is why "MERGE" and "overwrite" both cost you new files.
- **Snapshots are an append-only log.** Snapshot 3 still names exactly the files it named after snapshot 4 lands. That is what makes time travel and rollback possible — and it is exactly why metadata grows forever without expiry (Lesson 08).
- **"Atomic" means one pointer swap.** A commit writes all the new files first, then swaps which metadata file is current, in one step. A reader that already resolved the old pointer keeps reading a complete older table. There is no window in which the table is half-written.
- **You can see the pointer from Spark.** The repo does exactly that after every write: it reads the newest `metadata_location` from the table's own `metadata_log_entries` metadata table and re-registers it in the Glue mirror catalog so Redshift Spectrum sees the newest snapshot.

## Words you'll hear

| Word | What it means here |
|---|---|
| `metadata.json` | The table's root pointer file: schema, partition spec, snapshot list, current snapshot id |
| Manifest list | One Avro file per snapshot; names the manifests belonging to that snapshot |
| Manifest | An Avro file listing data files plus per-column stats used for pruning |
| Snapshot | One immutable version of the table, produced by one commit |
| `metadata_location` | The S3 URI of the current `metadata.json` — what the Glue catalog stores |
| Commit | Write new files, then swap the current-metadata pointer. One step |
| Time travel | Reading an older snapshot, which is possible only because nothing is deleted |

## In this repo

- [`src/glue/glue_engine/writers/s3_tables.py:487-489`](../../../tamimi-lakehouse/src/glue/glue_engine/writers/s3_tables.py) — the writer reads the live pointer straight off the table:
  `SELECT file FROM <fqn>.metadata_log_entries ORDER BY timestamp DESC LIMIT 1`.
- [`src/glue/glue_engine/writers/s3_tables.py:515-531`](../../../tamimi-lakehouse/src/glue/glue_engine/writers/s3_tables.py) — `glue.create_table` with `Parameters.metadata_location=<latest>`. Line 528 splits that URI on `"/metadata/"` to recover the table root: proof that the metadata files live under `<table-root>/metadata/`.
- [`src/glue/glue_engine/writers/s3_tables.py:505-513`](../../../tamimi-lakehouse/src/glue/glue_engine/writers/s3_tables.py) — the mirror table is deleted and recreated on every write **because the `metadata_location` changes on every write**. If you only remember one line from this lesson, remember why that delete is there.
- [`src/glue/glue_engine/writers/s3_tables.py:143-173`](../../../tamimi-lakehouse/src/glue/glue_engine/writers/s3_tables.py) — `_first_write_create`: the CREATE TABLE that produces the very first `metadata.json`, including `PARTITIONED BY` (see Lesson 09).
- [`docs/design-reference/decisions/0024-s3-tables-managed-iceberg.md`](../../../tamimi-lakehouse/docs/design-reference/decisions/0024-s3-tables-managed-iceberg.md) — why Bronze and Silver are S3 Tables at all, and the hard rule that follows from this file layout: **no S3 SDK access to table-bucket objects, only Iceberg APIs.**

## Do this

1. In a Glue/Spark session against Dev, run `SELECT * FROM <catalog>.<ns>.<table>.metadata_log_entries ORDER BY timestamp DESC` on a Silver table. Count the rows. That is your commit history.
2. Then `SELECT * FROM <catalog>.<ns>.<table>.snapshots` and `.files`. Match one snapshot to its manifest list, and one manifest to a Parquet file. Say out loud which level each row came from.
3. Trigger one more Bronze load and re-run the first query. Exactly one new row should appear, and the `metadata_location` in the Glue mirror table should now point at it.
4. Explain, without looking, why `_register_in_mirror_catalog` has to delete before it creates.

## You've got it when you can…

…draw `metadata.json → manifest list → manifests → data files` from memory, say which of those four an engine reads first and which one it usually doesn't need to read at all, and answer "what makes an Iceberg commit atomic?" with **"it swaps one pointer, after all the new files are already written"** — then point at the line in `s3_tables.py` that reads that pointer.
