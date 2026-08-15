# Module 2 — Applied to Tamimi (worked example)
### "How it actually works when it breaks, scales, or has to change"

> **Status:** PLAN — for review before slide production.
> **Prerequisite:** Module 1 complete (they know the vocabulary and the map).
> **Duration:** **18 hours** · 24 lessons · same format ([`../LECTURE-STYLE.md`](../LECTURE-STYLE.md))
> **Budget:** Module 1 (16h) + Module 2 (18h) = 34 of 40. Remaining **6 h → Module 3 capstone** (§7).

---

## 1. The shift from Module 1

| Module 1 asked | Module 2 asks |
|---|---|
| What is Iceberg? | Why did this MERGE fail with a cardinality error? |
| What is a watermark? | The watermark is `'S'` — what happened, and how do we not wedge the pipeline? |
| What is a barrier? | Two jobs raced the barrier. Which one wins, and why is that safe? |
| What does the engine do? | Add a new source without touching the engine. |

**Module 1 was descriptive. Module 2 is operative.** By the end they can read a failure, fix it, and extend the platform — which is exactly what Apparel Group will demand of them in week 1.

**Non-negotiable teaching rule for this module:** every lesson is anchored on **real code and, where possible, a real incident from this repo**. No hypotheticals.

---

## 2. Shape

| Part | Theme | Lessons | Hrs |
|---|---|---|---|
| **A** | The ingestion engine, opened up | 1–5 | 4 |
| **B** | Iceberg & storage internals | 6–9 | 3 |
| **C** | Transformation depth | 10–14 | 4 |
| **D** | Orchestration & the control plane | 15–18 | 3 |
| **E** | Infrastructure, security, delivery | 19–22 | 3 |
| **F** | Operate, debug, extend | 23–24 | 1 |
| | | **24 lessons** | **18** |

---

## PART A — The ingestion engine, opened up (4 hrs)

### L01 · Anatomy of the Engine
Spec → connector → writer → control plane. The four seams and why each is pluggable. Reading `glue_engine/` as an architecture, not a folder.
**Anchors:** `spec.py`, `sources/protocol.py`, `writers/`, `control_plane.py`.

### L02 · The Source Protocol — how a connector plugs in
The `Protocol` contract: `read_full` / `read_incremental` / `read_range` / `emit_metrics`. The registry (`@register`). **Why the engine never knows what SAP is.**
**Anchors:** `sources/protocol.py`, `sources/__init__.py`, `driver_select.py`.
**This is the lesson that makes Apparel Group possible** — a new source is a new class, not a new pipeline.

### L03 · JDBC at Scale — partitioning the giants
`partitionColumn` / bounds / `numPartitions`; hash fields; the `single_partition_max_rows` guard; connection saturation. **The real incident:** MBEW at 16 partitions → *"Cannot connect to host (socket timeout)"* → tuned to 4 (≈9 M rows/partition); VBRP later 4→8.
**Anchors:** `sources/sap_hana.py`, `specs/download/sap_mbew.yaml`.

### L04 · Watermarks & CDC — the delta window
How the predicate is built; SAP `NVARCHAR 'YYYYMMDD'` dates; watermark-in-projection guard; **why we refuse to persist a dirty watermark** (`MAX()='S'` would wedge every future cycle); non-date watermarks → full refresh (the 27-table fix).
**Anchors:** `sources/sap_hana.py` (`_build_query`, `read_incremental` hardening), commit `cbfa266`.

### L05 · Three Read Modes — full, windowed, backfill
`full_snapshot` / `date_from` range / incremental; the "initial load MUST be full" policy and the Bronze-parity invariant it protects; empty-result policy (full = fail, incremental = fine); `init_state` lifecycle.
**Anchors:** `jobs/source_download.py`, `CLAUDE.md` policy section.

## PART B — Iceberg & storage internals (3 hrs)

### L06 · Opening an Iceberg Table
Read a real `metadata.json` → manifest list → manifests → data files. Snapshots as an append-only log. What "atomic" actually means here.
**Lab:** walk the metadata of a live Silver table.

### L07 · MERGE Mechanics — and why it fails
`WHEN MATCHED / NOT MATCHED`; the **one-match constraint**; `MERGE_CARDINALITY` errors; source-side dedup before merge (`QUALIFY ROW_NUMBER()`); delete-aware MERGE (`change_op='D'`).
**Anchors:** `writers/s3_tables.py`, `stg_sap_zscc.sql`, commit `359b3b2`.

### L08 · Small Files, Compaction & Snapshot Expiry
Why streaming appends create a small-file problem; what S3 Tables manages *for* you and what it doesn't; `expire_snapshots` (exists in code, **no scheduled caller** — an honest open gap); cost of unbounded metadata.
**Anchors:** `writers/s3_tables.py:345-387`.

### L09 · Schema Evolution & Partitioning
Safe vs breaking changes; `on_schema_change='fail'` and why we chose fail; partition spec only honoured at create; type-widening traps (the `NUMERIC(38,4)` pre-cast fix).
**Anchors:** `unified_customer_count.sql`, `writers/s3_tables.py`.

## PART C — Transformation depth (4 hrs)

### L10 · Porting Sequential Logic to Spark ⭐
The hardest real problem in this codebase: **ZHOCIDC is a positional state machine**, not relational rows. Per-receipt fold, `SEQNO` order, `applyInPandas`; why a set-based join cannot express it; keeping the core pure and unit-testable.
**Anchors:** `abap/baskets.py`, `abap/ops.py` (`basket_op`).

### L11 · Reproducing Source Logic Faithfully
Decompiled ABAP → PySpark: `vat_split` (data-driven rate, `TAKLV=0` = exempt), `resolve_store_type` (WERKS prefix), `parse_pack_size` (byte-for-byte port of `strip_maktg`, off-by-one preserved deliberately). **When to reproduce a bug on purpose.**
**Anchors:** `abap/helpers.py`, `docs/ABAP/ID8-EXTRACTOR-MAPPING.md`.

### L12 · Spark Performance — partitions, shuffles, skew, cache
Why `.cache()` before count/agg/write (3–4× JDBC re-reads otherwise); shuffle cost; skew; `applyInPandas` trade-offs; reading a Spark plan.
**Anchors:** `sources/sap_hana.py` caching, `abap/ops.py`.

### L13 · dbt in Depth — incremental strategy on Redshift
`merge` + `unique_key`; the incremental predicate window (and what it silently drops); `on_schema_change`; late-binding views over external schemas; `dist`/`sort` choices and when they're wrong.
**Anchors:** `dbt_project.yml`, `macros/scenario_helpers.sql`, `unified_sales.sql`.

### L14 · Dimensional Modelling & Correctness Traps ⭐
Grain discipline; conformed dimensions; the `scenario` column pattern; **the two real doubling bugs** (TVKMT `SPRAS` fan-out; the synthetic `'All Dept'` row) and the tests that now prevent them.
**Anchors:** `unified_sales.sql`, `unified_sales_by_am.sql`, `tests/assert_all_dept_reconciles_to_per_dept.sql`.

## PART D — Orchestration & the control plane (3 hrs)

### L15 · Step Functions & the Dispatcher
What the state machines actually do; how the dispatcher decides today's work (initial / cdc / rerun / backfill); month-chunking; SFN input limits.
**Anchors:** `lambdas/dispatcher/handler.py`, `infra/env/dev/per_source_ingestion.tf`.

### L16 · The Barrier Pattern ⭐
Single-flight locks via DynamoDB **conditional writes**; how a barrier concludes a phase; latest-status-per-table resolution; the R31 terminal-state gate fix; what happens when two invocations race.
**Anchors:** `shared/control_plane/coordination.py`, `lambdas/*_barrier/handler.py`.

### L17 · The Control Plane Schema
`runs` (composite key, GSIs by_table/by_cycle), `watermarks`, `pipeline-state` (polymorphic), `lineage_edges`. **Which question each table answers** — and how the ops console reads them.
**Anchors:** `shared/control_plane/*.py`.

### L18 · Failure & Recovery
Idempotency end-to-end; the cycle sweeper safety net; rerun vs backfill vs re-baseline; partial-failure handling; why the Gold barrier checks for an in-flight run before starting one.
**Anchors:** `lambdas/cycle_sweeper/`, `lambdas/gold_barrier/handler.py`.

## PART E — Infrastructure, security, delivery (3 hrs)

### L19 · Terraform Architecture
**28** modules + per-env composition; what belongs in a module vs an env; provider pinning (all 28 carry `versions.tf`, `aws ~> 6.28`); `prevent_destroy` on the 4 stateful resource types.
**Anchors:** `infra/modules/`, `infra/env/{dev,qa,prod}/`.
> ⚠️ **Teach the live truth, not the comment.** As of 2026-08-11 all three `backend.tf` files still share **one** state bucket and **one** lock table (`tamimi-lakehouse-tfstate-633740007496`); only `key` differs — while the dev/qa comments describe a per-env split *as if it were applied*. The split was implemented earlier and has since been **reverted**. This is audit finding **CRIT-01, regressed**, and it is the single best teaching example of "read the value, not the comment."

### L20 · CI/CD & the Deploy Gates
Bitbucket Pipelines + **AWS OIDC** (no static keys); plan-artifact → gated apply; per-env roles; supply-chain pinning (checksums on `ngdbc.jar`, pinned Lambda deps).
**Anchors:** `bitbucket-pipelines.yml`, `global/oidc/`.

### L21 · Security & Governance
Least-privilege IAM (and what "scoped" really means); 6 KMS CMKs with `aws:SourceAccount` conditions; Lake Formation LF-TBAC; secrets by reference only. **Taught partly from the real audit findings** — including what was wrong and how it was fixed.
**Anchors:** `infra/modules/{iam,kms,catalog_federation}/`, `docs/handoff/audit_deep_analysis.md`.

### L22 · Networking & SAP Connectivity
VPC layout, TGW to SAP, interface endpoints vs NAT, flow logs; TLS enforcement on the JDBC path; why the ENI budget caps P1 concurrency.
**Anchors:** `infra/modules/vpc/`, `infra/env/*/sap_hana_source_download.tf`.

## PART F — Operate, debug, extend (1 hr)

### L23 · Reading a Broken Cycle — live debugging
Start from an alarm → ops console → `runs` row → Glue log → watermark → decide: rerun, backfill, or re-baseline. **Done live against a real failed cycle.**
**Anchors:** the ops console, `docs/OPERATIONS-RUNBOOK.md`.

### L24 · Adding a Source Without Touching the Engine ⭐ (bridge to capstone)
The full checklist: connector class (if new) → `download` spec → `bronze` spec → catalog row → dbt staging → tests → deploy. Walk it once with an Oracle table.
**Anchors:** `specs/`, `config/ingestion_tables.yaml`, `sources/rds_jdbc.py` as the non-SAP template.

---

## 3. Slides to produce (24)

| Priority | Lessons |
|---|---|
| ⭐ Tier 1 | **L02** (source protocol), **L10** (sequential→Spark), **L14** (correctness traps), **L16** (barrier pattern), **L24** (add a source) |
| Tier 2 | L03, L04, L07, L13, L15, L17, L18, L23 |
| Tier 3 | L01, L05, L06, L08, L09, L11, L12, L19, L20, L21, L22 |

Same deliverable per lesson: `L##.png` (1920×1080) + `L##.md` (take-home) + `_render/L##.html`, and one wide-format module PDF via `make_pdf.py Module-02-Tamimi`.

## 4. What's different about Module 2's teaching pattern
Module 1 was slide-led. Module 2 should be **code-led**: slide (5 min) → **open the file and read it together (20 min)** → break it / fix it (20 min) → check. The slides exist to frame and to give them something to take away, not to carry the hour.

## 5. Labs (need a decision — see §6)
Highest value, in order:
1. **Onboard an Oracle table end-to-end** (dry-run against a stand-in DB) — the capstone rehearsal.
2. **Break and fix:** hand them a wedged watermark, a fan-out join, a cardinality error.
3. **Read a real failed cycle** in the ops console and diagnose it.
4. **Write a dbt model + test** against Gold.

## 6. Decisions I need
1. **18 hrs / 24 lessons** — right, or trim Part E (infra) for a delivery-focused audience?
2. **Do they get hands-on AWS?** Module 2 is much weaker as a lecture-only module. Read-only console + a Dev Redshift login + ability to run a Glue job in Dev would transform it.
3. **Is an Oracle stand-in available** for labs (an RDS Oracle/XE instance, or do we simulate with Postgres)? Determines whether L24 + the capstone are real or paper.
4. **Audit content in L21** — comfortable teaching from our own audit findings (what was wrong, how fixed)? It's the most honest security lesson available, but it does expose past gaps.
5. **Module 3 capstone (6 hrs)** — confirm shape: teams of 2, each onboards one Apparel Group source (RMS / SIM / XStore / Magento) through to a Gold model, reviewed as a PR.

## 7. Proposed Module 3 (the remaining 6 hrs)
**Supervised build.** Not lectures — a real, small, reviewed deliverable per pair, using the Apparel Group source list. Output: a working spec + Bronze table + Silver conform + one Gold model + tests, merged via PR with review. That converts 34 hours of teaching into demonstrated capability before they land on the engagement.
