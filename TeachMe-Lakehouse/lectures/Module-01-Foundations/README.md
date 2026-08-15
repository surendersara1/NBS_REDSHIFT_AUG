# Module 1 — Foundations
### "What all these words mean, and what we actually built with them"

**16 hours · 22 lessons · 10 application developers, zero data-engineering background.**
Plan: [`MODULE-01-PLAN.md`](MODULE-01-PLAN.md) · Format spec: [`../LECTURE-STYLE.md`](../LECTURE-STYLE.md)

Each lesson = **one slide** (`L##-*.png`, 1920×1080, projector-ready) + **one take-home** (`L##-*.md`, half a page). Slide source lives in [`_render/`](_render/) and is re-renderable at any time.

---

## Part A — Why we're here (3 hrs)

| # | Lesson | Slide | Notes |
|---|---|---|---|
| L01 | Why Your App Database Can't Do This | `L01-oltp-vs-olap.png` | [md](L01-oltp-vs-olap.md) |
| L02 | Lake vs Warehouse vs Lakehouse | `L02-lake-warehouse-lakehouse.png` | [md](L02-lake-warehouse-lakehouse.md) |
| L03 | The Four Layers — and What Changes at Each | `L03-medallion.png` | [md](L03-medallion.md) |
| L04 | The Whole Platform on One Slide ⭐ | `L04-the-map.png` | [md](L04-the-map.md) |

## Part B — The storage stack (4 hrs)

| # | Lesson | Slide | Notes |
|---|---|---|---|
| L05 | Why Parquet, Not CSV | `L05-csv-vs-parquet.png` | [md](L05-csv-vs-parquet.md) |
| L06 | A Folder of Files Is Not a Table | `L06-what-is-a-table-format.png` | [md](L06-what-is-a-table-format.md) |
| L07 | Apache Iceberg — snapshots, MERGE, time travel | `L07-apache-iceberg.png` | [md](L07-apache-iceberg.md) |
| L08 | Amazon S3 Tables — managed Iceberg | `L08-s3-tables.png` | [md](L08-s3-tables.md) |
| L09 | Where the Data Actually Lives ⭐ | `L09-catalog-storage.png` | [md](L09-catalog-storage.md) |

## Part C — The engines (4 hrs)

| # | Lesson | Slide | Notes |
|---|---|---|---|
| L10 | Spark & Glue — why not just a Python script | `L10-spark-and-glue.png` | [md](L10-spark-and-glue.md) |
| L11 | Redshift Serverless — where answers live | `L11-redshift-serverless.png` | [md](L11-redshift-serverless.md) |
| L12 | Reading Data Redshift Doesn't Own | `L12-redshift-spectrum.png` | [md](L12-redshift-spectrum.md) |
| L13 | Is Spectrum Still Involved? ⭐⭐ | `L13-spectrum-iceberg-s3tables.png` | [md](L13-spectrum-iceberg-s3tables.md) |
| L14 | dbt — SQL as engineered code | `L14-dbt.png` | [md](L14-dbt.md) |

## Part D — How WE applied it, hop by hop (4 hrs) ← *the heart*

| # | Lesson | Slide | Notes |
|---|---|---|---|
| L15 | One Engine, N YAML Files ⭐ | `L15-spec-driven-design.png` | [md](L15-spec-driven-design.md) |
| L16 | SAP → RAW: land it, don't touch it | `L16-sap-to-raw.png` | [md](L16-sap-to-raw.md) |
| L17 | RAW → BRONZE: typed, deduped, idempotent | `L17-raw-to-bronze.png` | [md](L17-raw-to-bronze.md) |
| L18 | BRONZE → SILVER: cleansed, conformed, rebuilt | `L18-bronze-to-silver.png` | [md](L18-bronze-to-silver.md) |
| L19 | SILVER → GOLD: shaped for the question | `L19-silver-to-gold.png` | [md](L19-silver-to-gold.md) |
| L20 | The Last Mile: Gold → Power BI | `L20-gold-to-powerbi.png` | [md](L20-gold-to-powerbi.md) |
| L21 | What Actually Runs It | `L21-orchestration-control-plane.png` | [md](L21-orchestration-control-plane.md) |

## Part E — Bridge (1 hr)

| # | Lesson | Slide | Notes |
|---|---|---|---|
| L22 | Same Architecture, New Client — **Apparel Group** ⭐ | `L22-apparel-group-bridge.png` | [md](L22-apparel-group-bridge.md) |

---

## How to teach a lesson (same rhythm every time)
1. **Slide** — 5 min, the concept.
2. **Repo walk** — 10 min, open the actual file on screen.
3. **Do it** — 20 min, run/read/modify something small.
4. **Check** — 5 min, the question at the bottom of the take-home.
5. **Trap** — where relevant, the real bug we hit. *(The two doubling bugs — TVKMT `SPRAS` fan-out in L18, the `'All Dept'` row in L19 — land hardest.)*

## Where this is going
Tamimi Markets is the **worked example**. The destination is **Apparel Group** (12 weeks; workstreams: Data Foundation, Price Optimization, Inter-store Transfer, Amazon Quick) with 8 sources — Oracle RMS, Oracle SIM, Oracle XStore, Epsilon, MoEngage, Magento, Vemco and Irisys footfall. L22 makes that bridge explicit.

## Re-rendering slides
```bash
cd lectures
python render_slides.py Module-01-Foundations
```
Renders every `_render/L*.html` → `L*.png` and reports any slide with text overflowing the canvas.
