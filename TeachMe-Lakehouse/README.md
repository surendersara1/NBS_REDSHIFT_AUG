# TeachMe-Lakehouse

Working folder for the Tamimi Lakehouse **enablement, design and ops-console** work. Deliberately **outside** the client repo (`../tamimi-lakehouse/`) so nothing here pollutes the delivery codebase — this is where all new work lands.

```
TeachMe-Lakehouse/
├── lectures/          the training course — slides, take-homes, wide 16:9 PDFs
│   ├── LECTURE-STYLE.md          ← locked slide format spec
│   ├── render_slides.py          ← batch render + canvas/box/webfont QA
│   ├── make_pdf.py               ← wide 16:9 PDF builder + clipping check
│   ├── Module-00-Basics/         34 lessons · the ecosystem, decoded
│   ├── Module-01-Foundations/    22 lessons · how our platform is built
│   ├── Module-02-Foundation/     24 lessons · how to build the next one
│   └── Module-02-Tamimi/         24 lessons · the Tamimi worked example
├── diagrams/          architecture diagrams (editable source + rendered images)
│   ├── catalog-storage-layers.drawio   ← open in draw.io / VS Code Draw.io ext
│   ├── catalog-storage-layers.png      ← the shareable image (1400×840 @2×)
│   └── _render/                         SVG source; re-render to PNG anytime
├── ops-console/       the read-only operations & monitoring console
│   ├── ops-console-mockup.html          ← open in a browser; 8 screens, light+dark
│   └── README.md                        build plan: React → API → hosting → CI/CD
├── docs/              plans, audits, learning material
└── reference/         (empty) scratch / inputs
```

## The course

Four modules for 10 application developers with no data-engineering background, being trained for the Apparel Group engagement.

| Module | Lessons | Hrs | What it is | Deck |
|---|---:|---:|---|---|
| **[00 · Basics](lectures/Module-00-Basics/)** | 34 | 23 | The ecosystem decoded — warehouse vs lake vs lakehouse vs mesh, warehouse design in Redshift, who can read/write, pipelines and streaming, S3 and the federated catalog | `Module-00-Basics.pdf` |
| **[01 · Foundations](lectures/Module-01-Foundations/)** | 22 | 16 | How the Tamimi platform is actually built — medallion layers, catalog, Spectrum, the repo | `Module-01-Foundations.pdf` |
| **[02 · Foundation](lectures/Module-02-Foundation/)** | 24 | 18 | **Teach from this.** How to build the next one: the decisions, the setup and the reasoning, aimed at Apparel Group | `Module-02-Foundation.pdf` |
| **[02 · Tamimi](lectures/Module-02-Tamimi/)** | 24 | 18 | The same ground as a worked example on Tamimi — maintainer's reference, not lecture material | `Module-02-Tamimi.pdf` |

Every slide is a **1920×1080 PNG** with a companion take-home `.md`; each module also ships as **one wide 16:9 PDF** (slide page + notes page per lesson). Sources are hand-authored SVG in `_render/`, so everything diffs in git.

**Quality gates** — both scripts fail loudly rather than shipping quietly:
- `render_slides.py` — webfont load gate, canvas/margin bounds, and **box containment** (text must sit inside the panel it visually belongs to)
- `make_pdf.py` — detects **notes-page clipping**, since the two-column notes area has a fixed height and would otherwise truncate silently

Current status: **104 slides across four modules, 0 QA defects, 0 clipped notes pages.**

## What else is here

| File | What it is |
|---|---|
| `diagrams/catalog-storage-layers.*` | Fed Glue Catalog → S3 Tables → Iceberg → S3, with R/W paths, annotated with real repo file paths |
| `ops-console/ops-console-mockup.html` | Tamimi-branded ops console mockup — env-scoped (QA), 8 screens, timestamps + per-step durations |
| `ops-console/README.md` | Per-env deployment model + the CI/CD step to add to `bitbucket-pipelines.yml` |
| `docs/PLAN-ops-monitoring-dashboard.md` | The two-tier plan (CloudWatch for UAT §8.2 → Grafana → custom console) |
| `docs/MCP-SETUP.md` | How developers configure MCP servers (`.mcp.json`, secrets as `${VAR}`) |
| `docs/LEARNING-glue-ingestion-and-abap-to-glue.{md,html}` | Phase A full-load · Phase B CDC · Phase 3 ABAP→Glue walkthrough |
| `docs/PHASE-TO-SRC-AND-TF-MAP.md` | Phase → source code → Terraform traceability tables |
| `docs/audit_deep_analysis.md` (+ `_prompt`) | The CTO-level architecture/security audit |
| `docs/dbt_onboarding.md`, `docs/professor_dbt.md` | dbt curriculum for the team + the prompt that generates it |

## Notes

- **`docs/*` copies vs originals.** The learning/audit docs were already committed to the client repo (commit `573b4ff` on `develop`). They are **copied** here, not moved — the originals remain in `tamimi-lakehouse/`. Say the word if you want them removed from the client repo.
- **`.mcp.json` stayed behind on purpose.** Claude Code only reads a *project-scoped* MCP config from the **repo root**, so `tamimi-lakehouse/.mcp.json` must stay where it is to work for developers. Moving it here would break it.
- **Git:** this folder sits inside the `E:\NBS_Tamimi_Lakehouse` workspace repo (not the client `tamimi-lakehouse` repo), and is currently untracked there.

## Re-rendering a diagram
```bash
cd diagrams/_render
python -m http.server 8901          # then screenshot the page at 2× device scale
```
Or open the `.drawio` in draw.io and export directly.
