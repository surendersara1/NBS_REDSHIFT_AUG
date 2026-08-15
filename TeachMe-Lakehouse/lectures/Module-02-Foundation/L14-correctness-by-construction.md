# L14 · Guarantee Correctness by Construction ⭐

> **Module 2 · Lesson 14** · ~45 min
> **Slide:** [`_render/L14-correctness-by-construction.html`](_render/L14-correctness-by-construction.html)

---

## The decision

**How do you know the numbers are right?**

Not by looking at them. A doubled total looks exactly like a good year. A fanned-out join looks exactly like more transactions. The dangerous failure on a lakehouse is **not an error** — it is a plausible number, produced by a job that succeeded, that is quietly twice the truth.

You cannot inspect your way out of this. The answer is to build tables whose grain *cannot* be violated, and then to assert the invariant on every build. Correctness by construction, backed by tests — not correctness by review.

Two failure shapes account for most of it, and they are worth naming because they need different fixes:

| Shape | Mechanism | Fix |
|---|---|---|
| **Fan-out** | a join returns more rows than the driving table has | restrict the join so it cannot |
| **Two grains in one table** | detail rows *and* their own subtotals coexist | discipline + a test; the extra grain is wanted |

## Do this

### 1. State the grain of every table in one sentence, in the file header

```sql
-- Grain: one row per store × business date × style × colour × size × season
```

If you cannot write that sentence, you do not yet know what the table is, and no test you write will mean anything. Write it before the SQL, not after.

### 2. Ask of every join: is my key the whole of the right side's primary key?

This is the question that prevents fan-out, and it takes ten seconds. If your join key is only *part* of the right-hand table's primary key, that table has multiple rows per key — and the join will multiply your driving rows by however many there are.

```sql
-- right side keyed (language, dept_code) — joining on dept_code ALONE
-- matches the English row AND the Arabic row: every fact row comes out twice
```

If the key is not the whole PK, **restrict the remaining key columns before joining**.

### 3. Constrain language- and type-keyed lookups so they cannot fan out

Description and code-decode tables are the classic offenders: they are keyed by *(code, language)* or *(code, type, version)*, and the column you actually want to join on is only one part of that.

```sql
LEFT JOIN dim_style_desc d
       ON d.style_id = f.style_id
      AND d.language = 'EN'          -- pins the remaining key column
      AND d.is_current                -- ...and any version/validity column
```

Two further rules for these joins:

- **Prefer LEFT over INNER when restricting.** Filtering a lookup to one language and keeping an INNER join silently drops every fact row whose code has no row in that language. Losing rows is worse than a NULL description — keep the fact, let the label be NULL, and make the *scoping* decision downstream where it is visible.
- **Project away what you don't need.** Select only the label columns from the right side, so a stray key column cannot re-introduce duplicates later.

### 4. Exclude synthetic rollup rows from every aggregate that crosses that axis

A fact table that deliberately contains both per-style rows **and** an "all styles" rollup has two grains on purpose — usually so BI measures resolve directly. That is a legitimate design *if it is written down*. But every roll-up over that axis must exclude the synthetic rows:

```sql
WHERE style_id != '__ALL__'     -- in every roll-up. Every time. No exceptions.
```

Forget it once and the KPI is roughly double. Put the reason in a comment next to the filter, not in a wiki.

Related trap: subtotals are not always summable. A distinct-count (customers, baskets, transactions) at the rollup level is **not** the sum of the per-dimension distinct counts, because one basket touches several styles. Take that measure from a source computed at the rollup grain, not by summing detail.

### 5. Add a uniqueness test on every merge key and a reconciliation test on every total

```yaml
# uniqueness — the grain holds
- dbt_utils.unique_combination_of_columns:
    combination_of_columns: [store_id, business_date, style_id, season_id, scenario]
```

```sql
-- reconciliation — the rollup row equals the sum of its detail rows
SELECT store_id, business_date
FROM   ...
GROUP  BY 1, 2
HAVING ABS(MAX(rollup_value) - SUM(detail_value)) > 1.0
```

Run both on every build. And **test the config, not just the data** — assert that the join type is declared explicitly and that the language filter in the model matches the one the spec applies, so a typo cannot quietly restore a fan-out.

### 6. Know which invariants you cannot assert

Some relationships *look* like they must hold and don't — a per-dimension distinct count summing to at least the store-level count, for instance. If the source doesn't honour it, asserting it produces a permanently red test, and a permanently red test is no signal at all. Write down the ones you deliberately do not assert, and why.

**Worked examples of the pattern:** `tamimi-lakehouse/src/glue/specs/transform/zsdcc.yaml` shows a lookup join constrained by an explicit filter and an explicitly declared join type; `src/dbt/models/marts/gold/unified_sales.sql` declares its grain and its legs in the header; `src/dbt/tests/assert_all_dept_reconciles_to_per_dept.sql` is the reconciliation test in both directions.

## Why

A fan-out or a double-counted subtotal **does not raise an error**. The job succeeds. No NULLs appear. Row counts go up, which looks like growth. The number is returned to a dashboard looking entirely normal — and being exactly twice the truth.

That is why review does not catch it and monitoring does not catch it. The only things that catch it are structural: a join that *cannot* multiply, and an assertion that runs on every build.

**What breaks if you don't:** you hear about it from a business user months later, after decisions were made on it — and then you have to explain not just the bug, but why nothing detected it.

The cost asymmetry is the real argument. A wrong number that looks wrong gets fixed in an hour. A wrong number that looks right gets quoted in a board pack, drives a buy, and destroys trust in the platform for a year. The whole discipline in this lesson exists to make the second kind impossible rather than unlikely.

## On Apparel Group

**Apparel dimensions multiply faster than almost any other retail vertical, so grain discipline matters more here, not less.**

One "product" in apparel is a hierarchy: **style → colour → size → season**, plus fit, and often a pack or set. A single style becomes hundreds of SKUs. Every level of that hierarchy is a place where a join can fan out and a rollup can double.

Specific things to get right on this platform:

- **Name the level in every fact's grain sentence.** "Product" is not a grain. *Style*, *style-colour*, or *SKU* is. Half the arguments about a number are actually disagreements about which of those three it is at.
- **Style description tables are language-keyed and season-keyed.** The Middle East footprint means English and Arabic descriptions coexist, and the same style code can be re-issued in a later season. Both are extra key columns; both fan out if you join on the style code alone. Pin the language, pin the season, use LEFT.
- **Size is where the biggest multiplication lives.** A size-scale lookup joined without pinning the scale — or the size-range version — multiplies every sales row by the number of sizes in the scale. Devastating and completely plausible-looking.
- **Season overlaps are normal, not an anomaly.** Two seasons trade at once during transition. A fact that omits season from its grain will merge rows across seasons and appear to be working perfectly.
- **Distinct counts across style are not summable.** A basket containing a shirt, trousers and a belt is one transaction and three style rows. Take transaction and customer counts from a source at the right grain; never sum them across the style axis.
- **Returns and exchanges are a sign trap.** Confirm whether a return is a negative row or a separate row with a flag, and make sure your aggregate doesn't count both the original and its reversal as sales.
- **Cross-source overlap.** XStore, Magento and RMS can each describe the same sale. Decide which is authoritative for each measure and state it, or a "total sales" figure will double at the source level before any join gets a chance to.

## Checklist

- [ ] Every table's grain is stated in one sentence in its header
- [ ] For every join, I can name the right side's full primary key from the code
- [ ] Every lookup join keyed by language / type / version pins those columns
- [ ] Restricted lookup joins are LEFT, not INNER, and the join type is declared explicitly
- [ ] Right-side projections drop any column that could re-introduce duplicates
- [ ] Every table with two grains says so in the header
- [ ] Every roll-up excludes synthetic rows, with the reason in a comment beside it
- [ ] Distinct-count measures come from a source at the rollup grain, never summed
- [ ] A uniqueness test exists on every merge key
- [ ] A reconciliation test exists on every total, in both directions
- [ ] Invariants deliberately **not** asserted are written down, with the reason

## You've got it when you can…

…do two things on sight: point at any join and state the right-hand table's primary key from memory, and point at any `SUM()` over a fact table and say **which grain it is summing** — including whether that table contains its own subtotals.
