# Module 1 — Foundations
### "What all these words mean, and what we actually built with them"

> **Status:** PLAN — for review before slide production.
> **Audience:** 10 application developers. Strong coders (Java/C#/JS/Python), **zero** data-engineering, lakehouse, warehouse or SQL-analytics background.
> **Format:** every lesson = 1 concept slide (per [`../LECTURE-STYLE.md`](../LECTURE-STYLE.md)) + live repo walk + a check-for-understanding.
> **Duration:** **16 hours** of the 40 (Module 2 = deep architecture, Modules 3+ = build).
> **Why this order:** nothing is introduced before the problem it solves. Every abstraction is earned.

---

## 1. What they can do at the end of Module 1

1. Explain **why a lakehouse exists** — and when a plain database would have been fine.
2. Correctly use the words **catalog / table format / storage / engine** — and not confuse them.
3. Read the **medallion layers** (raw → bronze → silver → gold) and say *what changes at each hop and why*.
4. Explain **Iceberg** (snapshots, MERGE, schema evolution) and what **S3 Tables** adds on top.
5. Explain **how Redshift reads data it does not own** — Spectrum → Glue Catalog → Iceberg → S3 Tables — and **where Spectrum stops being involved**.
6. Trace **one real row** from SAP through our pipeline to a Power BI number.
7. Open **any file in this repo** and say which layer it belongs to and what it does.
8. Take the **same architecture to the next engagement** (retail/apparel, 8 Oracle sources) and know what changes and what doesn't.

---

## 2. Shape of the module

| Part | Theme | Lessons | Hrs |
|---|---|---|---|
| **A** | Why we're here — the problem & the map | 1–4 | 3 |
| **B** | The storage stack — files, tables, catalogs | 5–9 | 4 |
| **C** | The engines — who computes and who queries | 10–14 | 4 |
| **D** | **How WE applied it** — our pipeline, hop by hop | 15–21 | 4 |
| **E** | Bridge to the next project (8 Oracle sources) | 22 | 1 |
| | | **22 lessons** | **16** |

---

## PART A — Why we're here (3 hrs)

### L01 · From App Database to Analytics — why your OLTP database can't do this
- **Objective:** feel the problem before meeting the solution.
- **Concepts:** OLTP vs OLAP · row-store vs column-store · why `SELECT SUM(sales) GROUP BY store` over 1.4 B rows kills a transactional DB · why you don't report off production.
- **Hook for app coders:** "You've all written `SELECT * FROM orders WHERE id = ?`. Today we ask for *every* order, ever, grouped six ways — and the database dies. That's the whole reason this job exists."
- **Repo anchor:** the row counts we actually handle — `ZHOCIDC` 1.38 B, `S611` 638 M, `S603` 649 M.
- **Plain English:** OLTP is a filing clerk; OLAP is an auditor.

### L02 · Data Lake vs Warehouse vs Lakehouse — and which one we built
- **Concepts:** lake (cheap, dumb files) · warehouse (fast, strict, expensive) · lakehouse (files + table smarts + engines) · the trade-off table.
- **Repo anchor:** why Tamimi = lakehouse: S3 Tables (lake economics) + Redshift (warehouse speed) + Iceberg (the glue).
- **Plain English:** lake = a folder of files; warehouse = a locked, indexed database; lakehouse = the folder that behaves like the database.

### L03 · The Medallion Architecture — raw, bronze, silver, gold
- **Concepts:** why 4 layers, not 1 · each layer's *contract* · "never transform on the way in" · reprocessability.
- **Table to memorise:**
  | Layer | Contains | Rule |
  |---|---|---|
  | Raw | byte-for-byte source dump | never edited, replayable |
  | Bronze | typed, deduplicated, 1:1 with source | no business logic |
  | Silver | cleansed, conformed, derived | business rules live here |
  | Gold | star-schema facts + dims for BI | shaped for the question |
- **Repo anchor:** `bronze.sap.zsdcc` → `silver.sap.zsdcc` → `gold.unified_sales`.
- **Plain English:** raw = the photo of the receipt; bronze = typed into the system; silver = cleaned and standardised; gold = the report line.

### L04 · The 10,000-ft Map of What We Built
- **Concepts:** one slide, whole platform: SAP/NCR → P1 → raw S3 → P2 → Bronze → transform → Silver → dbt → Gold(Redshift) → Power BI, with control plane + orchestration alongside.
- **Purpose:** the map they'll return to for 40 hours. Everything later is a zoom into one box.
- **Slide:** ✅ *high priority — this is the module's spine.*

---

## PART B — The storage stack (4 hrs)

### L05 · Files: CSV vs Parquet — why columnar changes everything
- **Concepts:** row vs columnar layout · compression · predicate pushdown · column pruning · why 638 M rows is fine in Parquet and fatal in CSV.
- **Demo:** same data, both formats — size + scan time.
- **Plain English:** CSV stores rows like handwritten lines; Parquet stores columns like sorted spreadsheets — so reading one column is cheap.

### L06 · What a "Table Format" Actually Is — the problem Iceberg solves
- **Concepts:** a folder of Parquet is *not* a table (no atomicity, no schema, no updates) · metadata layer · manifests · snapshots.
- **Plain English:** Iceberg is the *table of contents* that turns a pile of files into a table.

### L07 · Apache Iceberg — snapshots, MERGE, time travel, schema evolution
- **Concepts:** immutable data files + snapshot pointer · `MERGE INTO` (upsert) · time travel · safe schema change · why deletes are hard on a lake.
- **Repo anchor:** [`src/glue/glue_engine/writers/s3_tables.py`](../../../tamimi-lakehouse/src/glue/glue_engine/writers/s3_tables.py) — `merge_into` / `append` / `full_refresh` / `expire_snapshots`.
- **Plain English:** every write makes a new "version of the table of contents" — that's how you get rollback and safe concurrent reads.

### L08 · Amazon S3 Tables — AWS-managed Iceberg
- **Concepts:** what AWS takes over (compaction, snapshot maintenance, the physical bucket) · table buckets & namespaces · what you give up.
- **Repo anchor:** `infra/modules/s3-data-lake/main.tf:11,30` — bronze + silver table buckets.
- **Plain English:** Iceberg you run yourself vs Iceberg as a service.

### L09 · Catalog vs Table Format vs Storage ✅ **SLIDE BUILT**
- **Status:** ✅ [`L03-catalog-storage.png`](L03-catalog-storage.png) — *renumber to L09.*
- **Concepts:** Glue Data Catalog · federated `s3tablescatalog` · why "no Glue Crawlers" · what the catalog does and doesn't hold.
- **Repo anchor:** `infra/modules/catalog_federation/`.

---

## PART C — The engines (4 hrs)

### L10 · Spark & AWS Glue — why not just a Python script
- **Concepts:** distributed compute · partitions/executors · lazy evaluation · shuffles · when Spark is the wrong tool.
- **Repo anchor:** `src/glue/glue_engine/` — our spec-driven engine; a Glue job = a Spark cluster for 10 minutes.
- **Plain English:** one machine reading 638 M rows = a week; 40 machines = 11 minutes. Spark is the foreman.

### L11 · Redshift Serverless — the warehouse that serves the answers
- **Concepts:** MPP · columnar storage · RPU/auto-scaling · dist/sort keys · why Gold lives *inside* Redshift, not on the lake.
- **Repo anchor:** `infra/modules/redshift-serverless/`, `dist='date'` in the dbt Gold models.

### L12 · **Redshift Spectrum — reading data Redshift doesn't own** ⭐
- *(Explicitly requested — the subtle one. Give it a full lesson.)*
- **Concepts:** what Spectrum is (query layer over external data) · `CREATE EXTERNAL SCHEMA … FROM DATA CATALOG` · external table vs native table · where the compute happens · cost model.
- **Repo anchor:** [`jobs/_scripts/run_dbt.py`](../../../tamimi-lakehouse/src/glue/glue_engine/jobs/_scripts/run_dbt.py) — the literal `CREATE EXTERNAL SCHEMA silver_external FROM DATA CATALOG DATABASE … IAM_ROLE …`.

### L13 · **Spectrum → Iceberg → S3 Tables: the actual read path** ⭐ *(answers "is Spectrum still involved?")*
- **The answer to teach, precisely:**
  - **YES for Silver.** Redshift reads Silver Iceberg tables **in place** via Spectrum: Redshift → Glue catalog → Iceberg metadata → `s3tables:GetTableData`. Nothing is copied.
    - ⚠️ **Accuracy correction (verified in code, 2026-08-11):** Spectrum **hardcodes `catalogId=<account>`**, so the federated sub-catalog `s3tablescatalog` is *not* directly reachable. The Glue writer therefore **re-registers each Iceberg table into a mirror database** (`silver_dev`) in the default catalog after every write. Teach the mirror DB, not a direct federated read — see `run_dbt.py` (the deliberate "we do NOT pass CATALOG_ID" note), `catalog_federation/main.tf` header, and the `mirror_database`/`mirror_table_name` arguments in `writers/s3_tables.py`.
  - **NO for Gold.** dbt materialises Gold as **native Redshift tables**. Once a row is in Gold, Spectrum is out of the picture — Power BI queries native storage. *That's why Gold is fast.*
  - **The dividing line is the dbt build.** Spectrum's job is to feed dbt; dbt's output is native.
- **Concepts:** IAM path (`s3tables:GetTableData` vs raw `s3:GetObject`) · why Glue's writer needs `s3:*` on the managed bucket but Spectrum does not · Lake Formation grants at the catalog level.
- **Slide:** ⭐ *high priority — this is the concept most likely to be misunderstood.*
- **Plain English:** Spectrum lets Redshift read someone else's filing cabinet. dbt photocopies what it needs into Redshift's own cabinet — after that, no more trips.

### L14 · dbt — SQL as engineered code
- **Concepts:** models = one `SELECT` · `ref()` and the DAG · materializations (view/table/incremental) · tests · why analysts' SQL becomes reviewable software.
- **Repo anchor:** `src/dbt/models/` — staging → gold → reporting.
- **Plain English:** dbt is `make` for SQL.

---

## PART D — How WE applied it, hop by hop (4 hrs) ← *the heart of the module*

### L15 · Spec-Driven Design — one engine, N YAML files ⭐
- **Concepts:** why we did **not** write one job per table · the spec as contract/meta-design · config vs code · adding a new table = a YAML file, not a deployment.
- **Repo anchor:** `src/glue/specs/{download,bronze,transform}/*.yaml` + `glue_engine/spec.py` (Pydantic validation).
- **Show:** one spec end-to-end — `schema`, `watermark_column`, `merge_key`, `jdbc_hash_partitions`.
- **Plain English:** the engine is the printer; the YAML is the document.

### L16 · SAP → RAW S3 (P1 `source_download`) — "what lands, and why untouched"
- **Concepts:** why raw exists at all (replay, audit, parity) · full load vs windowed · JDBC partitioned reads · `_SUCCESS` markers · MANDT client filter.
- **What changes at this hop:** **nothing** — byte-for-byte, only landed and partitioned by cycle.
- **Repo anchor:** `jobs/source_download.py`, `sources/sap_hana.py`, `writers/raw_landing.py`.

### L17 · RAW → BRONZE (P2 `bronze_pull`) — "typed, deduplicated, idempotent"
- **Concepts:** why P1/P2 are split (never re-hit SAP) · Iceberg `MERGE` on `merge_key` · why replays don't duplicate · watermarks + CDC.
- **What changes:** types applied, duplicates collapsed on the natural key, audit columns added (`_run_id`, `_ingested_at`). **No business logic.**
- **War story:** `bronze.sap.zncr01` held 446,611 rows vs 438,645 at source until `merge_key` upsert replaced append.
- **Repo anchor:** `jobs/bronze_pull.py`, `writers/s3_tables.py`.

### L18 · BRONZE → SILVER — "cleansed, conformed, and the ABAP rebuild"
- **Concepts:** conforming (naming, units, keys) · why derived objects are **rebuilt, not pulled** · re-implementing SAP ABAP in PySpark.
- **What changes:** business rules applied; SAP QuickViews/extractors reproduced (`zsdcc = ZDSALES ⋈ TVKMT`, the ZHOCIDC basket state machine).
- **Trap to teach:** the TVKMT language fan-out — joining without `SPRAS='E'` silently **doubles** every sales row.
- **Repo anchor:** `jobs/bronze_to_silver.py`, `glue_engine/abap/`, `specs/transform/*.yaml`.

### L19 · SILVER → GOLD (dbt on Redshift) — "shaped for the question"
- **Concepts:** star schema (facts + conformed dims) · incremental `merge` · the `scenario` column (CY/PY/Budget) · pushing DAX into SQL.
- **What changes:** business semantics — one row per (site × date × dept × scenario); measures precomputed.
- **Trap to teach:** the synthetic `'All Dept'` row — sum across dept without excluding it and every KPI **doubles** (a real bug we found).
- **Repo anchor:** `src/dbt/models/marts/gold/unified_sales.sql`.

### L20 · GOLD → Power BI — the last mile
- **Concepts:** reporting views · DirectQuery vs import · why measures moved from DAX to SQL · the 07:00 KSA SLA.
- **Repo anchor:** `src/dbt/models/marts/reporting/vw_*.sql`.

### L21 · Orchestration & the Control Plane — what runs it all
- **Concepts:** EventBridge cron → dispatcher → Step Functions → Glue · **barriers/gates** between phases · idempotency & retries · the control-plane tables (`runs`, `watermarks`, `pipeline-state`, `lineage_edges`) · how the ops console reads them.
- **Repo anchor:** `src/lambdas/*_barrier/`, `src/shared/control_plane/`.
- **Plain English:** barriers are `await Promise.all()` for data pipelines.

---

## PART E — Bridge (1 hr)

### L22 · Same Architecture, New Client — retail/apparel with 8 Oracle sources
- **Purpose:** prove the architecture is portable — this is the project these 8 engineers are heading to.
- **What stays identical:** medallion layers · raw-first · spec-driven engine · merge-key idempotency · barriers · dbt Gold · the control plane.
- **What changes:** connector (`sap_hana` → an Oracle JDBC source class) · watermark columns · MANDT filter drops away · dimensional model reflects apparel retail (style/colour/size/season instead of AAGM dept).
- **Exercise:** given one Oracle table, the class writes the `download` + `bronze` spec YAML.
- **Slide:** side-by-side — Tamimi (SAP) vs New Client (Oracle ×8), same skeleton.

---

## 3. Slides to produce for Module 1

| Priority | Lessons | Note |
|---|---|---|
| ✅ Built | L09 | catalog/storage — renumber |
| ⭐ Tier 1 | **L04** (the map), **L13** (Spectrum→Iceberg→S3 Tables), **L15** (spec-driven), **L03** (medallion) | the four that carry the module |
| Tier 2 | L01, L02, L07, L10, L12, L16–L20 | one slide each |
| Tier 3 | L05, L06, L08, L11, L14, L21, L22 | one slide each |

**~22 slides.** Suggest building Tier 1 first (4 slides) — you review, we then batch Tier 2 + 3.

## 4. Per-lesson delivery pattern (keeps 16 hrs consistent)
1. **Slide** (5 min) — the concept, in our format.
2. **Repo walk** (10 min) — open the actual file on screen.
3. **Do it** (20 min) — run/read/modify something small.
4. **Check** (5 min) — one question they must answer out loud.
5. **Trap** — where relevant, the real bug we hit (the doubling bugs land hardest).

## 5. Decisions I need from you
1. **16 hrs / 22 lessons for Module 1** — right split against the 40, or compress?
2. **Numbering** — renumber the built slide to `L09`, or keep slide numbers independent of lesson numbers?
3. **Hands-on depth** — do they get **AWS console read access + a Dev Redshift login** to run queries live? Changes the lab design substantially.
4. **The next client** — can I see the 8 Oracle sources / their data model, so L22 is real rather than generic?
5. **Build order** — Tier 1 (4 slides) first for review, or all 22 in one pass?
