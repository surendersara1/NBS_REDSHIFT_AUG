# L12 · Reading Data Redshift Doesn't Own

**Slide:** [`_render/L12-redshift-spectrum.html`](_render/L12-redshift-spectrum.html)

## The point

Redshift can query data it does not store. That capability is called **Redshift Spectrum**, and it is the only reason our Gold build can read the Silver lake without a copy step. You register an *external schema* that points at a Glue Data Catalog database; from then on, `silver_external.sap_zsdcc` behaves like a table in every SQL statement you write — but the bytes never leave S3.

## Key ideas

- **Native table** = Redshift owns the bytes (its own managed, sorted, dist-keyed storage). **External table** = Redshift owns only a pointer plus a schema; the files stay in S3. Dropping an external table deletes zero data.
- The schema for an external table comes from the **Glue Data Catalog**, not from Redshift. Redshift never learned the columns — it looked them up.
- `CREATE EXTERNAL SCHEMA … FROM DATA CATALOG DATABASE '<db>' IAM_ROLE '<role>'` mounts an entire catalog database in one statement. It is idempotent with `IF NOT EXISTS`, so our runner re-issues it on every build.
- **Compute is split.** The scan/filter/project happens on an AWS-managed Spectrum fleet outside your workgroup; only surviving rows come back to your RPUs, which do the joins and the final aggregate. Push predicates down or Spectrum reads everything.
- **Cost model differs.** Native scans are paid for in RPU-seconds you're already burning. Spectrum is billed **per byte scanned in S3** — so Parquet, column pruning and partition pruning are money, not style.
- Nine models selecting from the same external-backed staging view means **nine Spectrum scans**. Materialise once, read many times.
- We deliberately do **not** pass `CATALOG_ID`: Spectrum hardcodes `catalogId=<account>` regardless (CloudTrail-confirmed 2026-05-18), which is why we mount a default-catalog database rather than the federated one.

## Words you'll hear

| Word | What it means here |
|---|---|
| Spectrum | Redshift's query layer over data stored outside Redshift |
| External schema | A Redshift schema whose table definitions come from Glue |
| External table | A table Redshift can read but does not store or own |
| Native table | A table in Redshift's own managed storage |
| Predicate pushdown | Sending the `WHERE` to the scanner so fewer bytes come back |
| Bytes scanned | The Spectrum billing unit — not rows, not queries |

## In this repo

- [`src/glue/glue_engine/jobs/_scripts/run_dbt.py:151-155`](../../../tamimi-lakehouse/src/glue/glue_engine/jobs/_scripts/run_dbt.py) — the literal `CREATE EXTERNAL SCHEMA IF NOT EXISTS silver_external FROM DATA CATALOG DATABASE … IAM_ROLE …` we issue before every dbt build, via the Redshift Data API.
- Same file, `:110-147` — the docstring explaining *why* the Data API and not `redshift_connector` (socket timeout during a 30–90 s Lake Formation / Glue resolution), and `:144-146` on omitting `CATALOG_ID`.
- [`infra/modules/catalog_federation/main.tf`](../../../tamimi-lakehouse/infra/modules/catalog_federation/main.tf) — the mirror databases Spectrum actually reaches.

## Do this

1. Open `run_dbt.py`, find `_ensure_silver_external_schema`, and read the SQL string it builds. Note that the schema name is hard-coded and the database name is an argument.
2. In Redshift, run `SELECT * FROM svv_external_schemas;` then `SELECT * FROM svv_external_tables WHERE schemaname = 'silver_external';` — confirm the tables exist with no data in Redshift.
3. Run `SELECT count(*) FROM silver_external.sap_zsdcc;` and then the same against `gold.unified_sales`. Compare the query plans (`EXPLAIN`) — spot the `S3 Seq Scan`.

## You've got it when you can…

…explain, without notes, what physically happens between `SELECT … FROM silver_external.sap_zsdcc` and rows appearing — which component holds the schema, which component reads the bytes, which component does the join, and who gets the bill.
