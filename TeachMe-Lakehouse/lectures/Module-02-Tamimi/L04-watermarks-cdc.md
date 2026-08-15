# L04 · The Delta Window

> **Module 2 · Lesson 04** · ~45 min

**Slide:** [`_render/L04-watermarks-cdc.html`](_render/L04-watermarks-cdc.html)

## The point

A daily delta is one string interpolated into one `WHERE` clause. Everything that can go wrong with incremental ingestion goes wrong *in that string* — because SAP's date columns are not dates, they are `NVARCHAR(8)` text, and text columns hold whatever someone typed.

So the interesting decision in this file is not how we advance the watermark. It is **when we refuse to.** A `MAX()` that returns a status character `'S'` would be stored, then spliced next cycle, then rejected by our own guard — wedging that table forever. We would rather re-read yesterday.

## Key ideas

- **`_build_query` composes, it does not template.** Projection (the spec's own columns, quoted — never `SELECT *`), then a predicate list: MANDT client filter, watermark comparison, optional static filter. Missing pieces just don't appear.
- **The MANDT filter is not optional.** SAP application tables are client-partitioned; without `WHERE MANDT = '100'` the test client's rows leak into your facts. `configure()` demands either a digit `client` or an explicit `client_independent: true`.
- **The watermark is validated before it is spliced.** It must match ISO-8601-with-time or an all-digit id. Anything else raises `"refusing to splice watermark ... into SQL"` — an injection defence that doubles as a corruption detector.
- **Empty string is "no watermark yet", not "malformed".** `''` is the control plane's own sentinel; treating it as a value once sent a first-ever run straight into the splice guard.
- **SAP dates are text, so windows need reformatting.** `--date_from 2026-07-01` arrives ISO; `BUDAT` holds `'20260701'`. `watermark_date_format: "YYYYMMDD"` makes `_fmt_date` strip the dashes. Forget it and the `BETWEEN` matches nothing — a windowed load landed **0 rows** on 2026-07-17.
- **Projection guard.** `configure()` refuses a spec whose column list omits the watermark column, because `df.agg(F.max(watermark_column))` would otherwise raise an `AnalysisException` *after* the entire JDBC pull has been paid for.
- **What `MAX()` actually returns on these columns:** `'502812'` (not a date), `'22080401'` (a typo year), `'730121V1'` (a source-side column-shift defect in ZECOM's `ZDATE`), and in the worst case a letter, which sorts *after* every digit. All live-observed.
- **So the max is taken over plausible rows only** — 8 digits, ≥ `19000101`, ≤ today — and if the candidate still would not splice, the **prior watermark is kept**. Garbage rows still land in Bronze; they just cannot become the bookmark.
- **Forward-only.** With `safety_buffer_days` the read window starts *before* the stored watermark, so a hard delete upstream can make the window's `MAX()` come back lower. Persisting that would rewind progress every cycle, so a lower value is refused too.
- **Re-reading is free, wedging is not.** The Bronze MERGE on `merge_key` is idempotent, so keeping the old watermark costs one repeated delta. Storing a bad one costs every future cycle until a human notices.
- **No usable date column → don't run a delta at all.** 27 SAP tables watermark on a constant (25 × `MANDT`, plus `ZINPUT` and `DOMNAME`). They are set to `driver_by_mode: {full: sap_hana}` so the delta path never runs. Before that fix, a live daily fire failed **24 of 32** tables with `refusing to splice watermark ''`, and the all-or-nothing barrier held Bronze for the whole cycle.

## Words you'll hear

| Term | Means |
|---|---|
| Watermark | The stored high-water value of the watermark column — a bookmark, not a timestamp of the run |
| Splice | Interpolating a value into SQL text (hence the pattern check before doing it) |
| `watermark_date_format` | `YYYYMMDD` for SAP's dashless text dates; ISO otherwise |
| `safety_buffer_days` | Widen the delta's lower bound by N days to catch late-posted rows |
| Dirty watermark | A `MAX()` that is not a plausible, spliceable date |
| Wedged | A table whose stored watermark makes every future run fail at the same guard |
| `_watermark_valid` | The per-row Bronze audit column labelling row-level watermark quality |
| Forward-only | A new watermark below the stored one is discarded |

## In this repo

- [`src/glue/glue_engine/sources/sap_hana.py:544-592`](../../../tamimi-lakehouse/src/glue/glue_engine/sources/sap_hana.py) — `_build_query`. Note the comment at `:570-575` on why *falsy* means absent and only a non-empty unparseable value is corruption.
- [`src/glue/glue_engine/sources/sap_hana.py:1117-1231`](../../../tamimi-lakehouse/src/glue/glue_engine/sources/sap_hana.py) — `read_incremental` end to end: `.cache()` before the multi-action sequence (`:1160`), the plausible-only aggregate (`:1167-1182`), the refusal to persist (`:1188-1206`), and the forward-only check (`:1207-1223`).
- [`src/glue/glue_engine/sources/sap_hana.py:774-798`](../../../tamimi-lakehouse/src/glue/glue_engine/sources/sap_hana.py) — `_watermark_to_iso`, and the two garbage values observed live on 2026-07-17.
- [`src/glue/glue_engine/sources/sap_hana.py:465-474`](../../../tamimi-lakehouse/src/glue/glue_engine/sources/sap_hana.py) — the watermark-column-in-projection guard.
- [`src/glue/glue_engine/sources/sap_hana.py:644-664`](../../../tamimi-lakehouse/src/glue/glue_engine/sources/sap_hana.py) — `_fmt_date` and `format_watermark_bound`.
- [`src/glue/glue_engine/sources/sap_hana.py:594-642`](../../../tamimi-lakehouse/src/glue/glue_engine/sources/sap_hana.py) — `_buffered_watermark`: widen the read, never move the stored value.
- [`src/glue/glue_engine/sources/sap_hana.py:120-155`](../../../tamimi-lakehouse/src/glue/glue_engine/sources/sap_hana.py) — `_watermark_valid_for_row`, the pure-Python reference spec for the native Spark expression at `:1097-1112`, plus the Java-vs-Python `$` difference that made the explicit length check load-bearing.
- **Commit `cbfa266`** — *"fix(ingestion): full-refresh the 27 SAP tables with non-date watermarks"*. The message is the incident report; read it before the diff.
- [`CLAUDE.md:101-112`](../../../tamimi-lakehouse/CLAUDE.md) — the JDBC-only policy, and the standing caveat that a creation-date watermark cannot see hard deletes or in-place edits.

## Do this

Take a table whose stored watermark is `'S'`. Write down, in order, exactly what happens on the next scheduled run — which function raises, what the `runs` row looks like, and whether the barrier lets the cycle proceed. Then find the two independent places in `sap_hana.py` that would have stopped `'S'` from being stored in the first place, and say which one fires first.

## You've got it when you can…

…answer "why didn't the watermark move even though the job succeeded?" with a specific reason — empty delta, unspliceable `MAX()`, or a value behind the stored one — and name the log line each case emits.
