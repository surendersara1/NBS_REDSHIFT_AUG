# L14 · dbt: SQL as Engineered Code

**Slide:** [`_render/L14-dbt.html`](_render/L14-dbt.html)

## The point

dbt is `make` for SQL. You write one `SELECT` per model and nothing else — no `CREATE TABLE`, no `DROP`, no swap, no grants, no build script. dbt reads the `ref()` calls in your SQL, derives the dependency graph, builds every model in topological order, and runs each model's tests immediately after it. The result is that analyst SQL becomes reviewable, testable, version-controlled software.

## Key ideas

- **A model is one file containing one `SELECT`.** The file name is the relation name. That's the whole contract.
- **`ref()` does two jobs at once**: it compiles to the real schema-qualified relation *and* it declares an edge in the DAG. You never maintain a build order by hand — you can't get it wrong, because there's nowhere to write it down.
- **`source()`** is the same idea for things dbt doesn't build — our Silver tables, declared in `models/sources.yml` against the `silver_external` schema.
- **Materialization is one line of config, not a rewrite.** The same `SELECT` can be a `view`, a `table`, `incremental`, or `ephemeral`. Changing it is a config edit; the SQL is untouched. Ours: staging = view (late-binding), intermediate = ephemeral (compiles to a CTE, creates no object), marts/gold = incremental with `merge`, marts/reporting = view.
- **`+on_schema_change: fail`** on Gold: we never silently absorb schema drift. A new or missing column stops the build instead of quietly changing a number in a report.
- **Tests are declared next to the model** (`not_null`, `unique`, `accepted_values`, plus singular SQL tests). `dbt build` interleaves run and test per node, so a failing test blocks its dependents rather than being discovered downstream. `+store_failures: true` keeps the offending rows so you can look at them.
- Everything is a text file in git: SQL, tests, materialization, docs. Reviewable in a pull request like any other code.

## Words you'll hear

| Word | What it means here |
|---|---|
| Model | One `.sql` file = one `SELECT` = one relation |
| `ref()` / `source()` | Dependency declaration; builds the DAG |
| DAG | The dependency graph dbt derives and builds in order |
| Materialization | How a model is persisted: view / table / incremental / ephemeral |
| Incremental | Build only new/changed rows, merged into the existing table |
| `dbt build` | deps + seed + run + test, in dependency order |
| Late-binding | `WITH NO SCHEMA BINDING` — required over external schemas (L13) |

## In this repo

- [`src/dbt/dbt_project.yml:57-98`](../../../tamimi-lakehouse/src/dbt/dbt_project.yml) — the per-layer materialization config: `staging` (view + `bind: false`), `intermediate` (ephemeral), `marts` (table), `marts.gold` (incremental / merge / `on_schema_change: fail`), `marts.reporting` (view). `:118-120` — test defaults.
- `src/dbt/models/` — 9 staging models, 4 dims, 5 Gold facts, 11 reporting views (10 views + 1 materialized view).
- [`models/staging/stg_sap_zsdcc.sql:17-32`](../../../tamimi-lakehouse/src/dbt/models/staging/stg_sap_zsdcc.sql) — a model in its entirety: one config line, one `SELECT`, one `source()`.
- [`models/marts/gold/unified_sales.sql:76-83`](../../../tamimi-lakehouse/src/dbt/models/marts/gold/unified_sales.sql) — the incremental config with `unique_key`, `dist` and `sort`.
- [`src/glue/glue_engine/jobs/_scripts/run_dbt.py`](../../../tamimi-lakehouse/src/glue/glue_engine/jobs/_scripts/run_dbt.py) — how `dbt build` is actually invoked in production (Glue Python-shell, IAM-token auth, per-model run rows written to DynamoDB).

## Do this

1. Open `stg_sap_zsdcc.sql`. Count the lines that are *not* the `SELECT`. There is one.
2. Follow one `ref()` chain by hand: `stg_sap_zsdcc` → `unified_sales` → `vw_sales_actuals_pyc`. Now change the order in your head and convince yourself dbt would refuse.
3. Change a staging model's materialization from `view` to `table` in `dbt_project.yml` (locally). Note that no SQL changed.
4. Read `_gold.yml` and find a test whose failure would have caught a real reporting bug.

## You've got it when you can…

…take a 40-line analyst query, split it into two dbt models joined by `ref()`, pick the right materialization for each, add the one test that protects the grain, and explain why that is better than a stored procedure.
