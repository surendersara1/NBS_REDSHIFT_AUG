# Module 0 — Basics: The Ecosystem, Decoded
### "What each word means, which service does it, who can read it, who can write it, and how data actually gets there"

**23 hours · 34 lessons · no prerequisites.**
Plan: [`MODULE-00-PLAN.md`](MODULE-00-PLAN.md) · Format: [`../LECTURE-STYLE.md`](../LECTURE-STYLE.md) · One-file deck: **[`Module-00-Basics.pdf`](Module-00-Basics.pdf)**

> **Start here.** This module is the floor everything else stands on. It assumes no analytics, warehousing or AWS data-stack background whatsoever — only that you can code.
> By the end, you can point at any box on an AWS analytics diagram and say what it does, what it can read, what it can write, and when you would not use it.

Each lesson: **WHAT IT IS → HOW IT WORKS → WHEN TO USE / WHEN NOT → IN PRACTICE**, plus a plain-English line. Take-homes end with a **checklist** and a "you've got it when you can…".

---

## Part A — The four words (4 hrs)

| # | Lesson | Slide | Notes |
|---|---|---|---|
| L01 | Four Words For Where Data Lives | `L01-four-words.png` | [md](L01-four-words.md) |
| L02 | The Data Warehouse | `L02-data-warehouse.png` | [md](L02-data-warehouse.md) |
| L03 | The Data Lake | `L03-data-lake.png` | [md](L03-data-lake.md) |
| L04 | The Lakehouse ⭐ | `L04-lakehouse.png` | [md](L04-lakehouse.md) |
| L05 | Data Mesh Is Not A Product | `L05-data-mesh.png` | [md](L05-data-mesh.md) |
| L06 | So Which One Do You Need? | `L06-which-one.png` | [md](L06-which-one.md) |

## Part B — Warehouse design patterns, built in Redshift (4 hrs)

| # | Lesson | Slide | Notes |
|---|---|---|---|
| L07 | Facts, Dimensions and Grain ⭐ | `L07-dimensional-modelling.png` | [md](L07-dimensional-modelling.md) |
| L08 | When A Dimension Changes | `L08-slowly-changing-dimensions.png` | [md](L08-slowly-changing-dimensions.md) |
| L09 | Three Schools Of Warehouse Design | `L09-three-schools.png` | [md](L09-three-schools.md) |
| L10 | Creating Tables In Redshift | `L10-building-in-redshift.png` | [md](L10-building-in-redshift.md) |
| L11 | Getting Rows In, Correctly | `L11-loading-a-warehouse.png` | [md](L11-loading-a-warehouse.md) |
| L12 | Materialized Views | `L12-materialized-views.png` | [md](L12-materialized-views.md) |

## Part C — Who can read, who can write (4 hrs)

| # | Lesson | Slide | Notes |
|---|---|---|---|
| L13 | Everything That Touches Redshift ⭐ | `L13-participation-matrix.png` | [md](L13-participation-matrix.md) |
| L14 | Getting Data In | `L14-getting-data-in.png` | [md](L14-getting-data-in.md) |
| L15 | Getting Data Out Again | `L15-getting-data-out.png` | [md](L15-getting-data-out.md) |
| L16 | Reading Without Copying | `L16-reading-without-copying.png` | [md](L16-reading-without-copying.md) |
| L17 | Who Is Actually Allowed | `L17-permissions.png` | [md](L17-permissions.md) |
| L18 | Copy It, Or Point At It? ⭐ | `L18-copy-or-point.png` | [md](L18-copy-or-point.md) |

## Part D — Pipelines: getting data in from many sources (5 hrs)

| # | Lesson | Slide | Notes |
|---|---|---|---|
| L19 | Eight Kinds Of Source | `L19-source-taxonomy.png` | [md](L19-source-taxonomy.md) |
| L20 | Six Ways To Move Data ⭐ | `L20-six-ways-to-move-data.png` | [md](L20-six-ways-to-move-data.md) |
| L21 | Zero-ETL: No Pipeline At All ⭐ | `L21-zero-etl.png` | [md](L21-zero-etl.md) |
| L22 | Change Data Capture | `L22-cdc-and-dms.png` | [md](L22-cdc-and-dms.md) |
| L23 | Streaming, Honestly | `L23-streaming.png` | [md](L23-streaming.md) |
| L24 | Eight Sources, One Platform | `L24-many-sources-one-platform.png` | [md](L24-many-sources-one-platform.md) |
| L25 | Making It Run In Order | `L25-orchestration.png` | [md](L25-orchestration.md) |

## Part E — S3, the federated catalog, and query engines (4 hrs)

| # | Lesson | Slide | Notes |
|---|---|---|---|
| L26 | S3 Is Not A Filesystem | `L26-s3-as-a-platform.png` | [md](L26-s3-as-a-platform.md) |
| L27 | Hot Data, Cold Data ⭐ | `L27-hot-and-cold.png` | [md](L27-hot-and-cold.md) |
| L28 | Two Different Things Called "Format" | `L28-file-and-table-formats.png` | [md](L28-file-and-table-formats.md) |
| L29 | The Catalog Is Now Federated ⭐ | `L29-federated-catalog.png` | [md](L29-federated-catalog.md) |
| L30 | Athena Also Writes | `L30-athena-read-and-write.png` | [md](L30-athena-read-and-write.md) |
| L31 | One Query, Three Systems | `L31-external-schemas.png` | [md](L31-external-schemas.md) |

## Part F — Putting it together (2 hrs)

| # | Lesson | Slide | Notes |
|---|---|---|---|
| L32 | The Whole Thing, On One Slide ⭐ | `L32-reference-architecture.png` | [md](L32-reference-architecture.md) |
| L33 | The Whole AWS Analytics Stack ⭐ | `L33-ecosystem-map.png` | [md](L33-ecosystem-map.md) |
| L34 | The Cost And Latency Ladder | `L34-cost-and-latency-ladder.png` | [md](L34-cost-and-latency-ladder.md) |

---

## The four slides to print and put on the wall

- **L13** — the participation matrix: every path in and out of Redshift
- **L20** — six ways to move data: the design-review decision table
- **L32** — the reference architecture: the whole platform in five columns
- **L33** — the ecosystem map: eight groups, "use this when" on each service

## Where this module changes an Apparel Group decision

| Lesson | What it opens up |
|---|---|
| **L21** | Zero-ETL now supports **self-managed Oracle → Redshift**. Three of the eight sources are Oracle. This is a real alternative to hand-built JDBC, with real limits attached. |
| **L29** | Oracle can be **mounted as a federated catalog** rather than ingested — a third option for reference and lookup data. |
| **L18** | The framework for deciding between those two and a full Glue pipeline — **per source and per table**, not once for the platform. |

## Facts verified against live AWS documentation

Checked while building this module (2026-08-11). Cite these; do not paraphrase from memory:

- Glue Data Catalog is a **three-level `catalog.database.table`** hierarchy with nested catalogs; **managed** vs **federated** catalogs; federated sources include Redshift, DynamoDB, DocumentDB, MySQL, PostgreSQL, SQL Server, **Oracle**, Aurora, BigQuery, Snowflake, Azure SQL
- Lake Formation grants at **catalog / database / table / column**, enforced across engines; lakehouse identifiers are **lowercase**
- Zero-ETL sources include **DynamoDB, Oracle@AWS, SAP OData, Salesforce, ServiceNow, Zendesk, Zoho, Meta Ads**, and self-managed **Oracle / SQL Server / MySQL / PostgreSQL** via DMS; targets are **Redshift, S3, S3 Tables, RMS**; self-managed sources → **Redshift only**; SaaS sources have a **1-hour minimum latency**
- **Redshift streaming ingestion** = a materialized view on Kinesis/MSK/Kafka/Confluent with **no S3 staging**, `AUTO REFRESH`
- **Firehose** delivers to **Iceberg tables including S3 Tables** with insert/update/delete routing; throughput trades against open partitions; Firehose → Redshift stages to S3 then `COPY`
- **Datashares support write access** via `authorize-data-share --allow-writes`
- Redshift **federated query** reaches RDS/Aurora **PostgreSQL and MySQL**, with predicate pushdown
- **Athena writes** via CTAS and `INSERT INTO`; Iceberg gets full DML and time travel; **100 partitions per statement**; two federated connector types, only the **Glue-connection** type supports Lake Formation
- **Spectrum reads** Iceberg, Hudi CoW and Delta (symlink manifests); MVs on external tables support incremental maintenance

> ⚠️ **Re-verify before teaching:** Spectrum's `INSERT INTO` external-table write support and limits (L31), and the governance-catalog product naming — SageMaker Lakehouse / Unified Studio / DataZone (L05, L29, L33). Both are flagged on the slides themselves.

## Teaching rhythm

1. **Slide** (5 min) — what it is.
2. **Walk the mechanism** (15 min) — the HOW IT WORKS zone, on screen.
3. **Apply it** (20 min) — against a real Apparel Group source or a Dev-account query.
4. **Checklist** (5 min) — from the take-home.

Parts B, C and E are dramatically better as **labs** than as lectures if the group has Dev-account access.

## Rebuild

```bash
cd lectures
python render_slides.py Module-00-Basics   # PNGs + canvas/box overflow + webfont gate
python make_pdf.py     Module-00-Basics    # one wide 16:9 PDF
```

Current status: **34 slides, 34 take-homes, 0 QA defects.**
