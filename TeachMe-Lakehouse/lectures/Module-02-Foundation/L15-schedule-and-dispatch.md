# L15 · Design the Schedule and the Dispatcher

> **Module 2 · Lesson 15** · ~45 min
>
> **Slide:** [`_render/L15-schedule-and-dispatch.html`](_render/L15-schedule-and-dispatch.html) → [`L15-schedule-and-dispatch.png`](L15-schedule-and-dispatch.png)

## The decision

Where is *"what runs tonight"* actually decided?

You have two ways to answer it. You can put the answer in the schedule — a cron rule per table, each with its own time, its own target and its own idea of what "yesterday" means. Or you can put the answer in **one function** that wakes up once, reads the config and the current state, and works out the night's plan before a single job starts.

Choose the second. The cron becomes a doorbell: it carries no instructions at all.

## Do this

1. **One schedule rule → one dispatcher.**
   A single rule fires once per day at a fixed wall-clock time. It passes an empty payload. Everything the run needs is derived, not carried. If your team has to open the scheduler to answer "why did this table run?", the design is wrong.

2. **Stamp one cycle id for the whole night.**
   Use the UTC date for a scheduled run (`<YYYY-MM-DD>`) and a prefixed id for a scoped one (`init-…`, `bf-…`, `rebaseline-…`). Every run row, every lock, every alert and every lineage edge carries it. One id is what turns thousands of scattered rows into one answerable question: *what happened last night?*

3. **Write the cycle manifest first — and make it create-only.**
   Before you start any work, write one record that says: this cycle exists, it started at *T*, and these are the units of work it expects. Use a conditional write (`attribute_not_exists(pk)` or the equivalent) so a double-fire of the schedule cannot resurrect a finished cycle or reset the start clock. Write it *before* dispatch, or a fast source can reach the first hand-off before the manifest it needs is there.

4. **Build tonight's list from config plus state — never from a hardcoded schedule.**
   The dispatcher reads the source/table config (which tables are enabled, which source they belong to, what load strategy each uses) and the current watermark state (has this table completed its initial load yet?). It groups by source and produces one launch plan per source. Adding a table is a config row; it is never a change to the dispatcher.

5. **Make the expected list a promise, not a wish.**
   A table only enters `expected[]` if it was actually launched. A table that is enabled in config but has no runnable target must be reported as a failure now, not silently waited on forever by a downstream gate.

6. **Declare the run mode. Never infer it.**
   Four modes, chosen by the payload, all handled by the same function:

   | Mode | Payload shape | What it means |
   |---|---|---|
   | `initial` | `{"initial_load": true, "source": …}` | complete history, once, before CDC starts |
   | `incremental` | `{}` (the scheduled path) | tonight's delta, from the stored watermark |
   | `rerun` | `{"rerun": true, "cycle_id": …}` | redo today's failures inside the same cycle |
   | `backfill` | `{"rerun": true, "date_from": …, "date_to": …}` | a dated re-pull in its **own** cycle, watermark untouched |

   Route on the payload in one place — a handful of `if`s at the top of the handler is the entire public API of your pipeline. Write it so a reviewer can read all four branches on one screen.

7. **Keep the orchestration payload small: pass references, not data.**
   Every orchestration engine has a hard input-size ceiling (Step Functions: 262,144 bytes). A large initial load walks straight into it. Two habits keep you clear of the wall:
   - Each work item carries *identifiers* — source, table, mode, date window — and nothing the downstream stage can look up for itself. Strip every field that belongs to a later phase.
   - Chunk a long initial load into calendar-aligned windows, and make the chunk size a **parameter of the invocation**, not a constant in the code. Wider chunks mean fewer job startups but bigger, riskier pulls; narrower chunks mean resumability but startup cost dominates. You want to be able to change your mind without a deploy.

8. **Do not window a table that has no usable date column.**
   If a table's only strategy is full-refresh, a date predicate matches everything — so each "window" re-reads the entire table. Give those tables one un-windowed chunk. A table opts *into* chunking only when its watermark is a genuine date.

9. **Make dispatch itself idempotent.**
   Derive the execution name from `<source>-<cycle_id>` so a duplicate fire collides and no-ops. Then handle the trap: many engines reserve execution names long after the execution has ended, so "name already exists" does **not** mean "still running". Read the prior execution's status; if it is terminally dead, re-dispatch under a uniquified name.

> **Worked example (Tamimi):** `src/lambdas/dispatcher/handler.py` — `_dispatch` is the launch plan, the mode routing is five `if`s near the top, `_month_windows` / `_chunk_windows` is twenty lines that define what a chunk is, and `_make_table_item` documents exactly which fields a work item is *not* allowed to carry. Read it as a shape to copy, not as history.

## Why

- **Eight sources times dozens of tables is too many cron rules to keep correct by hand.** A schedule spread over hundreds of rules has no single place where its logic can be reviewed, tested, or explained.
- **A dispatcher is a pure-ish function, so you can unit-test the decision.** Feed it a config fixture and a watermark fixture; assert on the launch plan. You can never write that test against a scheduler.
- **State — not the clock — decides what is due.** A table that has not finished its initial load must not join the nightly delta cycle. Only something that reads state can enforce that.
- **Small payloads survive the orchestration layer.** Size limits apply to what you send *and* to what a parallel map aggregates on the way back; pass references in both directions and neither can bite you.

**What breaks if you don't:** per-table schedules drift apart until no two tables share a definition of "today", and nothing in the system can answer *"what ran tonight, and why that list?"*

## On Apparel Group

- **One nightly cycle covers all eight sources** — Oracle Retail (RMS), Oracle SIM, Oracle XStore, Epsilon, MoEngage, Magento, Vemco Footfall, Irisys Footfall — with one dispatcher fanning out to one execution per source. Sources run in parallel; tables within a source are the dispatcher's concern, not the scheduler's.
- **XStore is the giant.** Its initial load is the one that will hit the payload ceiling first, so it is the one to chunk into calendar windows, and the one whose chunk size you will tune. Size it before you size anything else.
- **RMS masters are small and mostly full-refresh** — one un-windowed chunk each. Do not let them inherit XStore's chunking scheme just because they share a dispatcher.
- **Epsilon and MoEngage have their own cursors**, not date watermarks. Their work item carries a cursor reference; the connector resolves it. The dispatcher does not need to know the difference — that is what L02's source contract bought you.
- **Vemco and Irisys are small file drops.** They ride the same fan-out as everything else. Resist the urge to give a small source a special path; two special paths become eight.
- **Pick the cycle-id timezone deliberately.** Gulf retail operates on a fixed offset with no DST, so a UTC-based cycle id maps to a stable local hour. Write that decision down once, in the config, and never recompute it per table.

## Checklist

- [ ] Exactly one schedule rule per environment, and it passes an empty payload
- [ ] `cycle_id` is generated in one place and stamped on every downstream record
- [ ] The cycle manifest is written **before** the first job starts, with a create-only condition
- [ ] The launch plan is derived from config + watermark state; no table names in code
- [ ] `expected[]` contains only work that was actually launched
- [ ] All four run modes are named, routed in one function, and documented in the runbook
- [ ] Chunk size is an invocation parameter, not a constant
- [ ] Full-refresh-only tables are dispatched un-windowed
- [ ] Work items carry identifiers only — you have measured the serialized size of a worst-case plan
- [ ] Execution names are deterministic, and "name exists" is resolved by reading the prior status
- [ ] Dev's schedule rule is **disabled**: Dev is manual-only

## You've got it when you can…

…take a payload you have never seen — say `{"initial_load": true, "source": "xstore", "chunk_months": 3}` — and predict, before running it: which cycle id it creates, roughly how many jobs it will produce, whether the orchestration input will fit inside the size ceiling, and which hand-off will decide when it is finished.
