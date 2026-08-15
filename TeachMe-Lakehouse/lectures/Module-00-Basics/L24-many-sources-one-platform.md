# L24 · Eight Sources, One Platform

> **Module 0 · Lesson 24** · ~40 min

**Slide:** [`_render/L24-many-sources-one-platform.html`](_render/L24-many-sources-one-platform.html)

## What it is

**Eight pipelines is not eight times one pipeline.**

One source is an engineering problem. Eight sources is a *convention* problem — and conventions have to be decided before the second source, not discovered around the sixth.

## Four conventions that make the ninth source cheap

### 1. One landing shape

```
raw/<source>/<table>/dt=YYYY-MM-DD/part-NNNN.parquet
```

Every source lands under the same prefix pattern, partitioned the same way. **No exceptions**, including for the source that "is a bit different" — that source is the reason the convention erodes.

The benefit is not tidiness. It is that every downstream tool, alarm, lifecycle rule and access grant can be written once against a shape rather than eight times against eight shapes.

### 2. One contract per source

Schema, natural key, load mode and owner declared **once**, in configuration, never buried in code.

A contract in config can be diffed in a pull request and read by someone who does not write Python. The same information spread across eight job files cannot be reviewed at all.

### 3. Isolation

**One bad feed must not stall the other seven.** That means separate runs, separate state and separate alarms per source.

The anti-pattern is a single orchestration that fails as a unit: Epsilon's API is slow, so the whole night's load is marked failed, and nobody can tell which seven sources actually succeeded.

### 4. Assume late and duplicate rows

Rows **will** arrive late, and they **will** arrive twice. Both are normal operating conditions, not incidents.

An idempotent `MERGE` on a key makes both harmless (Lesson 11). Without it, every late file is a manual decision and every duplicate delivery is an outage.

## Decide these early — they are painful to change

| Decision | Why it is painful later |
|---|---|
| **Partition key and its format** | changing it means rewriting every prefix and every downstream reference |
| **Timezone** | pick one, write it down; mixed timezones produce off-by-one-day bugs that survive for years |
| **What "yesterday" means per source** | a source in another timezone with a nightly cut has a different "yesterday" than your scheduler does |

That last one causes more quiet wrongness than any other item on this list. Write it down per source.

## The acceptance test

> **If adding the ninth source needs new code, the eighth was onboarded wrong.**

Check this at source two, not source eight. Onboard the second source and count the lines of new Python you had to write. If it is not close to zero, the seam is in the wrong place — fix it now, while there are two.

## In practice

Eight Apparel Group sources reduce to **three connectors**:

- Three Oracle databases → one Oracle connector
- Two cursor-paged SaaS APIs → one API connector
- Two footfall file feeds → one file-drop connector

The variety lives in the specs. That is exactly why the engine is worth building in week one rather than week nine — which is where Module 2 begins.

## Checklist

- [ ] Every source lands under the same prefix shape
- [ ] Every source has a contract in configuration, not in code
- [ ] One source failing cannot stall the others
- [ ] Loads are idempotent, and I have tested it
- [ ] Partition key, timezone and "yesterday" are written down
- [ ] I verified at source two that source three needs no new code

## You've got it when you can…

…be handed a ninth source and estimate the work as "one spec file" — and defend that estimate by pointing at the four conventions rather than by hoping.
