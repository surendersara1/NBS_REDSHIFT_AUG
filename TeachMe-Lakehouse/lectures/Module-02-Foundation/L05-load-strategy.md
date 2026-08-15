# L05 · Plan the Load Strategy per Table

> **Module 2 · Lesson 05** · ~45 min

**Slide:** [`_render/L05-load-strategy.html`](_render/L05-load-strategy.html)

## The decision

For every single table you onboard:

> **Full, incremental or windowed — and what exactly does day one load?**

These are two questions and people usually only answer the first. The steady-state mode is the easy part. The expensive part is **day one**: how the table gets from empty to complete, and how the platform knows it got there before the nightly delta takes over.

Classify the table first. The class determines the read mode, the day-one plan, and the empty-result rule — all three fall out of one decision, which is why it is worth making deliberately and writing down.

## Do this

### 1 · Put every table in exactly one of three boxes

| Class | When | Steady state | Day one |
|---|---|---|---|
| **FULL-ONLY MASTER** | No trustworthy change column (see [L04](L04-choosing-a-watermark.md)), **or** small enough that a full read is cheaper than the machinery | Read all of it, every run | Just a normal run |
| **INCREMENTAL FACT** | Trusted watermark, high volume, high churn | Daily delta from the stored watermark | **One complete full load** |
| **WINDOWED GIANT** | Too big to pull in one go, even partitioned (see [L03](L03-sizing-jdbc-parallelism.md)) | Daily delta | **N date windows**, run in parallel, **all** must finish |

```yaml
read_mode: full            # full-only master
read_mode: incremental     # incremental fact
read_mode: range           # windowed giant (chunked initial load)
```

*Worked example:* one row per table in [`config/ingestion_tables.yaml`](../../../tamimi-lakehouse/config/ingestion_tables.yaml), with the per-table detail in [`specs/download/`](../../../tamimi-lakehouse/src/glue/specs/download/).

### 2 · Make the initial load complete — never a window

An initial load must cover the table's **full declared scope**. If you define a horizon ("the last five years"), the initial load pulls the whole horizon in one go; it does not sub-window below it and call itself done.

And note the exception that catches people out: **master data and creation-date-keyed tables get no horizon at all.** A customer master keyed on a creation date, filtered to five years, drops every customer created before that — including the active ones. Master tables load *truly* full.

State the invariant you are protecting, in one sentence, and then test it:

> After the initial load, the landed row count equals the source's row count **measured with the same filter**.

Check it on **both** sides. Run the count against the source and against the target and compare. Do not assert it from reading the code.

### 3 · Derive `full` where the config already implies it

If a table's routing declares only a full mode and no incremental mode, the job should force full and **clear any date window** it was passed. A full-refresh table has no real date column, so a uniform initial-load window would filter on a placeholder and match nothing — a run that succeeds and lands zero rows.

One exception: a table that is *both* full-refresh *and* enormous is delivered as many windows on purpose. Make that an explicit opt-in flag (`chunk_full_reload` or similar) so the derivation does not silently un-window it.
*Worked example:* the derivation and its exception in [`jobs/source_download.py`](../../../tamimi-lakehouse/src/glue/glue_engine/jobs/source_download.py).

### 4 · Hand over to CDC once — and let the phase gate own the flip

Track an explicit lifecycle per table:

```
(none)  →  initial_loaded  →  cdc
```

- `(none)` — never loaded. Not admitted to the nightly cycle.
- `initial_loaded` — the complete initial load succeeded.
- `cdc` — the first plain daily delta after that has run.

**The phase barrier owns the transition, not the job.** A windowed load's chunks run concurrently across lanes and finish out of order, so no single chunk can know whether the load is complete. If a chunk flips the state, the table gets admitted to the next nightly cycle **mid-reload**, with a watermark from whichever window happened to finish first — and the delta then starts from the middle of history. Let the barrier flip it, once, when every window of every table is terminal.
*Worked example:* the completion check in [`src/lambdas/download_barrier/handler.py`](../../../tamimi-lakehouse/src/lambdas/download_barrier/handler.py).

### 5 · Seed the watermark from a windowed initial load

A windowed initial load still has to leave a watermark behind — seeded forward-only from the **end of the window range**. Otherwise a giant that never gets a single full pull reaches `initial_loaded` with an empty watermark, and every subsequent delta dies at the validation guard from [L04](L04-choosing-a-watermark.md).

### 6 · Define the empty-result policy — it is not one rule

An empty result means opposite things in the two directions:

| | Meaning | Action |
|---|---|---|
| **Empty FULL pull** | Almost always a broken extract, a wrong filter, or a connection that returned nothing | **FAIL** — and fail **before landing**, so no success marker is written and no watermark moves |
| **Empty DELTA** | A quiet window. Perfectly normal | **SUCCEED** — record zero rows and move on |

Allow a per-spec `on_empty: succeed | warn | fail` override for the genuine exceptions, but make the **defaults** the two rules above. The critical half is "fail before landing": an empty full pull that lands replaces good data with nothing, and the failure looks like a successful run.

### 7 · Treat a backfill as a side trip, not progress

A bounded `[date_from, date_to]` re-pull returns rows and **does not advance the watermark**. Write each chunk under its own sub-prefix (`chunk=<from>_<to>`) so concurrent chunks cannot clobber each other, and so a failed chunk can be re-run alone.

## Why

- **Day one is invisible when it is wrong.** There is no error. There is just a table that is quietly short, and every reconciliation built on it is wrong by an amount nobody can name — usually discovered when a business user disputes a number, months after the build.
- **An empty full pull that lands is worse than a crash.** It replaces good data with none, marks itself successful, and leaves the watermark intact so the next run sees nothing unusual.
- **Flipping to CDC early is the more dangerous of the two mistakes.** A late flip costs you a day. An early flip leaves a permanent hole in the middle of history, at a watermark that looks entirely plausible.
- **Classification is cheap and one-way.** Deciding the class takes ten minutes per table at design time. Discovering it was wrong takes a re-load of a giant table and a hard conversation.

**What breaks if you don't:** the error surfaces months after the build, in a total that cannot be reconciled against the system of record — and by then nobody remembers what day one looked like.

## On Apparel Group

The classification exercise for all eight sources. **Do this as a table, in a document, before writing any specs.**

| # | Source | Table class | Load strategy |
|---|---|---|---|
| 1 | **Oracle Retail (RMS)** — facts (sales, receipts, transfers) | Incremental fact | Full initial load within horizon, then daily delta |
| 1 | **Oracle Retail (RMS)** — masters (item, supplier, location) | Full-only master | Truly full, **no horizon**, every run |
| 1 | **Oracle Retail (RMS)** — code/lookup tables | Full-only master | Full every run; cheap |
| 2 | **Oracle SIM** — inventory positions | Incremental fact | High churn — requires a true update stamp, not a creation date |
| 3 | **Oracle XStore** — POS transactions | **Windowed giant** | N date windows on day one, all must complete before CDC |
| 4 | **Epsilon** — loyalty / customer master (**PII**) | Incremental fact (cursor) | Full initial pull, then vendor cursor. Classify and mask before it reaches a report |
| 5 | **MoEngage** — campaign & engagement | Incremental fact (cursor) | Vendor cursor; events are append-only |
| 6 | **Magento** — orders, customers, products | Incremental fact | `updated_at` delta; products may be small enough for full-only |
| 7 | **Vemco Footfall** | Full-only master | Small per-store counts — full-refresh the file drop |
| 8 | **Irisys Footfall** | Full-only master | As Vemco |

**XStore is the one to plan first.** It is the giant, it is the table that forces the windowed path to exist, and its day-one load will dominate the ingestion schedule for the first weeks of the build. Everything else is comparatively routine.

Two Apparel-Group notes:

- **Apparel dimensions multiply.** Style / colour / size / season means "master data" is bigger here than in most retail estates. Check the row counts before assuming a master table is small enough for full-only.
- **Epsilon is PII.** Its initial load is also the first time customer data lands in the lake. Have the masking and classification decision made *before* day one, not after.

## Checklist

- [ ] Every table classified: full-only master / incremental fact / windowed giant
- [ ] Classification recorded in config, not in someone's head
- [ ] Initial load covers the full declared scope — never sub-windowed below the horizon
- [ ] Master and creation-date-keyed tables load with **no** horizon
- [ ] Row-count parity verified on **both** sides after the initial load
- [ ] Full-derivation clears any date window it was passed
- [ ] Chunked full-reload is an explicit opt-in flag
- [ ] Lifecycle state tracked: `(none)` → `initial_loaded` → `cdc`
- [ ] The **phase barrier** flips the state, once, when every window is terminal — no chunk can flip it
- [ ] A windowed initial load seeds its watermark forward-only from the window end
- [ ] Empty FULL = fail, **before landing**; empty DELTA = succeed
- [ ] `on_empty` override available per spec, with the two defaults above
- [ ] Backfills do not advance the watermark and write under their own chunk prefix

## You've got it when you can…

…say why an empty pull is a **success** for one table and a **failure** for another on the same morning — and explain why declaring a windowed chunk complete is the more dangerous of the two possible mistakes.
