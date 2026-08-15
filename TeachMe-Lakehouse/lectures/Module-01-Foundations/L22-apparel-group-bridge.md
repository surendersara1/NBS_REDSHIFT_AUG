# L22 · Same Architecture, New Client — the Apparel Group bridge

**Slide:** [`_render/L22-apparel-group-bridge.html`](_render/L22-apparel-group-bridge.html)

## The point

The next engagement is **Apparel Group — Enterprise Data & AI Platform on AWS**: 12 weeks, four
workstreams (Data Foundation · Price Optimization · Inter-store Transfer · Amazon Quick / Retail IQ),
eight in-scope sources. It is a different industry, a different vendor stack and a different
dimensional model — and it is the *same skeleton you just spent Module 1 learning*.
This lesson is the diff, not a new architecture.

## Key ideas

- **What stays the same is the expensive part.** Medallion layers and their contracts, raw-first landing, the spec-driven YAML engine, `merge_key` idempotency, barriers between phases, dbt for Gold + reporting views, the four-table control plane, Terraform + OIDC CI/CD per environment.
- **What changes is the leaf nodes.** A new source connector class, different watermark columns, a different star schema — all of it plugs into unchanged machinery.
- **Connector:** `sap_hana` (HANA JDBC via `ngdbc.jar`) becomes an Oracle JDBC source class. It's a new file in `sources/` with an `@register("...")` decorator; the engine, the specs and the writers don't move.
- **Watermarks stop being uniform.** At Tamimi almost everything watermarks on a SAP date column such as `FKDAT`. Across eight heterogeneous sources you will have transaction timestamps, sequence numbers, API cursors and `updated_at` columns — one per source, declared per spec.
- **The MANDT client filter disappears.** `client: "100"` exists because SAP multiplexes clients into one table. Oracle Retail has no equivalent. Delete the concept; don't port it.
- **Not everything is a database.** Epsilon and MoEngage are SaaS APIs — paging, rate limits, tokens — so the download stage grows an API-shaped sibling to the JDBC path. Raw-first matters *more* here, because you often cannot re-request an old page.
- **The dimensional model becomes apparel retail:** style / colour / size / season replace AAGM department. Facts change grain (sales, inventory position, transfers, footfall, campaign response). Kimball still applies.
- **Two sources are optional.** Vemco and Irisys footfall are nice-to-have; design them as additive facts so the platform ships without them.
- **The bottom line: you already know 80% of the next project.** The nouns change; the verbs don't.

## The eight in-scope sources

| # | Source | Carries | Shape |
|---|---|---|---|
| 1 | Oracle Retail (RMS) | merchandising, cost, item & location hierarchy | JDBC |
| 2 | Oracle SIM | store inventory positions | JDBC |
| 3 | Oracle XStore | in-store sales transactions | JDBC |
| 4 | Epsilon | loyalty & customer master | SaaS API |
| 5 | MoEngage | campaign & engagement data | SaaS API |
| 6 | Magento | e-commerce orders, customers, products | DB / API |
| 7 | Vemco Footfall | store footfall counts | optional |
| 8 | Irisys Footfall | store footfall counts | optional |

## Words you'll hear

| Word | What it means here |
|---|---|
| **RMS** | Oracle Retail Merchandising System — the item/cost/hierarchy master |
| **SIM** | Oracle Store Inventory Management — what is on hand, per store |
| **XStore** | Oracle's POS — the transaction log at the till |
| **SKU / style-colour-size** | The apparel grain. A "style" fans out to colours, which fan out to sizes |
| **Season** | An apparel time dimension (SS26, AW26) that is *not* the calendar |
| **Inter-store transfer** | Moving stock between stores to fix a size-curve gap |
| **Price optimization** | Choosing markdown depth and timing from sell-through |
| **MANDT** | The SAP client column. Tamimi-only. It does not exist here |
| **Footfall** | People counted entering a store — the denominator for conversion rate |

## In this repo (the parts you will reuse verbatim)

- [`src/glue/glue_engine/sources/`](../../../tamimi-lakehouse/src/glue/glue_engine/sources/) — `sap_hana.py`, `rds_jdbc.py`, `s3_landing`/`landed_files.py`, `excel_landing.py`, and `__init__.py` with the `@register` registry. **This is where the new Oracle class lands.**
- [`src/glue/specs/`](../../../tamimi-lakehouse/src/glue/specs/) — `download/` (58), `bronze/` (67), `transform/` (14). Read `download/sap_zdsales.yaml` next to `bronze/sap_zdsales.yaml` to see `watermark_column`, `safety_buffer_days`, `jdbc_hash_partitions` and `merge_key` in one pair.
- `src/glue/glue_engine/spec.py` — the Pydantic contract every spec must satisfy
- [`src/lambdas/`](../../../tamimi-lakehouse/src/lambdas/) + [`src/shared/shared/control_plane/`](../../../tamimi-lakehouse/src/shared/shared/control_plane/) — barriers and control plane, unchanged
- [`src/dbt/models/`](../../../tamimi-lakehouse/src/dbt/models/) — `staging/` → `marts/dims/` → `marts/gold/` → `marts/reporting/`; the shape survives, the models are rewritten
- `infra/modules/` + `bitbucket-pipelines.yml` — Terraform modules and the OIDC deploy per env

## Do this

1. Take **Oracle Retail `ITEM_MASTER`** (or any table you know) and write the two spec YAMLs by hand: a `download/` spec (source type, watermark column, hash field, landing prefix, schema) and a `bronze/` spec (`merge_key`, same schema). Use `sap_zdsales.yaml` as the template.
2. Open `sources/sap_hana.py` and list every SAP-specific thing in it. That list is exactly your Oracle connector's to-do.
3. For each of the eight sources, write one line: what its watermark is, and what its natural key is. Where you can't answer, that's a discovery question for week 1.
4. Sketch the apparel star: name three facts and five dimensions.

## You've got it when you can…

- Put any of the eight sources on the medallion map and say which existing file you would copy first.
- Name the four things that genuinely change (connector, watermark, MANDT gone, dimensional model) — and defend everything else as unchanged.
- Explain why raw-first is *more* important with SaaS APIs than with a database.
- Say the line and mean it: **you already know 80% of the next project.**
