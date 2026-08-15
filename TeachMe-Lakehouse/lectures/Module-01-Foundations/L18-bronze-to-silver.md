# L18 · BRONZE → SILVER: Cleansed, Conformed, Rebuilt

**Slide:** [`_render/L18-bronze-to-silver.html`](_render/L18-bronze-to-silver.html)

## The point

This is the hop where **business meaning is added**. Column names stop being SAP field codes and start being words (`KTGRM` → `aagm`, `FKDAT` → `date`, `ZAMT_SOLD` → `sale`); keys are normalised so the same value means the same thing in every table; and SAP's *derived* objects — QuickViews, extractors, report logic written in ABAP — are **rebuilt in PySpark** rather than pulled, because they are code, not tables. Silver's job is fidelity: it keeps every row it was given.

## Key ideas

- **Conforming is a contract, not cosmetics.** Until `aagm` means the same thing in `zsdcc`, `dim_dept` and the budget upload, no join across them is trustworthy. `norm_aagm()` strips leading zeros so `'09'` and `'9'` stop being two departments.
- **Derived objects are rebuilt, not read.** A SAP QuickView has no table behind it. We read its *base* tables from Bronze and re-implement the join/fold in Spark — `zsdcc = ZDSALES ⋈ TVKMT`, `basket` = a receipt state machine folded over `ZHOCIDC`, plus `scan_611`, `distress_603`, `id8_product`, `dim_dept`.
- **The correctness-heavy logic lives in pure functions.** `abap/baskets.py` and `abap/helpers.py` are unit-tested plain Python; `abap/ops.py` is the thin Spark adapter that calls them. You can test the business rule without a cluster.
- **Silver has no watermark.** `bronze_to_silver` reads *all* of Bronze every run, so plain `append` amplifies: three no-op re-runs once tripled Silver. Two idempotent modes replace it — `merge` on the `deduplicate` op's key, or `overwrite_partitions` for the fact streams that have no row-level key.
- **Silver is permissive; Gold is where scope lives.** When an inner join to TVKMT silently discarded 273,867 ZDSALES rows (SAR 2.29 bn, 12.43 % of value), the fix was a LEFT join — because once Silver drops a row, Gold never sees Bronze again and the row is gone for good.
- **The trap: language fan-out.** TVKMT is keyed `(MANDT, SPRAS, KTGRM)`. In client 100 it holds 43 English departments, 43 Arabic and 3 German. Join on `KTGRM` alone and **every** sales row matches ~2×, silently doubling sale and customer count. `right_where: "SPRAS = 'E'"` restores 1:1 — and it mirrors what the QuickView's own selection screen did.

## Words you'll hear

| Word | What it means here |
|---|---|
| Conform | Make names, units and keys mean the same thing everywhere |
| Fan-out | A join that returns more rows than it started with |
| ABAP | SAP's programming language — where the derived logic lives |
| QuickView | A SAP-side saved query; code, not a stored table |
| Grain | What one row represents (site × date × dept, …) |
| `overwrite_partitions` | Replace exactly the partitions in this batch, keep the rest |
| Idempotent | Re-running changes nothing observable |

## In this repo

- [`src/glue/glue_engine/jobs/bronze_to_silver.py:192-233`](../../../tamimi-lakehouse/src/glue/glue_engine/jobs/bronze_to_silver.py) — the write-mode fork and *why* `append` was removed, with the "3 re-runs tripled Silver" note.
- [`src/glue/glue_engine/abap/ops.py:104-137`](../../../tamimi-lakehouse/src/glue/glue_engine/abap/ops.py) — `flat_join_op`, including `right_where` / `right_select` and the docstring explaining the fan-out they prevent. `basket_op` is at `:44`, `scan_611` at `:729`, `distress_603` at `:1001`.
- [`src/glue/specs/transform/zsdcc.yaml:22-63`](../../../tamimi-lakehouse/src/glue/specs/transform/zsdcc.yaml) — the 🔴 FAN-OUT banner (measured live, with the 43/43/3 split) and the 🟡 LEFT-JOIN decision with the 273,867-row measurement.
- [`src/glue/glue_engine/abap/helpers.py`](../../../tamimi-lakehouse/src/glue/glue_engine/abap/helpers.py) — `norm_aagm`, `resolve_join_type`, `select_options`: the shared conforming primitives.

## Do this

1. Read `zsdcc.yaml` top to bottom, including the comments. It is the single best-documented spec in the repo — the comments *are* the lesson.
2. Delete `right_where` in your head and compute the resulting row count from the 43/43/3 split. Which measures inflate, and by how much?
3. Find one op in `ops.py` that returns **two** DataFrames and explain why one input can produce two Silver tables.
4. Pick any Silver spec and identify its `write_mode`. Justify it from the table's grain.

## You've got it when you can…

…explain why we rebuild a SAP QuickView instead of querying it, and describe — with numbers — how a join to a harmless little text table can silently double a revenue figure without raising a single error.
