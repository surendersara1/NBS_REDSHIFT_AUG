# L17 · Design the Control Plane

> **Module 2 · Lesson 17** · ~45 min
>
> **Slide:** [`_render/L17-design-the-control-plane.html`](_render/L17-design-the-control-plane.html) → [`L17-design-the-control-plane.png`](L17-design-the-control-plane.png)

## The decision

What does the platform write down **about itself**?

Compute is stateless. An orchestrator forgets an execution's payload the moment it ends. Logs expire, and even while they live they are prose, not data. Nothing in a pipeline remembers anything by itself — so the memory is something you design, on purpose, before you need it.

The test to apply to every design choice here: *can an operator answer this question with a keyed lookup, instead of a log search?*

## Do this

Build **four record types**. Each answers exactly one question. Learn them that way and nobody ever has to guess where to look.

| Record type | The question it answers | Key |
|---|---|---|
| `runs` | *What happened?* | `run_id` + `stage` |
| `watermarks` | *How far did we get?* | `source_id` + `table_name` |
| `pipeline_state` | *Is it healthy right now?* | `<kind>:<id>` |
| `lineage_edges` | *What came from what?* | `<upstream>\|<downstream>\|<edge_type>` |

### 1 · `runs` — what happened

- **One row per stage, not one row per table.** Give it a composite key of `run_id` + `stage` so a table's `bronze` and `silver` steps are separate rows sharing one `run_id`. Do not overwrite one row as the table advances — you lose the history exactly when you need it.
- **Index it two ways, and both indexes are sparse:**
  - `by_table` = (`table_name`, `started_at`) — one table's history, for monitoring and re-run lookups.
  - `by_cycle` = (`cycle_id`, `started_at`) — one whole cycle's runs. **Every barrier queries this one.**
- **Every row carries the same envelope:** `status`, `rows_in` / `rows_out`, `error_message`, `run_kind` (`scheduled` / `initial` / `cdc` / `rerun` / `backfill`), `started_at`, `ended_at`, and a TTL (90 days is a good default). `error_message` is the exact blocker for that unit — it is the first field anyone reads on a failure, so make sure the job writes something useful into it.
- **Assume the index is eventually consistent.** A barrier invoked microseconds after the last write can legitimately fail to see it. Put a short explicit wait before the final gate call, and let single-flight make the redundant call a harmless no-op.
- **Add a crash net.** A job that dies hard cannot write its own terminal row, and a missing row is indistinguishable from a running one. Have the orchestrator (or a small status function) guarantee a terminal row exists for every dispatched unit, so the table stays trustworthy.
- **Many-to-many stages need their own `run_id`.** A single warehouse build produces many models; no one `run_id` spans it. Give those rows a per-model `run_id` and correlate back through `cycle_id`. Their *lineage* belongs in `lineage_edges`, not here.

### 2 · `watermarks` — how far did we get

- **One row per source table.** Read at job start, written at job end.
- **A failed run must never advance it.** That single invariant is the entire reason incremental loading is recoverable. Write the watermark on success only, in the same place, once.
- **Store the position in the shape the source uses** — a timestamp for a database, a cursor or token for an API, a key or filename for a file drop. If a source needs more than one position (a high-water date *and* a change-stream token), give it named fields rather than overloading one.
- **Carry an init-state machine on the same row:** `pending → initial_loaded → cdc`, plus a `needs_reinit` branch for "the change pointer expired, force a re-baseline". This is what enforces the rule that a table may not join the nightly delta cycle until its one-time initial load has completed.
- **Flip to `initial_loaded` from the barrier, not the job.** A chunked initial load finishes out of order, so no single chunk can conclude the load is done — only the phase can, and the barrier is the only actor that sees the whole phase.

### 3 · `pipeline_state` — is it healthy right now

- **One table, several widget kinds**, keyed polymorphically as `<kind>:<id>` where kind is `pipeline` | `alarm` | `freshness` | `reconciliation`. One API surface for the operator console; one place to add a widget.
- **Buy back the schema you gave up.** A polymorphic key weakens per-kind enforcement, so validate each kind against its own model with a discriminated union on `kind`. You get one table and four real schemas.
- **Enable a change stream with new-image only** if the console wants live updates; it does not need deltas.
- **Be careful with nullability in health fields.** "No comparable number" and "zero drift" are different answers. A non-optional `drift_pct` with a `>= 0` constraint forces a caller to clamp its *cannot-compute* sentinel to `0.0` — which renders a broken check as a perfect one. Make the field optional and let null mean null.

### 4 · `lineage_edges` — what came from what

- **Make the edge id deterministic:** `f"{upstream}|{downstream}|{edge_type}"`. Re-emitting the same edge overwrites the same item, so repeated runs never grow the graph.
- **Enumerate `edge_type`** — `source_to_bronze` | `bronze_to_silver` | `silver_to_gold` | `gold_to_view` — so impact analysis can walk one layer at a time.
- **Store a `transform_id`**: the model name, job ARN or function name that drew the edge. That is the handle an engineer uses to navigate from a lineage edge back to the *code*.
- **Write it at completion, from the transform itself.** Lineage inferred later is lineage you cannot trust.

### 5 · Two rules that make the whole thing usable

- **Never infer success from an orchestrator's execution status.** A fan-out execution can report success over children that all failed. Query the run rows.
- **Design the console query at the same time as the record.** If you cannot write, on a whiteboard, the exact keyed read that powers the widget, you have not finished designing the record.

> **Worked examples (Tamimi):** `src/shared/shared/control_plane/` — `runs.py` (composite key + both indexes), `watermarks.py` (`InitState` and the multi-position fields), `pipeline_state.py` (the discriminated union and the nullability lesson), `lineage_edges.py` (`_compute_edge_id`). The tables themselves are one Terraform module, `infra/modules/control_plane/main.tf`.

## Why

- **Executions expire; the record is the memory.** Everything that survives the night is something you chose to write.
- **A dashboard is nothing more than a read over these four types.** Design the records and the operator view is almost free; skip them and no dashboard is possible at any price.
- **Gates and sweepers judge on rows, not logs.** L16's barriers and L18's sweeper both read `runs` by cycle. The control plane is not documentation — it is load-bearing.
- **Every runbook step becomes a keyed lookup.** "Did it run?" "How far did it get?" "Is it alerting?" "Where did this column come from?" — four questions, four tables, no searching.

**What breaks if you don't:** every incident becomes archaeology, and nobody can build an operator view over data you never kept. You will discover this on the first bad night, which is the worst possible time to start writing records.

## On Apparel Group

- **One control plane spans all eight sources.** An Oracle RMS table and a MoEngage API pull produce the same four record shapes, so one console covers RMS, SIM, XStore, Epsilon, MoEngage, Magento, Vemco and Irisys without per-source special cases.
- **Stamp `source_id`, `cycle_id` and `run_kind` on every row.** Those three fields are what make "show me last night, by source" a query instead of a project — and they are the fields the Retail IQ / Quick operations view will group by.
- **Model the source-specific position properly, once.** Oracle tables get a date/SCN watermark; Epsilon and MoEngage get a cursor or token plus a freshness timestamp so you can alarm on token age; footfall file drops get the last processed key. Same table, named fields, no overloading.
- **Epsilon is PII.** The control plane records *metadata* — counts, timings, statuses — never sample rows or key values from a customer table. Decide that rule before the first run row is written, and encrypt these tables with the same class of key you use for audit data.
- **Freshness SLA per table belongs here**, not in a spreadsheet: it is what L23's lateness alarm reads and what the console's red/amber/green is computed from.
- **Retention:** 90-day TTL on run rows keeps the table cheap and still covers a full quarter-end investigation. Lineage edges have no TTL — they are the current shape of the graph, not history.

## Checklist

- [ ] Four record types exist, and each one has a written down "the question it answers"
- [ ] `runs` is keyed per stage, with a by-cycle and a by-table index
- [ ] Every run row carries status, row counts, `error_message`, `run_kind` and a TTL
- [ ] A crash net guarantees a terminal row for every dispatched unit
- [ ] Watermarks advance on success only — verified by a deliberate failure test
- [ ] An init-state machine gates entry into the nightly delta cycle
- [ ] `pipeline_state` kinds validate against their own models
- [ ] Health fields distinguish "unknown" from "zero"
- [ ] Lineage edge ids are deterministic, and edges are written by the transform at completion
- [ ] Every widget on the intended console maps to one keyed read you have written down
- [ ] The runbook says "query the run rows", never "check the execution status"

## You've got it when you can…

…be handed a question — *"did it run?"*, *"how far did it get?"*, *"is it alerting?"*, *"where did this column come from?"* — and name the record type, the key and the index you would query, without looking anything up.
