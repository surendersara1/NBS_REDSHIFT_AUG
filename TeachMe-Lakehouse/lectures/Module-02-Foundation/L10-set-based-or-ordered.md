# L10 · Choose Set-Based or Ordered, Deliberately

> **Module 2 · Lesson 10** · ~45 min
> **Slide:** [`_render/L10-set-based-or-ordered.html`](_render/L10-set-based-or-ordered.html)

---

## The decision

**Can this transformation be written as a join?**

Almost everything you will build on the new platform can. Dimensions, facts, aggregates, conformed lookups — all of it is set-based work: you declare the result, the engine decides how to compute it, and it scales without you touching a config file.

A small number of things genuinely cannot. Some source formats are not tables at all; they are **ordered blocks of rows**, where a row's meaning depends on the rows that came before it. POS receipt logs and event streams are the usual suspects. For those you need an **ordered per-group fold**, and reaching for one is a deliberate, defended decision — not a first instinct.

The choice is binary and you should be able to state which side you are on before writing a line of code:

| | Set-based | Ordered fold |
|---|---|---|
| Shape | joins, aggregates, window functions | `groupBy(...)` then a per-group loop |
| Cost | planned and optimised for you | a shuffle + a serialisation hop per group |
| Test | compare result sets | unit tests on a pure function |
| Use when | row meaning is independent | row *N* needs rows *1…N−1* |

## Do this

1. **Write it as joins and aggregates first.** Set-based SQL or DataFrame code is the default for every model on the platform. Do not start by asking whether ordering would be easier.
2. **Apply one test before you deviate:** *does row N mean anything without rows 1…N−1?* If the answer is yes, it stays set-based — no exceptions, no "but it would be simpler as a loop".
3. **If it fails the test, group on the smallest key that still holds all the state**, then fold that group in order. The whole group is materialised in memory on one worker, so the key must be small enough that its largest group comfortably fits. A receipt is tens of rows — fine. A store-month is not.
4. **Make the group key equal the identity you emit.** If the fold groups on one set of columns and emits a row identified by another, a single logical entity can be split across two groups and each half will emit its own record under the same identity. Grain damage, no error.
5. **Keep the fold pure and unit-test it.** A list of dicts in, lists out. No Spark session, no cloud SDK, no I/O inside the function. That is what makes the edge cases — incomplete blocks, repeated items, sign flips, uncommitted records — testable in milliseconds instead of in a 40-minute cluster run.
6. **Write down what you deliberately did not port.** A deferral you can name is a plan. A deferral you cannot name is a bug waiting to be discovered by a business user.

**Worked example of the pattern:** `tamimi-lakehouse/src/glue/glue_engine/abap/baskets.py` is the pure fold (no Spark, no AWS), and `.../abap/ops.py` is the thin Spark wrapper that groups, folds and caches around it. Read them in that order — the pure core first.

## Why

Set-based work is **declarative**: you state the result and the engine chooses the plan, the parallelism and the join strategy. It scales as the data grows without you re-tuning anything. That is a large amount of free engineering, and you give it up the moment you write a loop.

An ordered fold buys you something real — arbitrary sequential logic in plain code — and charges you for it: every row shuffles across the network to its group's partition, each group is serialised into the fold's runtime and the results serialised back. Worth it for a receipt. Ruinous on a key whose largest group is millions of rows.

**What breaks if you don't:** order-dependent logic squeezed into a set-based join does not raise an error — it returns numbers that are quietly wrong.

The converse costs you too. Logic that *is* naturally set-based, written as a fold out of habit, turns a query the optimiser would have handled into a shuffle you now own, maintain and pay for.

## On Apparel Group

| Source | Verdict |
|---|---|
| **Oracle XStore** | The one real candidate. POS transaction logs are ordered blocks — a header, its line items, its tender rows, a commit — and nothing should be emitted until the block completes. Fold this one, on the smallest receipt-identifying key. |
| **Oracle Retail RMS** | Pure set-based. Master and transaction tables, joins all the way. |
| **Oracle SIM** | Pure set-based. Inventory positions, high churn, still just joins. |
| **Magento** | Set-based. Orders and line items are already relational. |
| **Epsilon · MoEngage** | Set-based. Campaign and loyalty extracts arrive as records, not sequences. |
| **Vemco · Irisys Footfall** | Set-based. Small per-store counts. |

So: **one fold on the whole platform, and eight sources of joins.** If a second candidate appears, that is the signal to re-run the test in step 2 rather than to assume folds are now normal.

Apparel-specific caution on the XStore fold: a receipt in an apparel business routinely contains the same style in two sizes, or the same SKU scanned twice. Decide *deliberately* whether the fold merges those into one line or keeps them separate, and unit-test whichever you chose — that is a rule, not an implementation detail.

## Checklist

- [ ] I tried to write it as joins before considering anything else
- [ ] I can state, in one sentence, why row order does or does not carry meaning here
- [ ] If ordered: the group key is the smallest one that holds all the state
- [ ] If ordered: the group key **equals** the identity the fold emits
- [ ] If ordered: the fold is a pure function — no Spark, no SDK, no I/O
- [ ] If ordered: edge cases have unit tests (incomplete block, repeat, sign flip)
- [ ] The largest expected group fits comfortably in one worker's memory
- [ ] Anything deliberately not implemented is named in the docstring

## You've got it when you can…

…be handed an unfamiliar source table and say, within a minute, **"this is a join"** or **"this needs an ordered fold"** — and, if it is the fold, immediately name the group key, the identity it emits, and the one edge case you are going to write a test for first.
