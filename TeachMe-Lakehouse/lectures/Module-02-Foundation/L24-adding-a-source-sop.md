# L24 · The Standard Procedure for Adding a Source

> **Module 2 · Lesson 24** · ~45 min · **closes Module 2**
> **Slide:** [`_render/L24-adding-a-source-sop.html`](_render/L24-adding-a-source-sop.html)

## The decision

Is a new source an engineering project, or a configuration change?

Everything in this module has been building to one answer. You will run this loop **eight times in twelve weeks** at Apparel Group. Decide now what one new table is allowed to cost — because if the answer is "a sprint", the answer for eight sources is "the whole engagement".

Make it a checklist. Nine steps, in order, and none of them inside the engine.

## Do this

The whole procedure, once, worked concretely against **Oracle Retail RMS `ITEM_MASTER`** — the first table your team will onboard.

### 1 · Classify the table

Before you write anything, put it in exactly one bucket:

| Class | Looks like | Load shape |
|---|---|---|
| Full-only master | small, changes slowly, no reliable change column | full refresh every cycle |
| Incremental fact | large, append-mostly, has a trustworthy change column | initial load, then deltas |
| Windowed giant | very large, changes across a range | date-window pulls, chunked |

`RMS.ITEM_MASTER` is a **master with a change stamp** — one complete initial load, then incremental. Write the class down; steps 4 and 6 both depend on it.

### 2 · Confirm the primary key and the watermark

Two facts, both verified against the source, neither assumed:

- **Primary key** — read it out of the source's constraint catalog. Do not infer it from a column name, and do not accept "it's the item number, obviously".
- **Watermark** — a column that is monotonic, indexed, non-null and actually maintained by the application. If no such column exists, say so and declare the table full-refresh. **Faking CDC is worse than not having it.**

For `ITEM_MASTER`: PK `ITEM`; watermark `LAST_UPDATE_DATETIME`.

> These two lines are the highest-stakes output of the whole procedure. Everything downstream inherits them.

### 3 · Connector — only if the protocol isn't already satisfied

The engine never imports a concrete connector; it asks a registry for one by source type. If an existing connector already satisfies the protocol for this protocol shape, **you write no code at all.**

Oracle over JDBC is the same code path as any other JDBC engine. That makes RMS, SIM and XStore *one branch on an engine literal*, not three connectors:

```python
_SUPPORTED_ENGINES = {"postgresql", "sqlserver", "oracle"}   # ← the whole change
```

Choose deliberately between widening an existing connector and registering a sibling class: a genuinely new source-type string also has to be added to the spec's validated literal, which is a wider change than the branch.

Epsilon and MoEngage will **not** fit the JDBC shape. They need paging, cursors, token refresh and rate-limit handling — and raw-first landing, because you often cannot re-request an old page. Say that out loud when you plan them; do not discover it in week 9.

### 4 · Write the download spec (source → raw)

*Shape reference:* [`src/glue/specs/download/sap_mara.yaml`](../../../tamimi-lakehouse/src/glue/specs/download/sap_mara.yaml)

```yaml
# specs/download/rms_item_master.yaml
table: rms.item_master
source_type: rds_jdbc

source_config:
  cadence: daily
  jdbc_schema: RMS
  jdbc_table: ITEM_MASTER
  watermark_column: LAST_UPDATE_DATETIME   # monotonic, indexed, IN THE PROJECTION
  jdbc_hash_field: ITEM                    # PK member, high cardinality
  jdbc_hash_partitions: "8"                # parallelism is mandatory, not optional

landing_prefix: "rms/rms.item_master"      # RELATIVE to the raw bucket root
format: parquet

schema:
  - { name: ITEM,      type: string, pii_class: internal, description: "Item number (PK)" }
  - { name: ITEM_DESC, type: string, pii_class: internal }
  - { name: DEPT,      type: string, pii_class: internal }
  - { name: CLASS,     type: string, pii_class: internal }
  - { name: SUBCLASS,  type: string, pii_class: internal }
  - { name: LAST_UPDATE_DATETIME, type: string, pii_class: internal, description: "WATERMARK" }

partition_by: []
```

Three decisions live in this file:

- **The watermark column must be in the projection.** The new watermark is computed as `MAX(<watermark_column>)` over what you pulled. If it isn't selected, you find out *after* paying for the whole pull.
- **Parallelism has no safe default.** Declare exactly one of hash field or hash expression, never both. Without it the read runs on one executor.
- **Curate the projection; never `SELECT *`.** Declare the columns you consume. A wide table with hundreds of columns should arrive as the twenty you use, so a source-side schema change cannot silently leak untyped columns into Bronze.

### 5 · Write the bronze spec (raw → table format)

*Shape reference:* [`src/glue/specs/bronze/sap_mara.yaml`](../../../tamimi-lakehouse/src/glue/specs/bronze/sap_mara.yaml)

```yaml
# specs/bronze/rms_item_master.yaml
table: rms.item_master
source_type: s3_landing        # reads back what step 4 landed — no creds, no DB hit

merge_key: [ITEM]              # the VERIFIED natural PK from step 2

schema:                        # MUST mirror the download spec, column for column
  - { name: ITEM, type: string, pii_class: internal, description: "Item number (PK)" }
  # … identical to download/rms_item_master.yaml

source_config:
  landing_prefix: "rms/rms.item_master"   # the same relative prefix step 4 landed under
  format: parquet
```

`merge_key` is the single highest-stakes line in the procedure: it is what makes replays, overlapping windows and retries land each row exactly once. Validation can check that every member exists in the schema, that there are no duplicates, and that no member is classified PII. It **cannot** check that it is the real primary key — that was step 2's job.

Two specs exist because a re-pull and a re-load are different failures with different costs. Keep their schemas identical; drift between them is a silent correctness bug.

### 6 · Add the catalog row

One row per **table**, one connection entry per **source**:

```yaml
  - name: rms.item_master
    source: rms                 # → the connection entry carrying source_type + secret ARN
    source_object: ITEM_MASTER
    download_spec: download/rms_item_master.yaml
    bronze_spec:   bronze/rms_item_master.yaml
    driver_by_mode: { full: rds_jdbc, range: rds_jdbc, incremental: rds_jdbc }
    initial_load: once
    cadence_band: daily
    freshness_sla_seconds: 86400   # L23 — choose it here, not later
    enabled: true
```

- `initial_load: once` engages the init-once guard: one complete historical load first, and only then are daily deltas allowed.
- `enabled: false` pauses a table without deleting it — use it while you iterate.
- `driver_by_mode` keeps the option of different connectors for different read modes; for Oracle all three are the same, but declaring it costs nothing.

### 7 · Staging model + tests

```sql
-- models/staging/stg_rms_item_master.sql
{{ config(materialized='view') }}

SELECT
    item                  AS item_id,
    item_desc             AS item_name,
    dept, class, subclass,
    last_update_datetime  AS updated_at
FROM {{ source('silver', 'rms_item_master') }}
```

```yaml
# models/staging/_staging.yml
  - name: stg_rms_item_master
    description: "1:1 mirror of silver rms.item_master, snake_case columns."
    columns:
      - name: item_id
        tests: [not_null, unique]
```

Staging is a **view** and a rename — no business logic. The `not_null` + `unique` pair on the natural key is the cheapest correctness insurance you will ever buy; add it before you add anything clever. If the staging layer reads an external schema, declare it late-binding.

### 8 · Gold model — only if something reports on it

If `ITEM_MASTER` is a dimension feeding a fact that already exists, this is a join, not a new model. If it opens a new subject area, write the Gold model and its tests — with L14's checklist in hand: state the grain in one sentence, constrain lookup joins, exclude synthetic rollup rows, uniqueness test on the key, reconciliation test on the totals.

**Do not invent a Gold model to prove the pipeline works.** The run records and row counts already prove that.

### 9 · Deploy through the gate

Three things must happen, in this order:

1. **Sync the specs to object storage.** Jobs read the YAML at run time — a spec that isn't synced does not exist.
2. **Sync the transformation project.**
3. **Seed the control plane** from config, hashing the *same spec bytes* that were just uploaded, so the platform can tell whether the deployed spec matches the repo. Run it `--dry-run` first.

The seed runs **after** both the artifact upload and the infrastructure apply, because it hashes uploaded specs and writes rows for resources that must already exist. Then it goes through L20's gate like any other change.

**Smoke-test in Dev and watch for four things:** the run rows go green stage by stage; the watermark advanced; the new value is *plausible*; the cycle reaches its terminal state. That sequence — not a passing unit test — is "done".

## Why

The engine, the barriers, the writers, the control plane, the orchestration and the Silver/Gold contracts are **untouched by all nine steps**. Only configuration moves. That is what makes eight sources tractable in twelve weeks: one source, one pull request.

**What you never touch:** the job code, the writers, the dispatcher, the barriers, the sweeper, the control-plane models, the state machines, the reporting views. If your change needs one of those, stop and ask whether you are solving the wrong problem. The one legitimate exception is step 3's engine branch — and that is four lines in a connector, not the engine.

> **What breaks if you don't:** every new table becomes its own project.

## On Apparel Group

Run the procedure once for RMS `ITEM_MASTER`, then fill this table in before you write any more specs. It is the planning artefact for the whole Data Foundation workstream:

| # | Source | Shape | Step 3 needed? | Watermark | PK |
|---|---|---|---|---|---|
| 1 | Oracle Retail RMS | JDBC | branch only | change stamp per table | from constraint catalog |
| 2 | Oracle SIM | JDBC | no — same branch | high-churn position stamp | from constraint catalog |
| 3 | Oracle XStore | JDBC | no — same branch | transaction timestamp | from constraint catalog |
| 4 | Epsilon | SaaS API | **yes** — paging + cursor | API cursor / token | vendor id, confirm |
| 5 | MoEngage | SaaS API | **yes** — paging + rate limits | API cursor / token | vendor id, confirm |
| 6 | Magento | DB or API | decide the protocol first | `updated_at` | entity id |
| 7 | Vemco Footfall | file / API | small connector | file date | store + interval |
| 8 | Irisys Footfall | file / API | small connector | file date | store + interval |

Three of the eight are one connector branch. Two need real connector work. Plan the two early — an API connector written under deadline is where paging bugs come from.

## Checklist

- [ ] Table classified: full / incremental / windowed
- [ ] PK read from the source's constraint catalog, not assumed
- [ ] Watermark column verified monotonic, indexed, non-null — or the table declared full-refresh
- [ ] Connector work confirmed necessary before any is written
- [ ] Download spec: curated projection, watermark column present in it, parallelism declared
- [ ] Bronze spec: `merge_key` = the verified PK, schema mirrors the download spec exactly
- [ ] Catalog row added, with the freshness SLA chosen now
- [ ] Staging view + `not_null` and `unique` on the natural key
- [ ] Gold model written only if something reports on it
- [ ] Specs synced, control plane seeded (dry-run first), change taken through the gate
- [ ] Dev smoke test: all stages green, watermark advanced and plausible, cycle terminal
- [ ] No file outside specs, config and models was modified

## You've got it when you can…

- List the nine steps in order, from memory, and say which two are conditional.
- Explain why adding Oracle Retail is a branch in one connector rather than a new pipeline.
- Explain `merge_key` to a room in one sentence, and name what must be verified before you choose it.
- Say why the download spec and the bronze spec both exist, and what goes wrong when their schemas drift.
- Point at every file that must change — and every file that must not.
- Explain why a spec that isn't synced does not exist as far as the platform is concerned.
- Say the sentence that closes this module: **do this once for RMS. Then it's a habit.**

---

**Do this once for RMS. Then it's a habit.**
