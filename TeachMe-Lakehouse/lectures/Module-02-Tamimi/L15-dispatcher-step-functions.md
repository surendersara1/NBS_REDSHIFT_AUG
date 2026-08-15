# L15 · What Decides Today's Work

**Slide:** [`_render/L15-dispatcher-step-functions.html`](_render/L15-dispatcher-step-functions.html)

## The point

The cron carries no instructions. It is a doorbell.

Everything about *what runs tonight* is decided in one Python function — `_dispatch` in the dispatcher Lambda — and written down in DynamoDB **before a single Glue job starts**. Step Functions and Glue are pure execution; they never choose anything. If you want to know why a table ran (or didn't), you read the dispatcher and the cycle manifest, not the state machine.

Three things to take away:

1. **One EventBridge rule → one dispatcher → one cycle manifest → one SFN per source.** The cadence bands (hourly/daily/weekly) were collapsed into a single daily fire.
2. **The payload chooses the mode.** Same Lambda, five entry points: scheduled, `initial_load`, `rerun`, `rerun_download`, and `rerun`+dates (backfill).
3. **`StartExecution` will not accept an input over 262,144 bytes**, and at real scale the default initial load walks straight into that wall. That is not trivia — it is the reason `chunk_months` exists as an event override.

## Key ideas

- **The manifest is written first, deliberately.** `put_cycle` runs *before* any `start_execution`, "so a fast source SFN can't reach its barrier before the manifest exists". It is a **create-only** write (`ConditionExpression="attribute_not_exists(pk)"`), so a double-fire of the cron cannot resurrect a concluded cycle or reset `started_at` (which would restart the sweeper's deadline clock).
- **`expected[]` is a promise, not a wish.** A source that is enabled in `bronze_mapping` but has no configured SFN ARN is *excluded* from `expected[]` and reported as a failure — because a table in `expected[]` that can never run makes the barrier wait forever and silently downgrades every cycle to `gold_skipped`.
- **Execution names are deterministic on purpose:** `<source>-<cycle_id>`. A second cron fire the same day collides with the existing name and no-ops. But Step Functions **reserves execution names for 90 days regardless of state**, so `ExecutionAlreadyExists` does *not* mean "still running". Treating it as such made every re-dispatch of an ABORTED/FAILED cycle a silent no-op for 90 days (observed on QA 2026-07-31). The fix: read the prior execution's status, and if it is terminally dead, re-dispatch under `<name>-rHHMMSS`.
- **Month-chunking exists because Glue jobs have a wall clock.** A 5-year initial load is split into calendar-aligned windows (`_month_windows` → `_chunk_windows`), one `tables[]` item per (table × window), each its own resumable `source_download` run. Widen the chunk and you get fewer Glue startups (~75 s each) but bigger, riskier pulls; narrow it and you get resumability but startup dominates wall-clock.
- **Not every table may be windowed.** A table whose `driver_by_mode` has `full` but no `incremental` has no usable date watermark — a date predicate matches *everything*, so each "window" re-pulls the whole table. Proven from live run rows: `sap.konp` returned 371,946,132 rows for each of 3 windows. Those tables get one un-windowed chunk instead. The exception is a table that explicitly opts in via `chunk_full_reload` (e.g. `sap.vbrp`, 684 M rows), whose watermark *is* a real date.
- **The 256 KB ceiling, concretely.** 55 SAP tables × 11 six-month windows = **605 items ≈ 266,688 bytes** → `ValidationException`, nothing started, and the response still said `"status": "initial_load_started"` with `started: []`. Two mitigations shipped: the P1 item was slimmed (it no longer carries `spec_path` / `enable_silver` / `silver_spec_path` / `silver_table` — those belong to P2 and are rebuilt by the download barrier), saving ~165 bytes per item; and `chunk_months` is settable per event.
- **There is a second, different 256 KB limit.** A `Map` state's *aggregated result* also has to fit in the 256 KB state payload. Keeping the Glue `startJobRun.sync` response made a 300-item Map blow `States.DataLimitExceeded` after every chunk had succeeded. Hence `ResultPath: null` on every Task in every state machine — the barrier reads DynamoDB, never the Step Functions payload.
- **Lane interleaving.** Lane assignment is by *table name*, and the Map's in-flight set is a sliding window of consecutive items — so a table-major build put the whole in-flight window on one Glue lane. Round-robining the items across lanes turned a serial 605-chunk load back into a parallel one.

## Words you'll hear

| Word | What it means here |
|---|---|
| Cycle | One logical run of the whole pipeline. `cycle_id` is the UTC date for a scheduled run, or `init-…` / `bf-…` / `rebaseline-…` for a scoped one |
| Cycle manifest | The `cycle#<id>` row in the coordination table: what was launched, and what state the cycle is in |
| `expected[]` | The tables the barriers wait on. Only tables that were actually launched go in it |
| P1 / P2 | P1 = `source_download` (remote → raw S3). P2 = `bronze_pull` → `bronze_to_silver` (raw → Iceberg) |
| Dispatch / fan-out | Starting one Step Functions execution per source with that source's table list as input |
| Chunk / window | One `(table, date-range)` item. A 5-year load is many chunks per table |
| Gate 0 | The rule that a table may not join the daily CDC cycle until its one-time initial load has completed |
| `run_kind` | Provenance stamped on every run row: `scheduled` / `initial` / `cdc` / `rerun` / `backfill` |

## In this repo

- [`src/lambdas/dispatcher/handler.py:578-951`](../../../tamimi-lakehouse/src/lambdas/dispatcher/handler.py) — `_dispatch`: scan enabled `bronze_mapping`, group by `source_id`, build the launch plan, `put_cycle`, fan out. Read the mode routing at `:591-608` first — it is five `if`s and it is the whole API.
- [`:426-477`](../../../tamimi-lakehouse/src/lambdas/dispatcher/handler.py) — `_make_table_item`, whose docstring carries the 256 KB arithmetic and explains exactly which keys a P1 item is *not* allowed to carry.
- [`:1285-1322`](../../../tamimi-lakehouse/src/lambdas/dispatcher/handler.py) — `_month_windows` / `_chunk_windows`. Twenty lines; read them and you know exactly what a chunk is.
- [`:161-207`](../../../tamimi-lakehouse/src/lambdas/dispatcher/handler.py) — `_is_full_only`, and the measured evidence for why a full-only table must not be windowed.
- [`:972-1024`](../../../tamimi-lakehouse/src/lambdas/dispatcher/handler.py) — `_start_source_sfn` and the 90-day execution-name trap.
- [`:77-116`](../../../tamimi-lakehouse/src/lambdas/dispatcher/handler.py) — the three tuning knobs: `INITIAL_LOAD_LOOKBACK_YEARS`, `INITIAL_LOAD_CHUNK_MONTHS`, `FULL_RELOAD_CHUNK_MONTHS`. The comment on the last one is a small masterclass in why you measure a distribution instead of assuming one.
- [`infra/env/dev/per_source_ingestion.tf:43-227`](../../../tamimi-lakehouse/infra/env/dev/per_source_ingestion.tf) — the P2 state machine: `Map` over `$.tables`, `MaxConcurrency 10`, per-item `Catch → ItemFailed → Succeed` (failure isolation), `ResultPath: null` everywhere, then the barrier tail at `:201-222`.
- [`infra/env/dev/source_download.tf:19-135`](../../../tamimi-lakehouse/infra/env/dev/source_download.tf) — the P1 state machine: 24 h envelope, `MaxConcurrency 6`, and the lane-spread `JobName.$` trick.
- [`infra/modules/dispatcher_lambda/eventbridge.tf:11-47`](../../../tamimi-lakehouse/infra/modules/dispatcher_lambda/eventbridge.tf) + [`variables.tf:134-138`](../../../tamimi-lakehouse/infra/modules/dispatcher_lambda/variables.tf) — one rule, `cron(0 21 * * ? *)` = 00:00 KSA (KSA has no DST, so the offset is fixed). Note `schedule_enabled` — the rules exist in Dev but are DISABLED, so Dev is manual-only.
- [`docs/TICKET-initial-load-sfn-input-size.md`](../../../tamimi-lakehouse/docs/TICKET-initial-load-sfn-input-size.md) — the 256 KB incident written up properly, including why batching by `tables` is *not* a safe workaround (it fragments one logical load into several cycles).

## Do this

1. Invoke the Dev dispatcher with `{}` and read the response body. Name every field: `expected_count`, `started`, `failures`, `gate0_blocked`. Then find the `cycle#<today>` row in `tamimi-lakehouse-coordination-dev` and check `expected[]` matches.
2. Compute the input size yourself. Take today's `tables[]` list from the response, `json.dumps` it, and print `len(...)`. Now multiply by the number of chunks a 5-year load would create. Decide what `chunk_months` you would pass.
3. Re-invoke the dispatcher twice within a minute. Prove to yourself that nothing ran twice, and say **which** of the two mechanisms stopped it (the deterministic execution name, or `put_cycle`'s create-only condition). Then answer: what would have happened if last night's execution had been *aborted*?
4. Open `per_source_ingestion.tf` and find every `ResultPath = null`. For each one, say what would have been in the payload if it had been kept.

## You've got it when you can…

…take a payload you have never seen — say `{"initial_load": true, "source": "sap", "chunk_months": 3}` — and predict, before running it: which cycle_id it creates, roughly how many Glue runs it will produce, whether the SFN input will fit in 256 KB, and which barrier will decide when it's finished.
