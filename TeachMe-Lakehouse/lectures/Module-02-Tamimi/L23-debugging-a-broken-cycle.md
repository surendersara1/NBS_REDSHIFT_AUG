# L23 · It's 07:00 and Gold Is Missing — reading a broken cycle

**Slide:** [`_render/L23-debugging-a-broken-cycle.html`](_render/L23-debugging-a-broken-cycle.html)

## The point

Power BI is DirectQuery, so report freshness is exactly "the most recent dbt Gold build" —
**daily at 07:00 KSA** ([`docs/CLIENT-TECHNICAL-DESIGN.md:442`](../../../tamimi-lakehouse/docs/CLIENT-TECHNICAL-DESIGN.md)).
When Gold isn't there, you have maybe twenty minutes and a room full of people asking.
The instinct is to re-run something. **Don't.** The platform has already written down what
happened, in a fixed order, in places you can name. This lesson is that order — five moves
from the alert email to a diagnosis, then one decision between three recoveries of very
different cost.

The whole discipline is: **read before you act, and then pick the smallest fix that still
reaches Gold.**

## Key ideas

- **The alert email is not a notification, it's the first evidence.** `run_status` sees every
  terminal Glue state and emails the *stage*, *table*, *cycle*, the run's own recorded
  `error_message`, console links and the runbook next-steps. The ERROR block **is** the
  `runs` row — you are not being told "something failed", you are being handed the blocker.
- **Expect two emails for one failure.** The per-table stage email (what broke), and the
  cycle-level skip email (`gold_skipped` — what got held back). They are different facts.
- **The `runs` table is the flight recorder.** Keyed `(run_id HASH, stage RANGE)`, so one
  table has *several rows sharing one run_id* — `source_download`, `bronze_pull`,
  `bronze_to_silver`. Query the **`by_cycle`** GSI to see a whole day; the barrier resolves
  each table to its **latest** stage, and so should you.
- **The console scan view lies by omission.** DynamoDB's console shows a *filtered page*
  ("2/50" = 2 matched of 50 examined). Use the paginating CLI scan for the full cycle picture.
- **All-or-nothing is deliberate.** One failed table → `gold_skipped` for the whole cycle.
  Gold must never build from a partial day. So "Gold is missing" almost always means
  "exactly one table failed" — find it, don't rebuild everything.
- **Barriers are edge-triggered; the sweeper is level-triggered.** Each barrier is invoked
  once, at the end of a source Step Function. If a barrier *dies*, nothing re-evaluates it and
  the cycle sits in `running` forever. `cycle_sweeper` runs daily and does two different
  things: **RESUME** (nudge the barrier the cycle's state implies) and, only past the deadline
  *and* stalled, **CONCLUDE** (force-fail the non-terminal tables so the cycle can end).
- **Age is not evidence of death.** The sweeper originally concluded on wall-clock alone and
  force-failed three healthy QA initial reloads of 67–70 tables. Now the deadline only *opens*
  the question (`SWEEP_DEADLINE_HOURS`, 12) and progress answers it (`SWEEP_STALL_HOURS`, 3),
  with an absolute ceiling (`SWEEP_MAX_AGE_HOURS`, 96).
- **A dirty watermark is the failure that doesn't look like a failure.** A garbage `MAX()`
  value that sorts above every real one becomes the stored watermark, and every future
  `wm_col > '<wm>'` predicate then matches **nothing, forever** — green runs, zero rows, silent
  data loss. Both connectors now refuse to persist a watermark they would refuse to splice,
  refuse to move it backwards, and (for typed columns) bound the aggregate to a plausible range.
- **`MERGE_CARDINALITY_VIOLATION` means your merge_key isn't the PK — or the batch has dupes.**
  Iceberg forbids matching one target row to multiple source rows. `bronze_pull` defensively
  `dropDuplicates(merge_key)` before the upsert, because a retried `source_download` can
  double-write the same `cycle=<id>/` prefix (seen for real on `mbew`/`mbewh`, QA 2026-07-23).
- **Three recoveries, escalating.** Re-run (reopen today's cycle), backfill (a date-window
  re-pull in its own `bf-…` cycle, watermark untouched, ending in a `--full-refresh` Gold),
  re-baseline (throw the incremental state away and load the table from zero). Pick the
  cheapest one that actually fixes the data.

## The five moves

| # | Move | Where | What you're looking for |
|---|---|---|---|
| 1 | **The alarm** | SNS `…-alerts` email | `Stage:` and `Table:` — and the ERROR block |
| 2 | **The console** | DynamoDB → `tamimi-lakehouse-runs-<env>` → Query index `by_cycle` | every table × stage × status for the cycle |
| 3 | **The run row** | the `(run_id, stage)` item | `error_message` verbatim; `rows_in` / `rows_out` |
| 4 | **The Glue log** | Glue → Jobs → `…-<source>-source_download` → Runs | the stack trace / driver error behind the message |
| 5 | **The watermark** | DynamoDB `…-watermarks-<env>` | did `last_watermark_value` advance? is it *plausible*? what is `init_state`? |

Then decide. Not before.

## Symptom → likely cause → action

| Symptom | Likely cause | Action |
|---|---|---|
| `source_download` FAILED | SAP HANA host unreachable from the Glue VPC, or the `…-sap-db` secret rotated | fix the cause → **re-run Mode A** |
| Watermark frozen, 0 rows every day, no error | dirty/implausible `MAX()` the splice guard refuses (R29/R30) | reset the stored value → **backfill** the missed window |
| Cycle still `running` well past 07:00 | a barrier died mid-cycle; barriers are edge-triggered (R52) | `cycle_sweeper` RESUME nudges it; else invoke the barrier with `{"cycle_id": …}` |
| `MERGE_CARDINALITY_VIOLATION` | duplicate PKs in the batch, or `merge_key` isn't the verified PK | fix the spec's `merge_key` → **re-run** |
| Cycle says `gold_built` but Gold is yesterday's | the dbt build failed *after* the barrier marked the cycle (the barrier marks on **start**) | re-fire `…-gold-build` only — no ingest re-run |
| `download_skipped` / `transform_skipped` / `conform_skipped` | all-or-nothing: an upstream table failed, so the next phase never started | fix the *named* table, then Mode A |
| Silver error reads `conform input(s) failed: [...]` | the derived table didn't fail — its input did | re-run the **input**, never the derived table |

## The three recoveries

| | Rerun (Mode A/B/C) | Backfill (Mode D) | Re-baseline |
|---|---|---|---|
| **Question it answers** | "today broke" | "history is wrong for a date range" | "the incremental state is unrecoverable" |
| **Payload** | `{"rerun":true,"cycle_id":"2026-08-10"}` | `{"rerun":true,"source":"sap","date_from":"2026-06-01","date_to":"2026-06-20"}` | `{"initial_load":true,"force":true,"tables":["sap.mara"]}` |
| **Cycle** | reopens the existing one | its own `bf-<from>_<to>-<time>` | its own `init-…` / `rebaseline-<date>` |
| **Watermark** | advances normally | **untouched** — a backfill is a side-trip | reset; `init_state` → `initial_loaded` |
| **Gold** | incremental build | **`--full-refresh`** so an old window still surfaces | normal build after the load |
| **`run_kind`** | `rerun` | `backfill` | `initial` |
| **Cost** | minutes | Gold rebuild, all dates | hours; month-chunked |

Two rules that catch everybody:

1. **An empty/absent `tables` list means "re-run the failures."** To re-run something that
   already `succeeded`, you must **name** it. Auto-detect never touches a green table.
2. **Never list a derived/conform table** (e.g. `sales.basket`) in `tables`. It has no source
   SFN; the conform phase rebuilds it once its inputs go green. List the inputs.

## Words you'll hear

| Word | What it means here |
|---|---|
| **cycle_id** | the day's identity — the UTC date (`2026-08-10`), or a scoped `bf-…` / `init-…` id |
| **stage** | `source_download` → `bronze_pull` → `abap_transform` → `bronze_to_silver` → `silver_to_gold`; the RANGE key of `runs` |
| **barrier** | the Lambda that decides whether a phase may start, once every expected table is terminal |
| **single-flight lock** | `PutItem` with `ConditionExpression=attribute_not_exists(pk)` — only one racer claims `goldlock#<cycle>` |
| **all-or-nothing** | any failed table → the next phase is skipped for the whole cycle |
| **crash-net** | `run_status` — patches a phantom RUNNING row to FAILED when a Glue job dies without self-reporting |
| **sweeper** | `cycle_sweeper` — resumes stranded cycles; force-concludes genuinely dead ones |
| **wedged watermark** | a stored value so high that every future delta predicate matches nothing |
| **re-baseline** | throw away incremental state and full-load the table again |
| **freshness** | `pipeline_state` entity `freshness:<table>` — `last_success_at` vs `expected_within_seconds` |

## In this repo

- [`docs/OPERATIONS-RUNBOOK.md`](../../../tamimi-lakehouse/docs/OPERATIONS-RUNBOOK.md) — §2 monitor, §3 "did Gold build?", **§4 the four modes (A/B/C/D)**, §4b who gets the emails
- [`docs/runbooks/`](../../../tamimi-lakehouse/docs/runbooks/) — one per stage: `source-download-failure.md`, `bronze-pull-failure.md`, `bronze-to-silver-failure.md`, `abap-transform-failure.md`, `gold-build-failure.md`, `cycle-skipped.md`, `dispatcher-failure.md`
- [`src/lambdas/run_status/handler.py`](../../../tamimi-lakehouse/src/lambdas/run_status/handler.py) — the crash-net **and** the per-stage failure notifier; note `_gold_failure`, which is the *only* place a failed Gold build becomes an alert
- [`src/lambdas/cycle_sweeper/handler.py`](../../../tamimi-lakehouse/src/lambdas/cycle_sweeper/handler.py) — read the module docstring and `_should_conclude`; it is the best-written explanation of "slow ≠ dead" in the codebase
- [`src/shared/shared/control_plane/runs.py`](../../../tamimi-lakehouse/src/shared/shared/control_plane/runs.py) — `RunStage`, `RunStatus`, `RunKind`, the composite key and the two GSIs
- [`src/shared/shared/control_plane/watermarks.py`](../../../tamimi-lakehouse/src/shared/shared/control_plane/watermarks.py) — `InitState` (`pending` / `initial_loaded` / `cdc` / `needs_reinit`)
- [`src/shared/shared/control_plane/coordination.py`](../../../tamimi-lakehouse/src/shared/shared/control_plane/coordination.py) — `CycleState`, `CONCLUDED_CYCLE_STATES`, the four lock prefixes
- [`src/shared/shared/control_plane/pipeline_state.py`](../../../tamimi-lakehouse/src/shared/shared/control_plane/pipeline_state.py) — `FreshnessState` / `AlarmState`; the freshness signal behind "is it late?"
- [`src/glue/glue_engine/sources/rds_jdbc.py`](../../../tamimi-lakehouse/src/glue/glue_engine/sources/rds_jdbc.py) — `read_incremental`'s three-part watermark guard (plausible / spliceable / forward-only)
- [`src/glue/glue_engine/jobs/bronze_pull.py`](../../../tamimi-lakehouse/src/glue/glue_engine/jobs/bronze_pull.py) — the `dropDuplicates(merge_key)` that exists because of a real cardinality violation

> **Honest note on "the ops console":** there is no bespoke operator UI shipped today —
> `src/../ui/` is empty and `pipeline_state` is modelled *for* one. The console you actually
> use is three AWS screens: **Step Functions** (the execution graph), **DynamoDB** (`runs`
> by `by_cycle`, `coordination`), and **Glue → Runs** (the log). Learn those three.

## Do this

1. Take the last failed cycle you can find in Dev. Without asking anyone, produce four
   sentences: *which table*, *which stage*, *the exact `error_message`*, *which of the three
   recoveries you would run and why*. Then check yourself against the stage runbook.
2. Write out the Mode A / Mode D / re-baseline payloads from memory. Getting `cycle_id`
   wrong in a re-run is the most common self-inflicted incident.
3. Read `cycle_sweeper.handler` top to bottom and answer: *why are P1 (`source_download`)
   rows excluded from the force-fail pass but included in the liveness check?*
4. Explain `_is_sweeper_written` to a colleague — why must the sweeper ignore its own writes
   when deciding whether a cycle is alive?
5. Pick two of the eight Apparel Group sources and write their L23 table row in advance:
   what will "watermark frozen" look like for a SaaS API cursor (Epsilon, MoEngage) versus a
   JDBC date column (RMS, SIM, XStore)?

## You've got it when you can…

- Name the five places you look, in order, without the slide.
- Say what `runs`, `watermarks`, `coordination` and `pipeline-state` each answer — and which
  one you would *never* look at first.
- Explain why a cycle can read `gold_built` while Gold is stale, and what you re-fire.
- Choose between rerun / backfill / re-baseline out loud, and justify the choice by cost.
- State the two re-run rules: absent `tables` = failures only; never list a derived table.
- Explain a wedged watermark to a non-engineer in one sentence, and name the guard that
  prevents it now.
- Say why "the cycle has been running for 14 hours" is **not**, by itself, a reason to
  force-fail it.
