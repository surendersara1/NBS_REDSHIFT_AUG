# D25 · Orchestration And The Barrier

> **Module 3 · Architecture 25 · deep dive** · ~20 min

**Diagram:** [`_render/D25-orchestration-barriers.html`](_render/D25-orchestration-barriers.html)

## What this pattern is for

Running many sources in parallel, letting each fail on its own, and then **starting the next phase only when every branch of the previous one has genuinely finished**.

The hard part is not the parallelism. It is the gate — and the gate is one conditional write.

## The ten steps

**1 · One schedule, one entry point.** EventBridge Scheduler fires once. Not one cron per source — that is how you end up with a schedule nobody can reason about and two jobs racing at 02:00.

**2 · A dispatcher reads the specs.** It works out **which sources are due tonight** from configuration and control-plane state, not from a hardcoded list. This is what makes adding a source a config change rather than a deployment.

**3 · A Map state fans out.** One branch per source, running in parallel. Step Functions owns the concurrency limit, so you cap it in one place rather than hoping.

**4 · Each branch fails independently.** ⭐ Source B's slow API cannot mark source A as failed. Separate executions, separate retries, separate alarms. Without this, one bad feed marks the whole night red and nobody can tell which seven succeeded.

**5 · The barrier.** ⭐ Every branch writes its terminal state to DynamoDB with a **conditional write** — `attribute_not_exists(pk)`. The first writer wins; a second attempt fails harmlessly. This is the entire mechanism behind single-flight locks, and it is why two dispatchers firing at once cannot both proceed.

**6 · The phase gate asks one question.** ⭐ *Are all phase-1 branches in a terminal state?* Not "did they succeed" — **terminal**, which includes failed. A failed source must not hold the gate closed forever; it must be visible and skipped, or the whole platform stalls behind one broken feed.

**7 · Phase 2 fans out the same way.** Same shape, same isolation. Bronze MERGEs on the natural key.

**8 · Everything is re-runnable.** Because phase 2 merges rather than appends, re-running a branch is safe — which is what turns an incident into a retry.

**9 · Backfill is the same path.** ⭐ Not a separate script. The same state machine, given a date range. A backfill mechanism that differs from the nightly path is a mechanism nobody trusts at 6am.

**10 · Alarm on branches that never end.** A branch stuck in "running" is invisible to a failure alarm. Alarm on **duration and on missing terminal state**, not only on error.

## The condition, in full

```
ConditionExpression: attribute_not_exists(pk)
```

That single expression gives you: single-flight locks, idempotent phase transitions, and safety against two schedulers. It is worth understanding properly, because everything above depends on it.

## What breaks if you skip a piece

- **Cron per source** — races, and a schedule nobody can reason about.
- **No isolation** — one slow API fails the night; the other seven are unknown.
- **Gate on success, not terminal state** — one broken source blocks the platform indefinitely.
- **A separate backfill script** — used rarely, tested never, wrong when it matters.
- **Alarm only on failure** — a hung branch is silent.

## On Apparel Group

Eight sources means eight branches from day one. Build the Map/barrier shape with **two** sources and prove the gate behaves when one of them fails on purpose — at two sources, not at eight.

## Checklist

- [ ] One schedule, one entry point
- [ ] The dispatcher reads config, not a hardcoded list
- [ ] Branches fail independently, with their own retries and alarms
- [ ] Barrier uses a conditional write
- [ ] The gate waits for **terminal**, not for success
- [ ] Backfill uses the same state machine, with a date range
- [ ] Alarms cover duration and missing terminal state

## You've got it when you can…

…deliberately fail one source in dev and show that the other seven complete, the gate opens, and exactly one alarm fires — naming the row in DynamoDB that made it safe.
