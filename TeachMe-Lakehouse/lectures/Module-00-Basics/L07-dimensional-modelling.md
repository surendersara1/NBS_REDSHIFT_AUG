# L07 · Facts, Dimensions and Grain

> **Module 0 · Lesson 07** · ~45 min · **the most transferable skill in this module**

**Slide:** [`_render/L07-dimensional-modelling.html`](_render/L07-dimensional-modelling.html)

## What it is

A **star schema**: one fact table in the middle, surrounded by the dimensions you slice it by.

Facts are *what happened*, and they are measured. Dimensions are *the context* you filter and group by. Almost every retail reporting model in the world is this shape, and once you can see it you will see it everywhere.

## Say the grain out loud, first

Before any DDL, finish this sentence:

> **"One row in this table equals one ______."**

For example: *one row = one line on one receipt.*

Everything else follows. The grain decides which measures are valid, which dimensions can attach, and whether a number can be summed. Teams that skip this step spend the next year discovering that their fact table means slightly different things in different places.

Two rules about grain:
- **Go as fine as you can afford.** You can always aggregate up; you can never disaggregate down.
- **One grain per fact table.** Mixing "one row = one receipt line" with "one row = one receipt" in the same table guarantees double counting.

## Facts

Long and narrow. Contains:
- **Measures** — numbers you do arithmetic on
- **Foreign keys** — to the dimensions
- **Degenerate dimensions** — identifiers like receipt number that have no attributes of their own

Fact tables grow forever. They are where your storage and your compute go.

## Dimensions

Short and wide. Descriptive attributes you filter and group by: store name, region, product category, brand, day of week.

Dimensions change slowly — which is a whole lesson of its own (Lesson 08).

**Conformed dimensions** are dimensions shared across several fact tables. One `dim_date`, one `dim_store`, used by sales, stock and footfall alike. Without them, two marts that both report "sales by region" will disagree, and the disagreement will be structural rather than a bug you can find.

## Measures — not all numbers add up

| Type | Adds up over… | Example |
|---|---|---|
| **Additive** | every dimension | sales amount, quantity |
| **Semi-additive** | everything *except* time | stock on hand, account balance |
| **Non-additive** | nothing | ratios, percentages, unit price |

Summing a semi-additive measure over time is the most common wrong number in retail analytics. Stock on hand of 100 on Monday and 100 on Tuesday is not 200.

For non-additive measures, store the **numerator and denominator** as additive columns and compute the ratio at query time. Never store the ratio and sum it.

## Star vs snowflake

- **Star** — dimensions are flat and denormalised. More storage, simpler queries, faster joins.
- **Snowflake** — dimensions are normalised into sub-tables. Less storage, more joins, harder for business users.

**Prefer star.** Storage is cheap; the confusion that snowflaking causes among self-service users is not.

## When to use it

**Use dimensional modelling for:** any reporting model, on any warehouse; anywhere business users write their own SQL; anywhere one measure is sliced many ways.

**Do not use it for:** machine-learning feature tables, which want one wide row per entity rather than a star.

## In practice

- Dimensional modelling applies to the **gold layer only**. Bronze and silver keep the source shape.
- **One conformed `dim_date`** across every fact table, generated once.
- The grain of each fact is written into the model documentation, not just implied by the code.

## Checklist

- [ ] I can state the grain of a table as a sentence before writing DDL
- [ ] I can tell a fact from a dimension without being told
- [ ] I can classify a measure as additive, semi-additive or non-additive
- [ ] I know why ratios are stored as numerator and denominator
- [ ] I can explain what a conformed dimension prevents
- [ ] I default to star, and can say why

## You've got it when you can…

…be handed a source table you have never seen, ask three questions, and produce a fact-and-dimension design with the grain stated in one sentence that survives review.
