# Lecture Slide Format — locked spec

The single source of truth for every slide in the 40-hour course. **Lock this before mass-producing lessons.** Reference implementation: [`_render/L03-catalog-storage.html`](_render/L03-catalog-storage.html) → [`L03-catalog-storage.png`](L03-catalog-storage.png).

**Audience:** 10 application developers. Strong coders, **zero** data-engineering / lakehouse background. Everything is explained from first principles and then tied to a real file in this repo.
**Setting:** projected in a room. Read from the back row. Dark ground, heavy type, generous space. **Never compact.**

---

## 1. Canvas

| Property | Value | Why |
|---|---|---|
| Size | **1920 × 1080** (16:9) | native projector / Full-HD; 1:1 pixel mapping, no scaling blur |
| Margins | **90 px** left/right, 60 px top, 40 px bottom | safe area — projectors crop edges |
| Ground | `#0E1418` deep charcoal | not pure black: less eye strain, no halation on projectors |
| Brand rule | `#E3000E` bar, 11 px, full width, top | Tamimi identity on every slide |

## 2. Type scale (heavy — this is the readability contract)

| Role | Font | Weight | Size | Colour |
|---|---|---|---|---|
| Eyebrow (`MODULE 1 · LESSON 03`) | Asap | **800** | 22 px, +4 letter-spacing | `#FF3B47` |
| **Slide title** | Asap | **800** | **62 px** | `#FFFFFF` |
| Subtitle | Cabin | 500 | 27 px | `#A9BAC6` |
| Zone caption (`1 · THE CATALOG`) | Asap | **800** | 19 px, +3.5 tracking | `#7A8C99` |
| Box title | Asap | **800** | 31 px | `#FFFFFF` / `#0E1418` on light |
| Box body | Cabin | **600** | 21 px | `#D3DEE5` |
| Code / paths | IBM Plex Mono | 500–600 | 17 px | `#6FD8C6` |
| Edge label | Cabin | **700** | 20 px | `#A9BAC6` |
| Footer | Cabin / Plex Mono | 500–600 | 18–19 px | `#5E7080` |

> **Rule:** nothing below **17 px**. Body copy never lighter than **500**. Titles always **800**.
> Fonts are Tamimi's own (Asap + Cabin, sampled from tamimimarkets.com) + IBM Plex Mono for code.

## 3. Palette (dark-optimised, semantic ≠ brand)

| Token | Hex | Use |
|---|---|---|
| Ground | `#0E1418` | slide background |
| Panel | `#1B2329` / `#1B2A33` | neutral boxes |
| Border | `#2C3841` / `#3A4854` | box outlines, dashed groupings |
| **Brand red** | `#E3000E` | filled hero box, top rule |
| Brand red (text on dark) | `#FF3B47` | eyebrows, arrows — brightened for contrast |
| Write / input | `#5AA9FF` on `#12283F` | anything that *writes* |
| Read / output | `#3FD98A` on `#12331F` | anything that *reads* |
| Teach / analogy | `#FFB84D` on `#1A1E15` | the "In Plain English" strip |
| Muted / not-used | `#8296A3`, dashed border | out-of-scope, greyed |

Colour is **meaning**, and it stays constant across all 40 hours: **red = the thing being taught · blue = write · green = read · amber = plain-English · dashed grey = not used here.**

## 4. Slide skeleton (every slide follows this)

```
┌─ red rule ─────────────────────────────────────────────┐
│  MODULE n · LESSON nn                        (eyebrow) │
│  Slide Title In Sentence Case                 (62 px)  │
│  One-line subtitle framing the question       (27 px)  │
│  ────────────────────────────────────────────────────  │
│                                                        │
│   1 · ZONE CAP      2 · ZONE CAP      3 · ZONE CAP     │
│   ┌────────┐        ┌────────┐        ┌────────┐       │
│   │  box   │──────▶ │  box   │ ◀──────│  box   │       │
│   └────────┘        └────────┘        └────────┘       │
│                     file/path under or inside each box │
│                                                        │
│  ┌── IN PLAIN ENGLISH ─────────────────────────────┐   │
│  │ the analogy, for app coders                     │   │
│  └─────────────────────────────────────────────────┘   │
│  TeachMe-Lakehouse · Module n · Lesson nn   Tamimi …   │
└────────────────────────────────────────────────────────┘
```

**Non-negotiables on every slide**
1. **Numbered zones** (`1 ·`, `2 ·`, `3 ·`) — gives the lecturer a spoken path through the slide.
2. **Every box carries its real repo path** (`writers/s3_tables.py`) — theory is always tied to code they can open.
3. **The "In Plain English" strip** — one analogy in non-data language. This is what makes it land for app coders.
4. **Max 3 zones / ~9 boxes per slide.** If it needs more, it's two lessons.

## 5. Naming & structure

```
lectures/
├── LECTURE-STYLE.md              ← this file
├── L03-catalog-storage.png       ← the shipped slide
└── _render/
    └── L03-catalog-storage.html  ← editable source (SVG)
```
File naming: `L<nn>-<kebab-topic>.{html,png}` — `nn` is the global lesson number so slides sort in teaching order.

## 6. Render pipeline (repeatable, 30 seconds per slide)

```bash
cd lectures/_render
python -m http.server 8902           # serve
# browser at 1920×1080 → screenshot the #slide element → PNG
```
Output is **1920×1080 PNG**, ready to drop into PowerPoint/Keynote/Google Slides one-per-slide, or present straight from the browser.

**Why SVG-in-HTML and not PowerPoint:** the source is text, so it diffs in git, regenerates when the code changes, and stays perfectly consistent across 40 hours of material. No manual box-dragging, no drift.

## 7. Checklist before a slide ships
- [ ] Title ≤ 6 words, subtitle asks/answers one question
- [ ] Zones numbered; ≤ 3 zones
- [ ] Every box has a real, verified repo path
- [ ] "In Plain English" strip present and jargon-free
- [ ] No text touching or overflowing a box edge *(check the render, not the source)*
- [ ] Nothing below 17 px; body ≥ weight 500
- [ ] Colours follow the semantic map (§3)
