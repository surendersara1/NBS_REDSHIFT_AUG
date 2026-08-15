# Module 0 — Basics: The Ecosystem, Decoded
### "What each word means, which service does it, who can read it, who can write it, and how data actually gets there"

> **Status:** **BUILT** — 34 slides, 34 take-homes, 68-page PDF, 0 QA defects. See [`README.md`](README.md).
> This document is retained as the design rationale; §5 (Module 1 overlap) and §8 (course length) are still open decisions.
> **Audience:** 10 application developers. Strong coders. **No prior exposure to analytics, warehousing, or the AWS data stack.**
> **Position:** comes **before** Module 1.
> **Duration:** **34 lessons · 23 hours** (see §8 — this is bigger than v1 and needs a scheduling call).
> **Format:** per [`../LECTURE-STYLE.md`](../LECTURE-STYLE.md).
>
> **v2 changes:** the catalog lesson was written for the flat 2022 Glue Data Catalog and is wrong — the catalog is now a **three-level federated hierarchy** (Part E). "Who can read and write" was one lesson and is now a **six-lesson part** (Part C). Streaming and multi-source pipelines were one lesson each and are now **a full part** (Part D). Every claim below was checked against live AWS documentation on 2026-08-11; anything I could not confirm is marked ⚠️.

---

## 1. The problem this module solves

Ask ten app developers what a "data lake" is and you get ten answers, most of them "a database but bigger." They then meet a diagram with **S3, Glue, Athena, Redshift, Lake Formation, DMS, Kinesis, Firehose, Iceberg, RMS** on it and quietly stop asking questions.

By the end they can:

1. Define **warehouse / lake / lakehouse / mesh** precisely and say which problem each solves.
2. Name, for any service on the diagram, **what it does, what it can read, and what it can write**.
3. Design a **dimensional model** and build it in **Redshift**.
4. Choose among **six** ways to get data from a source into the platform — and defend the choice.
5. Explain **hot vs cold** and what getting it wrong costs.
6. Query across **warehouse + lake + live operational database in one statement**, and know when not to.

**Teaching rule:** every abstract term gets a named AWS service and a concrete example *in the same lesson*. No lesson ends on theory.

---

## 2. Shape

| Part | Theme | Lessons | Hrs |
|---|---|---|---|
| **A** | The four words — paradigms decoded | 1–6 | 4 |
| **B** | Warehouse design patterns, built in Redshift | 7–12 | 4 |
| **C** | **Who can read, who can write — the participation matrix** | 13–18 | 4 |
| **D** | **Pipelines: getting data in from many sources** | 19–25 | 5 |
| **E** | **S3, the federated catalog, and query engines** | 26–31 | 4 |
| **F** | Putting it together | 32–34 | 2 |
| | | **34** | **23** |

---

## PART A — The four words (4 hrs)

### L01 · Why This Is Confusing
Four names for where data lives, blurred deliberately by vendors. The four questions that actually separate them: **who writes the schema and when · who is allowed to read · what it costs per query · who owns it.**

### L02 · Data Warehouse
Schema-on-**write**. Curated, modelled, fast, expensive per TB. Built so the business can ask the same question twice and get the same answer. Columnar + MPP. **AWS: Amazon Redshift** (provisioned or Serverless), storing into **Redshift Managed Storage (RMS)** — a storage tier backed by S3 that scales to petabytes and lets compute and storage scale independently.

### L03 · Data Lake
Schema-on-**read**. Everything lands cheaply in raw form; meaning is applied later. Solves "we might need it one day," and creates the **data swamp** when nobody governs it. **AWS: S3 + Glue Data Catalog + Athena + Lake Formation.**

### L04 · Lakehouse
Lake economics, warehouse behaviour, bridged by an **open table format** (Iceberg / Hudi / Delta) that puts ACID transactions, schema and row-level updates on top of plain files. **AWS: S3 Tables (managed Iceberg) + Glue Catalog + Redshift + Athena + EMR.** *(This is what the Tamimi and Apparel Group platforms are.)*

### L05 · Data Mesh — an org pattern, not a product
**The most misused word of the four.** Mesh is about *ownership*: domain teams own their data as a **product**, with federated governance and self-serve infrastructure. You can build a mesh on a lakehouse; you cannot buy one.
**How AWS actually implements the sharing:**
- **Lake Formation cross-account sharing** over **AWS RAM** — **named-resource** or **tag-based (LF-TBAC)** grants, with table- and column-level control; consumers attach via **resource links**.
- **Redshift datashares** — producer/consumer containers sharing **live** data across clusters, accounts and Regions.
- **Federated catalogs** (Part E) so a domain's data appears in the central catalog without being copied.

### L06 · So Which One Do You Actually Need?
Decision table across cost, latency, skills, governance and team topology. **Honest answer to teach:** most organisations need a **lakehouse**; a **mesh** only pays off past a certain team count. Choosing mesh early buys ceremony, not capability.

## PART B — Warehouse design patterns, built in Redshift (4 hrs)

### L07 · Dimensional Modelling
Facts vs dimensions; **grain** ("one row = one …"); star vs snowflake; additive / semi-additive / non-additive measures; conformed dimensions. The most transferable skill in the module.

### L08 · Slowly Changing Dimensions
A store changes region — overwrite history or preserve it? **Type 1 / 2 / 3**, surrogate vs natural keys, effective-dating, and why Type 2 is the retail default.

### L09 · Kimball vs Inmon vs Data Vault
Bottom-up marts, top-down 3NF enterprise warehouse, hub/link/satellite. When each is right — and why most modern lakehouses are Kimball-shaped at the Gold layer.

### L10 · Building It in Redshift
Hands-on DDL: `CREATE TABLE`, **distribution styles** (KEY / EVEN / ALL / AUTO), **sort keys**, compression encodings, and the fact that PK/FK constraints are **informational only** — they inform the planner and do **not** enforce uniqueness. This surprises every SQL developer in the room.

### L11 · Loading a Warehouse
`COPY` from S3 (the bulk path), staging tables, `MERGE` for upserts, transaction boundaries, and why you never row-by-row `INSERT` into a warehouse. Vacuum/analyze and what maintenance survives in Serverless.

### L12 · Materialized Views — the warehouse's cache
Precomputed results, **AUTO REFRESH**, incremental vs full refresh, and MVs over **external data lake tables** (Spectrum) with incremental maintenance. Sets up L23 — the same object is also the landing point for streaming.

## PART C — Who can read, who can write (4 hrs) 🆕

*This is the part that answers "what services can read and write and participate in data in Redshift." Each lesson is a matrix plus the code that proves it.*

### L13 · The Participation Matrix ⭐ — the poster lesson
One slide, every service that touches Redshift, with **R / W / both** marked. This becomes the reference they photograph.

| Mechanism | In | Out | Notes |
|---|:--:|:--:|---|
| `COPY` (from S3, EMR, DynamoDB, remote host) | **W** | | the bulk load path |
| `INSERT` / `MERGE` / `CTAS` / `UPDATE` | **W** | | SQL DML |
| `UNLOAD` → S3 | | **R** | warehouse writing back to the lake |
| **Redshift Data API** | **W** | **R** | HTTP/SDK, no persistent connection — Lambda-friendly |
| JDBC / ODBC / Query Editor v2 | **W** | **R** | humans and BI |
| **Glue / Spark / EMR** Redshift connector | **W** | **R** | ETL both directions |
| **AWS DMS** (Redshift as target) | **W** | | full load + CDC |
| **Amazon Data Firehose** | **W** | | stages to S3, then issues `COPY` |
| **Redshift streaming ingestion** (Kinesis / MSK) | **W** | | MV on the stream, **no S3 staging** |
| **Zero-ETL integrations** | **W** | | managed replication, no pipeline |
| **Datashares** | **W**\* | **R** | \*write needs `--allow-writes` (L16) |
| **Spectrum** → S3 external tables | | **R** | Redshift reading the lake |
| **Federated query** → live RDS/Aurora | | **R** | Redshift reading an OLTP database |
| **Athena Redshift connector** | | **R** | Athena reading Redshift |
| **Glue federated catalog over Redshift** | | **R** | catalog engines read Redshift with LF governance |
| **QuickSight / Power BI / Tableau** | | **R** | consumption |
| **Redshift ML / SageMaker** | **W** | **R** | training reads, inference writes |
| **Lambda UDFs** | | ↔ | Redshift calling out mid-query |

### L14 · Getting Data In — the seven write paths
Walk each write path with its shape and when it's right: `COPY`, SQL DML, Data API, Spark connector, DMS, Firehose, streaming ingestion, zero-ETL. Latency, volume and operational cost side by side.

### L15 · Getting Data Out — and why UNLOAD matters
`UNLOAD` to S3/Parquet as the pattern for publishing gold data back to the lake so cheaper engines can read it; JDBC/ODBC; Data API for applications; BI connectivity; feeding SageMaker. The teaching point: **a warehouse that only lets people in through the front door becomes a bottleneck.**

### L16 · Reading Without Copying — Spectrum, federated query, datashares
Three zero-copy doors and their very different cost profiles.
- **Spectrum** — external tables over S3; reads Parquet/ORC/CSV/JSON/Avro and the transactional formats **Iceberg**, **Hudi Copy-on-Write**, and **Delta Lake** (via symlink manifests).
- **Federated query** — external schema onto live **RDS/Aurora PostgreSQL or MySQL**, with **predicate pushdown**.
- **Datashares** — live sharing across clusters/accounts/Regions. ✅ **Correction worth teaching explicitly: datashares are no longer read-only.** `authorize-data-share --allow-writes` lets a consumer `INSERT` and `UPDATE` on producer data.

### L17 · Permissions — who is *allowed*
The layered model, end to end. Redshift-side: users, groups, **roles**, schema ownership, `GRANT`, **row-level and column-level security**, IAM-based auth. Lake-side: **Lake Formation** fine-grained permissions at **catalog / database / table / column** level, enforced consistently across every engine that reads through the catalog. The **reader/writer separation pattern**: ETL role writes, BI role reads reporting views only.

### L18 · The Zero-Copy Decision
When to copy data in and when to point at it. A worked cost/latency comparison of the same question answered four ways — loaded table, Spectrum external table, federated query, datashare — and the rule of thumb they leave with.

## PART D — Pipelines: getting data in from many sources (5 hrs) 🆕

### L19 · Source Taxonomy
Eight kinds of source and what each demands: OLTP relational, mainframe/legacy, SaaS API, files/SFTP, streams/events, logs, third-party feeds, on-prem behind a VPN. Maps directly onto the **8 Apparel Group sources**.

### L20 · Six Ways to Move Data ⭐ — the decision table
| Mechanism | Service | Latency | Choose when |
|---|---|---|---|
| **Batch ETL** | Glue / EMR (Spark) | hours | transformation needed, big volumes, full control |
| **CDC replication** | **AWS DMS** | minutes | continuous replication, heterogeneous engines |
| **Zero-ETL** | managed integration | min → 1 hr | you want the table there with **no pipeline** |
| **Federated query** | Redshift / Athena | live | small lookups, no copy wanted |
| **Streaming** | Kinesis / MSK / Firehose | seconds | genuinely event-driven |
| **File transfer** | Transfer Family / DataSync / AppFlow | scheduled | SFTP drops, NAS sync, SaaS connectors |

### L21 · Zero-ETL in Depth ✅ *verified — and much broader than most people know*
Fully managed replication of transactional data **and schemas**, with **no ETL pipeline to build or maintain**.

**Sources**
- **AWS databases:** Aurora MySQL, Aurora PostgreSQL, RDS MySQL, **DynamoDB**, **Oracle Database@AWS (ODB)**
- **Self-managed databases (via DMS):** **Oracle, SQL Server, MySQL, PostgreSQL**
- **SaaS applications:** Salesforce, Salesforce Marketing Cloud Account Engagement, **SAP OData**, ServiceNow, Zendesk, Zoho CRM, Facebook Ads, Instagram Ads

**Targets**
- Amazon **Redshift** data warehouse
- **S3** general-purpose bucket · **S3 Tables** · **Redshift Managed Storage** — all three via the **SageMaker Lakehouse architecture**

**Limits that decide the design**
- ⚠️ Self-managed database sources can replicate **only to a Redshift data warehouse** — not to S3/S3 Tables/RMS.
- ⚠️ Application (SaaS) sources have a **minimum latency of 1 hour**.

> **This lesson matters more than any other in Part D for our situation.** Apparel Group's three biggest sources are **Oracle**, and zero-ETL now supports self-managed Oracle → Redshift. That is a direct, credible alternative to hand-building Glue JDBC pipelines, and the team should be able to argue it on the merits — including why we may still choose Glue (transformation control, medallion layering, cost at volume, targets other than Redshift).

### L22 · CDC and DMS in Depth
How change data capture actually works — reading the database's transaction log rather than querying tables. Full load + ongoing replication, task design, the schema-drift problem, and where CDC beats a watermarked batch pull. Contrast with the watermark approach Module 2 teaches.

### L23 · Streaming — the real options 🆕
- **Kinesis Data Streams** — durable ordered shards, multiple consumers.
- **Amazon MSK / Apache Kafka / Confluent Cloud** — the Kafka path.
- **Amazon Data Firehose** — managed delivery, no code. Destinations: **S3**, **Apache Iceberg tables** (self-managed **or S3 Tables**, with insert/update/delete **routing** from a single stream), **Redshift** (stages to S3, then `COPY`), OpenSearch, HTTP endpoints. ⚠️ Real trade-off to teach: **ingest throughput vs the number of Iceberg partitions written simultaneously.**
- **Redshift streaming ingestion** ✅ — a **materialized view mapped directly onto a Kinesis or Kafka stream**, refreshed from the stream **without staging in S3**, with `AUTO REFRESH`.
- **Managed Service for Apache Flink** / **Glue streaming ETL** — when you need windowing and stateful processing.
- **DynamoDB Streams**, **S3 Event Notifications**, **EventBridge** — event plumbing that triggers pipelines.

Honest closing note: **most retail analytics does not need streaming.** Batch is cheaper, simpler and easier to reason about. Teach it so they can recognise the 10% of cases that do.

### L24 · Many Sources, One Platform — the landing pattern
Heterogeneous sources into a single governed platform: landing zone conventions, per-source contracts, partition layout, idempotency, late-arriving data, and per-source isolation so one bad feed can't stall the rest.

### L25 · Orchestrating It
**Step Functions**, **MWAA (Airflow)**, **Glue workflows/triggers**, **EventBridge** schedules — what each is good at, and how dependencies, retries, backfills and alerting are expressed. Sets up Module 2's control-plane lessons.

## PART E — S3, the federated catalog, and query engines (4 hrs)

### L26 · S3 as a Data Platform
Objects, keys, prefixes; why "folders" aren't real; **partitioning** as a prefix convention; file-size economics and the small-file problem; consistency and versioning.

### L27 · Hot vs Cold — storage tiering ⭐
S3 storage classes (Standard → Standard-IA → **Glacier Instant Retrieval** → Flexible Retrieval → **Deep Archive**), Intelligent-Tiering, lifecycle rules. The trade the class actually encodes: **storage price vs retrieval price and latency.** Teaching point: **archiving data you still query is a cost increase, not a saving.** Worked retention design (90 days hot → IR at 90d → Deep Archive at 1y → expire at 7y).

### L28 · File Formats and Table Formats
Two different things people conflate. **File formats** — CSV / JSON / **Parquet** / ORC / Avro, and why columnar collapses scan cost. **Table formats** — **Iceberg / Hudi / Delta** — which add ACID, schema evolution, row-level updates and time travel on top of those files. Iceberg v2 delete files.

### L29 · The Federated Catalog ✅ *rewritten — the old flat-catalog framing is obsolete*
The Glue Data Catalog is no longer one flat list of databases. It is now a **three-level hierarchy: `catalog.database.table`**, with **nested catalogs** allowed to mirror the shape of the underlying sources.

**Two kinds of catalog:**
- **Managed catalog** — a catalog you create; the data is managed in **S3** or **Redshift Managed Storage (RMS)**.
- **Federated catalog** — **mounts an existing data source in place, without copying it.** Supported today: **Amazon Redshift, DynamoDB, DocumentDB, MySQL, PostgreSQL, SQL Server, Oracle, Aurora MySQL, Aurora PostgreSQL, Google BigQuery, Snowflake, Microsoft Azure SQL**, plus **S3 Tables** (`s3tablescatalog`).

This is the **SageMaker Lakehouse architecture**: S3 data lakes and Redshift warehouses unified into one catalog, queryable **in place by any Apache Iceberg-compatible engine**, with **Lake Formation** enforcing fine-grained permissions at **catalog / database / table / column** level across every engine. Permissions defined once apply everywhere.

⚠️ Practical gotcha to teach: the lakehouse architecture currently supports **lowercase** table, column and database identifiers — plan naming accordingly.
Also cover: crawlers vs declarative registration (and why mature platforms avoid crawlers), partitions, and partition projection.

### L30 · Athena — Read *and* Write ✅ *verified*
Serverless SQL over the catalog, priced **per TB scanned** — so partitioning and columnar formats are cost controls, not just speed. It is **not read-only**: **`CREATE TABLE AS SELECT`** and **`INSERT INTO`** both write, and **Iceberg tables get full DML plus time travel**. Limits: **100 partitions per CTAS/INSERT statement**; not supported for bucketed tables. Workgroups for cost governance.

**Athena federated query — two connector types, and the difference matters:**
- **Athena data catalog federated connector** — a **Lambda function in your account**; cannot be registered as a Glue federated catalog, so **no Lake Formation fine-grained control**.
- **Glue Data Catalog federated connector** — uses a **Glue connection**, registers as a federated catalog, and **does** support Lake Formation fine-grained governance. Prefer this one.

### L31 · External Schemas & Federated SQL ⭐
The unifying idea: **an external schema is a pointer, not a copy.** The doors compared side by side — **Spectrum** (Redshift reads S3 via the catalog), **Athena** (serverless engine over the same catalog), **Redshift federated query** (Redshift reads a live OLTP database), **Athena federated connectors** (Athena reads Redshift/DynamoDB/Snowflake). One query spanning warehouse + lake + operational database, then the cost and latency consequences of each door.

⚠️ **Verify before teaching:** whether/where Spectrum supports `INSERT INTO` an external table. Spectrum's read support is well documented; its write support is narrow and format-dependent. I will confirm and state the limits precisely rather than hand-wave.

## PART F — Putting it together (2 hrs)

### L32 · A Reference Architecture With Many Sources
Eight heterogeneous sources → landing → lake zones → warehouse → BI/ML, with the **AWS service named on every arrow**, the read/write boundary drawn, and governance, catalog and orchestration placed.

### L33 · The Ecosystem Map ⭐
One slide of the whole AWS analytics stack — **storage · catalog · compute · ingest · query · governance · orchestration · consumption** — each service tagged with a one-line *"use this when."* The poster they keep.

### L34 · Choosing Well — the cost & latency ladder
Every mechanism in the module placed on two axes: **freshness** and **cost**. Ends with the five questions to ask before adding anything to an architecture.

---

## 3. What we will build

| Artifact | Count |
|---|---|
| Slides `L##-*.png` — 1920×1080 | 34 |
| Take-homes `L##-*.md` | 34 |
| Editable sources `_render/L##-*.html` | 34 |
| Module index `README.md` | 1 |
| Wide 16:9 module PDF | 1 (68 pp) |

Slide zones for this module — explanatory, not prescriptive:
**1 · WHAT IT IS → 2 · HOW IT WORKS (named service, concretely) → 3 · WHEN TO USE / WHEN NOT → 4 · IN PRACTICE (runnable example or real config)** + the **IN PLAIN ENGLISH** strip.

Four lessons are **matrix slides** (L13, L20, L29, L33) and need a wider layout than the standard four-box grid — I'll extend the style spec with a full-width table variant rather than shrink type below the 17px floor.

## 4. Verified facts to cite (checked 2026-08-11)

| Claim | Status |
|---|---|
| Glue Data Catalog is a **three-level `catalog.database.table`** hierarchy with nested catalogs | ✅ |
| **Managed** catalogs (S3 or RMS) vs **federated** catalogs (mount in place) | ✅ |
| Federated catalog sources: Redshift, DynamoDB, DocumentDB, MySQL, PostgreSQL, SQL Server, **Oracle**, Aurora MySQL/PG, BigQuery, Snowflake, Azure SQL | ✅ |
| Lake Formation FGAC at catalog/database/table/column, enforced across engines | ✅ |
| Lakehouse requires **lowercase** identifiers | ✅ |
| Zero-ETL sources incl. **DynamoDB, Oracle@AWS, SAP OData, Salesforce, ServiceNow, Zendesk, Zoho, Meta Ads**, and self-managed **Oracle/SQL Server/MySQL/PostgreSQL** via DMS | ✅ |
| Zero-ETL targets: Redshift DW, **S3**, **S3 Tables**, **RMS** | ✅ |
| Self-managed sources → **Redshift DW only** | ✅ |
| SaaS zero-ETL **minimum latency 1 hour** | ✅ |
| Redshift **streaming ingestion** via MV on Kinesis/MSK/Kafka/Confluent, **no S3 staging**, AUTO REFRESH | ✅ |
| Firehose delivers to **Iceberg tables incl. S3 Tables**, with insert/update/delete routing; throughput ↔ active-partition trade-off | ✅ |
| Firehose → Redshift stages to S3 then issues `COPY` | ✅ |
| **Datashares support write access** via `authorize-data-share --allow-writes` | ✅ |
| Redshift federated query to RDS/Aurora **PostgreSQL and MySQL**, with predicate pushdown | ✅ |
| Athena writes via **CTAS** and **INSERT INTO**; Iceberg DML + time travel; **100 partitions/statement** | ✅ |
| Athena's **two** federated connector types; only the Glue-connection type supports Lake Formation FGAC | ✅ |
| Spectrum reads **Iceberg, Hudi CoW, Delta (symlink manifests)**; MVs on external tables with incremental maintenance | ✅ |
| S3 Tables: create with Athena or Spark; query with Athena, Redshift, Spark/EMR | ✅ |
| Spectrum **write** (`INSERT INTO` external table) support and limits | ⚠️ verify before L31 |
| Governance/catalog product naming (SageMaker Lakehouse / Unified Studio / DataZone) | ⚠️ re-check before L05, L29, L33 — this naming has moved recently |

## 5. Overlap with Module 1 — resolve before building ⚠️
Module 1 opens with two lessons that are now squarely Module 0 material:
- **M1 L01** "Why Your App Database Can't Do This" (OLTP vs OLAP) → **M0 L02 / L19**
- **M1 L02** "Lake vs Warehouse vs Lakehouse" → **M0 L02–L04**

**Recommendation:** retire both from Module 1 (22 → 20 lessons, 16 → ~14.5 hrs) and let Module 0 own the paradigms. Module 1 then starts where it is strongest — the medallion layers and the platform map.

## 6. What Module 0 deliberately does **not** cover
So the boundary is clear: no Spark internals, no dbt, no Terraform, no CI/CD, no watermark/CDC engine design, no ABAP conversion. Those are Modules 1 and 2. Module 0 stops at *"I know what each service is, what it can read and write, and how data gets from a source to a dashboard."*

## 7. Direct line to Apparel Group
Three Module 0 lessons change how they'll argue the new build:
- **L21 (zero-ETL)** — self-managed **Oracle → Redshift** with no pipeline is now a real option against three of their eight sources.
- **L29 (federated catalog)** — Oracle can be **mounted as a federated catalog** rather than ingested, for reference and lookup data.
- **L18 (zero-copy decision)** — gives them the framework to decide between the two above and a full Glue pipeline, **per source** rather than as one blanket choice.

## 8. Course arithmetic — needs your decision
| | Hours |
|---|---|
| **Module 0 — Basics** *(new)* | 23 |
| Module 1 — Foundations *(20 lessons if trimmed per §5)* | 14.5 |
| Module 2 — Foundation (how to build it) | 18 |
| Module 3 — Capstone *(proposed)* | 6 |
| **Total** | **~61** |

Module 0 is now the largest module, which is defensible — it's the floor — but 61 hours is well past the original 40. Three ways to land it:

- **A — Split Module 0 into two teaching blocks.** **0A** = Parts A+B (12 lessons, 8 hrs — paradigms + warehouse design), **0B** = Parts C–F (22 lessons, 15 hrs — the ecosystem). Same folder, same PDF, two blocks on the timetable. *(Recommended — keeps the depth, makes it schedulable, and 0A alone is a viable primer for non-engineers.)*
- **B — Trim to ~16 hrs.** Fold Part C into 3 lessons and Part D into 5, losing the matrix depth you just asked for.
- **C — Parts A+B taught, Parts C–F as reference.** Ship C–F as slides + notes for self-study. Cheapest, but Part C is exactly the content people cannot self-teach.

## 9. Decisions I need before building
1. **Structure** — A, B or C above?
2. **Trim Module 1's L01/L02** per §5, or accept deliberate reinforcement?
3. **Hands-on labs** — can they run Athena queries and create Redshift tables in Dev? Parts B, C and E are dramatically better as labs than lectures.
4. **Data mesh (L05)** — one lesson as planned, or two? It's the most over-hyped and least needed of the four for this team.
5. **Streaming (L23)** — full lesson as planned, or compress? Our platforms are batch; I've argued to keep it so they can recognise when it's warranted, but it's the most cuttable hour in Part D.
