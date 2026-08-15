# L20 · The Last Mile: Gold → Power BI

**Slide:** [`_render/L20-gold-to-powerbi.html`](_render/L20-gold-to-powerbi.html)

## The point

Gold is not the finish line. Power BI never points at a Gold fact table — it points at a thin
**reporting view layer** that pre-computes the joins, the prior-year shift and the aggregations
that used to be DAX. Getting that boundary right is what makes the reports fast, testable and
reusable by anything else that shows up later.

## Key ideas

- **Nine views + one materialised table** are the entire contract between the lakehouse and Power BI. Nothing else is exposed.
- **DirectQuery, not Import.** The `.pbix` caches no data; every visual emits live SQL over the Redshift ODBC driver. There is no dataset refresh to schedule or to fail.
- **58 of 73 DAX measures (~80%) were pushed down into SQL.** The rule: *if it doesn't depend on what the user clicks, it belongs in a view.*
- **15 measures stay in DAX** — 9 rank-family (`RANKX` / `ALLSELECTED` need Power BI's runtime filter context) and 6 display formatters (the K/M wrappers). That's deliberate, not unfinished.
- **Why bother:** SQL views are regression-tested in CI, change-managed in git, and readable by any future consumer. DAX in a `.pbix` is a black box.
- **Freshness is bounded by the last dbt Gold build.** Bronze 06:30 → Silver 07:00 → Gold 07:30 KSA, alarm at 08:00. Because it's DirectQuery, a page opened at 09:00 shows the 06:30 pull.
- Each view's header comment **names the DAX measures it replaced** — that's the migration audit trail.

## Words you'll hear

| Word | What it means here |
|---|---|
| **Reporting view** | A dbt-built SQL view in the Redshift `reporting` schema; the only thing Power BI reads |
| **DirectQuery** | Power BI storage mode where every visual queries the database live and caches nothing |
| **Import** | The opposite mode — data copied into the `.pbix`, refreshed on a schedule. Not used for facts |
| **DAX** | Power BI's measure language. `SUM(...)`, `RANKX(...)`, `DIVIDE(...)` |
| **Push-down** | Moving a calculation out of DAX and into the SQL view |
| **Materialised** | Computed once at build time and stored, instead of recomputed per query (`mv_top5_bottom5_sites_by_dept`) |
| **Grain** | The one row means *this*. e.g. Site × EquivalentDate × Dept |
| **SLA** | The promise: numbers correct and available by 07:00 KSA, daily |

## In this repo

- [`src/dbt/models/marts/reporting/`](../../../tamimi-lakehouse/src/dbt/models/marts/reporting/) — the whole serving layer
  - `vw_sales_actuals_pyc.sql` — the headline view; 12 DAX measures, CY/PY/Budget in one row
  - `vw_customer_count.sql`, `vw_abv.sql`, `vw_dept_performance.sql`, `vw_store_performance_bands.sql`
  - `vw_gross_profit.sql`, `vw_gross_profit_mtd.sql`, `vw_distress.sql`, `vw_am_kam.sql`
  - `mv_top5_bottom5_sites_by_dept.sql` — the hybrid; materialised as a **table**, not a Redshift MV
  - `_reporting.yml` — the dbt tests and column contracts for all of the above
- `docs/design-reference/decisions/0010-power-bi-direct-query-vs-import.md` — storage-mode ADR
- `docs/design-reference/decisions/0021-thin-powerbi-over-gold-views.md` — "thin Power BI" ADR
- `docs/CLIENT-TECHNICAL-DESIGN.md` §Phase 5 — view → PBI page mapping and measure counts

## Do this

1. Open `vw_sales_actuals_pyc.sql` and read only the header comment. List the 12 DAX measures it replaced.
2. Find the `COALESCE(...)` on `sale_var_vs_budget` and read the comment. Explain in one sentence why a bare `SUM(...) - SUM(...)` flipped a page total from +292 M to −8 M.
3. Find the `WHERE us.site IN (SELECT site FROM dim_site WHERE is_reporting_scope)` semi-join. Say why it is a semi-join and not a `JOIN`.
4. Open `mv_top5_bottom5_sites_by_dept.sql` and say why *this one* could not be a plain view.

## You've got it when you can…

- Draw the last mile: Gold table → `reporting.vw_*` → DirectQuery → visual, and say what happens at each arrow.
- Give the rule for deciding whether a new calculation goes in DAX or in a view — and apply it to "show me last 7 days from the slicer" (DAX) vs "sale vs budget %" (view).
- Explain why there is no Power BI refresh schedule in this platform, and what *does* bound freshness instead.
- Name the three things a view buys you that a DAX measure doesn't: testable, governable, reusable.
