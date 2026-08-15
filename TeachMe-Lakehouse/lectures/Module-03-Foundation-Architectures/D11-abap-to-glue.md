# D11 · ABAP To Glue, Stage By Stage

> **Module 3 · Architecture 11 · as built** · ~15 min

**Diagram:** [`_render/D11-abap-to-glue.html`](_render/D11-abap-to-glue.html)

## What it shows

Twenty years of receipt logic moved to Spark **without changing a single number**. Five stages, and one invariant that has to hold throughout.

## The invariant

> **The order of the lines *is* the business rule.**

A till roll only makes sense read top to bottom. A header sets the context; item lines accumulate against it; tender lines close it. Shuffle the rows and the receipt stops meaning anything.

That is why this is a **fold**, not an aggregation. Most Spark instincts — `groupBy().agg()` — throw away exactly the thing that carries the meaning.

## The five stages

**1 · Raw rows.** The ZHOCIDC extract: one flat table, one row per printed line, line type in a column, no keys and no types. Order carries meaning.

**2 · Group.** `groupBy(receipt_id).applyInPandas(...)`. Partition by receipt so one group is one complete receipt, and Python runs per group with line order preserved inside it.

**3 · Fold.** Walk the lines in order, exactly as the ABAP did. Header sets context, items accumulate, tenders close. This is a positional state machine, and it is the part that must match the original statement for statement.

**4 · Derive.** The ABAP arithmetic, extracted into named, unit-tested functions: `vat_split`, `resolve_store_type`, `parse_pack_size`. Each one small enough to test in isolation, which is what makes the whole thing reviewable.

**5 · Silver.** An Iceberg table, one row per sale line, typed and conformed, MERGEd on the key so it is safe to re-run.

## The only acceptance test that matters

Feed a day of real receipts through **both** the ABAP report and the Glue job.

> **Row for row, the totals must match.**

Anything else is a rewrite, not a migration — and a rewrite is a much bigger conversation with the business than anyone signed up for.

Where they legitimately differ (a rounding rule you deliberately corrected), **write the divergence down and pin it with a unit test**, so the next person does not "fix" it back.

## Why the derived functions are separate

Three reasons, all practical:

- **Testable.** `vat_split` takes numbers and returns numbers. No Spark, no fixtures, milliseconds per test.
- **Reviewable.** A finance person can read a twelve-line function. They cannot read a Spark job.
- **Reusable.** The same rule applies in more than one place, and now it exists once.

## Checklist

- [ ] I can explain why this is a fold rather than an aggregation
- [ ] I know why `applyInPandas` preserves what `groupBy().agg()` destroys
- [ ] Business rules are extracted into named, unit-tested functions
- [ ] The reconciliation test compares against the ABAP, row for row
- [ ] Deliberate divergences are documented and pinned by a test
- [ ] The silver table MERGEs and is safe to re-run

## You've got it when you can…

…be handed another ABAP report and immediately ask the right first question: *does the order of the rows carry meaning?* — because the answer decides the entire shape of the job.
