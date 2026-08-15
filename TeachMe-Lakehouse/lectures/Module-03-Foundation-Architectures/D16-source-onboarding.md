# D16 · Eight Sources, Three Connectors

> **Module 3 · Architecture 16 · proposed** · ~15 min

**Diagram:** [`_render/D16-source-onboarding.html`](_render/D16-source-onboarding.html)

## What it shows

Eight sources collapsing into **three connector classes**, feeding one engine driven by specs.

> **The variety lives in the specs, not in the code.**

That single property is what makes the ninth source a config change rather than a project.

## The three connector classes

**Oracle JDBC** — serves RMS, SIM and XStore. Parallel reads on a numeric key. One class, three sources, roughly ninety specs. Sizing differs per source (XStore is the giant), but sizing is a spec field, not a different class.

**Cursor-paged API** — serves Epsilon and MoEngage. Rate limits, paging and retry live here **once**, not re-solved per source. This is where the SaaS engineering problem actually is.

**File drop** — serves Vemco and Irisys. Late, duplicate and missing files are normal operating conditions, handled once, here.

Magento joins whichever of the first two it turns out to be — a question to settle in discovery, not in code.

## The four seams

| Seam | Owns |
|---|---|
| **Spec** | what the table *is* — schema, natural key, read mode, source config |
| **Connector** | where rows come *from* — one class per kind of source, never per table |
| **Writer** | where rows go *to* — land raw immutably, then MERGE on the key |
| **Control plane** | what actually *happened* — runs, watermarks, state, lineage |

Jobs only wire the seams together. If a job file contains business logic, that logic belongs behind a seam.

## The acceptance test

```
add table N+1 = 1 spec file — no new code, no deploy
```

**Check this at source two, not source eight.** Onboard the second source and count the lines of new Python. If it is not close to zero, a seam is in the wrong place — fix it while there are two, not while there are eight.

## Why this beats eight pipelines

- A fix lands **once** and every table gets it on the next run.
- A YAML spec **diffs in a pull request**, and a non-Python reviewer can read it.
- Spec parsing is a pure function, so the thing most likely to be wrong is **testable without a cluster**.
- "How do I add a table?" has a three-line answer a new joiner can execute on day two.

## Checklist

- [ ] Eight sources map to three connector classes
- [ ] The spec model is typed and validated before compute starts
- [ ] The four seams exist as separate modules
- [ ] No job file contains a source name or an `if source == …`
- [ ] Adding source two required zero new Python — verified, not assumed
- [ ] Routing and schedule live in the control plane, not in specs

## You've got it when you can…

…be handed a ninth source and estimate it as "one connector class if it is new, otherwise one spec per table" — and defend that by naming which seam each piece of work lands in.
