# L09 · Make Schema Change a Controlled Event

> **Module 2 · Lesson 09** · ~45 min
> **Slide:** [`_render/L09-schema-change.html`](_render/L09-schema-change.html)

---

## The decision

**What happens when a source adds or widens a column?**

It will happen. Oracle Retail gets a patch; the Magento team ships a feature and a new field appears on the order; MoEngage adds an attribute to an event payload; someone widens a numeric column from six digits to twelve because a currency conversion overflowed. None of these people know your pipeline exists.

So the decision is not whether to handle schema change. It is **what your pipeline does at the moment of the mismatch**:

| | Absorb it silently | **Fail loudly, then decide** |
|---|---|---|
| The run | succeeds | goes red |
| The table | quietly changes shape | unchanged |
| Downstream | keeps serving numbers | keeps serving *known-stale* numbers |
| Who finds out | a business user, months later | you, in the next ten minutes |
| Cost | a quarter of wrong reporting | an hour |

Choose **fail loudly**. Silent absorption is seductive because it keeps the build green — and that is precisely the problem. It converts a schema change into a data-quality problem with no timestamp and no owner.

There is a subtlety that makes loud failure even more clearly correct. When a write fails, **the old table stays readable**. Downstream reports keep rendering, keep serving pre-change numbers, and nothing tells the reader they are stale. So the choice is not "broken vs working" — it is "loud and stale" vs "quiet and wrong". Loud and stale is the one you can act on.

## Do this

1. **Set the drift policy to fail, on every model.** Make it a project-level default so nobody has to remember it per model, and comment it so nobody "fixes" it later:

   ```yaml
   models:
     +on_schema_change: fail   # NEVER silently absorb schema drift
   ```

   The alternatives — ignore, append-new-columns, sync-all-columns — each let a mismatch pass quietly into a table your BI tool is reading. Do the same at the ingestion layer: guard the write, and raise an error that **names the table and the columns**, so the person reading the log knows what to do without opening the code.

2. **Classify the change before you touch anything.** There are exactly two categories and the sorting rule is one sentence:

   - **Additive** — a new column at the end. Cheap: it is a metadata edit, existing data files stay valid, nothing is rewritten, and old rows read back null. **Backfill it before anyone depends on it**, because a null meaning "not populated yet" will be read as a business value.
   - **Everything else is a migration** — drop, rename, retype, reorder, narrow. Each one changes what existing rows *mean*, and each needs a plan, a window and a verification query.

   Say which category you are in out loud before writing code. The common failure is treating a migration as if it were additive.

3. **Allow a schema merge only on writes that rewrite every row.** Full-refresh and create-or-replace paths may carry a merge-schema option, because they replace the entire table and the new column lands populated everywhere. Append, partition-overwrite and merge paths must **not** get it: they touch a subset of rows and would leave the rest null in the new column — a table that is half-migrated and reports no error. Pin that distinction with a unit test so a future change cannot quietly grant the option to a partial-write path.

   Refuse drops by name. A schema merge is a *union*, so a column the frame stopped emitting survives on the target and gets nulls written over real values. Raise before the write, naming the missing columns.

4. **Pre-cast numerics to one stable width at the edge of every model.** This is the trap that catches people who did everything else right. A model that unions several legs resolves its column types from **whichever legs carried rows on that build**. Build once with only the integer legs present and the column materialises as an integer type; the next run, once a fractional leg has data, the type widens — and your fail-on-drift policy trips, correctly, on a model nobody changed.

   ```sql
   CAST(amount AS NUMERIC(38,4)) AS amount   -- every leg, every time
   ```

   Cast every leg to the same explicit type, at the edge of the model, not in the middle. Then the resolved type cannot drift regardless of which legs have rows. The same rule prevents the mirror-image failure — "union types numeric and character varying cannot be matched" — when a text-typed source column meets a numeric one.

5. **Set the partition spec when the table is created.** Partitioning is consulted **only** on first write, when the create-table statement runs. Later writes inherit the existing layout, so editing the partition setting in a spec for a live table changes nothing at all, and no existing data ever moves.

   ```sql
   PARTITIONED BY (months(business_date))
   ```

   That means: get it right at creation, and treat "we need to re-partition" as a table rebuild with a migration plan, not a config edit. Write the intended partition column into the spec review checklist for every new table.

**Worked example of the pattern:** the Tamimi lakehouse sets `on_schema_change: fail` as a Gold default in `src/dbt/dbt_project.yml`, guards non-additive drift in `writers/s3_tables.py` with an error that names the table and columns, passes the merge-schema option only on the full-rewrite writer paths, and pre-casts every union leg in `unified_customer_count.sql` to a single `NUMERIC(38,4)`. Four separate mechanisms, one policy.

## Why

**Silent absorption produces a plausible number, not an error.** That is the entire argument. An error is reviewed by an engineer within minutes because a build is red and someone is paged. A plausible number is reviewed by nobody, because the report still renders, the totals still look like totals, and there is no mechanism anywhere in the stack that flags "this figure is 4% lower than it should be".

The asymmetry is severe:

- A loud failure costs **an hour** — read the error, classify the change, apply the migration or the backfill, re-run.
- A silent absorption costs **a quarter** — because that is how long it takes for someone to notice, plus the time to work out when it started, plus the credibility you spend explaining it.

And you pay the second cost with interest, because by the time it is found, decisions have been made on the wrong numbers.

The type-widening trap deserves its own note, because it is the one that feels unfair. Nobody changed the model. Nobody changed the source. The build simply went red on the second run because a union leg started carrying rows. The lesson is that **a resolved type is not a stable type** — if you did not write the type down, the engine inferred it from data, and inferred types change when data changes. Pinning the cast is how you convert an inference into a declaration.

**What breaks if you don't:** a widened column shifts totals quietly, and finance finds it long before engineering does.

## On Apparel Group

**Oracle `NUMBER` is the one to watch.** It carries no fixed precision or scale unless the DDL specified one, which means every JDBC read has to decide a width, and different readers on different days can decide differently.

| Source | The schema-change risk | What to do about it |
|---|---|---|
| **Oracle Retail RMS** | `NUMBER` columns on cost, price, margin. Decades of patches add columns. | Pin every amount to `NUMERIC(38,4)` at the staging edge. Expect additive columns; fail on anything else. |
| **Oracle SIM** | `NUMBER` quantities; unit-of-measure changes ripple into meaning. | Same cast. Treat a UoM change as a migration, never as additive. |
| **Oracle XStore** | The largest surface: transaction, line, tender, tax columns. | Same cast. Because it is the giant, a full refresh here is expensive — get the types right before first load, not after. |
| **Magento** | Ships features regularly; new order/customer attributes appear without notice. | Fail on drift, then add the column deliberately. This is the source most likely to trip the policy. |
| **MoEngage** | Event payloads gain attributes as marketing configures campaigns. | Same. Treat "a new attribute appeared" as an ordinary, expected, *reviewed* event. |
| **Epsilon** | Loyalty attributes; PII classification can change with the schema. | A new column may be PII. Classification is part of accepting the change, not a follow-up. |
| **Vemco / Irisys Footfall** | Small and stable, but vendor file formats change on upgrade. | Fail on drift. A silently-absorbed footfall column is a silently-wrong conversion rate. |

The practical Apparel Group rule: **pin RMS, SIM and XStore amounts to `NUMERIC(38,4)` at staging, before the first union is written.** Do it once, at the edge, on every leg. It costs nothing and it removes the single most common cause of a model that builds fine on Monday and goes red on Tuesday.

## Checklist

- [ ] Fail-on-drift is the project-level default, with a comment saying why
- [ ] The ingestion writer guards drift and raises an error naming the table and columns
- [ ] I classified this change as additive or migration **before** writing code
- [ ] An added column is backfilled before anything reads it
- [ ] Merge-schema is enabled only on full-rewrite paths, and a test pins that
- [ ] Dropped columns are refused by name, not absorbed as a union
- [ ] Every union leg is explicitly cast to the same width — no inferred numeric types
- [ ] The partition spec was chosen at creation and reviewed as part of the spec
- [ ] I know that editing partitioning on a live table does nothing, and I have not tried it
- [ ] A migration has a plan, a window and a verification query before it runs

## You've got it when you can…

…classify any proposed schema change as **additive (safe) / non-additive (a migration)** in one sentence; explain the choice of fail-over-absorb using the real failure shape — *"the stale table stays readable and keeps serving pre-change numbers"*; state that partitioning is fixed at creation and that editing the spec later does nothing; and describe the type-pinning rule as **"pin every union leg to the same type so the resolved type cannot drift between runs."**
