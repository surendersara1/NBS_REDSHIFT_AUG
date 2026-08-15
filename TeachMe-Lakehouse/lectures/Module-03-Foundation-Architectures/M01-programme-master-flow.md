# M01 · The Programme, End To End

> **Module 3 · Master Flow 01 · Apparel Group** · ~15 min

**Diagram:** [`_render/M01-programme-master-flow.html`](_render/M01-programme-master-flow.html)

## What it shows

The whole engagement in six phases. **Everything in the other 34 diagrams sits inside one of these boxes.**

This is a sponsor's diagram, not an engineer's. It answers "where are we, and what happens next" without anyone needing to know what Iceberg is.

## The six phases, and what closes each

| Phase | Exit when |
|---|---|
| **1 · Discover** | every source has a named owner and a contract |
| **2 · Foundation** | one table flows end to end, in dev, from a spec |
| **3 · Source waves** | bronze and silver land nightly, and re-run safely |
| **4 · Model** | the business agrees the numbers, **in writing** |
| **5 · Consume** | users answer questions without asking us |
| **6 · Go-live** | the client team runs a nightly failure alone |

Each exit criterion is deliberately something you can **demonstrate**, not something you can assert. "Foundation is done" is an opinion; "one table flows end to end from a spec" is a demo.

## Phase 1 carries the questions that matter

Discovery is not a formality. Three things are established here or they cost you later:

- **Does each source hard-delete?** Decides the ingestion mechanism per source (D17, D22).
- **What is PII, and who signs off?** Blocks wave 3 entirely (M04).
- **Volumes and change rates.** Decides parallelism, cost and whether zero-ETL is even affordable.

## The things that actually delay programmes like this

None of them are engineering:

1. **Network access to on-prem Oracle** — weeks of lead time, and not ours to expedite (D18)
2. **PII classification and legal sign-off** — blocks the Epsilon wave
3. **Source system owners agreeing a contract** — blocks everything
4. **The Oracle ingestion decision** — needs a measured spike, not a meeting

**Start all four in phase 1**, even though none of them can finish there. A dependency you cannot complete is still a dependency you can begin.

## Phase 6 is a capability, not a date

"Go-live" is often written as a date and treated as a handover. It is neither. The exit criterion is that **the client team can handle a nightly failure without us** — which means runbooks written, alarms tuned, the ops console in use, and at least one real incident handled by them while we watch.

Anything less and hypercare never ends; it just stops being funded.

## Checklist

- [ ] I can name the six phases and each exit criterion
- [ ] Every exit criterion is demonstrable, not assertable
- [ ] The four blockers were started in phase 1
- [ ] Phase 4 ends with written agreement on the numbers
- [ ] Phase 6 ends with a capability, not a date

## You've got it when you can…

…present this to a sponsor and answer "when will it be done?" by pointing at the exit criteria — and by naming which of the four blockers is currently the critical path.
