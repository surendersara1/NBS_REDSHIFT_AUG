# L08 · When A Dimension Changes

> **Module 0 · Lesson 08** · ~45 min

**Slide:** [`_render/L08-slowly-changing-dimensions.html`](_render/L08-slowly-changing-dimensions.html)

## The question

A store moves from the Central region to the Western region on 1 March.

Someone runs "sales by region for last year". Do that store's January sales appear under **Central** (where it was at the time) or **Western** (where it is now)?

Both answers are defensible. Both are wanted by different people. **The choice is the SCD type**, and it is a business decision, not a technical one — which is why the first thing to do is ask the business, not the DBA.

## Type 1 — overwrite

Update the row in place. The old region never existed; every historical report retrospectively moves the store to Western.

- **Use for:** genuine corrections. A misspelled store name, a wrong postcode.
- **Do not use for:** anything reported on over time. It silently rewrites history.

## Type 2 — new row

Close the current row, insert a new one. The dimension gains three columns:

| Column | Meaning |
|---|---|
| `valid_from` | when this version became true |
| `valid_to` | when it stopped (or a far-future date / null) |
| `is_current` | convenience flag for "the version now" |

History is preserved: January sales stay attached to the Central version of the store, and March onwards attaches to the Western version.

**This is the retail default.** Assume Type 2 unless someone argues otherwise.

## Type 3 — extra column

Keep `prev_region` alongside `region`. Remembers exactly one change, forever.

Rarely enough in practice. If someone asks for Type 3, ask what happens on the second change — the answer is usually "oh".

## The surrogate key is what makes Type 2 work

This is the part people miss, and getting it wrong quietly breaks everything.

- `store_id` is the **business key** — stable, from the source system. Store 4471 is always store 4471.
- `store_sk` is the **surrogate key** — one per *version* of the row. Store 4471 has one `store_sk` for its Central period and a different one for its Western period.

**The fact table joins on `store_sk`, never on `store_id`.**

If the fact joins on the business key, every historical row silently picks up whichever version is current — which is Type 1 behaviour with Type 2 storage costs. You have built the complexity and got none of the benefit.

## When to use which

| Situation | Type |
|---|---|
| Anything reported on over time | **Type 2** — the default |
| Fixing a genuine data error | Type 1 |
| One attribute, one step of history, strong reason | Type 3 |
| Attribute changes very frequently | Neither — split it into its own table or make it a fact |

That last row matters: a "slowly changing" dimension that changes daily is not slowly changing. Modelling it as Type 2 produces an enormous dimension. Move the volatile attribute out.

## In practice

- `dim_store` and `dim_product` are **Type 2**.
- **dbt snapshots** build the history — you declare the key and the columns to track, and dbt maintains `valid_from` / `valid_to` for you.
- BI filters on `is_current = true` for "as it is now" reporting, and joins through `store_sk` for "as it was" reporting.

## Checklist

- [ ] I can state the business question that decides the SCD type
- [ ] I know the three types and when each applies
- [ ] I can explain why a surrogate key is required for Type 2
- [ ] I would notice a fact table joining on a business key in review
- [ ] I know what to do with a fast-changing attribute
- [ ] I know which of our dimensions are Type 2 and how they are built

## You've got it when you can…

…be told "the store moved region" and immediately ask the business the right question — then implement whichever answer they give, and explain to a reviewer why the fact table joins where it does.
