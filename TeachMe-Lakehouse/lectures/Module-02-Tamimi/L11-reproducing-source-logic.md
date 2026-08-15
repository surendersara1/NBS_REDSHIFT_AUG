# L11 · Porting ABAP Faithfully

**Slide:** [`_render/L11-reproducing-source-logic.html`](_render/L11-reproducing-source-logic.html)

## The point

Silver's job is **fidelity**: a derived Silver table must be identical to the SAP view it re-implements. That makes "port the ABAP" a design decision on every function, not a mechanical translation. Three real examples, three different answers.

- **`vat_split` — the rate is data.** The ABAP FM `ZMM_GET_RETAIL_WITH_TAX` looks up the MWST condition (`A078` → `KONP.KBETR/1000`) by country *and date*, and it treats `MARA.TAKLV = 0` as **exempt — no split at all**. A flat `incl / 1.15` invents tax SAP never charged on exempt items, and it silently misprices every historical row from before the 15 % rate.
- **`resolve_store_type` — a rule, not a lookup.** Every site's type is *derived* from the WERKS plant code (`E*` → EXPRESS, `S/N/M` + 301-303 → BULK SALES, `S899` → DSD CONSOLIDATION, `R399` → BAKERY PRODUCTION…). There is no text table to join, so there is no row to be missing and no language to fan out. Porting it as a lookup would have invented a dependency SAP does not have.
- **`parse_pack_size` — a bug kept on purpose.** It is a byte-for-byte port of ABAP `strip_maktg`: both passes scan a right-justified fixed buffer from offset 39 (or 19) **down to 1**, so offset 0 is never inspected. That off-by-one is reproduced deliberately, because the goal is parity with what SAP actually prints — pack sizes that are already on shelf labels and in the customer's reports.

The transferable skill is knowing **which of the three you are looking at** before you write the function.

## Key ideas

- **Reproduce a source bug when its output is already the accepted answer.** Descriptions and pack sizes flow to the business as-is; a "fixed" parser would make every product description differ from SAP's and every reconciliation fail. Reproduce it, and say so in the docstring — `parse_pack_size` spells out the off-by-one, the discarded `6X` multiplier, and the empty-description single-word case as *reproduced*, not accidental.
- **Do not reproduce a bug that drops data.** `zsdcc`'s join is the counter-example. SAP's own QuickView uses an INNER join to `TVKMT`, and reproducing it discarded 273,867 ZDSALES rows (SAR 2,285,602,930.33 — 12.43 % of `ZAMT_SOLD`) for six dept codes with no English text row. Gold never reads Bronze again, so that loss is unrecoverable. The operator overrode ABAP parity: `join_type: left`, orphan depts arrive with `vtext` NULL, and the *scoping* decision moves to Gold (`dim_dept.include`).
- **Do not reproduce a bug that is a sequential artifact.** `id8_product`'s `components_per_unit` is a plain LEFT JOIN to MARM. The ABAP's mutable `w_umrez` can carry a **stale value from the previous material** when its own lookup misses — a work-area artifact, not a rule. Replicating it would attach a random unrelated material's ratio. The port returns NULL and documents the divergence.
- **Do not mis-encode a source *idiom* as a bug.** ABAP `SELECT-OPTIONS` means "no restriction" when empty; a pre-filled screen value is only a default. Encoding `scan_611`'s default as `fkart == 'FP'` dropped every non-POS billing document — 281,994.50 of sale on a single day, in Silver, unrecoverably (R40). `select_options()` now normalises the range and returns `[]` for "no filter".
- **Make the ported unit fail loudly, not quietly.** `resolve_join_type` raises on an unknown value instead of defaulting to `inner`, precisely so a typo cannot silently restore the 273,867-row drop. `resolve_extwg` returns the **raw** unknown code rather than NULL, so the dbt `accepted_values` test can see it (a NULL never fails a `NOT IN` predicate).
- **Every divergence lives in two places: the docstring and a test.** That is what stops the next person "fixing" it back.

## Words you'll hear

| Word | What it means here |
|---|---|
| Fidelity / parity | Silver reproduces the SAP view exactly, including its quirks |
| Decompiled ABAP | The real source under `docs/ABAP/src/` — `LZID8F01..F05`, the FMs |
| `TAKLV` | SAP tax classification on the material; `0` = exempt, no VAT split |
| `WERKS` | Plant / site code — 1 letter + 3 digits, e.g. `S106` |
| `MAKTG` | Material short text; the pack-size token is parsed off its tail |
| Work area | An ABAP mutable local that persists across loop iterations — the source of sequential artifacts |
| `SELECT-OPTIONS` | An ABAP selection range; **empty means unrestricted**, not "no rows" |

## In this repo

- [`src/glue/glue_engine/abap/helpers.py:144-154`](../../../tamimi-lakehouse/src/glue/glue_engine/abap/helpers.py) — `vat_split`: exempt or zero rate passes through untouched; otherwise `excl = incl / (1 + rate)`. Called per item at [`baskets.py:159-161`](../../../tamimi-lakehouse/src/glue/glue_engine/abap/baskets.py) with `exempt=(taklv == "0")`.
- [`helpers.py:157-221`](../../../tamimi-lakehouse/src/glue/glue_engine/abap/helpers.py) — `resolve_store_type`, the whole prefix rule plus the honest notes: `D*` → WAREHOUSE **added** 2026-07-30 after a live cross-tab (the ABAP doc was silent on `D`), and the `301-303` / `197-199` ranges are "the plain reading, not a re-verified SAP fact".
- [`helpers.py:256-329`](../../../tamimi-lakehouse/src/glue/glue_engine/abap/helpers.py) — `parse_pack_size`, traced offset-by-offset against `LZID8F01.abap:199-275`. Read the docstring before the code.
- [`helpers.py:17-39`](../../../tamimi-lakehouse/src/glue/glue_engine/abap/helpers.py) (`resolve_join_type`, raises) and [`:332-353`](../../../tamimi-lakehouse/src/glue/glue_engine/abap/helpers.py) (`select_options`, the R40 story).
- [`docs/ABAP/ID8-EXTRACTOR-MAPPING.md:239-249`](../../../tamimi-lakehouse/docs/ABAP/ID8-EXTRACTOR-MAPPING.md) — the decompiled VAT FM: `tax_code = 0 ⇒ exempt, no split`, rate from `KONP.KBETR/1000`. `:183` is the store-type prefix table; `:167-170` warns that `strip_maktg` is "fiddly string logic, not a column copy".
- [`src/glue/glue_engine/abap/ops.py:648-655`](../../../tamimi-lakehouse/src/glue/glue_engine/abap/ops.py) — the disclosed `components_per_unit` simplification, in `id8_product_op`'s docstring.
- [`tests/unit/test_phase3_abap_transform.py:48-65`](../../../tamimi-lakehouse/tests/unit/test_phase3_abap_transform.py) (VAT incl. the exempt case), `:169-201` (store type, parametrized), `:439-497` (pack size: weight suffix, discarded `6X` multiplier, unmatched unit, `**PROMO**` stripping, single-word → empty description).

## Do this

1. Run `parse_pack_size("SPRITE CAN 6X330ML", uom)` on paper. Where does the `6X` go, and which loop iteration drops it?
2. Change `vat_split` to always divide by 1.15 and run the unit tests. Then work out, in SAR, what that does to a day of exempt-item sales.
3. Open `zsdcc.yaml`'s banner and `helpers.py::resolve_join_type` together. Explain why a typo like `join_type: lft` **raises** instead of falling back to `inner`.
4. Pick any ported function and classify it: reproduce the bug, refuse the bug, or the source has no bug and you mis-read an idiom.

## You've got it when you can…

…hold both sentences at once — **"we copied SAP's bug on purpose"** and **"we refused to copy SAP's bug"** — and say which rule decides between them: *does the divergence change a number people already reconcile against, or does it lose data we can never get back?*
