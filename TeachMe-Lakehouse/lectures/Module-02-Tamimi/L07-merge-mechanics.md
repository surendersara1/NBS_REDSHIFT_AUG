# L07 · Why This MERGE Failed

**Slide:** [`_render/L07-merge-mechanics.html`](_render/L07-merge-mechanics.html)

## The point

`MERGE INTO` is how Bronze and Silver stay idempotent: replays, overlapping windows and Glue auto-retries land each row **once** instead of duplicating it. It works because of one rule, and it fails for one reason.

**The rule:** a target row may be claimed by **at most one** source row. Two source rows matching the same target row is `MERGE_CARDINALITY_VIOLATION`, and the job dies.

**Therefore:** a cardinality error is never a bug in the target. It is a duplicate that arrived with the source. You fix it upstream, before the MERGE, and this repo now does that in three separate places.

## Key ideas

- **The arms.** `WHEN MATCHED THEN UPDATE SET *` handles the update; `WHEN NOT MATCHED THEN INSERT *` handles the insert. That pair is the classic upsert and is what most tables get.
- **The delete-aware third arm.** When the frame carries `_change_op` (SAP ODP deltas), the writer builds a different statement: `WHEN MATCHED AND s._change_op = 'D' THEN DELETE`, plus `WHEN NOT MATCHED AND s._change_op <> 'D' THEN INSERT`. A `'D'` for a row that is already absent is deliberately **not** inserted, and `_change_op` itself is excluded from the written column list — it is a Bronze audit column, not a Silver attribute.
- **The one-match constraint is a planner rule, not a data rule.** Iceberg refuses because the result would be non-deterministic: which of the two source rows should win? It will not guess.
- **The real incident (2026-07-23, QA).** A retried `source_download` re-wrote the same `cycle=<id>/` RAW prefix. Two overlapping `.mode("overwrite")` writes do **not** clean each other on S3, so the full snapshot landed twice → duplicate PKs → `MERGE_CARDINALITY_VIOLATION` in `bronze_pull` on `sap.mbew` / `sap.mbewh`, blocking the SAP→Gold E2E at the RAW→BRONZE hop. Fixed in commit **`359b3b2`**.
- **Dedup is safe here for a specific reason, not in general.** A JDBC watermark-range delta is a *current-state snapshot* — one row per PK. So collapsing to one row per `merge_key` only ever drops byte-identical copies, never a distinct update. Say that reason out loud before you add a `dropDuplicates` anywhere else.
- **When you have audit columns, pick a winner deterministically.** `_dedupe_latest` ranks with `ROW_NUMBER() OVER (PARTITION BY key ORDER BY _ingested_at DESC, _run_id DESC)` and keeps rank 1 — the same ordering as the offline parity cleanup, so an in-flight dedup and a retrospective one agree. Without those columns it falls back to `dropDuplicates(key)` (arbitrary winner).
- **First write is the sneaky one.** `MERGE INTO` on a non-existent table raises table-not-found and falls back to `CREATE TABLE + append`, which appends the frame **verbatim**. If the source was not deduped, duplicate keys become permanent Bronze PK duplicates from day one — that is the `zncr01` defect (446,611 rows landed against a 438,645-row source).
- **`QUALIFY` is the canonical idiom, but not on Spectrum.** Redshift raises `syntax error at or near ROW_NUMBER` for `QUALIFY` when the scan targets a Spectrum external table, so the staging models use an equivalent ranked subquery with `WHERE _rn = 1`.

## Words you'll hear

| Word | What it means here |
|---|---|
| Upsert | Update if the key exists, insert if it doesn't — one statement |
| `merge_key` | The natural/primary key a Bronze spec declares for the MERGE |
| `MERGE_CARDINALITY_VIOLATION` | Two source rows matched one target row; Iceberg refuses to guess |
| Delete-aware MERGE | The extra arm that turns `_change_op='D'` into a real DELETE (gap G09) |
| Idempotent | Re-running the same input leaves the same row count — the whole point of MERGE |
| `QUALIFY` | Filter on a window function without a subquery. Unsupported over Spectrum externals |
| Source-side dedup | Collapsing the input to one row per key *before* the MERGE sees it |

## In this repo

- [`src/glue/glue_engine/writers/s3_tables.py:193-281`](../../../tamimi-lakehouse/src/glue/glue_engine/writers/s3_tables.py) — `merge_into`. Read the docstring first (`:196-228`), then the two SQL branches: delete-aware at `:251-266`, classic upsert at `:267-274`.
- [`src/glue/glue_engine/writers/s3_tables.py:241`](../../../tamimi-lakehouse/src/glue/glue_engine/writers/s3_tables.py) — `source = df if delete_aware else _dedupe_latest(df, key)`, and the comment above it explaining the `zncr01` defect and the first-write trap. `_dedupe_latest` itself is at `:539-561`.
- [`src/glue/glue_engine/jobs/bronze_pull.py:302-314`](../../../tamimi-lakehouse/src/glue/glue_engine/jobs/bronze_pull.py) — the `359b3b2` fix: `df = df.dropDuplicates(list(spec.merge_key))` immediately before `writer.merge_into(...)`, with the incident written into the comment.
- [`src/glue/glue_engine/jobs/bronze_to_silver.py:213-233`](../../../tamimi-lakehouse/src/glue/glue_engine/jobs/bronze_to_silver.py) — where the key comes from on the Silver side: the spec's `deduplicate` op. No `deduplicate` op → the job refuses to run rather than MERGE on a guessed key.
- [`src/glue/glue_engine/spec.py:132-144`](../../../tamimi-lakehouse/src/glue/glue_engine/spec.py) — the `merge_key` field, with the TML-68 rationale and the 446,611-vs-438,645 numbers. Example in use: [`src/glue/specs/bronze/sap_mbew.yaml:14`](../../../tamimi-lakehouse/src/glue/specs/bronze/sap_mbew.yaml) — `merge_key: [MANDT, MATNR, BWKEY, BWTAR]`.
- [`src/dbt/models/staging/stg_sap_zscc.sql:19-63`](../../../tamimi-lakehouse/src/dbt/models/staging/stg_sap_zscc.sql) — the same problem one layer up: a duplicate `(site, date)` would fan out `unified_sales`' All-Dept joins and break the **Redshift** MERGE with "multiple matches". Note the comment recording why `QUALIFY` could not be used.

## Do this

1. Read `merge_into` end to end and write down, from the code alone, the exact SQL it emits for (a) a frame with `_change_op` and (b) one without.
2. `git show 359b3b2`. Read the commit message before the diff — it is a model incident write-up: symptom, mechanism, blast radius, fix, why the fix is safe.
3. **Break it:** build a two-row DataFrame with the same `merge_key`, MERGE it into a Dev table, and read the error text. Then add `dropDuplicates` and watch it pass.
4. Answer this: why is the delete-aware source deliberately *not* passed through `_dedupe_latest`? (Hint: what would happen to a `'D'` marker?)
5. Take one Silver spec and find its `deduplicate` key. Convince yourself it is genuinely unique in Bronze — that key is the whole contract.

## You've got it when you can…

…read `MERGE_CARDINALITY_VIOLATION` in a Glue log and, without opening the target table, say **"two source rows share a merge key — something upstream landed twice"**; name the three places this repo dedupes (job, writer, dbt staging); and explain why deduping the source is safe for a watermark-range delta but would be dangerous for a true CDC stream carrying `'D'` markers.
