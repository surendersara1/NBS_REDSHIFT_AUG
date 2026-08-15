# Module 3 — Foundation Architectures
### "Thirty diagrams: every pattern this course has taught, drawn with real AWS icons — from the one-line shape to the numbered-step deep dive"

> **Status:** PLAN — for review before mass production. **1 of 30 built** ([`L01`](L01-lakehouse-reference.png)) as the format proof.
> **Audience:** the same 10 developers, plus client-facing use. These diagrams are the artefacts that leave the room — they end up in decks, in the SOW response, and on the wall.
> **Duration as taught:** ~8 hours (30 diagrams × ~15 min walkthrough). Also usable as a standalone reference pack.
> **Format:** per [`../LECTURE-STYLE.md`](../LECTURE-STYLE.md), extended with two diagram grammars (§3).

---

## 1. Why this module exists

Modules 0–2 taught the ideas in words and boxes. This module renders them as **architecture diagrams a client would accept** — real AWS service icons, correct service names, boundary containers, and numbered flows.

Three audiences, one artefact set:

| Audience | What they need from it |
|---|---|
| **The 10 developers** | recognise a pattern on sight; know which services compose it |
| **The Apparel Group proposal** | reference architectures that show we have done this before |
| **The Tamimi handover** | an accurate as-built record that survives the team changing |

---

## 2. The icon library — already in place

**605 icons** at [`../_icons/`](../_icons/), indexed in [`../_icons/ICONS.md`](../_icons/ICONS.md):

| Provider | Count | Categories |
|---|---:|---|
| `aws/` | 524 | analytics 29 · compute 63 · database 34 · storage 31 · network 40 · integration 23 · management 59 · ml 31 · security 40 · migration 12 · devtools 14 · general 24 · iot 61 · cost 6 · … 26 in all |
| `onprem/` | 65 | database (Oracle, MSSQL, MySQL, PostgreSQL…), analytics, queue, workflow, monitoring, client |
| `saas/` | 16 | analytics (Snowflake…), logging, chat, crm |

Regenerate with [`../sync_icons.py`](../sync_icons.py). Referenced from any slide as:

```xml
<image href="../../_icons/aws/analytics/redshift.png" x="756" y="396" width="66" height="66"/>
```

That relative path resolves for **both** render paths, because both load a file out of `<module>/_render/` — `render_slides.py` opens `_render/L##.html`, `make_pdf.py` writes `_render/_deck.html`. One library, no duplication, sources stay diffable.

**Provenance note:** this set ships with the `diagrams` package and derives from AWS's official Architecture Icons. It mixes icon generations — a few (Oracle, generic internet/disk/user) are older line art and render lighter than the modern coloured tiles; those get a tile treatment (§3). For a **client-facing** deliverable, consider pulling the canonical pack from <https://aws.amazon.com/architecture/icons/>, which is updated quarterly. One decision, §7.

---

## 3. Two diagram grammars

Different jobs need different shapes. Both live on the same dark ground, same type scale, same "IN PLAIN ENGLISH" strip, and both pass the existing canvas / box-containment / webfont QA.

### Grammar A — **Flow panels** (proven in L01)

Five-or-fewer labelled column panels, left to right, with a cross-cutting band underneath.

```
[ SOURCES ] → [ INGEST ] → [ LAKE ] → [ WAREHOUSE ] → [ CONSUME ]
└──────────── governance · orchestration · observability ────────────┘
```

- icon **66×66**, name at `+80,+30`, detail at `+80,+54`, rows **90px** apart — four services per 454px panel
- panel colour carries meaning: red = the layer being taught · blue = write · green = read · amber = consumption · dashed grey = out of scope
- **Use for:** "what are the pieces and in what order" — the foundation and module-recap tiers

### Grammar B — **Numbered-step reference** (the AWS style, to be proven in D21)

The shape a client recognises from AWS's own reference architectures: boundary containers, services placed freely, orthogonal arrows, and **numbered step badges** that give the lecturer a spoken path.

**Boundary containers** — nested, each with a corner badge:

| Container | Border | Badge |
|---|---|---|
| **AWS Cloud** | solid `#4A5560`, 3px | dark square, white label |
| **Region** | dashed `#3FD98A` | teal square |
| **VPC** | dashed `#5AA9FF` | blue square |
| **Private subnet** | dashed `#2E4A66`, tinted fill | blue outline |
| **Step Functions workflow** | solid `#E3007F` (AWS pink) | Step Functions icon |
| **Lake Formation scope** | solid `#8A5CF0` (AWS purple) | Lake Formation icon |
| **Account boundary** | solid `#7A8C99` | grey square |

**Numbered steps:** dark filled circle Ø34, white numeral (Asap 800, 19px), placed on the arrow it explains. Numbered 1..n in narration order — **the take-home MD has one paragraph per number.** That pairing is the whole point of the grammar.

**Icon convention:** 64×64, label **below** the icon (AWS convention, not to the right), name 17px white + optional detail 15px muted. Non-tile legacy icons sit on a `#1E262D` rounded tile so weight matches.

- **Use for:** "walk me through what happens, in order" — every deep dive in Tier 4

> **Trademark note:** we draw the AWS Cloud / Region badges as labelled squares. We do **not** reproduce the AWS logo mark inside our own branded deck.

---

## 4. The thirty diagrams

### Tier 1 · Foundation shapes (D01–D08) — Grammar A
*The patterns behind Modules 0–2. These are the "recognise it on sight" set.*

| # | Diagram | What it teaches | Anchors |
|---|---|---|---|
| **D01** | **The Lakehouse Reference Architecture** ✅ *built* | the five-stop road, end to end | M0 L32 |
| D02 | Four Paradigms Side by Side | warehouse vs lake vs lakehouse vs mesh, as four mini-architectures on one canvas | M0 L01–L06 |
| D03 | The Medallion Layers | raw → bronze → silver → gold, and **what changes at each boundary** | M1 · M0 L03–L04 |
| D04 | Who Reads, Who Writes | Redshift at centre, every in/out path radiating — the participation matrix, drawn | M0 L13 |
| D05 | Six Ways To Move Data | one canvas, six source→target paths, each labelled with latency | M0 L20 |
| D06 | The Federated Catalog | three-level hierarchy; managed vs federated catalogs; engines above, stores below | M0 L29 |
| D07 | Zero-Copy Access Paths | Spectrum · federated query · datashares · Athena connectors, and who pays for each | M0 L16, L18, L31 |
| D08 | The Control Plane | runs · watermarks · pipeline-state · lineage · coordination, and who writes each | M2 L17 |

### Tier 2 · Tamimi as built (D09–D14) — Grammar A, D10 in B
*The accurate as-built record. This is the handover artefact.*

| # | Diagram | What it teaches |
|---|---|---|
| D09 | Tamimi End-to-End | SAP → Glue → Iceberg on S3 Tables → Redshift → Power BI |
| D10 | Tamimi P1 / P2 Split *(Grammar B)* | `source_download` → barrier → `bronze_pull`, numbered, with the terminal-state gate |
| D11 | ABAP → Glue Transformation Path | the ZHOCIDC receipt fold: positional state machine → `applyInPandas` → VAT split |
| D12 | Catalog & Storage Layers | federated Glue catalog → `s3tablescatalog` → Iceberg → S3, with the Spectrum mirror-DB detail |
| D13 | Environments & Terraform Composition | dev/qa/prod, 28 modules, per-env composition, OIDC deploy roles |
| D14 | CI/CD & Deployment Path | Bitbucket pipelines → OIDC → plan/apply gates → per-env deploy |

> D12 supersedes the hand-drawn [`../../diagrams/catalog-storage-layers.drawio`](../../diagrams/catalog-storage-layers.drawio) — same content, real icons, consistent with the rest of the pack.

### Tier 3 · Apparel Group target (D15–D20) — Grammar A
*What we are proposing to build. These go in the response.*

| # | Diagram | What it teaches |
|---|---|---|
| D15 | AG Target Architecture | all 8 sources → lakehouse → Redshift → BI, the headline picture |
| D16 | Source Onboarding Pattern | 8 sources → 3 connector classes → N specs; "add a source = add a spec" |
| D17 | **Oracle: Three Ingestion Options Compared** | Glue JDBC vs DMS CDC vs zero-ETL, side by side with limits — the real decision |
| D18 | Network & Connectivity | on-prem Oracle over VPN/Direct Connect, private subnets, VPC endpoints, no public path |
| D19 | PII & Security Architecture | Epsilon customer data: KMS, Lake Formation column grants, RLS/CLS, masked views |
| D20 | Environments & Promotion Path | dev → qa → prod, what is shared and what is strictly not |

### Tier 4 · Advanced deep dives (D21–D30) — Grammar B, numbered
*The AWS-reference style. Each one has a numbered narration in its take-home.*

| # | Diagram | The flow it narrates |
|---|---|---|
| **D21** | **Event-Driven File Ingestion** | client drops a file → S3 raw → EventBridge → SQS → Step Functions (Lambda×2) → stage bucket → EventBridge → SQS → Lambda → Glue job + crawler → catalog → analytics bucket → Athena → analysts. *(The shape of the reference architecture you shared.)* |
| D22 | CDC Pipeline Deep Dive | DMS reads Oracle redo → S3/Kinesis → Glue MERGE into Iceberg → Redshift, incl. delete handling |
| D23 | Zero-ETL Deep Dive | Oracle / SAP OData / DynamoDB → managed integration → Redshift **and** S3 Tables/RMS via SageMaker Lakehouse |
| D24 | Streaming Ingestion Deep Dive | Kinesis / MSK → Firehose → Iceberg **vs** streaming ingestion → Redshift materialized view (no S3 hop) |
| D25 | Orchestration & Barriers Deep Dive | EventBridge → Step Functions → per-source parallelism → DynamoDB conditional-write barrier → phase gate → retry/backfill |
| D26 | Observability & Ops Console Deep Dive | job → CloudWatch metrics/logs → alarms → SNS → the ops console reading run state |
| D27 | Cross-Account Sharing / Mesh Deep Dive | producer account → Lake Formation grants over RAM → resource links → consumer account; Redshift datashares incl. `--allow-writes` |
| D28 | Security Deep Dive | IAM roles and trust, KMS keys per bucket, Secrets Manager, LF grants, network isolation, CloudTrail |
| D29 | Cost & Lifecycle Deep Dive | where the money actually goes: storage tiering, Athena workgroup caps, Redshift RPUs, Glue DPU-hours |
| D30 | DR, Backfill & Time Travel Deep Dive | Iceberg snapshots, `expire_snapshots`, replay from raw, cross-region copies, RTO/RPO |

---

### Tier 5 · Apparel Group master flows (M01–M05) — added
*Programme-level views for the SOW response and kickoff. These are the ones a client sponsor reads, not an engineer.*

| # | Diagram | What it answers |
|---|---|---|
| M01 | **Programme Master Flow** | the whole engagement as one picture: discovery → foundation → source waves → modelling → BI → go-live |
| M02 | **Source-to-Dashboard Traceability** | every one of the 8 sources traced to its landing, silver entity, gold mart and dashboard — "where does this number come from?" |
| M03 | **Retail Domain Model** | the business entities (store, product, customer, sale, stock, footfall, campaign) and which source feeds each |
| M04 | **Delivery Waves & Dependencies** | what gets built in which wave, and what blocks what — network access, contracts, PII sign-off |
| M05 | **Go-Live & Operations** | cutover, parallel run, reconciliation, hypercare, the ops console and the runbooks |

## 5. Coverage check — every module is represented

| Module | Diagrams that carry it |
|---|---|
| **Module 0** (ecosystem) | D01–D08 primarily; D23, D24, D27, D29 extend it |
| **Module 1** (Tamimi platform) | D03, D09, D12, D13, D14 |
| **Module 2 Foundation** (how to build) | D05, D08, D16, D17, D25, D26, D30 |
| **Module 2 Tamimi** (worked example) | D10, D11, D12 |
| **Apparel Group SOW** | D15–D20, plus D17 and D22/D23 as the Oracle decision evidence |

---

## 6. Deliverables

| Artifact | Count |
|---|---|
| Diagram slides `D##-*.png` — 1920×1080 | 30 |
| Companion take-homes `D##-*.md` — Grammar B ones have a numbered narration | 30 |
| Editable SVG sources `_render/D##-*.html` | 30 |
| Module index `README.md` | 1 |
| Wide 16:9 PDF with authored cover | 1 (~61 pp) |
| Shared icon library + index | ✅ done — 605 icons |

Naming shifts from `L##` (lesson) to `D##` (diagram) for this module — these are reference artefacts, not lessons in sequence. `render_slides.py` and `make_pdf.py` glob `L*.html`, so **both scripts need their glob widened to `[LD]*.html`** — a one-character change in each, noted here so it is not a surprise.

---

## 7. Decisions before I build

1. **Icon provenance.** Ship with the current 605-icon set (offline, verified, working), or pull the **official AWS Architecture Icons** pack for client-facing fidelity? *Recommendation: build with what we have; swap to official before anything goes to Apparel Group. The reference paths are centralised, so it is a re-sync, not a re-draw.*
2. **Tier 3 accuracy.** D15–D20 describe a system that does not exist yet. Should they be drawn as **proposed** (clearly labelled) or as **options** (two or three candidate shapes per decision)? *Recommendation: proposed, with D17 as the one explicit options diagram.*
3. **Build order.** All 30 in tier order, or **Tier 4 first** (the deep dives are the ones that impress, and D21 is the shape you showed me)? *Recommendation: D21 now as the Grammar B proof, then Tier 1, then the rest.*
4. **Does D12 replace the `.drawio`?** If yes I will add a superseded banner to the original rather than delete it.
5. **Standalone reference pack?** Beyond the module PDF, do you want a separate **client-safe** PDF — Tier 1 + Tier 3 only, no Tamimi internals, no incident detail — for the Apparel Group response?

---

## 8. What is already true

- **L01 built and rendering clean** — Grammar A proven, passes canvas + box-containment + webfont QA.
- **605-icon shared library in place**, indexed, regenerable, referenced relatively so slides and PDF both resolve.
- **Cover page, QA gates and PDF pipeline all carry over unchanged** from Modules 0–2, including the authorship block.
