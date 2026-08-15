# Module 2 (Foundation) — How To Build It
### "The decisions you will make on the new platform, how to set each one up, and why"

**18 hours · 24 lessons · prerequisite: Module 1.**
Plan: [`MODULE-02-FOUNDATION-PLAN.md`](MODULE-02-FOUNDATION-PLAN.md) · Format: [`../LECTURE-STYLE.md`](../LECTURE-STYLE.md) · One-file deck: **[`Module-02-Foundation.pdf`](Module-02-Foundation.pdf)**

> **This is the module you teach from.** It is prescriptive: every lesson is a decision they will face on the **Apparel Group** build, the setup that answers it, and the reasoning.
> Its sibling [`../Module-02-Tamimi/`](../Module-02-Tamimi/) documents *what the Tamimi codebase does and what went wrong there* — keep it as the maintainer's reference, don't lecture from it.

Each lesson: **THE DECISION → DO THIS → WHY → ON APPAREL GROUP**, plus a plain-English line. Take-homes end with a **checklist** they use on the job.

---

## Part A — Standing up ingestion (4 hrs)

| # | Lesson | Slide | Notes |
|---|---|---|---|
| L01 | Design the Engine Before the Pipelines | `L01-design-the-engine.png` | [md](L01-design-the-engine.md) |
| L02 | Define the Source Contract First | `L02-source-contract.png` | [md](L02-source-contract.md) |
| L03 | Size JDBC Parallelism Properly | `L03-sizing-jdbc-parallelism.png` | [md](L03-sizing-jdbc-parallelism.md) |
| L04 | Choose a Watermark You Can Trust | `L04-choosing-a-watermark.png` | [md](L04-choosing-a-watermark.md) |
| L05 | Plan the Load Strategy per Table | `L05-load-strategy.png` | [md](L05-load-strategy.md) |

## Part B — Laying out storage (3 hrs)

| # | Lesson | Slide | Notes |
|---|---|---|---|
| L06 | Lay Out the Lake | `L06-lay-out-the-lake.png` | [md](L06-lay-out-the-lake.md) |
| L07 | Make Every Load Idempotent | `L07-idempotent-loads.png` | [md](L07-idempotent-loads.md) |
| L08 | Plan Table Maintenance on Day One | `L08-table-maintenance.png` | [md](L08-table-maintenance.md) |
| L09 | Make Schema Change a Controlled Event | `L09-schema-change.png` | [md](L09-schema-change.md) |

## Part C — Building transformations (4 hrs)

| # | Lesson | Slide | Notes |
|---|---|---|---|
| L10 | Choose Set-Based or Ordered, Deliberately | `L10-set-based-or-ordered.png` | [md](L10-set-based-or-ordered.md) |
| L11 | Reproduce Source Business Rules Faithfully | `L11-reproduce-business-rules.png` | [md](L11-reproduce-business-rules.md) |
| L12 | Write Spark That Scales | `L12-spark-that-scales.png` | [md](L12-spark-that-scales.md) |
| L13 | Build Incremental Models Correctly | `L13-incremental-models.png` | [md](L13-incremental-models.md) |
| L14 | Guarantee Correctness by Construction ⭐ | `L14-correctness-by-construction.png` | [md](L14-correctness-by-construction.md) |

## Part D — Orchestration you can operate (3 hrs)

| # | Lesson | Slide | Notes |
|---|---|---|---|
| L15 | Design the Schedule and the Dispatcher | `L15-schedule-and-dispatch.png` | [md](L15-schedule-and-dispatch.md) |
| L16 | Make Phase Hand-offs Safe ⭐ | `L16-safe-phase-handoffs.png` | [md](L16-safe-phase-handoffs.md) |
| L17 | Design the Control Plane | `L17-design-the-control-plane.png` | [md](L17-design-the-control-plane.md) |
| L18 | Design for Failure Before You Ship | `L18-design-for-failure.png` | [md](L18-design-for-failure.md) |

## Part E — Platform setup (3 hrs)

| # | Lesson | Slide | Notes |
|---|---|---|---|
| L19 | Structure Terraform for Three Environments | `L19-terraform-for-three-envs.png` | [md](L19-terraform-for-three-envs.md) |
| L20 | Set Up CI/CD With Real Gates | `L20-cicd-with-real-gates.png` | [md](L20-cicd-with-real-gates.md) |
| L21 | Set Up Security and Governance | `L21-security-and-governance.png` | [md](L21-security-and-governance.md) |
| L22 | Connect to On-Prem Sources Safely | `L22-connect-to-on-prem.png` | [md](L22-connect-to-on-prem.md) |

## Part F — Operate and extend (1 hr)

| # | Lesson | Slide | Notes |
|---|---|---|---|
| L23 | Set Up Observability From Day One | `L23-observability-from-day-one.png` | [md](L23-observability-from-day-one.md) |
| L24 | The Standard Procedure for Adding a Source ⭐ | `L24-adding-a-source-sop.png` | [md](L24-adding-a-source-sop.md) |

---

## The 8 Apparel Group sources this module keeps pointing at

| # | Source | Kind | Load shape they'll choose |
|---|---|---|---|
| 1 | Oracle Retail (RMS) | Oracle DB | JDBC · large master + txn tables |
| 2 | Oracle SIM | Oracle DB | JDBC · inventory positions, high churn |
| 3 | Oracle XStore | Oracle DB | JDBC · POS transactions — **the giant** |
| 4 | Epsilon | SaaS API | loyalty + customer master — **PII** |
| 5 | MoEngage | SaaS API | campaign & engagement |
| 6 | Magento | DB or API | e-commerce orders/customers/products |
| 7 | Vemco Footfall | file/API | optional · small, per-store |
| 8 | Irisys Footfall | file/API | optional · small, per-store |

Three moves repeat all module: **classify a source → choose its load strategy → write its spec.**

## Teaching rhythm
1. **Slide** (5 min) — the decision.
2. **Walk the setup** (15 min) — the DO THIS zone, on screen.
3. **Apply it** (20 min) — same decision, against an Apparel Group source.
4. **Checklist** (5 min) — from the take-home.

## Rebuild
```bash
cd lectures
python render_slides.py Module-02-Foundation   # PNGs + canvas/box overflow + webfont gate
python make_pdf.py     Module-02-Foundation    # one wide 16:9 PDF
```
