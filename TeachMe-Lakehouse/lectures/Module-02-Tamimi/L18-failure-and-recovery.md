# L18 · When It Breaks at 3 AM

**Slide:** [`_render/L18-failure-and-recovery.html`](_render/L18-failure-and-recovery.html)

## The point

The alert says a table failed and Gold was skipped. You have three decisions to make, in this order:

1. **What actually failed?** → read the `runs` row's `error_message` (L17).
2. **Is it safe to just re-run it?** → yes, and the slide lists the five independent reasons why.
3. **Which kind of re-run?** → `rerun`, `rerun_download`, backfill, or re-baseline. They are not interchangeable.

The design principle behind all of it: **re-running is the normal move, not the desperate one.** Every write in this pipeline is safe to repeat, and the system is built so that a second attempt is either identical work or a no-op. If re-running feels risky, you have misunderstood something — go and find which of the five guarantees you don't believe.

## Key ideas

### Idempotency, end to end

Five independent mechanisms, at five different layers:

1. **The execution name.** `<source>-<cycle_id>` is deterministic, so a duplicate dispatch collides and no-ops. The trap: Step Functions reserves names for **90 days regardless of state**, so `ExecutionAlreadyExists` is not proof of "still running". A terminally dead prior run is re-dispatched under `<name>-rHHMMSS`.
2. **The manifest.** `put_cycle` is create-only (`attribute_not_exists(pk)`) — a re-fire cannot overwrite a manifest that is already `gold_built`, nor reset `started_at` and restart the sweeper's clock.
3. **The locks.** One conditional write per phase; the loser does nothing (L16).
4. **The writes themselves.** Bronze overwrites its snapshot; Silver MERGEs on key or overwrites partitions. Re-running a table never duplicates rows.
5. **Resolution by latest run.** A barrier judges each table by its most recent row, so a fresh SUCCEEDED run supersedes the old FAILED one without anyone deleting anything.

### Why the Gold barrier looks before it leaps

`StartJobRun` has **no client idempotency token**. So this sequence is possible:

```
03:12:04  StartJobRun → Glue ACCEPTS the run, r-8821 starts
03:12:34  the API response never comes back (socket timeout)
03:12:35  the SFN Task retries the barrier → a fresh lock claim succeeds
          → a SECOND gold build for the same day
```

Note that the lock does **not** save you here: the first attempt released it (or the retry landed in a re-opened cycle), and from the second invocation's point of view everything looks fine. Locks protect against *concurrent deciders*; they do not protect against *an ambiguous side effect you already caused*.

So before starting, the barrier calls `get_job_runs(MaxResults=50)` and looks for a run whose `--cycle_id` argument matches this cycle and whose state is `STARTING` / `RUNNING` / `WAITING` / `SUCCEEDED`. If it finds one, it treats the day as already built, reconciles the cycle state, and returns `gold_already_running`.

It **fails open**: any error in the pre-check (throttle, missing permission) returns `None` and the caller proceeds to start — the pre-existing behaviour, never worse than before the guard existed. That is the right default for a guard that is an optimisation over correctness rather than the correctness mechanism itself.

### The cycle sweeper — the level-triggered net

Barriers are edge-triggered: invoked once, at the end of a phase. If a barrier *dies*, nothing re-evaluates it and the cycle sits forever. The sweeper runs every 15 minutes and does two different jobs:

- **RESUME** (every pass, no deadline). For any non-concluded cycle, re-invoke the barrier its state implies: `running` → download barrier, `download_built` → transform barrier, `transform_built` → gold barrier. Barriers are self-gating (`no_cycle` / `already_concluded` / `waiting`) and single-flight, so a nudge is free unless the gate is genuinely satisfiable. This exists because of a real incident: the download barrier crashed on a manifest `ValidationError` for four consecutive invocations while P1 had SUCCEEDED and the gate had been satisfiable the whole time.
- **CONCLUDE** (only when overdue **and** no longer moving). Force-fail every expected table that is still non-terminal — writing a synthetic FAILED `bronze_pull` row for a table with no row at all — then re-invoke the gold barrier so it claims the lock and concludes `gold_skipped` + alert.

**Age alone is not evidence of death**, and treating it as such destroyed real work: QA force-failed three healthy initial reloads (67–70 tables each) whose only fault was taking longer than the deadline. So now the 12 h deadline only *opens the question*; 3 h of no new run rows *answers* it; 96 h is an absolute ceiling so "never hangs forever" still holds.

Two subtleties worth internalising:

- **The sweeper ignores rows it wrote itself.** A force-fail pass stamps `ended_at` on every non-terminal table; counting those would let it read its own writes back as proof the cycle is alive, and refuse to conclude for another 3 hours. Seen for real on 2026-08-09, 70 rows timestamped at the sweep instant.
- **The force-fail pass excludes P1 rows.** A SUCCEEDED `source_download` means the raw extract landed, not that the table bronzed. Counting it made a table with no `bronze_pull` row look terminal, so it was never force-failed and the gold barrier's completeness hold had nothing to break it — the cycle hung instead of concluding.

### Partial failure

Two rules that look contradictory and aren't:

- **Per-item isolation.** In the `Map`, a failed table catches to `ItemFailed` which is a `Succeed` state — so one bad table never stops the other 54 from processing. The failed table's run row is already FAILED (the job self-reports before raising).
- **All-or-nothing at the gate.** Any FAILED table in `expected[]` → the next phase does not start. A partial raw landing must not load into Bronze; a partial Bronze must not build Gold.

Isolation maximises how much useful work one cycle gets done; all-or-nothing stops a half-complete picture reaching a report. The `runs` table is what reconciles them.

### Which recovery — and when

| Mode | Payload | Use when | What it does |
|---|---|---|---|
| **rerun** | `{"rerun":true,"cycle_id":"…"}` | a table failed in **today's** cycle | Reopens the cycle (`state → running`), releases the gold **and** conform locks, restarts the source SFN under a unique name. Omit `tables` = re-run everything that failed; name `tables` to force a green table to re-run |
| **rerun_download** | `{"rerun_download":true,"cycle_id":"…"}` | the **raw pull** (P1) failed | P1 only. Never starts P2 — the download barrier does that once the gate re-passes. Also re-points `download_expected_chunks`, because a re-pull dispatches **one** un-windowed item per table and the old 10-window plan would be permanently unsatisfiable |
| **backfill** | `{"rerun":true,"source":"sap","date_from":…,"date_to":…}` | **old** data was wrong | Its own scoped `bf-…` cycle. Bounded `BETWEEN` read; **the incremental watermark is untouched**, so tomorrow's normal run is unaffected. Sets `full_refresh=True`, so Gold builds with `--full-refresh` — otherwise a window older than Gold's incremental predicate would land in Silver and never surface |
| **re-baseline** | `{"initial_load":true,"tables":[…],"force":true,…}` | the ODP delta token expired (`init_state = needs_reinit`) | A JDBC range re-pull over the CDC gap, in its own `rebaseline-<date>` cycle. On success `init_state → initial_loaded`, so the next CDC run can reseed a fresh token. The dispatcher queues this **automatically** when it sees `needs_reinit` |

Two rules people get wrong: **derived / conform tables are never named in `tables`** (they have no source SFN — list their *inputs* and the conform phase rebuilds them), and **auto-detect never re-runs a green table** (an empty `tables` means "re-run the failures"; to redo something that succeeded you must name it).

## Words you'll hear

| Word | What it means here |
|---|---|
| Idempotent | Doing it twice has the same effect as doing it once |
| Edge- / level-triggered | Fires once on an event / re-checks the world on a timer. Barriers vs the sweeper |
| Force-fail | The sweeper writing a synthetic FAILED row so a stuck cycle can reach a verdict |
| Stall / deadline / ceiling | 3 h without a new run row / 12 h old / 96 h absolute — the three sweeper clocks |
| Fail open | On an internal error, proceed as if the guard weren't there |
| Re-baseline | Re-establish the CDC starting point with a JDBC pull after a token expiry |
| Backfill | A date-scoped re-pull in its own cycle that leaves the watermark alone |
| All-or-nothing | Any failure in the phase → the next phase does not start |
| Crash net | `run_status`, which writes a terminal row for a Glue job that died before it could |

## In this repo

- [`src/lambdas/cycle_sweeper/handler.py:1-34`](../../../tamimi-lakehouse/src/lambdas/cycle_sweeper/handler.py) — the docstring is the design rationale for the whole lesson: why edge-triggered barriers need a level-triggered counterpart. Then `_RESUME_BARRIER` at `:77-81`, `_last_activity` at `:107-142` (the "don't read your own writes" fix), `_should_conclude` at `:145-170`, the force-fail pass at `:292-322`, and `_put_failed` at `:349-370`.
- [`src/lambdas/gold_barrier/handler.py:50`](../../../tamimi-lakehouse/src/lambdas/gold_barrier/handler.py) — `_INFLIGHT_OR_DONE`; [`:83-111`](../../../tamimi-lakehouse/src/lambdas/gold_barrier/handler.py) — `_existing_gold_run` and the fail-open contract; [`:249-263`](../../../tamimi-lakehouse/src/lambdas/gold_barrier/handler.py) — the pre-check in use; [`:278-295`](../../../tamimi-lakehouse/src/lambdas/gold_barrier/handler.py) — release-on-start-failure vs never-release-after-success, with the reasoning spelled out in comments.
- [`src/lambdas/download_barrier/handler.py:418-460`](../../../tamimi-lakehouse/src/lambdas/download_barrier/handler.py) — the same shape one phase earlier: any P2 start failure → alert, release the lock, do **not** mark `download_built`.
- [`src/lambdas/dispatcher/handler.py:1027-1141`](../../../tamimi-lakehouse/src/lambdas/dispatcher/handler.py) `_rerun` · [`:1144-1282`](../../../tamimi-lakehouse/src/lambdas/dispatcher/handler.py) `_rerun_download` (note the chunk-count re-point at `:1241-1253`) · [`:1417-1673`](../../../tamimi-lakehouse/src/lambdas/dispatcher/handler.py) `_initial_load` · [`:1701+`](../../../tamimi-lakehouse/src/lambdas/dispatcher/handler.py) `_backfill` · [`:1369-1414`](../../../tamimi-lakehouse/src/lambdas/dispatcher/handler.py) `_auto_rebaseline`.
- [`:501-532`](../../../tamimi-lakehouse/src/lambdas/dispatcher/handler.py) — `_invoke_gold_barrier`, the "nothing started at all" backstop, and `:875-911` for when it fires.
- [`infra/env/dev/per_source_ingestion.tf:185-190`](../../../tamimi-lakehouse/infra/env/dev/per_source_ingestion.tf) — `ItemFailed = { Type = "Succeed" }`: per-item failure isolation in three lines. And `:88-112` for the retry policy, whose budget must outlast the longest-running job (220 attempts ≈ 9.2 h > the 480-minute Glue timeout).
- [`infra/env/dev/cycle_sweeper.tf:174`](../../../tamimi-lakehouse/infra/env/dev/cycle_sweeper.tf) — `rate(15 minutes)`.
- [`src/lambdas/run_status/handler.py`](../../../tamimi-lakehouse/src/lambdas/run_status/handler.py) — the crash net, and also the per-stage failure notifier that sends the email you woke up to.
- [`docs/OPERATIONS-RUNBOOK.md` §4](../../../tamimi-lakehouse/docs/OPERATIONS-RUNBOOK.md) — the operator-facing version of the recovery table, with copy-paste payloads.

## Do this

1. Fail a table on purpose in Dev (point a spec at a nonexistent column). Watch: the run row goes FAILED, the cycle concludes `gold_skipped`, the alert email arrives. Then fix it, `rerun`, and watch the cycle reach `gold_built`. Do this once and the rest of the lesson is obvious.
2. Read `_should_conclude` and answer: a 57-table initial load has been running for 20 hours and wrote a run row 40 minutes ago. What does the sweeper do — and what did the *old* age-only version do?
3. Delete a `goldlock#…` row by hand and re-invoke the gold barrier. Predict what happens first. Now do the same thing while a gold build is genuinely in flight, and say which guard stops the second build.
4. For each of these, pick a recovery mode and justify it in one sentence: (a) `sap.zsdcc` failed at `bronze_to_silver` an hour ago; (b) last March's figures were restated at source; (c) the ODP token expired while CDC was down for a week; (d) the raw landing for six tables is missing but Bronze looks fine.
5. Trace the "post-submit timeout" scenario through `gold_barrier/handler.py` line by line, and identify the exact line that saves you.

## You've got it when you can…

…be handed a red cycle at 3 AM and, without guessing: name the failed stage and its `error_message` from `runs`, say whether the cycle will conclude by itself or needs the sweeper, choose the right recovery mode and explain in one sentence why the other three are wrong, and state which of the five idempotency guarantees means your re-run cannot make things worse.
