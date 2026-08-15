# Module 2 — Applied to Tamimi
### "How Module 2's principles were actually implemented here — and what it cost to learn them"

> **This is the worked example, not the teaching module.**
> Teach from [`../Module-02-Foundation/`](../Module-02-Foundation/) — it gives the decision, the setup and the reasoning.
> **This** module shows how each of those decisions landed in the Tamimi codebase, including the incidents that produced them. It is the reference for anyone maintaining or extending Tamimi, and the evidence behind every rule in the Foundation module.

**18 hours · 24 lessons · prerequisite: Module 1.**
Plan: [`MODULE-02-PLAN.md`](MODULE-02-PLAN.md) · Format: [`../LECTURE-STYLE.md`](../LECTURE-STYLE.md) · One-file deck: **[`Module-02-Tamimi.pdf`](Module-02-Tamimi.pdf)**

Module 1 was *descriptive* — what the words mean. **Module 2 is operative** — read a failure, fix it, extend the platform. Every lesson is anchored on real code and, wherever possible, **a real incident from this repo**.

---

## Part A — The engine, opened up (4 hrs)

| # | Lesson | Slide | Notes |
|---|---|---|---|
| L01 | Anatomy of the Engine | `L01-engine-anatomy.png` | [md](L01-engine-anatomy.md) |
| L02 | The Engine Doesn't Know What SAP Is ⭐ | `L02-source-protocol.png` | [md](L02-source-protocol.md) |
| L03 | Partitioning the Giants | `L03-jdbc-at-scale.png` | [md](L03-jdbc-at-scale.md) |
| L04 | The Delta Window | `L04-watermarks-cdc.png` | [md](L04-watermarks-cdc.md) |
| L05 | Full, Windowed, Backfill | `L05-three-read-modes.png` | [md](L05-three-read-modes.md) |

## Part B — Iceberg & storage internals (3 hrs)

| # | Lesson | Slide | Notes |
|---|---|---|---|
| L06 | What's Actually on Disk | `L06-opening-an-iceberg-table.png` | [md](L06-opening-an-iceberg-table.md) |
| L07 | Why This MERGE Failed | `L07-merge-mechanics.png` | [md](L07-merge-mechanics.md) |
| L08 | The Maintenance Problem | `L08-small-files-compaction.png` | [md](L08-small-files-compaction.md) |
| L09 | Changing a Table Without Breaking It | `L09-schema-evolution-partitioning.png` | [md](L09-schema-evolution-partitioning.md) |

## Part C — Transformation depth (4 hrs)

| # | Lesson | Slide | Notes |
|---|---|---|---|
| L10 | When a Join Won't Do ⭐ | `L10-sequential-to-spark.png` | [md](L10-sequential-to-spark.md) |
| L11 | Porting ABAP Faithfully | `L11-reproducing-source-logic.png` | [md](L11-reproducing-source-logic.md) |
| L12 | Partitions, Shuffles, Skew, Cache | `L12-spark-performance.png` | [md](L12-spark-performance.md) |
| L13 | Incremental on Redshift, Properly | `L13-dbt-incremental-depth.png` | [md](L13-dbt-incremental-depth.md) |
| L14 | Two Bugs That Doubled the Numbers ⭐ | `L14-correctness-traps.png` | [md](L14-correctness-traps.md) |

## Part D — Orchestration & the control plane (3 hrs)

| # | Lesson | Slide | Notes |
|---|---|---|---|
| L15 | What Decides Today's Work | `L15-dispatcher-step-functions.png` | [md](L15-dispatcher-step-functions.md) |
| L16 | How Two Jobs Don't Collide ⭐ | `L16-barrier-pattern.png` | [md](L16-barrier-pattern.md) |
| L17 | The System's Memory | `L17-control-plane-schema.png` | [md](L17-control-plane-schema.md) |
| L18 | When It Breaks at 3 AM | `L18-failure-and-recovery.png` | [md](L18-failure-and-recovery.md) |

## Part E — Infrastructure, security, delivery (3 hrs)

| # | Lesson | Slide | Notes |
|---|---|---|---|
| L19 | How the Infrastructure Is Built | `L19-terraform-architecture.png` | [md](L19-terraform-architecture.md) |
| L20 | How Code Reaches Production | `L20-cicd-deploy-gates.png` | [md](L20-cicd-deploy-gates.md) |
| L21 | Least Privilege, For Real | `L21-security-governance.png` | [md](L21-security-governance.md) |
| L22 | Getting to SAP Safely | `L22-networking-sap-connectivity.png` | [md](L22-networking-sap-connectivity.md) |

## Part F — Operate & extend (1 hr)

| # | Lesson | Slide | Notes |
|---|---|---|---|
| L23 | It's 07:00 and Gold Is Missing | `L23-debugging-a-broken-cycle.png` | [md](L23-debugging-a-broken-cycle.md) |
| L24 | Add a Source Without Touching the Engine ⭐ | `L24-adding-a-source.png` | [md](L24-adding-a-source.md) |

---

## How to teach Module 2 — **code-led, not slide-led**
Module 1 was carried by its slides. Module 2 should not be:
1. **Slide** — 5 min, frame the problem.
2. **Open the file and read it together** — 20 min. This is the lesson.
3. **Break it / fix it** — 20 min.
4. **Check** — the question at the foot of the take-home.

## Real incidents used as teaching material
These land harder than any diagram — all verified in the repo:
- **MBEW at 16 JDBC partitions** → *"Cannot connect to host (socket timeout)"* → cut to 4 (~9 M rows/partition). *(L03)*
- **Dirty watermarks** — live values `'502812'`, `'22080401'`, `'730121V1'`, and the `'S'` that would wedge every future cycle. *(L04)*
- **Two doubling bugs** — TVKMT language fan-out (43 EN · 43 AR · 3 DE) and the synthetic `'All Dept'` row. *(L14)*
- **A 13 ms barrier race** between the `sap` and `excel` Step Functions. *(L16)*
- **Prod SAP pulls timing out 2026-08-04** — TGW route pointed at the wrong route table while SAP ENIs sat in the `/26` data subnets. *(L22)*
- **The 256 KB `StartExecution` ceiling** hit on Prod 2026-07-31 (605 items ≈ 266,688 B). *(L15)*

## Two live defects surfaced while building this module
Found by reading the code for the slides — worth acting on:
1. **CRIT-01 has regressed.** All three `backend.tf` share one state bucket + one lock table again (`tamimi-lakehouse-tfstate-633740007496`), while the dev/qa comments still describe a per-env split as if applied. Taught in L19 as *"read the value, not the comment."*
2. **Dev OIDC trust is broken.** `global/oidc/locals.tf:24` pins the dev subject claim to branch `main`, but the pipeline deploys Dev from `develop` — the assume-role cannot match. Flagged on L20.

## Re-render / rebuild
```bash
cd lectures
python render_slides.py Module-02-Tamimi   # PNGs + overflow + webfont check
python make_pdf.py     Module-02-Tamimi    # one wide 16:9 PDF
```
