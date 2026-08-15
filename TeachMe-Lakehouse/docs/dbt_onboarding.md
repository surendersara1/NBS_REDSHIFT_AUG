# dbt Onboarding Curriculum — NBS Tamimi Lakehouse
### Taught by "Professor dbt" · grounded strictly in this repository

Welcome aboard. You already know how to write software — so I'm not going to waste your time on generic "what is a data warehouse" fluff. Instead, I'll teach you dbt **through the exact code in this repo**, so that by Lesson 10 you can open any `.sql` file under `src/dbt/` and know precisely what it does, why it's shaped that way, and how to run it safely.

Every claim below points at a real file. If you want to verify me, open the path — that's the whole point.

> **Read-me-first companion docs:** [CLAUDE.md](CLAUDE.md) (architecture + ADR index), [docs/DATA-FLOW-AND-OBJECT-CATALOG.md](docs/DATA-FLOW-AND-OBJECT-CATALOG.md) (object lineage), [docs/design-reference/_understanding/](docs/design-reference/_understanding/) (deep design), [docs/design-reference/architecture-diagrams/](docs/design-reference/architecture-diagrams/) (the `.puml` flow diagrams).

---

## Lesson 1 — The Big Picture: where Glue ends and dbt begins

**The one sentence to memorize:** *In this project, AWS Glue builds Bronze **and** Silver as Apache Iceberg tables; dbt takes over at Silver and builds Gold + Reporting inside Amazon Redshift Serverless.*

A lot of "medallion" tutorials imply dbt does everything from raw ingestion onward. **Not here.** Let's be precise about the seam, because misunderstanding it is the #1 way new engineers get lost in this codebase.

**The flow, stage by stage:**
1. **Ingestion → Bronze → Silver (AWS Glue / PySpark).** The spec-driven Glue engine ([src/glue/glue_engine/](src/glue/glue_engine/)) pulls from SAP/HANA, RDS, OData, and Excel, and writes **Apache Iceberg v2 tables on Amazon S3 Tables**. dbt never touches this. If you're debugging why a Silver table is empty, that's a Glue problem, not a dbt problem.
2. **The handoff (Silver).** dbt reads Silver through a **Redshift Spectrum external schema** called `silver_external`. That schema is created at run time by [run_dbt.py:156-161](src/glue/glue_engine/jobs/_scripts/run_dbt.py#L156-L161):
   ```sql
   CREATE EXTERNAL SCHEMA IF NOT EXISTS silver_external
   FROM DATA CATALOG
     DATABASE '<silver_glue_db>'
     IAM_ROLE '<redshift_role_arn>'
   ```
   That single statement is the bridge: it mounts the Glue federated catalog (`s3tablescatalog` → the Silver S3 Tables bucket) into Redshift so dbt can `SELECT` from Iceberg as if it were a normal schema.
3. **Silver → Gold → Reporting (dbt on Redshift).** dbt's `source()`s point at those Silver tables ([models/sources.yml](src/dbt/models/sources.yml)), `stg_*` staging models clean them, `unified_*` Gold facts model the business, and `vw_*` reporting views serve Power BI over DirectQuery.

**Why this architecture?** Redshift Serverless won the ADR-0024/0025 benchmark (7/7 by 10–28×) for Gold query serving, and dbt was chosen (ADR-0027) as the Silver→Gold transformation tool. See [CLAUDE.md](CLAUDE.md) §Architecture and [docs/design-reference/_understanding/04-adr0025-benchmark-and-infra-learnings.md](docs/design-reference/_understanding/04-adr0025-benchmark-and-infra-learnings.md).

**📎 Read:** [CLAUDE.md](CLAUDE.md) · [docs/design-reference/architecture-diagrams/03-medallion-flow.puml](docs/design-reference/architecture-diagrams/03-medallion-flow.puml) · [docs/design-reference/architecture-diagrams/06-d13-gold-flow.puml](docs/design-reference/architecture-diagrams/06-d13-gold-flow.puml)

**🧪 Try it:** Open [models/sources.yml](src/dbt/models/sources.yml) and note `schema: silver_external`. Then open [run_dbt.py](src/glue/glue_engine/jobs/_scripts/run_dbt.py) and find where that schema name is created. You've just traced the entire Glue→dbt seam.

---

## Lesson 2 — dbt project structure & fundamentals

A dbt project is "just" a folder of SQL + YAML that dbt compiles and runs in dependency order. Ours lives entirely under [src/dbt/](src/dbt/).

**The control file — [dbt_project.yml](src/dbt/dbt_project.yml):**
- `name: tamimi_dlh`, `profile: tamimi_dlh` ([dbt_project.yml:17-21](src/dbt/dbt_project.yml#L17-L21)) — the project name and which connection profile to use (Lesson 10).
- `model-paths: ["models"]`, `macro-paths: ["macros"]`, `test-paths: ["tests"]` ([:23-28](src/dbt/dbt_project.yml#L23-L28)) — where dbt looks for each artifact type.
- **The `vars:` block** ([:37-47](src/dbt/dbt_project.yml#L37-L47)) — project-wide constants: `scenario_cy: "2026 A"`, `scenario_py: "2025 A"`, `scenario_budget: "Budget"`, `current_calendar_year: 2026`. Hardcoded on purpose so changing them requires a PR (auditability).
- **The `models:` block** ([:50-91](src/dbt/dbt_project.yml#L50-L91)) — layer-by-layer defaults (materializations, schemas, tags). We'll dissect this in Lesson 6.

**What is a "model"?** A model is **one `.sql` file that contains exactly one `SELECT`**. dbt wraps that `SELECT` in the right DDL (`CREATE TABLE AS`, `CREATE VIEW AS`, a `MERGE`, …) based on its materialization, and executes it in Redshift. You never write `CREATE TABLE` yourself — you write the `SELECT`, dbt writes the DDL.

**The folder layout (mirrors the medallion layers):**
```
src/dbt/
├── dbt_project.yml            # project config
├── profiles.yml.template      # connection template (real file is gitignored)
├── packages.yml               # dbt_utils + dbt_expectations
├── models/
│   ├── sources.yml            # the Silver source declarations
│   ├── staging/               # stg_*  (1:1 with sources; light clean)
│   └── marts/
│       ├── dims/              # dim_*  (conformed dimensions)
│       ├── gold/              # unified_*  (the 5 Gold facts)
│       └── reporting/         # vw_* / mv_*  (BI-facing views)
├── macros/                    # scenario_helpers.sql, generate_schema_name.sql
└── tests/                     # singular (custom SQL) tests
```

**How compilation works:** `dbt compile` reads each model, resolves the Jinja (`{{ ref(...) }}`, `{{ var(...) }}`, macros) into plain Redshift SQL, and writes the result to `target/`. Nothing runs against the database on `compile` — it's the "type-check" step. `dbt run` then executes the compiled SQL.

**📎 Read:** [dbt_project.yml](src/dbt/dbt_project.yml) (top to bottom — it's well-commented) · [BUILD-PLAN.md](BUILD-PLAN.md)

**🧪 Try it:** Run `dbt parse` from `src/dbt/` — it validates the whole project graph without touching Redshift. If it's green, your YAML and `ref()`s are structurally sound.

---

## Lesson 3 — The Glue→dbt handoff: Sources & the Silver layer

**How does dbt know about the data Glue just landed?** Through **sources** — declarations, not queries. Open [models/sources.yml](src/dbt/models/sources.yml):

```yaml
sources:
  - name: silver
    database: "{{ env_var('REDSHIFT_DBNAME', 'lakehouse') }}"
    schema: silver_external          # the Spectrum external schema from Lesson 1
    loaded_at_field: _ingested_at
    tables:
      - name: sap_zsdcc              # per-dept sales/CC
      - name: sap_zscc              # store-level customer count
      - name: sap_scan_611          # POS scan (sale, cogs)
      - name: sap_distress_603      # distress / goods-issue
      - name: dim_site / dim_dept / dim_date / dim_area_mgr
      - name: budget_upload
```
([sources.yml:11-131](src/dbt/models/sources.yml#L11-L131))

Those 8 tables are the **Silver Iceberg tables** — exactly what Glue wrote. Declaring them here lets dbt (a) reference them with `source('silver', 'sap_zsdcc')`, (b) draw them on the lineage graph, and (c) test them.

> ⚠️ **Correction to a common misconception:** there is **no dbt "Bronze layer."** Bronze and Silver are Glue's output. dbt's lowest layer is `source()` (Silver) → `stg_*`. If someone tells you to "look at the dbt Bronze models," they're wrong — they don't exist.

**The staging layer** (`stg_*`) is the first thing dbt *builds*. Its job: 1:1 with a source, light renames, casts, and cleanup — nothing clever. Example — [stg_sap_zsdcc.sql](src/dbt/models/staging/stg_sap_zsdcc.sql):
```sql
FROM {{ source('silver', 'sap_zsdcc') }}   -- reads the Silver Iceberg table
GROUP BY site, date, dept
```
([stg_sap_zsdcc.sql:28-29](src/dbt/models/staging/stg_sap_zsdcc.sql#L28-L29)). Note the real-world defensive detail at [:22](src/dbt/models/staging/stg_sap_zsdcc.sql#L22): it guards `SUM(sale)` against non-finite `NaN`/`Infinity` values that would otherwise poison the aggregate — the kind of thing you only learn from production data.

**📎 Read:** [models/sources.yml](src/dbt/models/sources.yml) · [docs/DATA-FLOW-AND-OBJECT-CATALOG.md](docs/DATA-FLOW-AND-OBJECT-CATALOG.md)

**🧪 Try it:** `dbt source freshness` (once connected) checks the `_ingested_at` field to see how stale Silver is.

---

## Lesson 4 — Building the DAG: `ref()`, the most important function in dbt

`ref()` is the concept that makes dbt *dbt*. When one model needs another, you never hardcode a table name — you write `{{ ref('other_model') }}`. dbt does two things with that:
1. **Resolves it** to the correct physical `schema.table` for your target (dev/qa/prod).
2. **Records a dependency edge**, so it knows `stg_sap_zsdcc` must be built *before* `unified_sales`. The full set of edges is your **DAG** (Directed Acyclic Graph) — dbt runs models in topological order and can parallelize independent branches.

`source()` is the sibling function for the *entry* nodes (Silver tables); `ref()` is for everything dbt itself builds.

**See the DAG being built** in [unified_sales.sql](src/dbt/models/marts/gold/unified_sales.sql):
```sql
FROM {{ ref('stg_sap_zsdcc') }} s
LEFT JOIN {{ ref('stg_dim_dept') }} d ON s.aagm = d.aagm     -- :71-72
...
JOIN {{ ref('stg_sap_zscc') }} c ON z.site = c.site ...      -- :156-157
...
FROM {{ ref('stg_budget_upload') }} b                        -- :206
```
From these `ref()`s dbt infers: `stg_sap_zsdcc`, `stg_dim_dept`, `stg_sap_zscc`, `stg_budget_upload` → **all build before** `unified_sales`. And since `stg_sap_zsdcc` itself `ref()`s `stg_dim_dept` ([stg_sap_zsdcc.sql:34](src/dbt/models/staging/stg_sap_zsdcc.sql#L34)), the chain is: `source(silver.*)` → `stg_*` → `unified_sales` → (Lesson 5) `vw_*`.

**Why this matters to you as a coder:** you get correct build ordering *for free*, and refactoring is safe — rename a model and every `ref()` follows, because they resolve by model name, not by hardcoded schema.

**📎 Read:** [docs/design-reference/_understanding/05-lineage-walkthrough-tdd-ncr.md](docs/design-reference/_understanding/05-lineage-walkthrough-tdd-ncr.md)

**🧪 Try it:** `dbt run --select +unified_sales` — the `+` prefix means "build `unified_sales` **and everything it depends on**." dbt walks the DAG upstream for you.

---

## Lesson 5 — The Gold layer: aggregation & Redshift delivery

Gold is where business meaning lives. Our five Gold facts are `unified_sales`, `unified_customer_count`, `unified_gross_profit`, `unified_distress`, and `unified_sales_by_am`. Let's walk the flagship, [unified_sales.sql](src/dbt/models/marts/gold/unified_sales.sql).

**Its shape: six `UNION ALL` legs** ([unified_sales.sql:230-240](src/dbt/models/marts/gold/unified_sales.sql#L230-L240)):
| Leg | What | scenario |
|---|---|---|
| `actuals_cy` | per-dept sales, current year | `'2026 A'` |
| `actuals_py` | per-dept sales, prior year | `'2025 A'` |
| `all_dept_cy` | **synthetic** All-Dept rollup, CY | `'2026 A'` |
| `all_dept_py` | synthetic All-Dept rollup, PY | `'2025 A'` |
| `budget` | annual budget per-dept | `'Budget'` |
| `all_dept_budget` | Excel All-Dept budget rows | `'Budget'` |

**The single most important thing in this whole codebase — the synthetic `'All Dept'` row.** The model deliberately emits, for each (site, date), an extra row where `dept = 'All Dept'` whose `sale` is `SUM` of that day's per-department sales ([:109-158](src/dbt/models/marts/gold/unified_sales.sql#L109-L158)). This is "Option A" — it lets the Power BI `.bim` measures that filter `[Dept] = "All Dept"` resolve with **zero DAX rewrites** (decision-log 2026-05-22).

> 🚨 **The trap you must never fall into:** because `unified_sales` contains **both** the per-dept legs **and** the All-Dept rollup (which is their sum), *any query that `SUM`s across the dept axis without excluding `'All Dept'` will double-count by ≈2×.* This is a live bug in [unified_sales_by_am.sql:52-63](src/dbt/models/marts/gold/unified_sales_by_am.sql#L52-L63) — `am_rollup` does `SUM(sale)` over `unified_sales` with **no `dept != 'All Dept'` filter** — so every Area-Manager total is currently inflated. When you write a new Gold/reporting model, **always ask: am I summing over a table that contains All-Dept rollups?**

**The materialization + Redshift tuning** ([:52-59](src/dbt/models/marts/gold/unified_sales.sql#L52-L59)):
```sql
{{ config(
    materialized='incremental',
    incremental_strategy='merge',
    unique_key=['site', 'date', 'aagm', 'scenario'],
    on_schema_change='fail',
    dist='date',
    sort=['date', 'site']
) }}
```
`dist`/`sort` are Redshift distribution/sort keys (physical layout for query speed). `unique_key` is the MERGE key. Note the clever detail at [:139-145](src/dbt/models/marts/gold/unified_sales.sql#L139-L145): All-Dept rows use the sentinel `aagm = '__ALL__'` instead of `NULL`, because `NULL = NULL` is false in a SQL MERGE predicate — a `NULL` key would re-insert the row on every run and silently inflate the table.

**📎 Read:** [docs/design-reference/_understanding/02-bi-semantics-spec-bim-excel.md](docs/design-reference/_understanding/02-bi-semantics-spec-bim-excel.md) (the `.bim` semantics this Gold layer serves).

**🧪 Try it:** `dbt run --select unified_sales` then query `SELECT dept, COUNT(*) FROM gold.unified_sales GROUP BY dept` — you'll see the `'All Dept'` rows sitting alongside the real depts.

---

## Lesson 6 — Materializations in our lakehouse

A **materialization** is *how* dbt persists a model's `SELECT`. dbt ships four: `ephemeral` (inlined CTE, no object), `view`, `table`, and `incremental`. We set defaults **per layer** in [dbt_project.yml:50-91](src/dbt/dbt_project.yml#L50-L91):

| Layer | Materialization | Config location | Why |
|---|---|---|---|
| project default | `view` | [:52](src/dbt/dbt_project.yml#L52) | cheap default |
| `staging` | `view` + `bind: false` | [:56-65](src/dbt/dbt_project.yml#L56-L65) | **late-binding** views — required because they read from the external `silver_external` schema; a normal view errors with "External tables are not supported in views" |
| `intermediate` | `ephemeral` | [:67-70](src/dbt/dbt_project.yml#L67-L70) | in-memory CTEs, no physical artifact |
| `marts/dims` | `table` | [:76-79](src/dbt/dbt_project.yml#L76-L79) | small, rebuilt fully |
| `marts/gold` | `incremental` + `merge` | [:81-86](src/dbt/dbt_project.yml#L81-L86) | big facts — only merge changed rows |
| `marts/reporting` | `view` | [:88-91](src/dbt/dbt_project.yml#L88-L91) | thin DirectQuery layer for Power BI |

**The `+bind: false` detail is a genuine Redshift-on-Iceberg gotcha** — memorize it. Staging views read Spectrum external tables, so they *must* be late-binding ([:58-63](src/dbt/dbt_project.yml#L58-L63)).

**Incremental = the important one.** For Gold facts, a full rebuild of hundreds of millions of rows every run is wasteful. Incremental means: on the first run, build the whole table; on later runs, only process new/changed rows and `MERGE` them in on the `unique_key`. The "which rows are new" logic is the incremental predicate — see Lesson 8. A model can be individually overridden too: [stg_sap_zsdcc.sql:11](src/dbt/models/staging/stg_sap_zsdcc.sql#L11) sets `{{ config(materialized='view') }}` inline.

**📎 Read:** [dbt_project.yml:49-91](src/dbt/dbt_project.yml#L49-L91) (the model-defaults block, heavily commented).

**🧪 Try it:** `dbt run --select unified_sales` twice. The first run does a full build; the second does a MERGE of only the last 14 days (Lesson 8). Watch the row counts in the logs.

---

## Lesson 7 — Testing & data-quality assurance

dbt turns "did the data survive the transformation?" into version-controlled code. Two kinds:

**1. Generic tests** — declared in YAML next to the model, reusable. In [sources.yml](src/dbt/models/sources.yml) and [_gold.yml](src/dbt/models/marts/gold/_gold.yml):
```yaml
- name: scenario
  tests:
    - not_null
    - accepted_values:
        values: ["2026 A", "2025 A", "Budget"]     # _gold.yml:30-35
```
Note the **conditional** test at [_gold.yml:24-26](src/dbt/models/marts/gold/_gold.yml#L24-L26): `not_null` on `aagm` `where: "dept != 'All Dept'"` — because the synthetic All-Dept rows legitimately use the `'__ALL__'` sentinel. That's how you test a column that's "not null except for a known, intended case." Beyond the built-ins, we pull `unique`, `not_null`, `accepted_values`, `relationships` from dbt-core, plus `dbt_utils` + `dbt_expectations` ([packages.yml](src/dbt/packages.yml)).

**2. Singular tests** — a `.sql` file in [tests/](src/dbt/tests/) that **passes when it returns zero rows**. Example — [recon_unified_sales_has_synthetic_all_dept.sql](src/dbt/tests/recon_unified_sales_has_synthetic_all_dept.sql):
```sql
WITH all_dept_count AS (
    SELECT COUNT(*) AS n FROM {{ ref('unified_sales') }} WHERE dept = 'All Dept'
)
SELECT * FROM all_dept_count WHERE n = 0     -- returns a row (=fails) if Option A regressed
```
This fails loudly if the All-Dept rows ever disappear — protecting the Power BI measures downstream. Other singular tests: [assert_clubbing_dept_single_attributes.sql](src/dbt/tests/assert_clubbing_dept_single_attributes.sql), [recon_unified_sales_scenario_coverage.sql](src/dbt/tests/recon_unified_sales_scenario_coverage.sql), [recon_distress_no_filters_applied.sql](src/dbt/tests/recon_distress_no_filters_applied.sql).

**Config that matters:** [dbt_project.yml:99-101](src/dbt/dbt_project.yml#L99-L101) sets `+store_failures: true` (failed rows are written to a `dbt_test__audit` schema so you can inspect *which* rows broke) and `+severity: error` (a failing test fails the build).

> 🔎 **Honest gap to know about:** there is currently **no composite-key uniqueness test** on the Gold facts' `unique_key`s. That's the one test that would catch upstream row fan-out *before* the incremental MERGE errors at run time. If you're extending the tests, `dbt_utils.unique_combination_of_columns` on each fact's `unique_key` is the highest-value add.

**📎 Read:** [_gold.yml](src/dbt/models/marts/gold/_gold.yml) · [docs/design-reference/SDD_Best_Practice_Checklist.md](docs/design-reference/SDD_Best_Practice_Checklist.md)

**🧪 Try it:** `dbt test --select unified_sales` runs every generic + singular test attached to that model.

---

## Lesson 8 — Macros, Jinja & DRY code

dbt models are **Jinja templates that render to SQL**. Anything in `{{ ... }}` or `{% ... %}` is Jinja, evaluated at compile time. A **macro** is a reusable Jinja function — our way of not copy-pasting the same SQL six times.

**Our workhorse — [macros/scenario_helpers.sql](src/dbt/macros/scenario_helpers.sql).** The whole Gold design turns on a `scenario` column (`'2026 A'` / `'2025 A'` / `'Budget'`). Rather than hardcode those strings in every model, we centralize them:
```sql
{% macro scenario_cy() %}
    CAST('{{ var("scenario_cy") }}' AS VARCHAR(10))
{% endmacro %}
```
([scenario_helpers.sql:14-16](src/dbt/macros/scenario_helpers.sql#L14-L16)). Called in [unified_sales.sql:70](src/dbt/models/marts/gold/unified_sales.sql#L70) as `{{ scenario_cy() }} AS scenario`. Change the label once (via the `var`), and all five Gold models follow — that's DRY.

**The cleverest macro — `gold_incremental_predicate`** ([scenario_helpers.sql:48-55](src/dbt/macros/scenario_helpers.sql#L48-L55)):
```sql
{% macro gold_incremental_predicate(date_column='date') %}
    {% if is_incremental() %}
        WHERE {{ date_column }} >= COALESCE(
            (SELECT MAX({{ date_column }}) - INTERVAL '14 days' FROM {{ this }}), DATE '1900-01-01')
    {% endif %}
{% endmacro %}
```
`is_incremental()` is true only on a non-first run of an incremental model; `{{ this }}` is the model's own table. So on re-runs it appends "only reprocess the last 14 days." One macro, appended to all five Gold facts (e.g. [unified_sales.sql:242](src/dbt/models/marts/gold/unified_sales.sql#L242)) — DRY across the whole layer. *(Trade-off to know: restatements older than 14 days won't be re-merged — a deliberate cost/coverage choice.)*

**A structural macro — [generate_schema_name.sql](src/dbt/macros/generate_schema_name.sql).** This overrides a dbt built-in so our physical schemas are named `gold`/`staging`/`reporting` (what the design and Power BI ODBC strings expect) instead of dbt's default `<target>_<schema>` concatenation. Read the header comment — it explains exactly why ([generate_schema_name.sql:1-33](src/dbt/macros/generate_schema_name.sql#L1-L33)).

**📎 Read:** [macros/scenario_helpers.sql](src/dbt/macros/scenario_helpers.sql) (short, and the comments are the lesson).

**🧪 Try it:** `dbt compile --select unified_sales`, then open `target/compiled/tamimi_dlh/models/marts/gold/unified_sales.sql` — you'll see the macros rendered into literal SQL. That's the single best way to understand any macro: read its compiled output.

---

## Lesson 9 — Documentation & lineage

dbt generates a browsable docs site + an interactive lineage graph **from the code itself** — no separate wiki to rot.

**Where the descriptions come from:** the `description:` fields in the schema YAMLs. Look at [sources.yml:33-35](src/dbt/models/sources.yml#L33-L35) (a source-table description) and [_gold.yml:4-13](src/dbt/models/marts/gold/_gold.yml#L4-L13) (the `unified_sales` model + column descriptions). Every `description` becomes a searchable doc entry. Our YAMLs are unusually rich — they cite decision-log entries and the reason for each design choice, so they double as onboarding notes.

**Where lineage comes from:** the `ref()` and `source()` calls you learned in Lessons 3–4. dbt reads them and draws the graph — `silver.sap_zsdcc` → `stg_sap_zsdcc` → `unified_sales` → `vw_sales_actuals_pyc`. Nothing to maintain by hand.

**How to generate it:**
```bash
dbt docs generate      # builds the catalog + manifest into target/
dbt docs serve         # opens the docs site with the clickable DAG
```

**Companion human docs (read these for column-level business context):**
- [docs/DATA-FLOW-AND-OBJECT-CATALOG.md](docs/DATA-FLOW-AND-OBJECT-CATALOG.md) — the object catalog, source→gold mapping.
- [docs/design-reference/_understanding/02-bi-semantics-spec-bim-excel.md](docs/design-reference/_understanding/02-bi-semantics-spec-bim-excel.md) — how each Gold column maps to a Power BI `.bim` measure.
- [docs/design-reference/data-contracts/](docs/design-reference/data-contracts/) — the schema contracts.

**How to *read* a schema YAML:** top-level `models:` → each `- name:` is a model → its `description:` explains intent → its `columns:` list gives per-column meaning and `tests:`. When a column has a `where:` on a test (like `aagm`), the YAML is telling you about a real edge case in the data — pay attention to those.

**🧪 Try it:** `dbt docs generate && dbt docs serve`, click `unified_sales`, and follow its lineage both upstream (to the Silver sources) and downstream (to the reporting views).

---

## Lesson 10 — Operational flow: running the pipeline

Now the muscle memory. First, **how dbt authenticates here** — [profiles.yml.template](src/dbt/profiles.yml.template):
```yaml
type: redshift
method: iam_role          # no password in the file — assumes an IAM role
cluster_id: tamimi-dlh-dev
schema: gold
sslmode: require
```
([profiles.yml.template:17-30](src/dbt/profiles.yml.template#L17-L30)). Locally it uses the `tamimi-dev` AWS profile; in CI it uses the BitBucket OIDC role. You copy this template to `~/.dbt/profiles.yml` and fill the env vars; the real file is gitignored.

**The core commands, and what they actually do here:**
| Command | What it does |
|---|---|
| `dbt parse` | Validates the project graph/YAML. No DB connection. Your fastest sanity check. |
| `dbt compile` | Renders Jinja → SQL into `target/`. No DB writes. Use it to *see* generated SQL. |
| `dbt run` | Executes models in DAG order: `CREATE VIEW` for staging/reporting, `CREATE TABLE` for dims, `MERGE` for Gold incrementals. |
| `dbt test` | Runs generic + singular tests; failures stored to `dbt_test__audit` (Lesson 7). |
| `dbt build` | The one you'll use most: runs **and** tests **and** snapshots/seeds, node by node in DAG order — so a model's tests run right after it builds, and a failure stops its downstream children. |

**The real execution sequence in our environment** (end to end):
1. **Glue** builds Bronze → Silver (Iceberg on S3 Tables). *(Not dbt.)*
2. **[run_dbt.py](src/glue/glue_engine/jobs/_scripts/run_dbt.py)** (a Glue Python-shell runner, orchestrated by Step Functions / the Gold barrier) first runs `CREATE EXTERNAL SCHEMA silver_external …` via the Redshift Data API ([run_dbt.py:156-189](src/glue/glue_engine/jobs/_scripts/run_dbt.py#L156-L189)) — mounting Silver into Redshift.
3. It then invokes **dbt** against Redshift Serverless, which builds, in DAG order: `stg_*` (late-binding views) → `dim_*` (tables) → `unified_*` (incremental MERGE) → `vw_*`/`mv_*` (reporting views).
4. **Power BI** reads `reporting.vw_*` over DirectQuery.

**Useful selectors** (you'll live in these):
- `dbt build --select staging` — just the staging layer.
- `dbt build --select +unified_sales` — `unified_sales` and everything upstream of it.
- `dbt build --select unified_sales+` — `unified_sales` and everything downstream (the reporting views).
- `dbt run --select unified_sales_by_am --full-refresh` — force a full rebuild (needed after certain schema changes; see the header note in [unified_sales_by_am.sql:18-22](src/dbt/models/marts/gold/unified_sales_by_am.sql#L18-L22)).

**📎 Read:** [run_dbt.py](src/glue/glue_engine/jobs/_scripts/run_dbt.py) (the handoff + invocation) · [CLAUDE.md](CLAUDE.md) §"Tool tiers" (which dbt commands are safe to run autonomously).

**🧪 Try it (safe, in order):** `dbt parse` → `dbt compile` → `dbt build --select stg_sap_zsdcc` → `dbt build --select +unified_sales`. By the end you've driven Silver→Gold yourself.

---

## Where to go next
- Re-read [unified_sales.sql](src/dbt/models/marts/gold/unified_sales.sql) end-to-end — if all six UNION-ALL legs and the `'__ALL__'` sentinel now make sense, you've internalized this project's dbt.
- Skim the other four Gold facts to see the same pattern repeated: [unified_gross_profit.sql](src/dbt/models/marts/gold/unified_gross_profit.sql), [unified_distress.sql](src/dbt/models/marts/gold/unified_distress.sql), [unified_customer_count.sql](src/dbt/models/marts/gold/unified_customer_count.sql), [unified_sales_by_am.sql](src/dbt/models/marts/gold/unified_sales_by_am.sql).
- Keep [docs/DATA-FLOW-AND-OBJECT-CATALOG.md](docs/DATA-FLOW-AND-OBJECT-CATALOG.md) open as your map.

**The two rules to carry with you:** (1) *dbt starts at Silver — Bronze/Silver are Glue's job.* (2) *`unified_sales` contains synthetic `'All Dept'` rows — never `SUM` across depts without excluding them, or you'll double-count.* Master those two and you'll avoid the mistakes that trip up everyone new to this repo.

*Class dismissed. Welcome to the team.* — Professor dbt
