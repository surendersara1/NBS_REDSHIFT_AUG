# L06 · A Folder of Files Is Not a Table
> **Module 1 · Lesson 06** · ~45 min

## The point
Putting Parquet on S3 is an afternoon's work; making that pile of files behave like a table — atomic, typed, updatable, safe for concurrent readers — is the problem a *table format* exists to solve.

## Key ideas
- What you actually have is a **prefix**: a dozen `part-*.parquet` objects under `sap/sap.s611/cycle=.../`. Nothing in there says "table".
- **No atomicity.** A reader can arrive halfway through a write and see 6 of 12 files. Half the files is not half the truth — it is a wrong answer.
- **No schema.** Types live inside each file, not across the set. When file 9 renames or retypes a column, nothing decides who wins.
- **No updates.** S3 objects are immutable: there is no `UPDATE`. Changing one row means rewriting the file that holds it.
- **No concurrency.** Two writers, no lock, last one wins — and readers watch the file list move under them.
- The fix is a **metadata layer** that sits above the unchanged data files: **manifests** (which files belong to the table, with row counts and min/max) and a **snapshot** (one pointer that *is* the table).
- Swapping the snapshot pointer is a single atomic commit, so nobody ever sees half a write — and the old pointer still reads the old set of files.
- Our `_SUCCESS` marker in raw is the poor-man's version of this: data files written first, marker last, and readers refuse a prefix with no marker.

## Words you'll hear
| Term | Means |
|---|---|
| Table format | the metadata spec that turns files into a table |
| Manifest | a list of data files plus per-file stats |
| Snapshot | an immutable pointer to one exact set of files = one table version |
| Commit | publishing a new snapshot, atomically |
| Atomicity | all of a write is visible, or none of it |
| `_SUCCESS` | marker file proving a write finished (our raw-zone version) |

## In this repo
- `src/glue/glue_engine/writers/raw_landing.py` — the folder-of-files problem in the flesh: per-cycle prefix, data files first, `_SUCCESS` last.
- `src/glue/glue_engine/sources/landed_files.py` — the reader that refuses a prefix without a `_SUCCESS` marker.
- `src/glue/glue_engine/writers/s3_tables.py` — where the real metadata layer takes over (Lesson 07).

## Do this
Read the module docstring at the top of `writers/raw_landing.py` and explain why the `_SUCCESS` marker is written last — then list one failure it still does not protect against.

## You've got it when you can...
Say what breaks when two jobs write to the same S3 prefix at the same time, and name the two metadata pieces that make it safe.
