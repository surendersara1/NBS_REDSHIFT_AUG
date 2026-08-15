# L18 · Design for Failure Before You Ship

> **Module 2 · Lesson 18** · ~45 min
>
> **Slide:** [`_render/L18-design-for-failure.html`](_render/L18-design-for-failure.html) → [`L18-design-for-failure.png`](L18-design-for-failure.png)

## The decision

Is re-running the **normal** move, or the desperate one?

You get to choose. If every write in the pipeline is safe to repeat, a re-run is a shrug: it is either identical work or a no-op. If they are not, every recovery becomes a negotiation about what might get double-counted, and the team stops touching the pipeline at exactly the moment it needs touching.

Design for the second run **before** the first one ships. At-least-once delivery is the normal contract of every queue, every retry policy and every timeout you will use — so a job *will* run twice. Plan the doorstep, not the apology.

## Do this

### 1 · Make every stage idempotent, at five independent layers

Belt and braces on purpose — no single mechanism is enough, and you want the design to survive any one of them being wrong.

1. **Deterministic dispatch names.** `<source>-<cycle_id>` collides on a duplicate fire and no-ops. Handle the trap: engines commonly reserve execution names long after the run ended, so "already exists" is not proof of "still running". Read the prior status; re-dispatch a terminally dead one under a uniquified name.
2. **A create-only manifest.** `put_cycle` writes with `attribute_not_exists(pk)`, so a re-fire cannot overwrite a concluded cycle or reset `started_at` (which would restart the sweeper's clock).
3. **Single-flight locks.** One conditional write per phase; the loser does nothing (L16).
4. **Repeatable writes.** Landing overwrites its per-cycle snapshot; bronze/silver `MERGE` on a real natural key, or overwrite whole partitions. Re-running a table never duplicates rows. (This is L07's rule, and this is why it matters.)
5. **Resolution by latest attempt.** A gate judges each unit by its most recent row, so a fresh success supersedes an old failure without anyone deleting anything.

### 2 · Look before you leap: check for an in-flight job

Most job-start APIs have **no client idempotency token**. That makes this sequence possible:

```
03:12:04   StartJob → the service ACCEPTS the run, r-8821 starts
03:12:34   the API response never comes back (socket timeout)
03:12:35   the task retries the barrier → a fresh lock claim succeeds
           → a SECOND build for the same day
```

The lock does **not** save you here. Locks protect against *concurrent deciders*; they do not protect against *an ambiguous side effect you already caused*.

So before starting, query recent job runs and look for one whose cycle argument matches this cycle and whose state is `STARTING` / `RUNNING` / `WAITING` / `SUCCEEDED`. If you find one, treat the day as already built, reconcile the cycle state, and return `already_running`.

**Fail open.** Any error inside the pre-check — a throttle, a missing permission — returns "unknown" and the caller proceeds. This guard is an optimisation over correctness, not the correctness mechanism itself, so it must never be worse than not having it.

### 3 · Add a sweeper — the level-triggered net

Barriers are **edge-triggered**: invoked once, at the end of a phase. If a barrier dies, nothing re-evaluates it and the cycle sits forever. So add a sweeper on a timer (15 minutes is a good default) doing two different jobs:

- **RESUME — every pass, no deadline.** For any non-concluded cycle, re-invoke the barrier its state implies: `running` → landing barrier, `landing_built` → bronze barrier, and so on. Barriers are self-gating and single-flight, so a nudge costs nothing unless the gate is genuinely satisfiable. This is the whole payoff of L16's lock.
- **CONCLUDE — only when overdue *and* no longer moving.** Force-fail every expected unit that is still non-terminal (writing a synthetic failed row for a unit with no row at all), then re-invoke the final barrier so it claims the lock and concludes the cycle with an alert.

Three clocks, not one, and each has a distinct job:

| Clock | Default | What it means |
|---|---|---|
| deadline | 12 h | *opens the question* — this cycle is overdue |
| stall | 3 h with no new run row | *answers it* — nothing is progressing |
| ceiling | 96 h | absolute backstop, so "never hangs forever" still holds |

**Age alone is not evidence of death.** A long initial load is slow, not dead. A sweeper that concludes on age alone will force-fail healthy work — and the cost of that is a whole night's re-run.

Two subtleties worth building in from the start:

- **The sweeper must ignore rows it wrote itself.** A force-fail pass stamps timestamps on every non-terminal unit; counting those lets the sweeper read its own writes back as proof the cycle is alive and refuse to conclude for another stall window.
- **Exclude earlier-phase rows from the force-fail pass.** A successful *landing* row means the raw extract arrived, not that the table reached bronze. Counting it makes a table with no bronze row look terminal, so it is never force-failed, the completeness gate has nothing to break it, and the cycle hangs instead of concluding.

### 4 · Isolate per item, but gate all-or-nothing

Two rules that look contradictory and are not:

- **Per-item isolation.** In the fan-out, a failed table catches to a *succeed* state, so one bad table never stops the other fifty from processing. Its run row is already failed — the job self-reports before raising.
- **All-or-nothing at the gate.** Any failed unit in `expected[]` → the next phase does not start. A partial raw landing must not load into bronze; a partial bronze must not build gold.

Isolation maximises how much useful work one cycle completes. All-or-nothing stops a half-complete picture reaching a report. The run rows are what reconcile the two.

### 5 · Define the recovery modes — and who may run each

| Mode | Use when | What it does | Who runs it |
|---|---|---|---|
| **rerun** | a table failed in **today's** cycle | reopens the cycle (`state → running`), releases the downstream locks, restarts the source under a unique name. Empty `tables` = re-run what failed; name a table to force a green one to re-run | on-call engineer, self-serve |
| **rerun (landing only)** | the **raw pull** failed | re-pulls raw only; never starts the next phase — the barrier does that once the gate re-passes. Must also re-point any planned-chunk count, because a re-pull dispatches one un-windowed item per table and the old multi-window plan would be permanently unsatisfiable | on-call engineer |
| **backfill** | **old** data was restated at source | its own scoped `bf-…` cycle, a bounded `BETWEEN` read, and **the incremental watermark is untouched** so tomorrow's normal run is unaffected. Force a full refresh downstream, or a window older than the incremental predicate lands in silver and never surfaces | data owner signs off |
| **re-baseline** | the change-stream pointer expired | a bounded re-pull over the CDC gap in its own `rebaseline-…` cycle; on success `init_state → initial_loaded` so the next run can reseed a fresh token. The dispatcher should queue this **automatically** when it sees `needs_reinit` | platform team |
| **auto sweep** | a cycle is stuck and nobody asked | resume, or conclude with an alert | the system, every 15 min |

Two rules people get wrong:
- **Derived / conformed tables are never named in `tables`** — they have no source pipeline. Name their *inputs*, and the conform phase rebuilds them.
- **Auto-detect never re-runs a green table.** An empty `tables` means "re-run the failures". To redo something that succeeded you must name it.

### 6 · Write the recovery table before go-live

Put it in the runbook with copy-paste payloads, and put a name next to each mode. A recovery procedure discovered at 3 AM is a recovery procedure that will be got wrong.

> **Worked examples (Tamimi):** `src/lambdas/cycle_sweeper/handler.py` — its docstring is the design rationale for edge- vs level-triggered, then `_last_activity` (don't read your own writes), `_should_conclude` (the three clocks) and the force-fail pass. `src/lambdas/gold_barrier/handler.py` — the in-flight pre-check, its fail-open contract, and release-on-start-failure vs never-release-after-success. `docs/OPERATIONS-RUNBOOK.md` §4 is the operator-facing recovery table.

## Why

- **At-least-once is the normal delivery contract.** Retries, redeliveries and duplicate triggers are not exotic — they are the guarantee you actually bought.
- **A timeout hides a side effect you already caused.** The absence of a response is not the absence of an effect, which is why locks alone are not enough and the in-flight check exists.
- **An event-triggered gate that dies is never retried.** Edge-triggered logic needs a level-triggered counterpart, or one dead invocation costs you a night.
- **Age alone is not evidence a cycle is dead.** Slow and stuck look identical from a distance; only *activity* tells them apart.

**What breaks if you don't:** one duplicate trigger doubles a day's numbers, and a single wedged cycle blocks every night that follows it — with the report showing yesterday's figures the whole time.

## On Apparel Group

- **Eight sources, eight ways to fail.** Oracle sessions drop mid-read on RMS, SIM and XStore; Epsilon and MoEngage throttle and return 429s; Magento's API pages out; the Vemco and Irisys footfall files simply arrive late. Every one of those is a *normal* night, and every one is fixed by a re-run — provided you built for it.
- **XStore's initial load is where the sweeper deadline will bite first.** It runs for many hours legitimately. Tune the stall window against XStore, not against RMS, or the sweeper will force-fail your largest and most expensive load.
- **The footfall feeds are the "arrived late" case, not the "failed" case.** Decide up front whether a missing optional source blocks the cycle. If it does not, it must not be in `expected[]` — a unit that can never run makes the gate wait forever.
- **Name an owner per mode before go-live.** `rerun` is self-serve for on-call. `backfill` needs a business owner's sign-off because it changes history. `re-baseline` is platform-team only. Put these three names in the runbook on day one; the on-call rota starts with the first production cycle, not after it.
- **Test the recovery path in Dev deliberately.** Point a spec at a nonexistent column, watch the run row go failed, the cycle conclude skipped and the alert arrive; then fix it, `rerun`, and watch the cycle reach built. Doing that once makes the whole lesson obvious — and it is the single best onboarding exercise for a new engineer on the platform.

## Checklist

- [ ] Every write in the pipeline is repeatable — snapshot overwrite or merge on a real key
- [ ] Dispatch names are deterministic, and "name exists" is resolved by reading the prior status
- [ ] The cycle manifest is create-only
- [ ] An in-flight pre-check runs before any job start, and it fails open
- [ ] A sweeper runs on a timer and can both resume and conclude
- [ ] The sweeper has three clocks (deadline / stall / ceiling), not one
- [ ] The sweeper ignores rows it wrote itself, and excludes earlier-phase rows from force-fail
- [ ] Per-item failures are isolated in the fan-out; the phase gate is all-or-nothing
- [ ] All recovery modes are named, documented with copy-paste payloads, and have an owner
- [ ] Backfill leaves the incremental watermark untouched and forces a downstream full refresh
- [ ] A deliberate failure and recovery has been rehearsed in Dev by someone who will be on call

## You've got it when you can…

…be handed a red cycle at 3 AM and, without guessing: name the failed stage and its `error_message` from the run rows, say whether the cycle will conclude by itself or needs the sweeper, choose the right recovery mode and explain in one sentence why the other three are wrong — and state which of the five idempotency guarantees means your re-run cannot make things worse.
