# L17 · The System's Memory

**Slide:** [`_render/L17-control-plane-schema.html`](_render/L17-control-plane-schema.html)

## The point

Glue jobs are stateless. Step Functions forgets an execution's payload the moment it ends. Nothing in this pipeline remembers anything by itself.

**Four DynamoDB tables do all the remembering**, and each one answers exactly one question:

| Table | The question |
|---|---|
| `runs` | *What happened?* |
| `watermarks` | *How far did we get?* |
| `pipeline-state` | *Is it healthy right now?* |
| `lineage_edges` | *What came from what?* |

Learn them that way and you never have to guess where to look. Every step of the operations runbook — and every widget the ops console shows — is a read against one of these.

(There are three more tables in the same module: `coordination` holds the cycle manifest and the single-flight locks, which is L16's subject, and `bronze_mapping` + `source_catalog` are the *config* the dispatcher reads, which is L15's.)

## Key ideas

### `runs` — "what happened?"

- **Composite key: `run_id` (HASH) + `stage` (RANGE).** One row *per stage*, all sharing the table's `run_id`. A table's `bronze_pull` and `bronze_to_silver` are separate rows — not one row overwritten as it advances. That is why a single logical table shows up twice (or more) in a cycle's rows, and why the barriers must resolve "the table's status" as *the latest stage by `started_at`*.
- **Two GSIs, both sparse (only rows that set the key appear):**
  - `by_table` = `(table_name, started_at)` — one table's history. Operator monitoring, re-run lookups.
  - `by_cycle` = `(cycle_id, started_at)` — one whole cycle's runs. **This is the index every barrier queries.**
- `silver_to_gold` rows are the exception: Gold is many-to-many (one dbt build, many models), so no single `run_id` can span it. Those rows get their own per-model `run_id` and correlate back through `cycle_id`. Lineage lives in `lineage_edges`, not here.
- Every row carries `status`, `rows_in` / `rows_out`, `error_message`, `run_kind` (`scheduled`/`initial`/`cdc`/`rerun`/`backfill`) and a 90-day `ttl`. **`error_message` is the exact blocker for that table** — it is the first thing to read on any failure.
- **`by_cycle` is eventually consistent.** A barrier invoked microseconds after the last write can legitimately fail to see it. The state machines account for this with an explicit `Wait` (15 s) before the final gold-barrier call — see `WaitForGsi` in `infra/env/dev/transform_ingestion.tf:161-169`. Single-flight makes the second call a harmless no-op if Gold already fired.

### `watermarks` — "how far did we get?"

- **Key: `source_id` (HASH) + `table_name` (RANGE).** Read at job start, written at job end. **A failed run does not advance it** — that invariant is the whole reason CDC is recoverable.
- Three positions, not one, because SAP tables are a hybrid: `last_watermark_value` (the generic position — an S3 key for Excel, a date for RDS), `jdbc_watermark` (high-water date from the last JDBC read), and `odp_delta_token` + `token_updated_at` (the CDC resume pointer and its freshness clock, which drives the token-age expiry alarm).
- **`init_state` is a little state machine of its own**, and it is what Gate 0 reads:
  `pending` → `initial_loaded` → `cdc`, with `needs_reinit` as the "the ODP delta token expired, force a JDBC re-baseline" branch. `None` means "not applicable" (Excel tables have no init/CDC lifecycle).
- The flip to `initial_loaded` is written by the **download barrier**, not by the Glue job — because a chunked initial load finishes out of order and only the barrier sees the whole phase.

### `pipeline-state` — "is it healthy right now?"

- **One table, four widgets.** The key is polymorphic: `'<kind>:<id>'`, where kind is `pipeline` | `alarm` | `freshness` | `reconciliation`. Chosen over four tables to save cost and give the operator UI one API surface; the trade-off (weaker per-kind schema enforcement) is bought back with a **Pydantic discriminated union** on `state.kind`, so each kind still validates against its own model.
- Note the Python/DDB naming seam: the Pydantic field is `entity`, aliased to `pipeline_id` for serialisation, because that is what the deployed table's HASH key is called.
- Stream is enabled with `NEW_IMAGE` only — the dashboard just needs the latest state, not deltas.
- A worked example of schema care: `ReconciliationState.drift_pct` is `float | None`, because "no comparable number" and "zero drift" are different answers. The earlier non-optional `ge=0.0` field forced the harness to clamp its "cannot reconcile" sentinel to `0.0` — **rendering a broken check as a perfect one.**

### `lineage_edges` — "what came from what?"

- **Key: `edge_id`, and it is deterministic** — `f"{upstream}|{downstream}|{edge_type}"`. Re-emitting the same edge overwrites the same item, so repeated runs never grow the DAG.
- `edge_type` ∈ `source_to_bronze` | `bronze_to_silver` | `silver_to_gold` | `gold_to_view`.
- `transform_id` is the dbt model name, Glue job ARN or Lambda name that drew the edge — the handle you use to navigate from a lineage edge *back to the code*.
- Written by each transform at completion. Read by impact analysis and the dashboard's `/ops/lineage` route.

### The ops surface

All the control-plane tables live in one Terraform module — seven of them today, though the module header still says six, because `coordination` was added after it was written. All `PAY_PER_REQUEST`, all encrypted with the audit CMK (their semantic class is "operational / compliance data", the same as CloudTrail). Streams are enabled on exactly two: `runs` (`NEW_AND_OLD_IMAGES`) and `pipeline_state` (`NEW_IMAGE`, for the dashboard).

The operational rule that follows from all of this: **never infer success from a Step Functions execution status.** A P1 download execution has been observed reporting `SUCCEEDED` over a fan-out in which every chunk failed. The barrier held correctly and no bad data landed — but the execution status lied. Query `runs` by cycle.

## Words you'll hear

| Word | What it means here |
|---|---|
| Control plane | The DynamoDB tables that hold state *about* the pipeline (as opposed to the data itself) |
| HASH / RANGE key | DynamoDB's partition key and sort key. Together they identify one item |
| GSI | Global Secondary Index — a second way to query the same table (here: by table, by cycle) |
| Sparse index | Only items that carry the index's key attribute appear in it |
| Polymorphic key | One key column holding `'<kind>:<id>'`, so several record types share a table |
| Discriminated union | Pydantic picks the right payload model from a `kind` field, so each kind keeps its own schema |
| Watermark | The high-water mark of what has already been read from a source |
| Delta token | ODP's CDC resume pointer. Expires if unused past the queue-retention window |
| TTL | DynamoDB's automatic expiry. Run rows self-delete at 90 days |
| Eventually consistent | A GSI read may not yet reflect a just-committed write |

## In this repo

- [`src/shared/shared/control_plane/runs.py:1-104`](../../../tamimi-lakehouse/src/shared/shared/control_plane/runs.py) — `RunItem`. The module docstring (`:1-24`) explains the composite key and both GSIs better than any diagram; `RunStage` at `:42-44` and `RunKind` at `:51` are the two vocabularies you will use every day.
- [`src/shared/shared/control_plane/watermarks.py:20-93`](../../../tamimi-lakehouse/src/shared/shared/control_plane/watermarks.py) — `InitState` (`:20-27`) and the dual-watermark fields (`:65-93`).
- [`src/shared/shared/control_plane/pipeline_state.py:23-101`](../../../tamimi-lakehouse/src/shared/shared/control_plane/pipeline_state.py) — the four state payloads, the `StateUnion` discriminator at `:75-78`, and the `ReconciliationState` docstring at `:54-65` (read that one; it is a good lesson about nullability).
- [`src/shared/shared/control_plane/lineage_edges.py:21-59`](../../../tamimi-lakehouse/src/shared/shared/control_plane/lineage_edges.py) — `_compute_edge_id` and the `model_validator` that fills it in.
- [`infra/modules/control_plane/main.tf:117-184`](../../../tamimi-lakehouse/infra/modules/control_plane/main.tf) — the `runs` table with both GSIs declared (`:155-169`). Then `watermarks` at `:84-114`, `lineage_edges` at `:214-238` ("Read by operator dashboard /ops/lineage route"), `pipeline_state` at `:240-268` ("Operator dashboard subscribes for real-time updates"), and `coordination` at `:186-212`.
- [`docs/OPERATIONS-RUNBOOK.md` §0, §2, §3](../../../tamimi-lakehouse/docs/OPERATIONS-RUNBOOK.md) — the operator's view of exactly these tables, with the CLI you will actually type. §2's callout on "two rows per table, one per stage" is the same fact as `runs.py`'s composite key, said in operator language.
- [`src/lambdas/run_status/handler.py:1-22`](../../../tamimi-lakehouse/src/lambdas/run_status/handler.py) — the crash-net that guarantees a dead Glue job still leaves a terminal `runs` row, so the table stays trustworthy.

## Do this

1. For today's cycle, run the runbook's `by_cycle` query. Count the rows, then count the tables. Explain the difference out loud (stages × retries).
2. Pick one table that ran. Find *all* its rows, sort by `started_at`, and write down the sequence of stages. Now do what a barrier does: name its single resolved status.
3. Read one `watermarks` row for a SAP table. Which of the three positions is populated? What does its `init_state` allow to happen tomorrow night?
4. Given "Power BI shows yesterday's number for `unified_sales`" — write down, in order, which of the four tables you query and what you expect each to tell you. That is the L23 debugging drill in miniature.
5. Find a `lineage_edges` row whose `downstream` is a `gold.*` table, then use its `transform_id` to open the code that produced it.

## You've got it when you can…

…be handed a question — "did it run?", "how far did it get?", "is it alerting?", "where did this column come from?" — and name the table, the key, and the index you would query, without looking anything up.
