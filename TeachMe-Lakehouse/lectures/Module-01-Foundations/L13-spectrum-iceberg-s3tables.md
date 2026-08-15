# L13 · Is Spectrum Still Involved? ⭐

**Slide:** [`_render/L13-spectrum-iceberg-s3tables.html`](_render/L13-spectrum-iceberg-s3tables.html)

## The point

This is the question everyone asks once they've seen L12, and the answer has two halves.

- **YES for Silver.** Redshift reads the Silver Iceberg tables **in place**: Redshift → Glue Data Catalog → Iceberg metadata → `s3tables:GetTableData`. Nothing is copied. Rows stream into Redshift's memory for the duration of the query and are gone afterwards.
- **NO for Gold.** dbt materialises Gold as **native Redshift tables**. Once a row is in Gold, Spectrum is out of the picture — Power BI queries Redshift's own storage. *That is why Gold is fast.*
- **The dividing line is the dbt build.** Spectrum's job is to feed dbt; dbt's output is native.

## Key ideas

- The read path has four hops, and each one is a different service: the **query engine** (Redshift/Spectrum), the **catalog** (Glue — what tables exist and where their metadata lives), the **table format** (Iceberg — `metadata.json` → manifests → data files), and the **storage** (S3 Tables — the Parquet).
- Nothing in that chain is a copy. The catalog holds a `metadata_location` pointer; Iceberg holds file lists; S3 Tables holds bytes.
- Because Spectrum's Glue lookup hardcodes `catalogId=<account>`, the federated `s3tablescatalog` sub-catalogs are unreachable from Spectrum. Our Glue writer therefore **re-registers each Iceberg table into a default-catalog mirror database** (`silver_<env>`) after every write, so Spectrum can find it. Same tables, reachable name.
- **Evidence #1 — late-binding views.** A plain Redshift view cannot `SELECT` from an external schema; Redshift rejects it outright. So every staging model is declared `+bind: false` (`WITH NO SCHEMA BINDING`). That config exists *only* because staging reads `silver_external.*`. It is the fingerprint of Spectrum in the dbt project.
- **Evidence #2 — the IAM paths differ.** Spectrum's role uses `s3tables:GetTableData` and needs **no** raw `s3:` on the managed physical bucket. Glue's Iceberg S3FileIO writer is the one calling raw `s3:GetObject`/`PutObject` there. Two different doors into the same data.
- Downstream of dbt — `gold.*`, `reporting.vw_*`, Power BI — there is no Spectrum, no Glue lookup and no per-byte S3 bill.
- Practical consequence: a slow Gold build is usually a Spectrum problem; a slow *report* is never one.

## Words you'll hear

| Word | What it means here |
|---|---|
| In place | Read where it lies — no copy, no load step |
| Materialise | Write the query result out as a real stored table |
| Late-binding view | A Redshift view that resolves its source at query time, not create time |
| Mirror database | `silver_<env>` in the default Glue catalog, re-registered after each write |
| `s3tables:GetTableData` | The S3 Tables data-plane action Spectrum uses instead of `s3:GetObject` |
| Federated catalog | `s3tablescatalog` — where S3 Tables auto-mount, but Spectrum can't see |

## In this repo

- [`src/dbt/dbt_project.yml:63-72`](../../../tamimi-lakehouse/src/dbt/dbt_project.yml) — the staging block with `+materialized: view`, `+bind: false` and the comment recording the 2026-06-05 failure ("External tables are not supported in views") that forced it.
- [`infra/modules/iam/main.tf:309-317`](../../../tamimi-lakehouse/infra/modules/iam/main.tf) — the comment stating Spectrum uses `s3tables:GetTableData` "so we do NOT need `s3:*` on this role", and `:334` — the explicit action list. Contrast `:64-79`, the Glue role's `s3tables:Put*` data-plane statement.
- [`src/glue/glue_engine/writers/s3_tables.py:451-536`](../../../tamimi-lakehouse/src/glue/glue_engine/writers/s3_tables.py) — `_register_in_mirror_catalog`: read `metadata_location`, delete, re-create the Glue table so Spectrum sees the newest snapshot.
- [`src/dbt/models/marts/gold/unified_sales.sql:76-83`](../../../tamimi-lakehouse/src/dbt/models/marts/gold/unified_sales.sql) — `materialized='incremental'`, `dist='date'`, `sort=['date','site']`: unmistakably a native table.

## Do this

1. Open `dbt_project.yml`, delete `+bind: false` in your head, and predict the exact error. Then read the comment above it and check you were right.
2. Trace one table end to end: `silver.sap.zsdcc` (S3 Tables) → mirror registration in `s3_tables.py` → `silver_external.sap_zsdcc` → `stg_sap_zsdcc` (late-binding view) → `gold.unified_sales` (native). Say out loud where Spectrum stops.
3. In Redshift, run `EXPLAIN` on a query against `stg_sap_zsdcc` and on one against `gold.unified_sales`. Only one plan mentions S3.

## You've got it when you can…

…answer "is Spectrum still involved?" with **"for Silver yes, for Gold no, and the boundary is the dbt build"** — and then point at two independent pieces of evidence in the repo that prove it (`+bind: false`, and the `s3tables:GetTableData` vs raw `s3:` split in IAM).
