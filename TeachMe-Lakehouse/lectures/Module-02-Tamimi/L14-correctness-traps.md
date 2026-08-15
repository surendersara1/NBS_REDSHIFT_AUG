# L14 · Two Bugs That Doubled the Numbers ⭐

**Slide:** [`_render/L14-correctness-traps.html`](_render/L14-correctness-traps.html)

## The point

Both bugs shipped a number that looked completely normal — no error, no NULLs, no failed job — and was **exactly twice** the truth. They come from the two ways a grain can go wrong.

- **Bug 1 — the language fan-out (a join that multiplies rows).** `TVKMT` is a *language-keyed* text table: its primary key is `(MANDT, SPRAS, KTGRM)`. `KTGRM` (the dept code) is unique only **within** a language slice. Joining `ZDSALES ⋈ TVKMT` on `KTGRM` alone matches the English row **and** the Arabic row for the same dept, so every sales row comes out twice — doubling `LC` and `CC` silently. In Bronze client 100: 43 EN · 43 AR · 3 DE.
- **Bug 2 — the synthetic `'All Dept'` row (a table with two grains).** `gold.unified_sales` deliberately contains **both** per-dept rows *and* an All-Dept rollup that is their sum, so Power BI's `[Dept] = "All Dept"` measures resolve directly. Any `SUM(sale)` across the dept axis that does not exclude it therefore counts every riyal twice.

Bug 1 is fixed by **restricting the join** (`right_where: SPRAS = 'E'`). Bug 2 cannot be "fixed" — the extra grain is wanted — so it is handled by **discipline plus a test** (`WHERE dept != 'All Dept'` in every roll-up).

## Key ideas

- **Any join to a text/description table is a fan-out risk.** Ask one question every time: *what is this table's real primary key, and is my join key the whole of it?* If not, restrict the other key columns before joining (`right_where`), and project away the duplicates (`right_select` drops `MANDT`). SAP's own QuickView does the same thing on its selection screen (`TVKMT~SPRAS in <sel>`).
- **The same bug bit a second table, and was caught by the same question.** `DD07T` is keyed `(DOMNAME, DDLANGUAGE, AS4LOCAL, VALPOS, AS4VERS)`; `domvalue_l` is not in that key. Joining on the value alone doubled customers: measured live on QA 2026-07-24, DD07T held 14 rows for 7 `ZSEGMENT` values, so 6,165,640 of 6,898,089 active customers were emitted twice and Silver carried 13,063,729 rows. The fix is the same shape — filter to one language *and* the active DDIC version, then keep one row per value deterministically.
- **A restriction is not always safe by itself.** Filtering `TVKMT` to `SPRAS='E'` and keeping the INNER join dropped 273,867 ZDSALES rows (SAR 2,285,602,930.33) for six dept codes with no English text row — unrecoverable, because Gold never re-reads Bronze. So `zsdcc` uses `join_type: left`: fidelity of *rows* wins, and the six orphan depts arrive with `vtext` NULL. Reporting scope stays in Gold (`dim_dept.include`).
- **Two grains in one table is a legitimate design — if it is written down.** `unified_sales` declares its grain and its six UNION-ALL legs in the file header. The All-Dept legs use `SUM(ZSDCC.sale)` for sale but `ZSCC.cc` for the customer count, because summing per-dept `cc` would double-count a basket that touched three departments. That is a *third* grain trap, handled in the same place.
- **CRIT-04 is the recurring instance.** Every roll-up of `unified_sales` must filter `dept != 'All Dept'` — `unified_sales_by_am` does it in the CTE, with the reason in a comment. Forget it once and every AM/store KPI (`sale_total`, `cc_total`) roughly doubles.
- **Test the invariant, not the symptom.** `assert_all_dept_reconciles_to_per_dept` asserts the All-Dept row equals `SUM(per-dept)` for the same `(site, date, scenario)`, tolerance 1.0, actuals only (budget All-Dept rows are preserved verbatim from Excel, not synthesized). `recon_unified_sales_has_synthetic_all_dept` asserts the opposite direction — that the rows still *exist*, so DAX doesn't go blank.
- **Test the config, not just the data.** The guard against Bug 1 coming back is a **unit test on the spec**: the diagnostic op must use the same `SPRAS` that `zsdcc.yaml`'s `right_where` applies, and `join_type` must be declared `left` explicitly rather than inherited from a default.
- **Know which invariants you *cannot* assert.** `SUM(per-dept cc) >= All-Dept cc` reads as though it must hold — and SAP does not honour it (A048 on 2026-02-06: per-dept 746 vs store 3,935). Asserting it would fail forever on correct data, and a permanently red test is no signal.

## Words you'll hear

| Word | What it means here |
|---|---|
| Grain | What one row means — the level a fact table is stored at |
| Fan-out | A join that returns more rows than the driving table has |
| Language-keyed table | An SAP text table with `SPRAS` in its primary key (`TVKMT`, `MAKT`, `T023T`, `DD07T`…) |
| `SPRAS` | SAP language key — `E` English, `A` Arabic, `D` German |
| `KTGRM` / `AAGM` | The department code; `norm_aagm` strips SAP's zero-padding |
| Sentinel | `'All Dept'` / `'__ALL__'` — a deliberate non-NULL marker value |
| CRIT-04 | This project's name for the All-Dept double-count class of bug |
| Conformed dimension | One `dim_site` / `dim_dept` shared by every fact, so totals can be compared |

## In this repo

- [`src/glue/specs/transform/zsdcc.yaml:22-30`](../../../tamimi-lakehouse/src/glue/specs/transform/zsdcc.yaml) — the 🔴 FAN-OUT banner with the live counts and the sentence *"joining on KTGRM ALONE… MULTIPLIES every ZDSALES row ~2x — silently DOUBLING LC and CC"*; `:32-48` — the Item 8 LEFT-join decision; `:56-62` — `right_where` / `right_select` / `join_type` as actual spec parameters.
- [`src/glue/glue_engine/abap/ops.py:121-127`](../../../tamimi-lakehouse/src/glue/glue_engine/abap/ops.py) — `flat_join_op`'s docstring, the general rule ("pre-filter the right side to the grain the join key implies"); `:347-355` — the DD07T fan-out with the measured customer numbers.
- [`src/dbt/models/marts/gold/unified_sales.sql:6-10`](../../../tamimi-lakehouse/src/dbt/models/marts/gold/unified_sales.sql) — the grain and the six legs, declared in the header; `:119-157` — the All-Dept rollup CTEs and why `cc` comes from ZSCC, not from summing ZSDCC; `:159-188` — `all_dept_cy` with the `__ALL__` sentinel.
- [`src/dbt/models/marts/gold/unified_sales_by_am.sql:62-66`](../../../tamimi-lakehouse/src/dbt/models/marts/gold/unified_sales_by_am.sql) — the CRIT-04 exclusion, with the reason written next to it.
- [`src/dbt/tests/assert_all_dept_reconciles_to_per_dept.sql`](../../../tamimi-lakehouse/src/dbt/tests/assert_all_dept_reconciles_to_per_dept.sql) — the reconciliation test, including *why* budget rows and CC-less store-days are out of scope.
- [`src/dbt/tests/assert_all_dept_cc_equals_customer_count.sql`](../../../tamimi-lakehouse/src/dbt/tests/assert_all_dept_cc_equals_customer_count.sql) — the `cc` half, and the honest section on the inequality that is *not* asserted.
- [`src/dbt/tests/recon_unified_sales_has_synthetic_all_dept.sql`](../../../tamimi-lakehouse/src/dbt/tests/recon_unified_sales_has_synthetic_all_dept.sql) — the guard in the other direction.
- [`tests/unit/test_phase3_abap_transform.py:756-800`](../../../tamimi-lakehouse/tests/unit/test_phase3_abap_transform.py) — the two spec-level unit tests: `join_type` must be explicitly `left`, and the diagnostic's `spras` must equal the language in `right_where`.

## Do this

1. For every join in `_material_attrs` (`ops.py`), name the right-hand table's primary key and say why the join cannot fan out. Two of them are only safe because of a `SPRAS = 'E'` filter — find them.
2. Run `SELECT SUM(sale) FROM gold.unified_sales WHERE scenario = '2026 A'` and then the same with `AND dept != 'All Dept'`. Explain the ratio before you look.
3. Delete `WHERE dept != 'All Dept'` from `unified_sales_by_am` and predict which dbt test fails and which one doesn't. (Only one of them looks at AM grain.)
4. Write the fan-out guard you would add for a *new* text-table join — the SQL that returns rows only when the right side is not 1:1 on the join key.

## You've got it when you can…

…do two things on sight: point at any join and state the right-hand table's primary key from memory, and point at any `SUM()` over a fact table and say **which grain it is summing** — including whether that table contains its own subtotals.
