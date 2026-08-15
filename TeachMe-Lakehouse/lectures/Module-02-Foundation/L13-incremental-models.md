# L13 · Build Incremental Models Correctly

> **Module 2 · Lesson 13** · ~45 min
> **Slide:** [`_render/L13-incremental-models.html`](_render/L13-incremental-models.html)

---

## The decision

**View, table, or incremental — and merged on which key?**

- **View** — cheap to build, computed on every query. Right for thin staging layers over the lake.
- **Table** — rebuilt in full each run. Right while a model is small, and right forever for small dimensions.
- **Incremental + merge** — built once, then only new and changed rows are merged in. Right for facts, and it is the default for every fact on the platform.

Choosing "incremental" is really choosing **four** things, and each has its own failure mode:

| Promise | Fails when |
|---|---|
| the **merge key** | it isn't genuinely unique, or it contains a NULL |
| the **reprocess window** | a correction lands outside it |
| the **schema-change policy** | column types drift between runs |
| the **refresh cadence** | nobody scheduled the full refresh |

The key is the grain. Get that one right and the rest are configuration.

## Do this

1. **Write the grain in the model header, in one sentence, then make the merge key equal it — column for column.**
   ```sql
   -- Grain: one row per store × business date × style × season × scenario
   {{ config(
       materialized = 'incremental',
       incremental_strategy = 'merge',
       unique_key = ['store_id', 'business_date', 'style_id', 'season_id', 'scenario'],
       on_schema_change = 'fail'
   ) }}
   ```
   If the header sentence and the `unique_key` disagree, one of them is wrong and you do not yet know which.

2. **Prove the key is unique in the source before you trust it in a merge.** Run the duplicate-check query, on real volumes, over a real window:
   ```sql
   SELECT store_id, business_date, style_id, season_id, scenario, COUNT(*)
   FROM   {{ ref('stg_sales') }}
   GROUP  BY 1,2,3,4,5 HAVING COUNT(*) > 1
   ```
   **Too narrow** and several source rows match one target row — the engine raises a cardinality error. **Too wide** and the match never fires, so rows re-insert instead of updating. The first is loud; the second is silent, which makes it worse.

3. **Use a sentinel, never NULL, in any column that forms part of the key.** If a model carries synthetic rollup rows — an "all departments" or "all styles" total — give that column a real marker value:
   ```sql
   '__ALL__' AS style_id      -- NOT: NULL AS style_id
   ```
   This is the single most expensive mistake in the lesson, and it is invisible: see **Why**.

4. **Set the reprocess window wider than the source's late-arrival habit, and make it a variable.**
   ```yaml
   vars:
     reprocess_days: 45     # widen per-run with --vars; never a literal in the model
   ```
   Find out empirically how late corrections actually arrive from each source, then set the window comfortably past that. Ops can widen it for a single run; they cannot widen it retroactively.

5. **Schedule a periodic full refresh, and write down its cadence.**
   ```bash
   dbt run --select fct_sales --full-refresh     # monthly, and after any source period re-open
   ```
   The window is a backstop for routine lateness, not a substitute for a rebuild. Anything older than the window is *only* recoverable this way.

6. **Mind the shape the incremental predicate forces on your SQL.** The predicate is appended as a `WHERE` on the final `SELECT`, and `GROUP BY` immediately followed by `WHERE` is a syntax error. Put aggregation in a CTE and end the model with a bare `SELECT * FROM ...`.

7. **Pin column types when unioning legs.** With `on_schema_change='fail'`, a first build that materialises a column as one numeric type and a later run that widens it will fail. Pre-cast **every** leg of a UNION to the same explicit type so the resolved type cannot drift between runs.

8. **Guard the silent drops.** If a filter sits on the right side of a LEFT JOIN, unmatched rows vanish without an error. Keep the join shape, and add a test that asserts nothing is being dropped.

**Worked example of the pattern:** `tamimi-lakehouse/src/dbt/dbt_project.yml` sets the incremental + merge + `on_schema_change: fail` defaults and the reprocess-days variable; `src/dbt/macros/scenario_helpers.sql` builds the windowed predicate; `src/dbt/models/marts/gold/unified_sales.sql` shows the declared grain, the matching `unique_key`, and the sentinel on the rollup legs.

## Why

**NULL never equals NULL in a merge predicate.** This is the whole lesson in one line. A row whose key column is NULL matches *nothing* in the target — including the identical row inserted by yesterday's run — so the merge treats it as new and inserts it again. And again. Every run, forever.

The consequence is uniquely nasty because nothing complains. No error, no failed test, no log line. The table grows a little each night, every total that includes those rows drifts upward, and the drift looks like business growth. By the time someone questions the number, months of reporting have been built on it.

The reprocess window has the mirror-image property: a correction that lands *outside* the window is never re-read, so the model keeps the stale value silently. Both failure modes are quiet, which is why both need a scheduled counter-measure rather than vigilance.

**What breaks if you don't:** the table grows quietly, every total drifts upward, and no run ever reports an error.

## On Apparel Group

**Confirm the true primary key on every Oracle table before you write its spec.** Do not take it from the data dictionary, the vendor documentation, or an assumption — run the duplicate check yourself, on production-like volumes. Composite keys in Oracle Retail rarely match what the documentation claims, and a key that is unique in a sample is not necessarily unique across the estate.

Per source:

- **RMS** — composite keys are the norm and often include an organisational or set-of-books column that is invisible in a single-entity extract. Verify with that column and without it.
- **SIM** — inventory positions churn heavily; the key almost always includes a location and a snapshot dimension. Decide whether you are storing a snapshot per day or a current position, and make the key say so.
- **XStore** — receipt identity usually needs store *and* till *and* date *and* transaction number. A transaction number alone is not unique across the estate, and the store column is what people forget.
- **Magento** — order line IDs are usually genuinely unique; confirm rather than assume, especially across store views.
- **Epsilon · MoEngage** — API extracts often re-send the same record with an updated timestamp. The natural key is the customer or campaign identifier, not the delivery batch.
- **Footfall (Vemco · Irisys)** — store × interval. Small, but the interval boundary convention differs by vendor; make it explicit in the key.

**Apparel-specific grain warning.** Style, colour, size and season multiply. A fact declared at "style" grain and merged on a key that omits colour or size will collapse rows that are genuinely distinct — and a fact declared at SKU grain whose key omits season will collide across seasons that reuse a SKU. Write the grain sentence first; it prevents both.

**Late arrivals:** ask each source owner how late a correction realistically lands. Store-level POS adjustments, supplier invoice restatements and returns all have different tails, and the widest one sets your window.

## Checklist

- [ ] The grain is stated in one sentence in the model header
- [ ] `unique_key` equals that grain, column for column
- [ ] The duplicate-check query returns zero rows on production-like volumes
- [ ] No key column can ever be NULL; synthetic rows use a sentinel
- [ ] The reprocess window is a variable, and wider than the source's real late-arrival tail
- [ ] A full refresh is scheduled, with a documented cadence and owner
- [ ] Aggregation is in a CTE; the model's final statement is a bare `SELECT *`
- [ ] Every leg of any UNION is pre-cast to an explicit, identical type
- [ ] A uniqueness test on the merge key runs on every build

## You've got it when you can…

…answer *"the fact table shows the wrong number for a day last quarter"* with the right first question — **is that day inside the reprocess window?** — and then name the three settings that could each have caused it: the merge key, the window, and the last time anyone ran a full refresh.
