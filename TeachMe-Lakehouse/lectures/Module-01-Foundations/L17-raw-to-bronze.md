# L17 · RAW → BRONZE: Typed, Deduplicated, Idempotent

**Slide:** [`_render/L17-raw-to-bronze.html`](_render/L17-raw-to-bronze.html)

## The point

P2 (`bronze_pull`) reads the cycle P1 landed and writes it into an Iceberg table. It applies real types, collapses duplicate keys, and **upserts** instead of appending — so running it twice produces the same table, not twice the rows. What it never does is business logic. Bronze is still one row per source row; only its *shape* has changed.

## Key ideas

- **P1 and P2 are separate jobs on purpose.** P2 reads S3 via the `s3_landing` connector and never touches the source. Retries, replays and Glue's auto-retry therefore cannot hammer HANA, and a load bug is free to fix.
- **One owner per fact.** P1 owns the watermark; `bronze_pull` explicitly forces `new_watermark = watermark_value` on the landed-read path so the reader's contract is guaranteed by the job, not merely promised by the connector.
- **Types come from the spec, not from inference.** The `schema:` block in `specs/bronze/*.yaml` is the contract; the same file names the PII columns, which are hashed *before* any write.
- **`merge_key` makes replays free.** Iceberg `MERGE INTO … WHEN MATCHED THEN UPDATE SET * WHEN NOT MATCHED THEN INSERT *` keyed on the natural key. Same input twice → same row count.
- **Deduplicate before you merge.** Raw can legitimately hold duplicate keys (a retried P1 write), and Iceberg refuses to match one target row to two source rows (`MERGE_CARDINALITY_VIOLATION`). So `dropDuplicates(merge_key)` runs first.
- **Overlap is a feature.** `safety_buffer_days: 7` deliberately re-reads a trailing window, because a business date is not a change timestamp — a restated store-day keeps its original date. The MERGE absorbs the overlap.
- **The war story.** `bronze.sap.zncr01` held **446,611** rows against a **438,645**-row source (2026-07-14). Plain `append` plus overlapping loads re-inserted the same keys; nothing errored and nothing warned. Declaring `merge_key: [MANDT, DATUM, WERKS]` stopped new duplicates — the existing ones needed a separate one-time dedup, which is the expensive part.

## Words you'll hear

| Word | What it means here |
|---|---|
| P2 | The load half — reads landed files, writes Bronze |
| Idempotent | Running it again changes nothing you can observe |
| MERGE / upsert | Update the row if the key exists, insert it if it doesn't |
| `merge_key` | The natural (source) primary key the upsert matches on |
| Natural key | The key the business already has — not a surrogate id |
| CDC | Change data capture: only rows that changed since last time |
| Audit column | `_run_id`, `_ingested_at` etc. — provenance, not data |

## In this repo

- [`src/glue/glue_engine/jobs/bronze_pull.py:298-316`](../../../tamimi-lakehouse/src/glue/glue_engine/jobs/bronze_pull.py) — the write-strategy fork: `full_refresh` for Excel, `dropDuplicates` + `merge_into` when `merge_key` is declared, `append` otherwise.
- Same file, `:114-160` — the `remote_pull` branch that swaps in the `s3_landing` reader, and `:189-194`, where P2 refuses to move the watermark.
- [`src/glue/glue_engine/writers/s3_tables.py:193-281`](../../../tamimi-lakehouse/src/glue/glue_engine/writers/s3_tables.py) — `merge_into`: the generated `MERGE INTO`, the delete-aware CDC arm (`_change_op = 'D'`), and the first-write `CREATE TABLE` fallback.
- [`src/glue/specs/bronze/sap_zncr01.yaml:14-18`](../../../tamimi-lakehouse/src/glue/specs/bronze/sap_zncr01.yaml) — the merge key, with the 446,611-vs-438,645 incident recorded in the comment above it.

## Do this

1. Read the generated SQL in `merge_into`. Write out, by hand, the statement it produces for `sap.zncr01`.
2. Change one row's `ZCUSTOMER` in a copy of the landed Parquet, re-run the merge mentally, and state which arm fires.
3. Find `_dedupe_latest` in `s3_tables.py` and explain why the *first-write* path needs it just as much as the merge path does.
4. Open two bronze specs — one with `merge_key`, one without — and justify each choice from the source's shape.

## You've got it when you can…

…explain to a colleague why re-running yesterday's load is safe, name the one YAML field that makes it safe, and describe exactly how `bronze.sap.zncr01` ended up with 7,966 rows that no SAP row justified.
