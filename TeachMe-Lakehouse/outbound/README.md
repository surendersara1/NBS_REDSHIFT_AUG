# Outbound — the shareable decks

Copies of every module PDF, in one place, ready to attach or upload.
Each opens with an authored cover page — **Surender Sara · Northbay Solutions**.

Six **decks** are wide 16:9 (1920×1080) for projecting. One **reference document** is A4
portrait with live clickable links, marked 🔗 below — it is meant to be read on a laptop
and clicked, not projected.

| Deck | Pages | Size | What it is | Who it's for |
|---|---:|---:|---|---|
| **Module-00-Basics.pdf** | 103 | 1.6 MB | The ecosystem decoded — warehouse vs lake vs lakehouse vs mesh, warehouse design in Redshift, who can read and write, pipelines and streaming, S3 and the federated catalog | anyone with no data-engineering background |
| **Module-01-Basics-Redshift-Deep-Dive.pdf** | 166 | 2.7 MB | **Redshift mastery in 45 lessons** — infrastructure, objects, physical design, loading, performant SQL, procedures and UDFs, operations. Written for developers coming from Node.js and an app database | ⭐ the three new hires |
| 🔗 **Module-01-Redshift-Hands-On-Labs.pdf** | 6 | 0.4 MB | **The four-day AWS Redshift lab plan** — every official workshop mapped to the 45 lessons, plus two custom labs for the gaps AWS does not cover. **25 clickable links**, all verified live 12 Aug 2026 | the same three hires, at the keyboard |
| **Module-01-Foundations.pdf** | 61 | 1.7 MB | How the Tamimi platform is actually built — medallion layers, catalog, Spectrum, the repo | the delivery team |
| **Module-02-Foundation.pdf** | 104 | 2.1 MB | **How to build the next one** — the decisions, the setup and the reasoning, aimed at Apparel Group | ⭐ teach from this one |
| **Module-02-Tamimi.pdf** | 107 | 2.6 MB | The same ground as a worked example on Tamimi | maintainer's reference — see the note below |
| **Module-03-Foundation-Architectures.pdf** | 105 | 2.5 MB | 35 architecture diagrams with real AWS icons, incl. 5 Apparel Group master flows | client-facing and the wall |

## Quality

All six decks pass the full render gate: **no missing icons, nothing outside the canvas,
no text escaping the panel it belongs to, no clipped notes pages.** Verified on every
slide in every module — 184 slides in total.

> **Notes pages rebuilt 12 Aug 2026 — two separate bugs.**
>
> **1 ·** The builder had no markdown code-fence extension at all, so all **310 code
> blocks** across the course rendered as literal ```` ```sql ```` text flowed into
> paragraphs.
> **2 ·** The obvious fix (`fenced_code`) only matches a fence at the *start of a line*,
> so code indented inside a numbered list stayed literal anyway. Now on
> `pymdownx.superfences`, which handles both and keeps the block nested in its list item.
>
> Take-homes also now continue onto **as many pages as they need** — the old build forced
> each one into a single fixed box and silently guillotined the overflow, which is why
> page counts roughly doubled.
>
> Three gates now guard the text pages and fail the build: **no unconverted ``` fences ·
> no clipped content · no missing take-home.** Each deck also drops `_cover.png`,
> `_notes_sample.png` and `_notes_cont.png` beside it, so the pages can be eyeballed
> without opening the PDF.
>
> Re-sync this folder any time with `python sync_outbound.py` from the parent directory —
> it names any file that is locked open in a viewer rather than skipping it silently.

The lab-track document is checked differently: every anchor is confirmed to survive into
the PDF as a real link annotation (**18 anchors → 25 clickable rectangles, 7 distinct
destinations**), and every destination URL was fetched live before publishing. A PDF that
merely *looks* like it has links is the failure mode that check exists to prevent.

## Before you send

- **Module-01-Basics-Redshift-Deep-Dive** is the onboarding deck for the three new
  Redshift engineers. It assumes no warehouse background and pairs with 45 take-home
  `.md` files of runnable SQL that live beside the source, not in this folder — send
  both if you are handing over the whole course.
- **Module-01-Redshift-Hands-On-Labs** provisions **real billable AWS infrastructure**. It
  carries its own cost and teardown section — MWAA and Managed Grafana are the expensive
  ones and neither auto-pauses. Send it with the instruction to use a dedicated training
  account, never Tamimi Dev.
- **Module-02-Foundation** is the teaching deck. **Module-02-Tamimi** covers the same ground retrospectively and names what went wrong on Tamimi — fine internally, think twice before it goes to a third party.
- **Module-03** contains Tamimi internals (D09–D14) alongside the Apparel Group material. If it is going to Apparel Group, ask for the **client-safe cut** — Tier 1 + Tier 3 + the master flows only.

## Regenerating

These are copies. The originals live beside their sources:

```bash
cd lectures
python make_pdf.py Module-00-Basics          # 16:9 decks — …and each other module

# the A4 clickable reference document
python make_doc_pdf.py Module-01-Basics-Redshift-Deep-Dive \
                       LAB-TRACK.md Module-01-Redshift-Hands-On-Labs.pdf
```

Then re-copy into this folder. Nothing here is edited by hand.
