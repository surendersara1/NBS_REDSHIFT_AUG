# L01 · Design the Engine Before the Pipelines

> **Module 2 · Lesson 01** · ~45 min

**Slide:** [`_render/L01-design-the-engine.html`](_render/L01-design-the-engine.html)

## The decision

You are about to onboard eight source systems and roughly a hundred tables. Before you write a single pipeline, you have to answer one question:

> **Is the unit of work a job, or a spec?**

Either every table gets its own Python job — its own file, its own tests, its own deployment — or you build **one engine** that reads a **declarative spec** and treats every table as data.

You pick this in week one, and the next hundred tables have to live inside whatever you picked. It is not a refactor you get to do later: by the time the cost is obvious, there are ninety jobs to unpick.

**Choose the engine.**

## Do this

1. **Define the spec model first, in code.** A typed, validated object — Pydantic or equivalent — with fields for: source system, object name, column list with types, natural key (`merge_key`), read mode, landing prefix, and any per-table overrides. Nothing about a table lives anywhere else.
2. **Make an invalid spec fail at parse time, not at run time.** Add model validators that reject the classes of mistake you cannot detect later: a `merge_key` naming a column that is not in the declared schema; a column marked as sensitive being used as a key; a watermark column missing from the projection. These are cheap to write and each one removes a whole family of production bugs.
   *Worked example:* [`src/glue/glue_engine/spec.py`](../../../tamimi-lakehouse/src/glue/glue_engine/spec.py) — read the `@model_validator` block.
3. **Cut the engine along four seams, and only four.**

   | Seam | Owns | Reference file |
   |---|---|---|
   | **Spec** | What the table *is* | [`glue_engine/spec.py`](../../../tamimi-lakehouse/src/glue/glue_engine/spec.py) |
   | **Connector** | Where the rows come *from* | [`sources/protocol.py`](../../../tamimi-lakehouse/src/glue/glue_engine/sources/protocol.py) |
   | **Writer** | Where the rows go *to* | [`writers/raw_landing.py`](../../../tamimi-lakehouse/src/glue/glue_engine/writers/raw_landing.py) · [`writers/s3_tables.py`](../../../tamimi-lakehouse/src/glue/glue_engine/writers/s3_tables.py) |
   | **Control plane** | What actually *happened* | [`glue_engine/control_plane.py`](../../../tamimi-lakehouse/src/glue/glue_engine/control_plane.py) |

4. **Write jobs that only wire the seams together.** A download job should read: resolve the table's routing → parse its spec → ask the registry for a connector → call one read method → hand the frame to a writer → record the outcome. If a job contains business logic, that logic belongs behind a seam.
   *Worked example:* [`jobs/source_download.py`](../../../tamimi-lakehouse/src/glue/glue_engine/jobs/source_download.py) is exactly that sequence, end to end.
5. **Package the engine as one artifact.** One wheel, one version, deployed once. Specs are configuration that ships alongside it, not code that ships inside it.
6. **Keep routing in the control plane, not in the spec.** Which tables run today, in which phase, at what concurrency — that is operational state and it changes without a deploy. The spec describes the table; the control plane decides the schedule.
7. **Prove the claim before you scale.** Onboard the second table and check that you wrote **zero** new Python. If you had to write some, the seam it crossed is in the wrong place — fix it now, at two tables, not at fifty.

The target shape, stated as an acceptance test:

```
add table N+1  =  1 spec file  +  1 catalog row  —  no new code, no deploy
```

## Why

- **A fix lands once.** One `MERGE` implementation, one retry policy, one metrics emitter. When you improve it, every table gets the improvement on the next run.
- **The config path is reviewable.** A YAML spec diffs in a pull request and a non-Python reviewer can read it. A hundred near-identical Python files diff badly and nobody reads them.
- **The config path is testable without a cluster.** Spec parsing and validation are pure functions. You get a fast unit-test suite over the thing that actually breaks — the per-table declarations.
- **Onboarding is bounded.** "How do I add a table?" has a three-line answer that a new joiner can execute on day two.

**What breaks if you don't:** a hundred near-identical jobs drift apart, and every fix has to be made a hundred times — with the ones you miss failing silently.

## On Apparel Group

Eight sources, three connector classes, roughly a hundred specs.

| Source | Kind | Connector it needs |
|---|---|---|
| Oracle Retail (RMS) | Oracle DB | **Oracle JDBC** |
| Oracle SIM | Oracle DB | **Oracle JDBC** |
| Oracle XStore | Oracle DB | **Oracle JDBC** |
| Epsilon | SaaS API (PII) | **API / cursor** |
| MoEngage | SaaS API | **API / cursor** |
| Magento | DB or API | Oracle JDBC pattern, or API |
| Vemco Footfall | file / API | **File drop** |
| Irisys Footfall | file / API | **File drop** |

Three of the eight are Oracle and share one connector class outright. Two are cursor-paged SaaS APIs and share a second. The footfall feeds are small file drops and share a third. **The variety is in the specs, not in the code** — which is the whole reason the engine is worth building on week one rather than week nine.

Sequence the build: engine and spec model first, then the Oracle connector, then RMS as the first real table. Every source after RMS is a spec-writing exercise.

## Checklist

- [ ] Spec model is typed and validated; an invalid spec raises before any compute starts
- [ ] Validators cover: key not in schema, watermark not in projection, sensitive column used as key
- [ ] The four seams exist as separate modules with no cross-imports between them
- [ ] No job file contains an `if source == ...` or a table name
- [ ] Adding the second table required zero new Python — verified, not assumed
- [ ] Engine is one versioned artifact; specs ship as configuration
- [ ] Routing and schedule live in the control plane, not in the spec files
- [ ] A new joiner can add a table from the README alone

## You've got it when you can…

…be handed a ninth source system and estimate the work as *"one connector class, then one spec per table"* — and defend that estimate by naming which of the four seams each piece of the work lands in, and why none of it touches the jobs.
