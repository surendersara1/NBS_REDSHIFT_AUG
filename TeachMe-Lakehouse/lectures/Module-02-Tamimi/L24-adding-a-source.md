# L24 · Add a Source Without Touching the Engine — the capstone bridge

**Slide:** [`_render/L24-adding-a-source.html`](_render/L24-adding-a-source.html)

## The point

Everything in Modules 1 and 2 was building to one claim, and this lesson cashes it:
**onboarding a new table is a configuration change, not an engineering project.** Seven
artifacts, in a fixed order, none of which is engine code. The dispatcher, the Step Functions,
the barriers, the writers, the control plane, the Silver and Gold contracts — untouched.

That claim is not marketing. `sources/__init__.py` says it in its own docstring: *"To add a new
source: implement the `SourceConnector` Protocol, decorate with `@register(...)`, add a row in
DDB `source_catalog`, and you're done. **NO engine changes.**"* This lesson walks the seven
steps once, concretely, against **Oracle Retail RMS `ITEM_MASTER`** — the first table your team
will onboard at Apparel Group.

Finish this lesson and you have the capstone spec: *one source, one PR.*

## The seven artifacts

| # | Artifact | Where it lives | When you skip it |
|---|---|---|---|
| 1 | **Connector class** | `src/glue/glue_engine/sources/<type>.py` + `@register("<type>")` | when the protocol is already satisfied — a Postgres or SQL Server source needs **nothing** |
| 2 | **`download` spec** (P1) | `src/glue/specs/download/<table>.yaml` | never — this is the pull |
| 3 | **`bronze` spec** (P2) | `src/glue/specs/bronze/<table>.yaml` | never — this is the load |
| 4 | **Catalog row** | `config/ingestion_tables.yaml` (+ a `connections.yaml` entry per source) | never — this is what the dispatcher scans |
| 5 | **dbt staging model + tests** | `src/dbt/models/staging/stg_<table>.sql` + `_staging.yml` | never — Silver must be typed and asserted |
| 6 | **Gold model** | `src/dbt/models/marts/gold/*.sql` | when nothing reports on it yet |
| 7 | **Deploy** | `bitbucket-pipelines.yml` → spec sync → `scripts/seed_control_plane.py` | never |

## Step 1 — the connector (only if the protocol isn't already satisfied)

The engine never imports a concrete connector. It calls `get_connector(source_type)` and gets
whatever `@register`'d itself at import time. The contract is five methods
([`sources/protocol.py`](../../../tamimi-lakehouse/src/glue/glue_engine/sources/protocol.py)):

| Method | Contract |
|---|---|
| `configure(source_row, spec)` | validate the spec, resolve creds from `secrets_arn`, pre-check the Glue Connection. Fail **fast and loudly** |
| `read_incremental(spark, watermark, run_id)` | return `(df, new_watermark)`. **Never persist the watermark yourself** — the engine writes it atomically with the run-success record |
| `read_full(spark, run_id)` | full snapshot |
| `read_range(spark, date_from, date_to, run_id)` | the backfill window. Does **not** advance the watermark |
| `emit_metrics()` | `rows_read`, `bytes_downloaded`, `retries`, `throttles`, `rows_with_errors` |

**For Oracle Retail, this is one branch, not one project.** `rds_jdbc.py` already does Glue JDBC
with `useConnectionProperties` + `sampleQuery` + `hashfield` parallel reads, watermark
validation and injection guards. Its own docstring names the gap:

> *Out of scope … Oracle / MySQL / MariaDB engines — code path is identical; add another branch
> on the engine literal when needed.*

So: add `"oracle"` to `_SUPPORTED_ENGINES` (today `{"postgresql", "sqlserver"}`), confirm Glue 5.0's
`connection_type` literal, and you have RMS, SIM and XStore. **Read `rds_jdbc.py` as the
non-SAP template — not `sap_hana.py`**, which carries MANDT, `ngdbc.jar` and `NVARCHAR
YYYYMMDD` dates that do not exist at Apparel Group.

> **Gotcha:** a genuinely *new* `source_type` string must also be added to the Literal in
> [`glue_engine/spec.py`](../../../tamimi-lakehouse/src/glue/glue_engine/spec.py) — today
> `Literal["sap_hana", "rds_jdbc", "excel_landing", "s3_landing"]`. Widening `rds_jdbc` with an
> engine branch avoids that; a sibling `oracle_jdbc` class does not. Choose deliberately.

## Step 2 — the `download` spec (P1: source → S3 raw)

Template: [`specs/download/sap_mara.yaml`](../../../tamimi-lakehouse/src/glue/specs/download/sap_mara.yaml).

```yaml
# src/glue/specs/download/rms_item_master.yaml
table: rms.item_master
source_type: rds_jdbc

source_config:
  cadence: daily
  jdbc_schema: RMS
  jdbc_table: ITEM_MASTER
  watermark_column: LAST_UPDATE_DATETIME   # monotonic, in the projection
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

Three things this file decides, and each has bitten someone:

- **`watermark_column` must appear in the projection.** `read_incremental` computes the new
  watermark via `F.max(<watermark_column>)`; if it's absent, Spark raises *after* you've paid
  for the whole JDBC pull. `configure()` now fails fast instead.
- **Parallelism has no default.** Exactly one of `jdbc_hash_field` / `jdbc_hash_expression`,
  never both. Without it, `sampleQuery` runs on one executor and OOMs on anything real.
- **Curate the projection.** MARA has 317 columns; the spec declares the 16 that are consumed.
  `SELECT *` is banned so a source-schema drift can't silently leak untyped columns into Bronze.

## Step 3 — the `bronze` spec (P2: raw → Iceberg)

Template: [`specs/bronze/sap_mara.yaml`](../../../tamimi-lakehouse/src/glue/specs/bronze/sap_mara.yaml).

```yaml
# src/glue/specs/bronze/rms_item_master.yaml
table: rms.item_master
source_type: s3_landing          # reads back what P1 landed — no source creds, no DB hit

merge_key: [ITEM]                # the VERIFIED natural PK

schema:                          # MUST mirror the download spec
  - { name: ITEM, type: string, pii_class: internal, description: "Item number (PK)" }
  # ... identical to download/rms_item_master.yaml

source_config:
  landing_prefix: "rms/rms.item_master"   # the same relative prefix P1 landed under
  format: parquet
```

**`merge_key` is the single highest-stakes line you will write.** It is the Bronze
zero-duplicates invariant: replays, overlapping windows and Glue auto-retries must land each
row exactly once. `spec.py` enforces that every member exists in the schema, that there are no
duplicates, and that no member is `pii_class: pii`. What it *cannot* enforce is that it is the
real primary key — **verify it against the source's constraint catalog**, the way the SAP specs
did (`SYS.CONSTRAINTS`, 2026-07-14). Get it wrong and you get `MERGE_CARDINALITY_VIOLATION` at
best, silent row loss at worst.

## Step 4 — the catalog row

One entry in [`config/ingestion_tables.yaml`](../../../tamimi-lakehouse/config/ingestion_tables.yaml)
— *"the ONE place the technical team edits to add / modify / remove a table"* — plus one
connection in `config/connections.yaml` per **source** (not per table).

```yaml
  - name: rms.item_master
    source: rms                    # -> connections.yaml entry (carries source_type + secrets_arn)
    source_object: ITEM_MASTER
    bronze_spec:   bronze/rms_item_master.yaml
    download_spec: download/rms_item_master.yaml
    driver_by_mode: { full: rds_jdbc, range: rds_jdbc, incremental: rds_jdbc }
    initial_load: once
    cadence_band: daily
    enabled: true
```

- **`driver_by_mode`** is the seam that lets one table use different connectors for different
  read modes (that's how SAP was designed to do JDBC-init → OData-CDC before OData was retired).
  For Oracle, all three modes are the same driver — but declaring it keeps the option open.
- **`initial_load: once`** engages the init-once guard: the table gets one bulk historical load,
  `init_state` becomes `initial_loaded`, and only then does Gate 0 allow daily deltas.
- **`enabled: false`** is how you pause a table without deleting it. Use it while you're
  iterating — the dispatcher only scans enabled rows.

## Step 5 — dbt staging + tests

```sql
-- src/dbt/models/staging/stg_rms_item_master.sql
{{ config(materialized='view') }}

SELECT
    item                  AS item_id,
    item_desc             AS item_name,
    dept, class, subclass,
    last_update_datetime  AS updated_at
FROM {{ source('silver', 'rms_item_master') }}
```

```yaml
# src/dbt/models/staging/_staging.yml
  - name: stg_rms_item_master
    description: "1:1 mirror of silver.rms.item_master with snake_case column names."
    columns:
      - name: item_id
        tests: [not_null, unique]
```

Staging is a **view**, and — because it reads an external schema — the whole staging layer is
declared `+bind: false` (late-binding) in `dbt_project.yml`. A plain Redshift view cannot
`SELECT` from an external schema. The `not_null` + `unique` pair on the natural key is the
cheapest correctness insurance in the codebase; add it before you add anything clever.

## Step 6 — the Gold model (only if something reports on it)

If RMS item master is a *dimension* feeding a fact that already exists, this step is a join, not
a new model. If it's the first table of a new subject area, you write the Gold model and its
tests — and Module 2's L14 correctness traps (grain discipline, fan-out joins, synthetic
"all" rows) are the checklist. **Do not invent a Gold model to prove the pipeline works.**
`runs` + row counts already prove that.

## Step 7 — deploy

CI does exactly three things that matter here, in this order:

1. `aws s3 sync src/glue/specs/ s3://$ART_BUCKET/specs/` — Glue jobs read the YAML **from S3 at
   runtime**, so a spec that isn't synced doesn't exist.
2. `aws s3 sync src/dbt/ s3://$ART_BUCKET/dbt/project/`
3. `python scripts/seed_control_plane.py --env <env> --specs-from s3 --from-config --prune --commit`
   — reconciles `connections.yaml` → `source_catalog` and `ingestion_tables.yaml` →
   `bronze_mapping`, hashing the *same spec bytes* the artifact step uploaded into `spec_hash`.

Run it `--dry-run` first. It runs **after** both the artifact upload and the Terraform apply,
because the seed hashes uploaded specs and writes rows for resources that must already exist.

Then smoke-test in Dev: invoke the dispatcher, watch `runs` go green at `source_download` →
`bronze_pull` → `bronze_to_silver`, confirm the watermark advanced, confirm the cycle reaches
`gold_built`. That sequence — not a passing unit test — is "done".

## What you never touch

`glue_engine/jobs/` · `writers/` · `dispatcher` · the four barriers · `cycle_sweeper` ·
`run_status` · the control-plane models · Step Functions · the Silver and Gold contracts ·
the reporting views · Power BI.

If your change requires editing any of those, stop and ask whether you're solving the wrong
problem. The one legitimate exception is Step 1's `_SUPPORTED_ENGINES` branch — and even that
is four lines in a connector, not the engine.

## Words you'll hear

| Word | What it means here |
|---|---|
| **Protocol** | the five-method Python `Protocol` every connector satisfies; the engine's only knowledge of a source |
| **`@register("type")`** | the class decorator that puts a connector in the registry at import time; duplicate registration raises |
| **P1 / P2** | P1 = `source_download` (source → S3 raw); P2 = `bronze_pull` (raw → Iceberg). Split so a re-pull and a re-load are separate failures |
| **download spec** | the P1 YAML — how to *pull*: schema, watermark column, hash field, landing prefix |
| **bronze spec** | the P2 YAML — how to *land*: `merge_key`, the mirrored schema, the same landing prefix |
| **`merge_key`** | the verified natural PK. Iceberg MERGE upserts on it; this is what makes replays idempotent |
| **`driver_by_mode`** | per-read-mode connector choice: `{full, range, incremental}` |
| **`landing_prefix`** | the RELATIVE raw path, qualified against the raw bucket at runtime |
| **`init_state`** | `pending` → `initial_loaded` → `cdc` (or `needs_reinit`). Gate 0 refuses deltas before the initial load |
| **`spec_hash`** | the seeder's fingerprint of the spec bytes in S3 — how the control plane knows the deployed spec matches the repo |
| **late-binding view** | `+bind: false` — required for any view over an external schema |
| **RMS / SIM / XStore** | Oracle Retail merchandising / store inventory / POS — three JDBC sources, one connector |

## In this repo

- [`src/glue/glue_engine/sources/__init__.py`](../../../tamimi-lakehouse/src/glue/glue_engine/sources/__init__.py) — the registry, `register`, `get_connector`, and the "NO engine changes" promise in the docstring
- [`src/glue/glue_engine/sources/protocol.py`](../../../tamimi-lakehouse/src/glue/glue_engine/sources/protocol.py) — the contract, read it before you write a line
- [`src/glue/glue_engine/sources/rds_jdbc.py`](../../../tamimi-lakehouse/src/glue/glue_engine/sources/rds_jdbc.py) — **your template.** `_SUPPORTED_ENGINES`, `_build_sample_query`, `_build_range_query`, the watermark guards
- [`src/glue/specs/download/sap_mara.yaml`](../../../tamimi-lakehouse/src/glue/specs/download/sap_mara.yaml) + [`src/glue/specs/bronze/sap_mara.yaml`](../../../tamimi-lakehouse/src/glue/specs/bronze/sap_mara.yaml) — the pair, read side by side
- [`src/glue/glue_engine/spec.py`](../../../tamimi-lakehouse/src/glue/glue_engine/spec.py) — `BronzeSpec`: the `source_type` Literal, the `merge_key` validators, the P1-vs-P2 field rules
- [`config/ingestion_tables.yaml`](../../../tamimi-lakehouse/config/ingestion_tables.yaml) + [`config/connections.yaml`](../../../tamimi-lakehouse/config/connections.yaml) — the catalog and the per-source connection
- [`scripts/seed_control_plane.py`](../../../tamimi-lakehouse/scripts/seed_control_plane.py) — `--from-config --specs-from s3 --prune`
- [`src/dbt/models/staging/`](../../../tamimi-lakehouse/src/dbt/models/staging/) — `stg_sap_zsdcc.sql` as the shape, `_staging.yml` as the test pattern
- [`bitbucket-pipelines.yml`](../../../tamimi-lakehouse/bitbucket-pipelines.yml) — the spec sync + seed steps, per environment
- [`docs/CONNECTOR-ACTIVATION-GUIDE.md`](../../../tamimi-lakehouse/docs/CONNECTOR-ACTIVATION-GUIDE.md) — the activation checklist (written pre-`sap_odata` retirement; the *shape* is right, the SAP OData sections are historical)

## Do this

1. **Write the two YAMLs for Oracle Retail `ITEM_MASTER` by hand**, using the MARA pair as the
   template. Then validate: `python -c "import yaml; from glue_engine.spec import BronzeSpec; BronzeSpec.model_validate(yaml.safe_load(open('specs/bronze/rms_item_master.yaml')))"`.
2. Open `rds_jdbc.py` and list every line that would change to support Oracle. It should be a
   short list. If yours is long, you're writing a new connector when you needed a branch.
3. For each of the eight Apparel Group sources, fill one row: **watermark column · natural key ·
   does step 1 apply?** Epsilon and MoEngage will not fit the JDBC shape — say so, and say what
   the connector would need instead (paging, tokens, rate limits, and raw-first landing because
   you often cannot re-request an old page).
4. Trace one spec change from `git commit` to a running Glue job. Name every hop: pipeline →
   S3 specs → seed → `bronze_mapping.spec_hash` → dispatcher → SFN → Glue → spec read from S3.
5. Deliberately break it: set `merge_key` to a non-unique column and predict the exact error
   before you run it.

## You've got it when you can…

- List the seven artifacts in order, from memory, and say which two are conditional.
- Say why adding Oracle Retail is a **branch in one connector**, not a new pipeline — and cite
  the docstring that says so.
- Explain `merge_key` to a room in one sentence, and name what you must verify before choosing it.
- Explain why the `download` spec and the `bronze` spec both exist, and what breaks if their
  schemas drift apart.
- Point at every file that must change, and every file that must **not**.
- Explain why a spec that isn't in S3 doesn't exist as far as the pipeline is concerned.
- Say the sentence that ends this module: **this is your capstone — one source, one PR.**
