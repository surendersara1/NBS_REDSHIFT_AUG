# Module 3 — Foundation Architectures
### "Every pattern this course has taught, drawn with real AWS icons"

**35 diagrams · 0 QA defects** · Plan: [`MODULE-03-PLAN.md`](MODULE-03-PLAN.md) · Format: [`../LECTURE-STYLE.md`](../LECTURE-STYLE.md) · One-file deck: **[`Module-03-Foundation-Architectures.pdf`](Module-03-Foundation-Architectures.pdf)**

> These are the artefacts that leave the room — they go into decks, into the SOW response, and onto the wall. Real AWS service icons, correct service names, boundary containers and numbered flows.

---

## Tier 1 · Foundation shapes — the patterns behind Modules 0–2

| # | Diagram | Grammar |
|---|---|---|
| D01 | [The Lakehouse Reference Architecture](D01-lakehouse-reference.png) | flow panels |
| D02 | [Four Paradigms, Four Architectures](D02-four-paradigms.png) | comparison |
| D03 | [The Medallion Layers](D03-medallion-layers.png) | flow panels |
| D04 | [Who Writes, Who Reads](D04-who-reads-who-writes.png) | radial |
| D05 | [Six Ways To Move Data](D05-six-ways-to-move-data.png) | matrix |
| D06 | [The Federated Catalog](D06-federated-catalog.png) | layered |
| D07 | [Zero-Copy Access Paths](D07-zero-copy-paths.png) | comparison |
| D08 | [The Control Plane](D08-control-plane.png) | writers / store / readers |

## Tier 2 · Tamimi as built — the handover record

| # | Diagram | Grammar |
|---|---|---|
| D09 | [Tamimi, End To End](D09-tamimi-end-to-end.png) | flow panels |
| D10 | [The P1 / P2 Split](D10-p1-p2-split.png) | **numbered** |
| D11 | [ABAP To Glue, Stage By Stage](D11-abap-to-glue.png) | flow panels |
| D12 | [Catalog And Storage Layers](D12-catalog-storage-layers.png) | layered |
| D13 | [Environments And Composition](D13-environments-terraform.png) | comparison |
| D14 | [From Commit To Environment](D14-cicd-deployment.png) | **numbered** |

## Tier 3 · Apparel Group target — what we are proposing

| # | Diagram | Grammar |
|---|---|---|
| D15 | [Target Architecture](D15-ag-target-architecture.png) | flow panels |
| D16 | [Eight Sources, Three Connectors](D16-source-onboarding.png) | fan-in |
| D17 | [**Oracle — Three Ways In**](D17-oracle-three-options.png) ⭐ | comparison |
| D18 | [Reaching The On-Prem Sources](D18-network-connectivity.png) | **VPC containers** |
| D19 | [PII And The Security Model](D19-pii-security.png) | layered |
| D20 | [What Gets Promoted](D20-promotion-path.png) | flow |

## Tier 4 · Advanced deep dives — numbered AWS-reference style

*All ten carry a numbered narration in their take-home — one paragraph per badge.*

| # | Diagram | Notes |
|---|---|---|
| D21 | [Event-Driven File Ingestion](D21-event-driven-ingestion.png) | [md](D21-event-driven-ingestion.md) |
| D22 | [CDC — Reading The Log, Not The Table](D22-cdc-pipeline.png) | [md](D22-cdc-pipeline.md) |
| D23 | [Zero-ETL — And Where It Stops](D23-zero-etl-deep-dive.png) | [md](D23-zero-etl-deep-dive.md) |
| D24 | [Streaming — Two Landing Paths](D24-streaming-ingestion.png) | [md](D24-streaming-ingestion.md) |
| D25 | [Orchestration And The Barrier](D25-orchestration-barriers.png) | [md](D25-orchestration-barriers.md) |
| D26 | [Observability And The Ops Console](D26-observability.png) | [md](D26-observability.md) |
| D27 | [Sharing Across Accounts](D27-cross-account-sharing.png) | [md](D27-cross-account-sharing.md) |
| D28 | [One Query, Every Control It Passes](D28-security-deep-dive.png) | [md](D28-security-deep-dive.md) |
| D29 | [Following The Money](D29-cost-and-lifecycle.png) | [md](D29-cost-and-lifecycle.md) |
| D30 | [Recovery, Backfill And Time Travel](D30-dr-backfill-time-travel.png) | [md](D30-dr-backfill-time-travel.md) |

## Tier 5 · Apparel Group master flows — for the SOW response and kickoff

| # | Diagram | What it answers |
|---|---|---|
| M01 | [The Programme, End To End](M01-programme-master-flow.png) | six phases, and what actually delays them |
| M02 | [Source To Dashboard, Traced](M02-source-to-dashboard.png) | "where does this number come from?" |
| M03 | [The Retail Domain Model](M03-retail-domain-model.png) | four dimensions, four facts, and what feeds each |
| M04 | [Delivery Waves And What Blocks Them](M04-delivery-waves.png) | wave order, and the non-engineering blockers |
| M05 | [Go-Live And Operations](M05-go-live-operations.png) | parallel run → sign-off → cutover → handover |

---

## The two diagram grammars

**Grammar A — flow panels.** Labelled column panels left to right with a cross-cutting band. Icon 66×66, name at `+80,+30`, detail at `+80,+54`, rows 90px apart. For *"what are the pieces and in what order."*

**Grammar B — numbered reference.** The AWS style: **AWS Cloud** / **Region** / **VPC** boundary containers, service group boxes (Step Functions pink, Lake Formation purple), and **numbered badges on the arrows**. Icons 64×64 with the label centred *below*. For *"walk me through what happens, in order."*

> **The rule for Grammar B:** every numbered badge gets exactly one numbered paragraph in the companion `.md`. A badge with no paragraph is a bug, not a style choice. See [D21](D21-event-driven-ingestion.md) for the reference implementation.

## The icon library

**605 icons** at [`../_icons/`](../_icons/), indexed in [`../_icons/ICONS.md`](../_icons/ICONS.md) — 524 AWS across 26 categories, 65 on-prem (Oracle, SQL Server, PostgreSQL…), 16 SaaS. Regenerate with [`../sync_icons.py`](../sync_icons.py).

Referenced relatively so both render paths resolve:

```xml
<image href="../../_icons/aws/analytics/redshift.png" x="756" y="396" width="66" height="66"/>
```

Legacy line-art icons (Oracle, generic client/disk/user) sit on a `#1E262D` tile so their visual weight matches the modern coloured AWS tiles.

## The typefaces are self-hosted

Slides used to `<link>` fonts.googleapis.com at render time, which made the whole
build depend on the network. When Google was briefly unreachable, the webfont gate
correctly refused to render all 35 diagrams — after waiting 20s each. Ten minutes,
nothing produced.

[`fetch_fonts.py`](../fetch_fonts.py) downloads Asap, Cabin and IBM Plex Mono once into
[`../_fonts/`](../_fonts/); every module's `_style.css` `@import`s them. Renders are now
offline-capable, deterministic and considerably faster.

## Quality gates

`render_slides.py` fails the build on any of:
- a **missing icon** — it would otherwise render as a silent hole in the diagram
- text outside the **canvas** safe margins
- text escaping the **panel it visually belongs to**
- **webfonts** not loaded (fallback metrics shift every layout)

`make_pdf.py` additionally fails on **notes-page clipping**.

## Rebuild

```bash
cd lectures
python fetch_fonts.py                             # once — self-host the typefaces
python sync_icons.py                              # refresh the shared icon library
python render_slides.py Module-03-Foundation-Architectures
python make_pdf.py     Module-03-Foundation-Architectures
```

## Status

**35 diagrams · 35 take-homes · 0 QA defects · complete.**

Every diagram has a companion `.md`. The thirteen Grammar B diagrams (D10, D14, D21–D30,
M05) each carry a numbered narration — one paragraph per badge — because that pairing is
a correctness requirement of the grammar, not an optional extra.
