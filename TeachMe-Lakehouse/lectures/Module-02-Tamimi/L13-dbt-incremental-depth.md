# L13 · Incremental on Redshift, Properly

**Slide:** [`_render/L13-dbt-incremental-depth.html`](_render/L13-dbt-incremental-depth.html)

## The point

Every Gold fact in this project is `materialized='incremental'`, `incremental_strategy='merge'`. That is four separate promises, and each one has a failure mode.

- **`unique_key` is the grain.** dbt turns it into the MERGE's `ON` predicate. Too wide → the match never fires and rows re-insert; too narrow → several source rows match one target row and Redshift raises a cardinality error.
- **The incremental predicate is a *time window*, and it drops what falls outside.** `gold_incremental_predicate` re-processes the trailing `gold_reprocess_days` (45) only. A SAP posting restated 60 days back is never re-read, so Gold keeps the stale value — **no error, no log line**.
- **`on_schema_change='fail'`** means Gold never silently absorbs a Silver schema change. Good — provided the model's own column *types* are pinned, or the build fails on its own union.
- **Staging must be late-binding** because it reads an external schema, and **`dist`/`sort`** are right for the query you designed for and wrong for the next one.

## Key ideas

- **Write the grain in the header, then make `unique_key` equal it.** `unified_sales` is Site × Date × Dept × Scenario → `unique_key=['site','date','aagm','scenario']`. `unified_distress` carries a seven-column key for exactly this reason, and its header says so: *"The `unique_key` MUST equal this grain or the incremental MERGE hits Redshift's…"* cardinality rule.
- **NULL is not a key.** `NULL = NULL` is false in a MERGE predicate, so the synthetic All-Dept rows use the sentinel `aagm = '__ALL__'`. With a NULL they matched nothing and re-inserted on **every** incremental run, inflating the table forever (W4.c).
- **The window is a backstop, not a substitute for a rebuild.** M-26 widened it from a hardcoded 14 days to a configurable 45 (`var('gold_reprocess_days')`) because SAP corrections routinely land past 14 days. Anything older is only recovered by `dbt run --select <model> --full-refresh`, on the documented monthly cadence and always after a SAP month-end re-open. Ops can widen it per run with `--vars`; they cannot widen it retroactively.
- **The predicate constrains the *shape* of your final SELECT.** The macro appends `WHERE date >= …` to the end of the model, and `GROUP BY` immediately followed by `WHERE` is a syntax error. So aggregation lives in a CTE and the model ends with a bare `SELECT * FROM …` — see the comment in `unified_sales_by_am`.
- **`on_schema_change='fail'` + UNION ALL = pin your types.** M-28: `cc` was BIGINT on the actuals legs and NUMERIC on the budget leg. A first build with only actuals materialised BIGINT, and the next run failed the moment the budget leg widened it. Fix: pre-cast **every** leg to `NUMERIC(38,4)` so the resolved type cannot drift between runs.
- **Late-binding views are not a style choice.** A plain Redshift view cannot select from an external schema — *"External tables are not supported in views"*, observed 2026-06-05. The whole staging layer is therefore `+materialized: view` + `+bind: false` (`WITH NO SCHEMA BINDING`). The trade-off: nothing validates the source exists until query time.
- **`dist`/`sort` encode an assumption about the query.** `dist='date'` + `sort=['date','site']` is right for BI filtered by date. It is wrong the moment you join on something else: `unified_sales_by_am` joins `unified_sales` to the AM map **on `site`**, so Redshift redistributes the table for that model. Low-cardinality or heavily-skewed dist keys are worse still — they concentrate rows on a few slices.
- **A silent drop deserves a loud test.** The budget CTE filters on `d.include` — the *right* side of a LEFT JOIN — so an unmatched dept is dropped with no error. It drops 0 rows today; `assert_budget_upload_depts_all_resolve.sql` is what keeps that true. The comment explicitly says *don't* "fix" it into an INNER JOIN: same semantics, and the test is the guard.

## Words you'll hear

| Word | What it means here |
|---|---|
| Incremental model | Build once, then only merge new/changed rows on later runs |
| `unique_key` | The column list dbt matches on in the MERGE — i.e. the grain |
| Cardinality error | One target row matched by several source rows in a MERGE |
| Incremental predicate | The `WHERE` dbt appends to bound how much history a run re-reads |
| Full refresh | `--full-refresh` — drop and rebuild, the only way to fix pre-window history |
| Late-binding view | `WITH NO SCHEMA BINDING`; resolves its source at query time, not create time |
| `dist` / `sort` | Redshift: how rows spread across slices, and their on-disk order |

## In this repo

- [`src/dbt/dbt_project.yml:88-93`](../../../tamimi-lakehouse/src/dbt/dbt_project.yml) — the Gold defaults: `incremental` + `merge` + `on_schema_change: fail`, applied to every fact. `:63-72` — the staging block with `+bind: false` and the 2026-06-05 failure recorded above it. `:50-54` — `gold_reprocess_days: 45` with the M-26 rationale.
- [`src/dbt/macros/scenario_helpers.sql:44-68`](../../../tamimi-lakehouse/src/dbt/macros/scenario_helpers.sql) — `gold_incremental_predicate`: `MAX(date) - INTERVAL 'N days'`, `COALESCE` to `1900-01-01` on the first run, and the paragraph stating plainly that corrections older than the window need a full refresh.
- [`src/dbt/models/marts/gold/unified_sales.sql:76-83`](../../../tamimi-lakehouse/src/dbt/models/marts/gold/unified_sales.sql) — the config block; `:63-70` — why the `__ALL__` sentinel exists; `:282` — the predicate as the model's last line.
- [`src/dbt/models/marts/gold/unified_sales_by_am.sql:70-73`](../../../tamimi-lakehouse/src/dbt/models/marts/gold/unified_sales_by_am.sql) — "aggregation lives in the CTE so the final SELECT has NO trailing GROUP BY"; `:47-49` — the join on `site` against a `dist='date'` table.
- [`src/dbt/models/marts/gold/unified_customer_count.sql:36-42`](../../../tamimi-lakehouse/src/dbt/models/marts/gold/unified_customer_count.sql) — M-28, the `NUMERIC(38,4)` pre-cast on every leg.
- [`src/dbt/models/sources.yml:19-22`](../../../tamimi-lakehouse/src/dbt/models/sources.yml) — the `silver_external` external schema every staging view reads.
- [`src/dbt/models/marts/gold/unified_distress.sql:12,62-65`](../../../tamimi-lakehouse/src/dbt/models/marts/gold/unified_distress.sql) — a seven-column `unique_key` and the note that it must equal the grain.

## Do this

1. Compile `unified_sales` (`dbt compile --select unified_sales`) with and without `is_incremental()`. Read the generated MERGE and find your `unique_key` in it.
2. Pick a date 60 days back and ask: if SAP restated that day tonight, which run fixes Gold? Write the exact command.
3. Drop `'scenario'` from `unified_sales`' `unique_key` on paper. Which two rows now collide, and is the result a duplicate or a cardinality error?
4. Add a column to a Silver table and predict the failure under `on_schema_change='fail'`. Then decide what the right response is — is it ever "change it to `append_new_columns`"?

## You've got it when you can…

…answer *"Gold shows the wrong number for a day in June"* with the right first question — **is that day inside the 45-day window?** — and then name the three settings that could each have caused it: the `unique_key`, the incremental predicate, and the last time anyone ran `--full-refresh`.
