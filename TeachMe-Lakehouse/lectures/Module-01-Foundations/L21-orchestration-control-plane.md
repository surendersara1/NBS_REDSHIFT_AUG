# L21 · What Actually Runs It — Orchestration & the Control Plane

**Slide:** [`_render/L21-orchestration-control-plane.html`](_render/L21-orchestration-control-plane.html)

## The point

One EventBridge rule fires each day. After that, **nothing is scheduled** — every subsequent phase is
*unlocked* by a barrier Lambda that only fires when the phase before it is provably complete.
That, plus a four-table control plane in DynamoDB, is the whole runtime.

## Key ideas

- **The chain:** EventBridge (one daily rule) → dispatcher Lambda → one Step Functions execution per source → Glue jobs (`source_download`, `bronze_pull`, `abap_transform`, `bronze_to_silver`).
- **Barriers are `await Promise.all()`.** Each is the tail Task of a Step Function. It reads the cycle manifest, resolves every expected table to its latest run, and returns *waiting* unless all of them are terminal.
- **Four gates:** `download_barrier` (raw → Bronze), `transform_barrier` (ABAP rebuild → Silver), `silver_barrier` (per-source → cross-source conform), `gold_barrier` (Silver → dbt Gold).
- **All-or-nothing.** If any expected table failed, the barrier marks the cycle `*_skipped` and raises SNS. A partial raw landing must never become a partial Bronze.
- **Single-flight.** Every barrier claims a lock with a conditional DynamoDB write, so the *many* invocations that race to close a phase produce *one* decision — and one Gold build per day.
- **Idempotency is designed in, twice.** The dispatcher uses a deterministic Step Functions execution name (`<source>-<cycle_id>`), so a re-fire the same day is rejected outright; and Bronze loads MERGE on `merge_key`, so a replay overwrites instead of duplicating.
- **Retries are boring on purpose.** boto3 adaptive retry in every Lambda, Step Functions `Retry`/`Catch` around the barrier Task, and a `cycle_sweeper` on `rate(15 minutes)` that re-invokes a hung cycle.
- **The control plane answers four questions** — see the table below. Together they are the ops console's entire data source.

## Words you'll hear

| Word | What it means here |
|---|---|
| **Cycle / `cycle_id`** | One day's run of the whole pipeline, e.g. `2026-06-17`. Everything correlates on it |
| **Manifest** | The dispatcher's written promise: `expected[]` = the tables this cycle will produce |
| **Barrier / gate** | A Lambda that blocks the next phase until every table in the current phase is terminal |
| **Terminal** | A run reached `succeeded`, `failed` or `cancelled` — it is no longer in flight |
| **Single-flight** | Many callers race; a conditional write means exactly one wins and acts |
| **Idempotent** | Running it twice leaves the same result as running it once |
| **Watermark** | "How far did we get last time" — the resume pointer for an incremental pull |
| **Lineage edge** | A directed `upstream → downstream` fact, so you can answer "what feeds this?" |

## In this repo

- [`src/lambdas/`](../../../tamimi-lakehouse/src/lambdas/)
  - `dispatcher/handler.py` — writes the manifest, starts one SFN per source
  - `download_barrier/handler.py` — the P1→P2 gate; also counts chunked runs, not just latest ones
  - `transform_barrier/handler.py` — the ABAP-rebuild gate
  - `silver_barrier/handler.py` — the cross-source conform gate
  - `gold_barrier/handler.py` — the dbt Gold gate; single-flight `gold_lock`
  - `cycle_sweeper/handler.py` — the backstop that re-invokes a stalled cycle
- [`src/shared/shared/control_plane/`](../../../tamimi-lakehouse/src/shared/shared/control_plane/) — `runs.py`, `watermarks.py`, `pipeline_state.py`, `lineage_edges.py`, `coordination.py`
- `infra/modules/control_plane/main.tf` — the DynamoDB tables themselves
- `infra/modules/dispatcher_lambda/eventbridge.tf` — the one rule

**The four tables, and what each answers**

| Table | Question it answers | Key |
|---|---|---|
| `runs` | What ran, and how did it go? | `run_id` + `stage`; GSIs `by_table`, `by_cycle`; 90-day TTL |
| `watermarks` | Where did we get to last time? | `source_id` + `table_name`; a failed run never advances it |
| `pipeline-state` | What is happening right now? | `pipeline_id` = `<kind>:<id>` — pipeline / alarm / freshness / reconciliation |
| `lineage_edges` | What feeds what? | `edge_id` = `upstream\|downstream\|edge_type`, deterministic so re-emits overwrite |

## Do this

1. Read the docstring at the top of `gold_barrier/handler.py`. Write out its 4 steps in your own words.
2. In `download_barrier/handler.py`, find step **2b** (the chunk count). Explain why "latest run is terminal" is not enough for a chunked initial load.
3. In `dispatcher/handler.py`, find where the Step Functions execution name is built. Say what happens if the EventBridge rule fires twice in one day.
4. In `runs.py`, explain why a table's `bronze_pull` and `bronze_to_silver` are two rows and not one updated row.

## You've got it when you can…

- Draw the daily cycle from cron to Gold, and put the four barriers on the right arrows.
- Explain a barrier to a backend developer in one sentence using `Promise.all()`, and then say where the analogy breaks (barriers are re-entrant and stateless; the state lives in DynamoDB).
- Say what happens to Gold when exactly one of 58 tables fails — and why that is the correct behaviour.
- Pick any of the four control-plane tables and say which operator question it answers, without looking.
