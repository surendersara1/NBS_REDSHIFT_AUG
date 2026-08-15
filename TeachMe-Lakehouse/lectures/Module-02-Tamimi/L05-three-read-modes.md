# L05 · Full, Windowed, Backfill

> **Module 2 · Lesson 05** · ~45 min

**Slide:** [`_render/L05-three-read-modes.html`](_render/L05-three-read-modes.html)

## The point

Three read modes, chosen by one line of Python. The line itself is trivial; what surrounds it is not. Two policies and one state machine exist because each of them was learned from a live failure: a table that loaded a meaningless window and landed empty, a full extract that would have overwritten good data with nothing, and a giant that declared itself loaded while most of its history was still landing.

## Key ideas

- **Precedence is literal:** `read_mode = "range" if date_from else ("full" if full_snapshot else "incremental")`. A date window beats a full-snapshot flag; the daily delta is what's left.
- **`full` can be *derived*, not just passed.** If the table's mapping declares only `full` (no `incremental`), the job forces `full_snapshot = True` **and clears `date_from`**. A full-refresh table has no real date column, so a uniform initial-load window would filter on a placeholder and match nothing.
- **That derivation has exactly one exception:** `chunk_full_reload`. `sap.vbrp` is *both* full-only *and* 126 windows' worth of rows; without the exception the branch silently un-windowed every chunk and turned each into a complete 684,592,846-row read.
- **An initial load MUST be a full load, never windowed.** The invariant it protects is Bronze parity: a Bronze base table's row count must equal SAP's *within the initial-load horizon* (default last 5 years). Sub-windowing below the horizon is a bug — on 2026-07-15 `zdsales`/`zncr01`/`s611` loaded to a tiny window and Bronze came out far below SAP.
- **Master and creation-date tables load truly full — no horizon at all.** `KNA1` keyed on `ERDAT` keeps only ~33% of customers at a 5-year window, dropping active master data.
- **Empty results mean opposite things in the two directions.** An empty *delta* is a quiet window: succeed. An empty *full snapshot* is almost always a broken extract: fail — and fail **before** landing, so no `_SUCCESS` marker is written and the watermark is untouched. A spec's `on_empty` overrides both.
- **`init_state` is Gate 0's memory:** `(none)` → `initial_loaded` (an un-windowed `run_kind=initial` succeeded) → `cdc` (the first plain daily delta after that).
- **A windowed chunk never flips it.** Chunks run concurrently across lanes and finish out of order, so no single chunk can know the load is done. Flipping on the first one to finish admitted `sap.s603` into the very next daily cycle at watermark `20220131` — mid-reload, 649M rows (live 2026-08-09). The `download_barrier` owns the flip, once, when every chunk of every table is terminal.
- **A windowed *initial* load still seeds its watermark**, forward-only, from the window's end — otherwise a giant that never gets a full pull goes `initial_loaded` with watermark `''` and every later delta dies at the splice guard.
- **A backfill is a side trip, not progress.** `read_range` returns a DataFrame only; the watermark does not advance, and each chunk writes under its own `chunk=<from>_<to>` sub-prefix so concurrent chunks cannot clobber each other.

## Words you'll hear

| Term | Means |
|---|---|
| Read-mode | `full` / `range` / `incremental` — which connector method runs |
| `full_snapshot` | Job arg (or derived flag) meaning "read everything in scope" |
| Backfill | A bounded `[date_from, date_to]` re-pull that does not advance the watermark |
| Initial-load horizon | `INITIAL_LOAD_LOOKBACK_YEARS`, default 5 — the defined scope of "full" |
| Bronze parity | Bronze's row count equals SAP's, measured with the same horizon filter |
| `on_empty` | Per-spec override of the zero-row policy: `succeed` / `warn` / `fail` |
| `init_state` | `(none)` → `initial_loaded` → `cdc`, plus `needs_reinit` |
| Gate 0 | The admission check that keeps a table out of CDC until its initial load is done |
| `chunk_full_reload` | Opt-in flag: full-refresh, but delivered as many date windows |

## In this repo

- [`src/glue/glue_engine/jobs/source_download.py:222`](../../../tamimi-lakehouse/src/glue/glue_engine/jobs/source_download.py) — the precedence line; `:235-267` are the three branches it selects.
- [`src/glue/glue_engine/jobs/source_download.py:172-213`](../../../tamimi-lakehouse/src/glue/glue_engine/jobs/source_download.py) — the full-only derivation, the 2026-07-16 empty-landing incident (`tvfkt`/`twewt`/`twtyt`/`zzz_mc2t`), and the `chunk_full_reload` exception found live on 2026-08-09.
- [`src/glue/glue_engine/jobs/source_download.py:272-296`](../../../tamimi-lakehouse/src/glue/glue_engine/jobs/source_download.py) — the empty-result policy, resolved by [`bronze_pull.py:393`](../../../tamimi-lakehouse/src/glue/glue_engine/jobs/bronze_pull.py) (`_resolve_empty_policy`).
- [`src/glue/glue_engine/jobs/source_download.py:318-363`](../../../tamimi-lakehouse/src/glue/glue_engine/jobs/source_download.py) — the `init_state` lifecycle and why a windowed chunk must not flip it.
- [`src/glue/glue_engine/jobs/source_download.py:246-258`](../../../tamimi-lakehouse/src/glue/glue_engine/jobs/source_download.py) — TML-64, the forward-only watermark seed for a windowed initial load.
- [`src/lambdas/download_barrier/handler.py:166`](../../../tamimi-lakehouse/src/lambdas/download_barrier/handler.py) — `_completed_initial_loads`, the phase owner that actually declares an initial load complete.
- [`CLAUDE.md:91-99`](../../../tamimi-lakehouse/CLAUDE.md) — "Initial load = full load = the last N years", the master/creation-date exception, and the 2026-07-17 data-horizon evidence.
- [`CLAUDE.md:114-125`](../../../tamimi-lakehouse/CLAUDE.md) — the Bronze parity invariant, and the instruction to verify it on **both** sides rather than assert it from the code.

## Do this

Pick one table from `config/ingestion_tables.yaml` and answer four questions from config alone: (1) which read-mode does its next scheduled run take? (2) if it returns zero rows, does the run succeed or fail? (3) what is its `init_state` right now, and what would flip it? (4) if you had to re-load one month of it, which mode would you use and would the watermark move? Then verify (1) and (3) against its `watermarks` row in DynamoDB.

## You've got it when you can…

…say why an empty pull is a *success* for one table and a *failure* for another on the same morning — and why declaring a windowed chunk `initial_loaded` is the more dangerous of the two mistakes.
