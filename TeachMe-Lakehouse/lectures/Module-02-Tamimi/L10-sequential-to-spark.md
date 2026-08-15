# L10 · When a Join Won't Do ⭐

**Slide:** [`_render/L10-sequential-to-spark.html`](_render/L10-sequential-to-spark.html)

## The point

`ZHOCIDC` is the NCR-POS end-of-day log. It looks like a table and it is not one.

- Each row carries a **record type** in `ZTRNTYPE` — `H` header, `S` sale line, `T` tender, `F` footer/commit — and the *same* generic columns (`ZVARID1..4`, `ZCODE1..3`, `TAKLV`) mean **different things per type**. `ZVARID4` is one 19-character string: on an `S` row `[9:18]` is the amount × 100 and `[0:8]` is the quantity; on a `T` row `[0:2]` is the tender code.
- A receipt is an **ordered block** of those rows, `H … S … T … F`, read in `SEQNO` order. Row *N* only means something given rows *1..N−1*: the open `basket_id` came from the last `H`, an item's quantity accumulates over repeated barcodes, and **nothing is emitted until `F` commits**.
- A set-based join cannot express "the row before". So the port keeps the ABAP's shape: **group by receipt, then fold the group in order**. In Spark that is `groupBy(...).applyInPandas(...)`; the fold itself is plain Python.
- The correctness-critical part — `build_baskets` — is **pure**: a list of dicts in, two lists out. No Spark, no AWS. That is what makes it unit-testable, and it is why the edge cases (training transactions, uncommitted receipts, sign flips) have real tests instead of hope.

## Key ideas

- **Read the ABAP's control flow, not its output.** `process_sold_articles` (LZID8F03) is a linear loop with mutable work areas (`w_ilsxd`, `w_total`, `w_linno`, `w_tender_count`). The port keeps those as local variables inside one function; it does not try to reconstruct them with window functions.
- **The four ported branches.** `H` opens a basket and resets state (`ZCODE1='3'` = a training transaction → skip the whole receipt). `S` parses amount/qty/sign and accumulates into an item keyed by **barcode** (matching the ABAP's read-by-EAN, so two scans of the same product merge into one line). `T` decodes the tender code and flips to `'Multiple Tender'` on the second one. `F` drops zero-price items, rolls up `BASKETAMOUNT*`, and appends.
- **All-or-nothing per receipt.** No `F` → no header, no items. A header with sales but no commit produces *nothing* — proven by `test_build_baskets_uncommitted_receipt_not_emitted`.
- **The group key must equal the emitted identity.** `basket_id` is `'20' + zdate + zptno + zreceipt` (truncated to 16). The fold therefore groups on `(werks, zdate, zptno, zreceipt)` — **not** `budat`. That was Item 10: grouping on `budat` split a receipt whose POS date and posting date disagreed across two groups, and each group committed its own header under the same `(store_id, basket_id)`. Measured on dev Bronze 2026-08-08 over 43,500,445 header rows: 22,150 identities spanned more than one `budat` against 88 where SAP genuinely emits two headers — the grouping key manufactured ~99.6 % of the duplicates.
- **`applyInPandas` is a contract with two sides.** Spark shuffles every row to its group's partition; Python then materialises the whole group as a pandas DataFrame. Cheap here because a receipt is tens of rows — it would be ruinous on a key with a million-row group. Choose the *smallest* key that still contains all the state.
- **The JSON tag trick.** One pass emits both outputs: each folded row is `{_kind: 'H'|'I', _row: <json>}`, and the union is filtered twice into `sap.basket` and `sap.basket_item`. That is also why `folded.cache()` is there — see L12.
- **What is deliberately not ported yet** is written down in the module docstring: markdown/discount (`C`), weight items, external-vendor EAN remap, points (`G`), promo code (`K`), B2B (`y`), and the ecom/bulk paths. A deferral you can name is a plan; a deferral you can't is a bug.

## Words you'll hear

| Word | What it means here |
|---|---|
| Positional / state machine | The row's meaning depends on its position and on the state left by earlier rows |
| Fold (reduce) | Walk an ordered sequence carrying an accumulator — the shape a cursor loop has in a functional language |
| `applyInPandas` | Spark: shuffle rows into groups, hand each group to Python as a pandas DataFrame |
| Receipt identity | `(store_id, basket_id)` — `basket_id` alone does **not** encode the store |
| Pure core | A function with no I/O and no framework, so it can be tested in milliseconds |
| Commit record | The `F` row — until it arrives the receipt does not exist downstream |

## In this repo

- [`src/glue/glue_engine/abap/baskets.py:55-184`](../../../tamimi-lakehouse/src/glue/glue_engine/abap/baskets.py) — `build_baskets`, the whole state machine: `H` at `:96`, `S` at `:117`, `T` at `:164`, `F` at `:174`, and `_commit` at `:76-91`.
- [`src/glue/glue_engine/abap/ops.py:30-91`](../../../tamimi-lakehouse/src/glue/glue_engine/abap/ops.py) — `_RECEIPT_KEYS` with the Item 10 comment and the measured numbers, `basket_op`, the `_fold` closure, `applyInPandas` at `:86`, `folded.cache()` at `:87`; `_explode_json` at `:94-101`.
- [`src/glue/specs/transform/basket.yaml`](../../../tamimi-lakehouse/src/glue/specs/transform/basket.yaml) — one spec, two outputs (`sap.basket`, `sap.basket_item`), `vat_rate: 0.15`, and the list of inputs deferred until their op logic lands.
- [`docs/ABAP/ID8-EXTRACTOR-MAPPING.md:60-119`](../../../tamimi-lakehouse/docs/ABAP/ID8-EXTRACTOR-MAPPING.md) — the raw field layout table and the per-record-type rules; `:252-255` states the constraint outright: *"ZHOCIDC is a positional state machine… not a set-based join. This is the single hardest part to port."*
- [`tests/unit/test_phase3_abap_transform.py:69-166`](../../../tamimi-lakehouse/tests/unit/test_phase3_abap_transform.py) — the group-key test, the golden one-item receipt (`basket_id`, `posting_date = budat − 1`, tender `Cash`, excl = 15.00/1.15), the training-transaction skip, and the uncommitted receipt.
- [`src/dbt/tests/assert_basket_receipt_identity_is_unique.sql`](../../../tamimi-lakehouse/src/dbt/tests/assert_basket_receipt_identity_is_unique.sql) — the downstream guard, and a model of how to write one: it does **not** assert uniqueness (SAP itself retransmits blocks); it asserts the transform never *splits* one physical receipt. 656 duplicate identities out of 41,038,625 QA headers, every one explained.

## Do this

1. Open `baskets.py` and hand-execute the four rows in `test_build_baskets_single_receipt_header_item_tender_footer`. Write down the value of `hdr`, `cur_items`, `w_total` and `w_tender_count` after each row.
2. Delete the `F` row from that test in your head. Predict the output; then run the test that already proves it.
3. Try to write the same logic as SQL. Get as far as you can with `LAG`/`LAST_VALUE` over `PARTITION BY receipt ORDER BY seqno`, then say precisely where it breaks (hint: the accumulate-by-barcode step, and the conditional commit).
4. Change `_RECEIPT_KEYS` to use `budat` instead of `zdate` and run `test_basket_group_key_matches_the_emitted_receipt_identity`. That red test is Item 10.

## You've got it when you can…

…explain to a SQL-first colleague **why this one table gets a Python fold while everything else in the pipeline is a join** — and then show them the two lines that make it safe: the group key that equals the emitted identity, and the pure `build_baskets` core with its unit tests.
