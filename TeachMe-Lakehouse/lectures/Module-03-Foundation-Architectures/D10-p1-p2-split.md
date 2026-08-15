# D10 · The P1 / P2 Split

> **Module 3 · Architecture 10 · deep dive** · ~20 min

**Diagram:** [`_render/D10-p1-p2-split.html`](_render/D10-p1-p2-split.html)

## What this pattern is for

Two phases with a barrier between them. **Every source must finish landing before any source starts building** — because a bronze table built while its siblings are still arriving is a table built on a partial view.

## The ten steps

**1 · EventBridge fires, once.** One schedule, one entry point. Not one cron per source — that is how you get two jobs racing at 02:00 and a schedule nobody can reason about.

**2 · The dispatcher reads the specs.** It works out which sources are due from configuration and control-plane state, not from a hardcoded list. This is what makes adding a source a config change.

**3 · Glue reads over JDBC, windowed.** Each source in its own branch, reading a bounded window rather than the whole table. Parallelism is sized per source (Module 2 L03), because RMS and XStore do not deserve the same settings.

**4 · Raw is written once.** Immutable, exactly as received. Nothing downstream is the only copy from this moment on.

**5 · The watermark advances — only on success.** ⭐ This is the correctness hinge of phase 1. A job that failed part-way must **not** advance its watermark, or the next run skips data that was never written. The watermark carries a **dirty** flag for exactly this case.

**6 · The barrier.** ⭐ Each branch records its terminal state with a **conditional write** — `attribute_not_exists(pk)`. First writer wins; a duplicate attempt fails harmlessly. This is the entire single-flight mechanism, and it is why two dispatchers cannot both open the gate.

**7 · The phase gate asks one question.** Are all phase-1 branches **terminal**? Not *successful* — terminal, which includes failed. A failed source must be visible and skipped, never able to hold the gate closed forever. Otherwise one broken feed stalls the whole platform.

**8 · Phase 2 MERGEs into Iceberg.** On `merge_key`. Because it merges rather than appends, re-running a branch is safe — which is what turns an incident into a retry rather than a repair.

**9 · Tables are registered in the catalog.** Declaratively. The schema is a reviewed artefact, not something a crawler inferred from whatever happened to land.

**10 · dbt builds gold in Redshift.** Only after phase 2 completes. Gold is the layer that promises the same answer twice, and it cannot promise that on top of a half-built silver.

## Why two phases and not one

Because **landing and building have different failure modes and different retry costs**.

Landing is network-bound and fails for reasons outside your control — a source is slow, a VPN drops, credentials expire. Building is compute-bound and fails for reasons inside it — a bad merge key, a type mismatch.

Separating them means a slow source delays the build; it does not corrupt it. Merging them means every network hiccup becomes a partially-built table.

## What breaks if you skip a piece

- **No barrier** — bronze is built on a partial landing, silently.
- **Gate on success rather than terminal** — one broken source blocks everything, indefinitely.
- **Watermark advances on failure** — a permanent gap nothing will ever tell you about.
- **Append instead of MERGE** — a retry doubles the day.

## Checklist

- [ ] One schedule, one entry point
- [ ] Watermarks advance only on success, and carry a dirty flag
- [ ] The barrier is a conditional write
- [ ] The gate waits for **terminal**, not for success
- [ ] Phase 2 MERGEs on a key and is safe to re-run
- [ ] I have deliberately failed one source and watched the gate behave

## You've got it when you can…

…explain to a new engineer why phase 2 does not simply start when phase 1's *first* branch finishes — and point at the row in DynamoDB that stops it.
