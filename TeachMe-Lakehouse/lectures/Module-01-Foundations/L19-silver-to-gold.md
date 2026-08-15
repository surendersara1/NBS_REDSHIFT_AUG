# L19 · SILVER → GOLD: Shaped for the Question

**Slide:** [`_render/L19-silver-to-gold.html`](_render/L19-silver-to-gold.html)

## The point

Gold stops storing *records* and starts storing *answers*. dbt reshapes Silver into a star schema — facts surrounded by conformed dimensions — at exactly the grain the report asks for: one row per **site × date × dept × scenario**. Measures that used to be computed in DAX, at click time, on every user's machine, are computed once in SQL and stored. And unlike Silver, Gold is a **native Redshift table**: after the dbt build, Spectrum is out of the picture.

## Key ideas

- **The grain is the design.** `gold.unified_sales` has one row per site × date × dept × scenario. Everything else — which scenarios exist, how comparisons work, what a report can slice by — follows from that sentence.
- **`scenario` turns a hard join into a cheap filter.** Current-year actuals, prior-year actuals and Budget are six `UNION ALL` legs sharing one column shape, tagged `'2026 A'` / `'2025 A'` / `'Budget'`. Comparing this year with last year is `WHERE scenario = …`, not a self-join.
- **Incremental merge, not rebuild.** `materialized='incremental'`, `incremental_strategy='merge'`, `unique_key=['site','date','aagm','scenario']`. Re-run a day and its rows are replaced, not added.
- **Sentinels beat NULLs in a merge key.** All-Dept rows carry `aagm = '__ALL__'` because `NULL = NULL` is never true in a MERGE predicate — with NULL they would re-insert on every incremental run and silently inflate the table.
- **Measures move to SQL.** Variance vs budget, achievement %, ABV are computed in the reporting views, so a measure has one definition instead of one per report, and Power BI reads a number instead of deriving one.
- **The trap: `'All Dept'`.** `unified_sales` deliberately carries a synthetic rolled-up row (`dept = 'All Dept'`) per site × date, because the existing DAX filters straight to it. Any rollup that SUMs *across* dept must exclude it — otherwise the detail rows and their own subtotal are added together and every store total comes out roughly **2× high**. That is a real defect found in this codebase (CRIT-04).
- **Know where each number comes from.** The All-Dept `sale` is `SUM(ZSDCC.sale)`; the All-Dept `cc` comes from **ZSCC directly**, because summing per-dept customer counts would double-count a basket that spans two departments.

## Words you'll hear

| Word | What it means here |
|---|---|
| Star schema | One fact table surrounded by dimension tables |
| Conformed dimension | One dimension shared by several facts, with one meaning |
| Grain | What exactly one row of a fact table represents |
| Scenario | Which version of reality a row describes: CY / PY / Budget |
| Incremental | Rebuild only the affected rows, not the whole table |
| `unique_key` | The columns dbt's MERGE matches an existing row on |
| Sentinel | A real value standing in for "all" or "none" (`'__ALL__'`) |
| DAX | Power BI's formula language — what we are moving out of |

## In this repo

- [`src/dbt/models/marts/gold/unified_sales.sql`](../../../tamimi-lakehouse/src/dbt/models/marts/gold/unified_sales.sql) — the canonical Gold fact. `:76-83` is the incremental/merge config; `:85-117` the CY/PY actual legs; `:133-211` the synthetic All-Dept CTEs (with the `'__ALL__'` sentinel rationale at `:163-170`); `:226-268` budget.
- [`src/dbt/models/marts/reporting/vw_store_performance_bands.sql:48-53`](../../../tamimi-lakehouse/src/dbt/models/marts/reporting/vw_store_performance_bands.sql) — `WHERE s.dept != 'All Dept'`, the CRIT-04 fix, with the "or every store total is ~2x" comment.
- [`src/dbt/models/marts/dims/`](../../../tamimi-lakehouse/src/dbt/models/marts/dims/) — the four conformed dimensions: `dim_site`, `dim_date`, `dim_dept`, `dim_area_mgr`.
- [`src/dbt/macros/scenario_helpers.sql`](../../../tamimi-lakehouse/src/dbt/macros/scenario_helpers.sql) — `scenario_cy()` / `scenario_py()` / `scenario_budget()`, so the year labels live in one place.

## Do this

1. Read the six CTEs of `unified_sales.sql` and name, for each, which Silver/staging model it draws from and which scenario it emits.
2. Write the query that returns total sale per site for one date — first wrongly (no `dept` filter), then correctly. Predict the ratio between them before you run it.
3. Find one reporting view that *keeps* the All-Dept rows and explain why keeping them is correct there.
4. In `unified_sales.sql`, change `unique_key` to drop `scenario` and describe what breaks on the next incremental run.

## You've got it when you can…

…state the grain of `gold.unified_sales` in one sentence, explain why a helpful subtotal row living inside a detail table is dangerous, and name the exact predicate that keeps every store total honest.
