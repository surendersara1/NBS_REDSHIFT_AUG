# L16 · Make Phase Hand-offs Safe ⭐

> **Module 2 · Lesson 16** · ~45 min
>
> **Slide:** [`_render/L16-safe-phase-handoffs.html`](_render/L16-safe-phase-handoffs.html) → [`L16-safe-phase-handoffs.png`](L16-safe-phase-handoffs.png)

## The decision

How does the next phase start — and start **only once**?

Your pipeline has phases: land the raw extract, build bronze, conform to silver, build gold. Each phase fans out across many sources and many tables, and each phase ends at the same question: *is the whole phase finished, and if so, who starts the next one?*

Every source's execution asks that question. On a busy night two of them ask it milliseconds apart, both look at the world, both see the same all-green picture, and both conclude "I should start the next phase now."

Exactly one of them must. Not because of a queue, not because of a leader election, not because of a lock service with a lease you have to tune — but because of **one conditional write to one item**.

## Do this

1. **End every phase with a barrier, and make it the only thing that advances the cycle.**
   A barrier is a small function invoked at the tail of a phase. It reads the cycle manifest, decides whether the phase is genuinely complete, and — if it is — starts the next phase exactly once. Individual jobs never start the next phase. Nothing else writes the cycle state.

2. **Claim the right to act with a single-flight lock, implemented as a conditional write.**

   ```python
   ddb.put_item(
       TableName=coordination_table,
       Item={"pk": f"lock#gold#{cycle_id}", "claimed_by": request_id, ...},
       ConditionExpression="attribute_not_exists(pk)",
   )
   ```

   The store serialises writes to a single item. Whichever request it orders first finds the item absent and succeeds; the second gets a conditional-check failure. One caller acts, the other does not. No timing assumptions, nothing to tune.

3. **One lock item per phase per cycle — identical code every time.**
   `lock#landing#<cycle>`, `lock#bronze#<cycle>`, `lock#silver#<cycle>`, `lock#gold#<cycle>`. Four locks, one helper, copied verbatim. Resist the urge to make each phase's claim "smarter"; the value of this pattern is that it is boring in four places.

4. **Treat losing the lock as SUCCESS.**
   The loser returns `{"status": "lock_lost"}` and does nothing at all. That is not an error path — it *is* the mechanism. In a healthy pipeline a large share of barrier invocations end this way. Make sure your metric names, log levels and alarm filters agree with that: a `lock_lost` must never page anyone.

5. **Hold before you claim.** Order matters, and this is the rule people get wrong.
   Every "not ready yet" check must return **above** the claim, mutating nothing. A claimed lock can never be re-claimed, so claiming one and *then* discovering you cannot proceed wedges the cycle permanently. Structure the barrier in exactly this order:

   ```
   1. read the cycle manifest                      → no manifest?      return "no_cycle"
   2. is the cycle already concluded?              → yes?              return "already_concluded"
   3. is every expected unit TERMINAL?             → no?               return "waiting"
   4. is the phase genuinely COMPLETE (see 7)?     → no?               return "waiting"
   5. claim the lock                               → lost?             return "lock_lost"
   6. ── only now may you mutate anything ──
   7. judge: any failure → mark the cycle skipped, alert, do not proceed
   8. otherwise start the next phase, then record the new cycle state
   ```

6. **Decide on TERMINAL states, never on "is it running".**
   A cycle *advances* through states: `running → landing_built → bronze_built → silver_built → gold_built`. A barrier that no-ops unless the state equals `running` will stop firing the instant the first barrier advances the state — and every phase after that silently never runs.

   Define the stop condition as a **set of concluded states**, not one string:

   ```python
   CONCLUDED_CYCLE_STATES = frozenset({
       "complete", "landing_skipped", "bronze_skipped",
       "silver_skipped", "gold_skipped", "gold_built",
   })
   ```

   Proceeding on an intermediate state is safe *precisely because* the lock makes it idempotent. The lock is what buys you the right to be relaxed about the state check.

7. **Resolve "is this unit finished?" as the latest attempt, and demand positive evidence.**
   One table produces several run rows per cycle — one per stage, plus one per retry. "The table's status" is only well defined as *its most recent attempt*, resolved by comparing `started_at` (ISO-8601 sorts lexically, so a string compare is a chronological one). Never rely on the store's natural query ordering.

   Two refinements that matter as soon as you have more than one stage:
   - **Terminal is not the same as done.** If terminality can be satisfied by *any* stage's row, a table whose bronze step never wrote a row at all still resolves to its successful landing row and reads as finished. Gate on **positive evidence for this phase**: a succeeded `bronze` row for every expected table.
   - **Latest is not the same as complete.** A chunked table is many runs sharing one name; collapsing it to its latest run passes a table whose other windows were dropped. Carry an expected-chunk count **on the manifest, counted off the items you actually dispatched**, and gate on `succeeded ≥ planned`.

8. **Release only when you caused nothing.**
   If the claim succeeded but the *start* then failed, delete the lock and re-raise so a retry or the sweeper can re-attempt. If the start **succeeded** and only the bookkeeping write failed, do **not** release — releasing would risk a second build.

9. **All-or-nothing is the verdict, not the gate.**
   Once you hold the lock: any failed unit in `expected[]` → set the cycle `*_skipped`, publish an alert, and do not start the next phase. A partial raw landing must never load into bronze; a partial bronze must never build gold.

10. **A barrier error must never fail a good ingestion.**
    Wrap the barrier task with a retry and a catch-to-succeed. The work already landed; a flaky tail call should not mark the whole source failed. The sweeper (L18) is what re-checks a barrier that died.

> **Worked examples (Tamimi):** `src/shared/shared/control_plane/coordination.py` — `try_claim_gold_lock` is sixteen lines and its three siblings are deliberately identical; `CONCLUDED_CYCLE_STATES` is the terminal-set predicate; `latest_run_by_table` is the one-status-per-table resolver. `src/lambdas/gold_barrier/handler.py` is the canonical barrier in the order listed above.

## Why

- **One item, one writer.** The database already serialises writes to a single item. You are borrowing a guarantee that is stronger than anything you would build, and it costs one request.
- **No queue, no leader election, no lease to tune.** There is no clock skew to reason about and no lease to expire at the wrong moment. The failure mode of a lock service — "the lease lapsed mid-work" — does not exist here.
- **A phase advances, so the gate must be a set.** The only durable way to express "do not proceed" is to enumerate the states from which nobody may proceed.
- **The lock is what makes re-checking free.** Because a second decider does nothing, you can safely nudge a barrier from a timer, from a retry, or from an operator's console. Everything in L18 depends on that.

**What breaks if you don't:** two builders publish the same day twice — or, with a naive `== running` gate, every hand-off after the first one quietly stops firing and the report simply never updates. Both failures are silent.

## On Apparel Group

- **All eight sources reach each hand-off together.** RMS, SIM and XStore are Oracle pulls of wildly different sizes; Epsilon and MoEngage are API pulls with their own pacing; Magento, Vemco and Irisys are small and fast. They will not finish in the same order twice, and two of them *will* land in the same millisecond.
- **Four lock items per cycle, one per phase** — landing, bronze, silver, gold. Same helper, four call sites. Review them as one change, not four.
- **The small sources are the dangerous ones.** Vemco and Irisys finish in seconds and will usually be the callers racing the barrier while XStore is still running — so the "waiting" path is the one that executes most often. Make sure it is cheap and mutates nothing.
- **Chunked XStore initial loads need the chunk count on the manifest.** Its windows finish out of order, and no single window can conclude "the load is done" — only the phase can, and only the barrier sees the whole phase.
- **Wire `lock_lost` out of alerting on day one.** With eight sources you will see it several times a night per phase. If it pages, the team will start ignoring the channel in week one.

## Checklist

- [ ] Every phase ends at a barrier; no job starts the next phase directly
- [ ] The claim is a conditional write on a single item, per phase, per cycle
- [ ] `lock_lost` returns success, is logged at info, and is excluded from alarms
- [ ] Every "waiting" return sits **above** the claim and mutates nothing
- [ ] The stop condition is a set of concluded states, not `!= "running"`
- [ ] Per-unit status is resolved as the latest attempt by timestamp, not by query order
- [ ] The gate requires positive evidence for *this* phase, not any terminal row
- [ ] Chunked work carries a planned-count on the manifest, taken from what was dispatched
- [ ] Start-failure releases the lock; post-start bookkeeping failure does not
- [ ] Any failed unit → cycle marked skipped + alert; the next phase does not start
- [ ] The barrier task is retried and caught, so a barrier error cannot fail a good ingestion

## You've got it when you can…

…answer *"two jobs raced the hand-off — which one wins, and why is that safe?"* with **"whichever one the store orders first on that single item; the other gets a conditional-check failure, returns `lock_lost`, and does nothing — which is the design working"** — and then name the two *other* checks (latest-status-per-unit and phase completeness) that must pass before anyone is allowed to reach for the lock at all.
