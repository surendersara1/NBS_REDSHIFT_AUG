# L04 · The Whole Platform on One Slide
> **Module 1 · Lesson 04** · ~45 min · slide: `L04-the-map.png`

## The point
One map you return to for the next 40 hours. **Every other lesson is a zoom into one box on this slide.**

## Key ideas
- **Top row = the assembly line.** Sources → Raw → Bronze → Silver → Gold → Power BI. Data only moves left to right.
- **Bottom row = the factory.** Orchestration, control plane, catalog/governance, and build/deploy. None of it touches the data — it *runs* the data.
- **P1 / P2 split:** one job pulls from the source (P1), another loads Bronze (P2). After P1, we never hit SAP again — that's deliberate.
- **Two storage worlds:** Bronze/Silver are Iceberg on S3 Tables (cheap, open). Gold is native Redshift (fast, closed). dbt is the bridge.
- **Barriers** gate each phase hand-off — nothing starts until the previous phase is provably complete.
- **The control plane knows everything:** what ran, when, how long, how many rows, and what came from what.
- **Three environments** (Dev/QA/Prod) deploy independently through the same pipeline.

## Words you'll hear
| Term | Means |
|---|---|
| P1 / P2 | Source-download job / Bronze-load job |
| Barrier | A gate that waits for a whole phase to finish |
| Control plane | The bookkeeping tables (runs, watermarks, lineage) |
| Cycle | One daily end-to-end run, identified by date |
| Dispatcher | The Lambda that decides what runs today |

## In this repo
- `src/glue/glue_engine/jobs/` — the four job types on the top row
- `src/lambdas/dispatcher/`, `src/lambdas/*_barrier/` — orchestration
- `src/shared/shared/control_plane/` — runs · watermarks · pipeline-state · lineage
- `infra/` + `bitbucket-pipelines.yml` — how it all gets deployed

## Do this
Point at any box on the slide and find the folder that implements it. All eight are findable in under a minute.

## You've got it when you can...
Draw this map from memory on a whiteboard, and explain what would break if you deleted the **Raw** layer.
