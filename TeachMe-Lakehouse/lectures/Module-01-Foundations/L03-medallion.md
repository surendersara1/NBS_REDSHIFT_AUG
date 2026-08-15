# L03 · The Four Layers — and What Changes at Each
> **Module 1 · Lesson 03** · ~45 min · slide: `L03-medallion.png`

## The point
Data moves through four layers, and **each hop has exactly one job**. Doing two jobs in one hop is how pipelines become unmaintainable.

## Key ideas
- **Raw** — byte-for-byte from the source. Never edited, never deleted. It exists so you can *replay* anything.
- **Bronze** — the same data, typed and deduplicated. Iceberg `MERGE` on the primary key. **No business logic.**
- **Silver** — cleansed and conformed. Business rules live here; source logic (SAP ABAP) is rebuilt in PySpark.
- **Gold** — star schema, aggregated to the grain the report asks for. Lives *inside* Redshift as native tables.
- **The discipline:** if you can't say which layer a transformation belongs in, you don't understand it yet.
- Layers are **cheap** (S3) until Gold, which is **fast** (Redshift). That trade is deliberate.
- Every layer is reproducible from the one before it — so a bug is fixed by reprocessing, not by patching data.

## Words you'll hear
| Term | Means |
|---|---|
| Medallion | The raw→bronze→silver→gold layering pattern |
| Conform | Make different sources agree on names, units and keys |
| Grain | What one row represents (e.g. *one site, one day, one dept*) |
| Star schema | One fact table surrounded by dimension tables |
| Replay | Rebuild a layer from the layer before it |

## In this repo
- `src/glue/glue_engine/jobs/source_download.py` — writes **Raw**
- `src/glue/glue_engine/jobs/bronze_pull.py` — Raw → **Bronze**
- `src/glue/glue_engine/jobs/bronze_to_silver.py` + `glue_engine/abap/` — Bronze → **Silver**
- `src/dbt/models/marts/gold/unified_sales.sql` — Silver → **Gold**

## Do this
Open `bronze_pull.py` and `unified_sales.sql` side by side. List three things Gold does that Bronze deliberately does *not*.

## You've got it when you can...
Take any transformation — "convert SAR to USD", "drop test stores", "add a department name" — and say which layer it belongs in, and why.
