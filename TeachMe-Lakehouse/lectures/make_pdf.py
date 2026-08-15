"""Build ONE wide-format (16:9) PDF for a module: slide page + notes page per lesson.

Pages are 1920x1080 px — the same 16:9 as the slides — so nothing is squeezed into
letter/A4. Slides stay VECTOR (SVG passed straight through), so text is crisp at any
zoom and selectable. Notes are flowed into two readable columns.

Usage:  python make_pdf.py [module_folder] [--slides-only]
"""
from __future__ import annotations
import re, sys, pathlib, datetime
import markdown
from playwright.sync_api import sync_playwright

# ── Authorship — appears on the cover page of EVERY module PDF ────────────────
AUTHOR = "Surender Sara"
COMPANY = "Northbay Solutions"
PROGRAMME = "TeachMe-Lakehouse · Training Programme"

ROOT = pathlib.Path(__file__).parent
args = [a for a in sys.argv[1:] if not a.startswith("--")]
MODULE = args[0] if args else "Module-01-Foundations"
SLIDES_ONLY = "--slides-only" in sys.argv
SRC = ROOT / MODULE / "_render"
NOTES = ROOT / MODULE
OUT = ROOT / MODULE / f"{MODULE}.pdf"

SVG_RE = re.compile(r"<svg\b.*?</svg>", re.S | re.I)
# Take the eyebrow and the right-hand footer from the slide itself rather than
# hardcoding them — otherwise every module's notes pages claim to be Module 1.
EYE_RE = re.compile(r'class="eyebrow"[^>]*>([^<]+)</text>')
FOOT_RE = re.compile(r'class="foot"[^>]*>([^<]+)</text>')

css = (SRC / "_style.css").read_text(encoding="utf-8")

"""Fonts come from the module's own _style.css, which @imports ../../_fonts/fonts.css.
The deck HTML is written into the same _render/ folder as _style.css, so that
relative path resolves identically here. No network call at build time."""
HEAD = f"""<!DOCTYPE html><html><head><meta charset="utf-8">
<style>
{css}
@page {{ size: 1920px 1080px; margin: 0; }}
*{{box-sizing:border-box}}
html,body{{margin:0;padding:0;background:#0E1418;-webkit-print-color-adjust:exact;print-color-adjust:exact}}
.page{{width:1920px;height:1080px;overflow:hidden;position:relative;break-after:page;page-break-after:always;background:#0E1418}}
.page:last-child{{break-after:auto;page-break-after:auto}}
.page svg{{display:block}}

/* ---- notes page: wide, two-column flow so line length stays readable ----
   Columns are (1920 - 180 padding - 60 gap) / 2 = 840px. At 13px IBM Plex Mono
   that is ~107 characters, which fits the SQL in the take-homes without wrapping.
   Content that does not fit one page is packed onto continuation pages by the
   measure-and-pack pass below — never silently clipped.                        */
.notes{{padding:64px 90px 58px;color:#D3DEE5;font-family:'Cabin',sans-serif;font-size:18px;line-height:1.5}}
.notes .nhead{{border-bottom:2px solid #243039;padding-bottom:12px;margin-bottom:20px}}
.notes .neye{{font-family:'Asap',sans-serif;font-weight:800;font-size:17px;letter-spacing:3.2px;color:#FF3B47;margin-bottom:6px}}
.notes h1{{font-family:'Asap',sans-serif;font-weight:800;font-size:38px;color:#fff;margin:0}}
.notes .ncols{{column-count:2;column-gap:60px;column-fill:balance;height:838px;overflow:hidden}}
.notes h2{{font-family:'Asap',sans-serif;font-weight:800;font-size:21px;color:#FFB84D;
  margin:0 0 8px;letter-spacing:.4px;break-after:avoid;page-break-after:avoid}}
.notes h2:not(:first-child){{margin-top:18px}}
.notes h3{{font-family:'Asap',sans-serif;font-weight:800;font-size:17.5px;color:#5AA9FF;
  margin:14px 0 6px;break-after:avoid;page-break-after:avoid}}
.notes h4{{font-family:'Asap',sans-serif;font-weight:800;font-size:16px;color:#8CC44C;
  margin:12px 0 5px;break-after:avoid}}
.notes p{{margin:0 0 11px}}
.notes ul,.notes ol{{margin:0 0 12px;padding-left:22px}}
.notes li{{margin:0 0 7px}}
.notes li.task{{list-style:none;margin-left:-20px}}
.notes li.task::before{{content:"\\2610";color:#5AA9FF;font-size:17px;margin-right:8px}}
.notes strong{{color:#fff;font-weight:700}}
.notes em{{color:#A9BAC6}}
.notes hr{{border:0;border-top:1px solid #243039;margin:16px 0}}
.notes a{{color:#6FD8C6;text-decoration:none;border-bottom:1px solid #2A5A52}}
.notes code{{font-family:'IBM Plex Mono',monospace;font-size:15px;color:#6FD8C6;
  background:#141A20;padding:1px 6px;border-radius:5px}}

/* fenced code blocks — the whole point of a SQL take-home. Left un-avoided for
   break-inside so a long block splits across the two columns rather than
   overflowing the page.                                                        */
.notes pre{{background:#0B1013;border:1px solid #2A4A3A;border-radius:8px;
  padding:12px 14px;margin:0 0 13px}}
.notes pre code{{background:none;padding:0;border-radius:0;display:block;
  font-size:13px;line-height:1.5;color:#8CE8B8;
  white-space:pre-wrap;overflow-wrap:break-word}}

.notes blockquote{{margin:0 0 18px;padding:10px 16px;border-left:4px solid #E3000E;
  background:#161C21;color:#A9BAC6;font-size:16px;break-inside:avoid}}
.notes blockquote p:last-child{{margin-bottom:0}}
.notes table{{border-collapse:collapse;width:100%;font-size:16px;margin:0 0 12px;break-inside:avoid}}
.notes th{{text-align:left;font-family:'Asap',sans-serif;font-weight:700;color:#7A8C99;
  font-size:13px;letter-spacing:1.4px;text-transform:uppercase;padding:5px 8px;border-bottom:2px solid #243039}}
.notes td{{padding:5px 8px;border-bottom:1px solid #1C242B;vertical-align:top}}
.notes td code,.notes th code{{font-size:13.5px;padding:0 4px}}
.notes .nfoot{{position:absolute;left:90px;right:90px;bottom:26px;display:flex;justify-content:space-between;
  font-family:'IBM Plex Mono',monospace;font-size:15px;color:#5E7080;border-top:1px solid #1C242B;padding-top:14px}}
/* measuring sandbox — same width as one column, never printed */
#measure{{position:absolute;left:-99999px;top:0;width:840px}}
#measure .mblk{{width:840px}}

/* ---- cover page ---------------------------------------------------------- */
.cover{{padding:0}}
.cover .crule{{position:absolute;top:0;left:0;right:0;height:11px;background:#E3000E}}
.cover .ghost{{position:absolute;right:96px;top:150px;font-family:'Asap',sans-serif;font-weight:800;
  font-size:400px;line-height:.78;color:#161D24;letter-spacing:-14px;user-select:none}}
.cover .cbody{{position:absolute;left:120px;top:214px;right:120px}}
.cover .ceye{{font-family:'Asap',sans-serif;font-weight:800;font-size:23px;letter-spacing:6px;
  color:#FF3B47;margin-bottom:40px}}
.cover h1{{font-family:'Asap',sans-serif;font-weight:800;font-size:78px;line-height:1.06;
  color:#fff;margin:0 0 26px;max-width:1330px}}
.cover .csub{{font-family:'Cabin',sans-serif;font-weight:500;font-size:29px;line-height:1.45;
  color:#A9BAC6;max-width:1200px;margin:0}}
.cover .cmeta{{margin-top:44px;display:flex;gap:14px}}
.cover .chip{{font-family:'Asap',sans-serif;font-weight:800;font-size:18px;letter-spacing:2.4px;
  color:#A9BAC6;border:2px solid #2C3841;border-radius:10px;padding:11px 20px;background:#161C21}}
.cover .credits{{position:absolute;left:120px;right:120px;bottom:132px;display:flex;gap:110px}}
.cover .cl{{font-family:'Asap',sans-serif;font-weight:800;font-size:15px;letter-spacing:3.4px;
  color:#5E7080;margin-bottom:10px}}
.cover .cv{{font-family:'Cabin',sans-serif;font-weight:700;font-size:27px;color:#fff}}
.cover .cfoot{{position:absolute;left:120px;right:120px;bottom:54px;border-top:1px solid #1C242B;
  padding-top:20px;display:flex;justify-content:space-between;
  font-family:'IBM Plex Mono',monospace;font-size:17px;color:#5E7080}}
</style></head><body>
"""

# Code fences are NOT optional: without an extension for them, every ```sql block in a
# take-home is emitted as literal text and flowed into a paragraph. That shipped once.
#
# superfences rather than the stock fenced_code because fenced_code only matches a fence
# at the START of a line — a code block indented inside a numbered list (which several
# take-homes use) silently stays literal. superfences handles both and keeps the block
# nested in its <li>. Falls back to fenced_code if pymdown-extensions is absent, and the
# ``` gate at the end of this script fails the build if anything slipped through.
try:
    import pymdownx  # noqa: F401
    FENCES = "pymdownx.superfences"
except ImportError:
    FENCES = "fenced_code"
    print("  NOTE: pymdown-extensions not installed — fences inside lists will not render")
md = markdown.Markdown(extensions=["tables", "sane_lists", FENCES])

# python-markdown has no task-list support; "- [ ] x" would render as literal "[ ] x".
TASK_RE = re.compile(r"<li>\s*\[([ xX])\]\s*")


def polish(html: str) -> str:
    return TASK_RE.sub(lambda m: '<li class="task">', html)


pages: list[str] = []

slides = sorted(SRC.glob("[LDM]*.html"))  # L##=lesson, D##=diagram, M##=master flow
print(f"building {OUT.name} from {len(slides)} lessons ...")

# ── Cover page — always page 1, carries authorship ────────────────────────────
def esc(s: str) -> str:
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

readme = NOTES / "README.md"
mod_title, mod_sub, chips = MODULE, "", []
if readme.exists():
    rl = readme.read_text(encoding="utf-8").splitlines()
    for line in rl[:12]:
        if line.startswith("# ") and mod_title == MODULE:
            mod_title = line[2:].strip()
        elif line.startswith("### ") and not mod_sub:
            mod_sub = line[4:].strip().strip('"“”')
        elif not chips:
            m = re.match(r"\*\*(.+?)\*\*", line.strip())
            if m and "hour" in m.group(1).lower():
                chips = [c.strip(" .") for c in m.group(1).split("·") if c.strip(" .")]
if not chips:
    chips = [f"{len(slides)} lessons"]

mod_no_m = re.search(r"Module-(\d+)", MODULE)
ghost = mod_no_m.group(1) if mod_no_m else ""
issued = datetime.date.today().strftime("%B %Y")

pages.append(
    '<div class="page cover"><div class="crule"></div>'
    f'<div class="ghost">{ghost}</div>'
    f'<div class="cbody"><div class="ceye">{esc(PROGRAMME).upper()}</div>'
    f'<h1>{esc(mod_title)}</h1>'
    + (f'<p class="csub">{esc(mod_sub)}</p>' if mod_sub else "")
    + '<div class="cmeta">'
    + "".join(f'<span class="chip">{esc(c).upper()}</span>' for c in chips)
    + '</div></div>'
    f'<div class="credits">'
    f'<div><div class="cl">AUTHOR</div><div class="cv">{esc(AUTHOR)}</div></div>'
    f'<div><div class="cl">COMPANY</div><div class="cv">{esc(COMPANY)}</div></div>'
    f'<div><div class="cl">ISSUED</div><div class="cv">{issued}</div></div>'
    f'</div>'
    f'<div class="cfoot"><span>{esc(MODULE)}</span>'
    f'<span>{len(slides)} lessons &#183; 1920&#215;1080 &#183; 16:9</span></div></div>'
)

# ── Gather each lesson: slide SVG + converted notes ──────────────────────────
lessons: list[dict] = []
for s in slides:
    html = s.read_text(encoding="utf-8")
    m = SVG_RE.search(html)
    if not m:
        print(f"  !! no <svg> in {s.name}")
        continue
    note = NOTES / (s.stem + ".md")
    body = ""
    title = s.stem
    if not SLIDES_ONLY and note.exists():
        lines = note.read_text(encoding="utf-8").splitlines()
        title = lines[0].lstrip("# ").strip() if lines else s.stem
        # drop the H1 + the leading "> Module ..." line; they become the page header
        body_src = "\n".join(l for l in lines[1:] if not l.startswith("> **Module"))
        md.reset()
        body = polish(md.convert(body_src))
    elif not SLIDES_ONLY:
        print(f"  -- no notes for {s.stem}")
    eye_m = EYE_RE.search(html)
    lesson_no = re.match(r"L(\d+)", s.stem)
    foot_m = FOOT_RE.search(html)
    lessons.append({
        "stem": s.stem, "svg": m.group(0), "title": title, "body": body,
        "eyebrow": eye_m.group(1) if eye_m else (
            f"LESSON {lesson_no.group(1)}" if lesson_no else MODULE),
        "foot": foot_m.group(1) if foot_m else MODULE,
    })

# ── Measure every top-level note block, then pack into pages ──────────────────
# One .ncols box is 2 columns x 838px. A take-home longer than that used to be
# silently guillotined; now it continues onto as many pages as it needs.
COL_H = 838
BUDGET = int(COL_H * 2 * 0.98)   # headroom for imperfect column balancing


def measure_and_pack(pg) -> dict[str, list[str]]:
    meas = "".join(
        f'<div class="notes" data-l="{L["stem"]}">{L["body"]}</div>'
        for L in lessons if L["body"]
    )
    pg.set_content(HEAD + f'<div id="measure">{meas}</div></body></html>')
    pg.wait_for_timeout(2500)                       # webfonts must load before measuring
    raw_blocks = pg.evaluate("""() => {
        const out = {};
        for (const box of document.querySelectorAll('#measure > .notes')) {
            out[box.dataset.l] = [...box.children].map(el => {
                const cs = getComputedStyle(el);
                return {html: el.outerHTML,
                        h: el.offsetHeight + parseFloat(cs.marginTop || 0)
                                           + parseFloat(cs.marginBottom || 0),
                        tag: el.tagName};
            });
        }
        return out;
    }""")

    packed: dict[str, list[str]] = {}
    for stem, blocks in raw_blocks.items():
        pgs: list[str] = []
        cur: list[dict] = []
        used = 0.0
        i = 0
        while i < len(blocks):
            b = blocks[i]
            if cur and used + b["h"] > BUDGET:
                # never leave a heading stranded at the foot of a page — push it
                # forward with the content it introduces
                while cur and cur[-1]["tag"] in ("H2", "H3", "H4"):
                    used -= cur.pop()["h"]
                    i -= 1
                if cur:
                    pgs.append("".join(x["html"] for x in cur))
                    cur, used = [], 0.0
                    continue
                # a page that is nothing but headings cannot be split further
                cur, used = [], 0.0
            cur.append(b)
            used += b["h"]
            i += 1
        if cur:
            pgs.append("".join(x["html"] for x in cur))
        packed[stem] = pgs or [""]
    return packed


with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page(viewport={"width": 1920, "height": 1080})

    packed = {} if SLIDES_ONLY else measure_and_pack(pg)

    for L in lessons:
        pages.append(f'<div class="page">{L["svg"]}</div>')
        for i, chunk in enumerate(packed.get(L["stem"], [])):
            if not chunk:
                continue
            cont = " (CONT.)" if i else ""
            pages.append(
                f'<div class="page notes" data-lesson="{L["stem"]}#{i+1}">'
                f'<div class="nhead"><div class="neye">{L["eyebrow"]}{cont}</div>'
                f'<h1>{L["title"]}</h1></div><div class="ncols">{chunk}</div>'
                f'<div class="nfoot"><span>TeachMe-Lakehouse · {MODULE}</span>'
                f'<span>{L["foot"]}</span></div></div>'
            )

    doc = HEAD + "\n".join(pages) + "</body></html>"
    tmp = SRC / "_deck.html"
    tmp.write_text(doc, encoding="utf-8")

    pg.goto(tmp.as_uri())
    pg.wait_for_timeout(2500)          # webfonts

    # .ncols has a fixed height and overflow:hidden, so a long take-home would be
    # SILENTLY truncated. Never ship without checking. 2px tolerance for rounding.
    clipped = pg.evaluate("""() => [...document.querySelectorAll('.page.notes')]
        .map(p => {
            const c = p.querySelector('.ncols');
            return {id: p.dataset.lesson, over: c.scrollHeight - c.clientHeight};
        })
        .filter(x => x.over > 2)""")

    # A literal ``` surviving into rendered text means a fenced block did not
    # convert — the exact failure that shipped six broken decks. Fail the build.
    raw_fences = pg.evaluate(r"""() => [...document.querySelectorAll('.page.notes')]
        .filter(p => /```/.test(p.innerText))
        .map(p => p.dataset.lesson)""")

    # also drop the cover out as a PNG — checkable without opening the PDF,
    # and usable on its own as a title card
    cov = pg.query_selector(".page.cover")
    if cov:
        cov.screenshot(path=str(NOTES / "_cover.png"))

    # …and the first notes page that actually contains a code block. Markdown that
    # fails to convert is invisible in a page count but obvious in a picture.
    sample = pg.query_selector(".page.notes:has(pre)")
    if sample:
        sample.screenshot(path=str(NOTES / "_notes_sample.png"))
    cont = pg.query_selector('.page.notes:has-text("(CONT.)")')
    if cont:
        cont.screenshot(path=str(NOTES / "_notes_cont.png"))

    tmp_pdf = OUT.with_suffix(".building.pdf")
    pg.pdf(path=str(tmp_pdf), width="1920px", height="1080px",
           print_background=True, margin={"top": "0", "right": "0", "bottom": "0", "left": "0"})
    b.close()

import os
try:
    os.replace(tmp_pdf, OUT)
except PermissionError:
    print(f"  NOTE: {OUT.name} is open/locked - wrote {tmp_pdf.name} instead")
    OUT = tmp_pdf

tmp.unlink(missing_ok=True)
size_mb = OUT.stat().st_size / 1_048_576
print(f"\n  {OUT}")
print(f"  {len(pages)} pages · {size_mb:.1f} MB · 1920x1080 (16:9 wide)")

if SLIDES_ONLY:
    pass
elif raw_fences:
    print(f"\n  !! {len(raw_fences)} notes page(s) contain a LITERAL ``` — markdown "
          f"did not convert:\n     {', '.join(raw_fences[:10])}")
    sys.exit(1)
elif clipped:
    print(f"\n  !! {len(clipped)} notes page(s) CLIPPED — content lost off the bottom:")
    for c in clipped:
        print(f"     {c['id']}: {c['over']}px over — trim the .md or raise .ncols height")
    sys.exit(1)
else:
    print("  notes pages: 0 clipped · 0 unconverted code fences")
