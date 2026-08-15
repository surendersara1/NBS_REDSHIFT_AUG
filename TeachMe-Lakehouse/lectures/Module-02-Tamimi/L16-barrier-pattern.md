# L16 · How Two Jobs Don't Collide ⭐

**Slide:** [`_render/L16-barrier-pattern.html`](_render/L16-barrier-pattern.html)

## The point

Every per-source Step Function ends by calling the same barrier Lambda. On a busy night two of them finish milliseconds apart, both read the same manifest, both see the same all-green picture, and both decide "I should start Gold now."

Exactly one of them does.

Not because of a queue, not because of a leader election, not because of a lock service with a lease you have to tune — but because of **one conditional write to one DynamoDB item**:

```python
client.put_item(
    TableName=coordination_table,
    Item={"pk": "goldlock#2026-08-10", ...},
    ConditionExpression="attribute_not_exists(pk)",
)
```

DynamoDB serialises writes to a single item. Whichever request the service orders first finds the item absent and succeeds; the second one gets `ConditionalCheckFailedException`, the helper returns `False`, and that invocation returns `{"status": "lock_lost"}` and does nothing at all. **That is not an error path. That is the mechanism working.** Half the barrier invocations in a healthy pipeline end in `lock_lost`.

## Key ideas

- **Single-flight = "at most one caller acts", not "exactly one caller runs".** Every phase has its own lock item in the same coordination table, all with identical code: `downloadlock#`, `transformlock#`, `conformlock#`, `goldlock#`. Four locks, one pattern.
- **A barrier is edge-triggered and therefore fragile on its own.** It is invoked once, as an SFN tail Task. If it dies, nothing re-checks — which is exactly why the `cycle_sweeper` exists (L18). The lock is what makes re-checking *safe*.
- **Order matters: hold before you claim.** A barrier that is merely *waiting* must return **before** touching the lock. A claimed lock can never be re-claimed, so claiming one and then discovering you can't proceed wedges the cycle permanently. Both the R22 completeness hold and the R80(d) chunk hold sit deliberately above the `try_claim_*` call, mutating nothing.
- **Release is the escape hatch.** If the claim succeeds but the *start* then fails (Glue rejects `StartJobRun`, an SFN won't start), the barrier deletes the lock and re-raises, so the SFN Task retry or the sweeper can re-attempt. If the start *succeeded* and only the bookkeeping write failed, it must **not** release — that would risk a second build.
- **Concluding a phase = resolving latest-status-per-table.** One table has several run rows per cycle: one per stage (`source_download`, `bronze_pull`, `abap_transform`, `bronze_to_silver`), plus one per retry. "The table's status" is only well-defined as *the most recent attempt*, resolved by `started_at` (ISO-8601 sorts lexically, so a string compare is a chronological one). Never rely on DynamoDB query ordering.
- **Terminal ≠ done — the R22 lesson.** Terminality is satisfied by *any* stage's row. A table whose `bronze_pull` never wrote a row at all still resolves to its SUCCEEDED P1 `source_download` row and reads as finished. That is how QA cycle `sap-init-151805` concluded SUCCEEDED with **27 of 51 tables actually bronzed**. The gate now demands positive evidence: a SUCCEEDED `bronze_pull` row for every expected base table.
- **Latest ≠ complete — the R80(d) lesson.** A chunked table is *many* runs sharing one name. Collapsing it to its latest run passed `sap.vbrp` on QA cycle `init-2021-08-09_2026-08-09-212758` when five of its ten windows had been dropped. So the manifest carries `download_expected_chunks` — counted off the very items that were dispatched, never recomputed from the windowing rules — and the download barrier gates on `succeeded ≥ planned`.
- **The R31 fix — gate on TERMINAL states, not on `== "running"`.** The cycle *advances*: `running → download_built → transform_built → gold_built`. Every barrier used to no-op unless `state == "running"`, so the moment the download barrier set `download_built`, every downstream barrier declared the cycle "already concluded" and silently stopped. Silver and Gold never built. The fix is a set, not a string:

  ```python
  CONCLUDED_CYCLE_STATES = frozenset({
      "complete", "download_skipped", "transform_skipped",
      "gold_skipped", "gold_built",
  })
  ```

  Proceeding on an intermediate state is safe **precisely because** the single-flight lock makes it idempotent. The lock is what buys you the right to be relaxed about the state check.
- **All-or-nothing is the verdict, not the gate.** Once a barrier holds the lock: any FAILED table → set the cycle `*_skipped`, publish an SNS alert, and do not start the next phase. A partial raw landing must never be loaded into Bronze; a partial Bronze must never build Gold.

## Words you'll hear

| Word | What it means here |
|---|---|
| Barrier | A Lambda invoked at the tail of a phase that decides whether the *whole* phase is finished |
| Single-flight | At most one caller performs the action, enforced by a conditional write |
| Conditional write | `PutItem` with `ConditionExpression="attribute_not_exists(pk)"` — succeeds only if the item isn't there |
| `ConditionalCheckFailedException` | The loser's answer. Caught, converted to `False`, and treated as a normal outcome |
| Edge-triggered / level-triggered | Fires once on an event / re-evaluates the world on a timer. Barriers are the first; the sweeper is the second |
| Terminal | `succeeded` \| `failed` \| `cancelled` — the run is over, whatever the outcome |
| Concluded | A cycle state from which no barrier may proceed (`gold_built`, `*_skipped`, `complete`) |
| All-or-nothing | Any failed table in the phase → the next phase does not start |
| `lock_lost` | The healthy no-op returned by every barrier invocation that did not win the claim |

## In this repo

- [`src/shared/shared/control_plane/coordination.py:521-537`](../../../tamimi-lakehouse/src/shared/shared/control_plane/coordination.py) — `try_claim_gold_lock`. Sixteen lines, `try` / `except ConditionalCheckFailedException` / `return False`. Compare with `try_claim_download_lock` (`:454-470`), `try_claim_transform_lock` (`:488-504`) and `try_claim_conform_lock` (`:556-572`) — identical, on purpose.
- [`:52-61`](../../../tamimi-lakehouse/src/shared/shared/control_plane/coordination.py) — `CONCLUDED_CYCLE_STATES` and the comment that records the R31 defect.
- [`:598-628`](../../../tamimi-lakehouse/src/shared/shared/control_plane/coordination.py) — `latest_run_by_table`, the "one status per table" resolver, with the `stage=` filter the download and transform barriers use.
- [`:631-655`](../../../tamimi-lakehouse/src/shared/shared/control_plane/coordination.py) — `base_bronze_tables` + `tables_missing_bronze`: the R22 completeness half of the gate.
- [`src/lambdas/gold_barrier/handler.py:136-215`](../../../tamimi-lakehouse/src/lambdas/gold_barrier/handler.py) — the canonical barrier, in order: read manifest → concluded-state check (`:142`) → latest status per table (`:150-158`) → completeness hold (`:181-193`) → claim (`:202-215`).
- [`src/lambdas/download_barrier/handler.py:242-332`](../../../tamimi-lakehouse/src/lambdas/download_barrier/handler.py) — the same shape one phase earlier, plus the chunk-completeness hold at `:277-317`. Note the comment on `:314-317`: the hold is deliberately *before* the lock.
- [`:166-194`](../../../tamimi-lakehouse/src/lambdas/download_barrier/handler.py) — `_completed_initial_loads`. A lovely piece of reasoning: a chunked initial load finishes **out of order**, so no single chunk can conclude "the load is done" — only the phase can, and the barrier is the only single-flight actor that sees the whole phase.
- [`src/lambdas/transform_barrier/handler.py:97`](../../../tamimi-lakehouse/src/lambdas/transform_barrier/handler.py) and [`src/lambdas/silver_barrier/handler.py:329`](../../../tamimi-lakehouse/src/lambdas/silver_barrier/handler.py) — the same `CONCLUDED_CYCLE_STATES` guard, so you can see the fix landed everywhere.
- [`infra/env/dev/per_source_ingestion.tf:201-222`](../../../tamimi-lakehouse/infra/env/dev/per_source_ingestion.tf) — the barrier tail is `Retry` + `Catch → Succeed`. A barrier error must never fail a good ingestion.

## Do this

1. Read `try_claim_gold_lock` and then write the race out on paper: two Lambdas, two `PutItem`s, one item. Say what each one returns and what each one does next. Now do it again where the *first* caller crashes immediately after winning — who cleans up, and how? (Answer is in L18.)
2. Find the three places a barrier can return `waiting`. For each, say why returning early is safe, and what would break if that check sat *after* the lock claim instead of before it.
3. In `tamimi-lakehouse-coordination-dev`, find a `goldlock#…` row. Read `claimed_by` — that is the `aws_request_id` of the invocation that won. Now find that request in the gold-barrier CloudWatch logs and read the sibling invocations that lost.
4. Break it in your head: change `CONCLUDED_CYCLE_STATES` back to `state != "running"`. Trace a cycle from `running` and name the first phase that stops. Then explain why the single-flight lock is what makes the correct version safe.

## You've got it when you can…

…answer "two jobs raced the barrier — which one wins, and why is that safe?" with **"whichever one DynamoDB orders first on that single item; the other gets `ConditionalCheckFailedException`, returns `lock_lost`, and does nothing — which is the design working"** — and then name the two *other* checks (terminal-per-table and completeness) that have to pass before anyone is even allowed to reach for the lock.
