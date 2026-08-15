"""Build a CLICKABLE A4 PDF from a single markdown document.

Different job from make_pdf.py: that one builds 16:9 decks (slide + notes per lesson).
This one turns one .md reference document into a paginated A4 portrait PDF where every
URL is a live hyperlink — for lab guides, runbooks and link collections that people read
and click rather than project.

Chromium's print-to-PDF preserves <a href> as PDF link annotations, so the anchors have
to survive markdown conversion: bare URLs are auto-linked here because python-markdown
does not do that on its own.

Usage:  python make_doc_pdf.py <module_folder> <doc.md> [out_name.pdf]
"""
from __future__ import annotations
import re, sys, pathlib, datetime, os
import markdown
from playwright.sync_api import sync_playwright

AUTHOR = "Surender Sara"
COMPANY = "Northbay Solutions"
PROGRAMME = "TeachMe-Lakehouse · Training Programme"

ROOT = pathlib.Path(__file__).parent
if len(sys.argv) < 3:
    sys.exit("usage: python make_doc_pdf.py <module_folder> <doc.md> [out_name.pdf]")
MODULE = sys.argv[1]
DOC = ROOT / MODULE / sys.argv[2]
OUT = ROOT / MODULE / (sys.argv[3] if len(sys.argv) > 3 else DOC.stem + ".pdf")
if not DOC.exists():
    sys.exit(f"no such document: {DOC}")

raw = DOC.read_text(encoding="utf-8")
lines = raw.splitlines()

# ── cover metadata: same convention as make_pdf.py — "# ", "### ", "**… days …**" ──
title = sub = ""
chips: list[str] = []
for line in lines[:10]:
    if line.startswith("# ") and not title:
        title = line[2:].strip()
    elif line.startswith("### ") and not sub:
        sub = line[4:].strip().strip('"“”')
    elif not chips:
        m = re.match(r"\*\*(.+?)\*\*", line.strip())
        if m and re.search(r"day|hour|lesson|lab", m.group(1), re.I):
            chips = [c.strip(" .") for c in m.group(1).split("·") if c.strip(" .")]

# strip the H1/H3/chips line from the body — they are the cover
body_src = "\n".join(
    l for l in lines
    if not (l.startswith("# ") or l.startswith("### ")
            or (chips and l.strip().startswith("**") and re.match(r"\*\*(.+?)\*\*", l.strip())
                and re.search(r"day|hour|lesson|lab", l, re.I)))
)

# python-markdown leaves bare URLs as text, which would kill the whole point of this
# script. Auto-link them — but never inside an existing markdown link or a code span.
URL_RE = re.compile(r"(?<![\(\[`])(https?://[^\s<>\)\]`|]+)")


def autolink(text: str) -> str:
    out, in_fence = [], False
    for ln in text.splitlines():
        if ln.lstrip().startswith("```"):
            in_fence = not in_fence
            out.append(ln)
            continue
        out.append(ln if in_fence else URL_RE.sub(r"[\1](\1)", ln))
    return "\n".join(out)


try:
    import pymdownx  # noqa: F401
    FENCES = "pymdownx.superfences"      # also handles fences indented inside lists
except ImportError:
    FENCES = "fenced_code"
md = markdown.Markdown(extensions=["tables", "sane_lists", FENCES])
body = md.convert(autolink(body_src))

issued = datetime.date.today().strftime("%d %B %Y")
mod_no = re.search(r"Module-(\d+)", MODULE)
ghost = mod_no.group(1) if mod_no else ""

HTML = f"""<!DOCTYPE html><html><head><meta charset="utf-8">
<style>
@import url("../_fonts/fonts.css");
@page {{ size: A4 portrait; margin: 18mm 16mm 20mm; }}
@page :first {{ margin: 0; }}
*{{box-sizing:border-box}}
html,body{{margin:0;padding:0;background:#0E1418;color:#D3DEE5;
  font-family:'Cabin',sans-serif;font-size:10.5pt;line-height:1.55;
  -webkit-print-color-adjust:exact;print-color-adjust:exact}}

/* ---- cover: full-bleed first page ---------------------------------------- */
.cover{{position:relative;width:210mm;height:297mm;overflow:hidden;
  break-after:page;page-break-after:always;background:#0E1418}}
.cover .crule{{position:absolute;top:0;left:0;right:0;height:7mm;background:#E3000E}}
.cover .ghost{{position:absolute;right:14mm;top:44mm;font-family:'Asap',sans-serif;
  font-weight:800;font-size:150pt;line-height:.78;color:#161D24;letter-spacing:-6pt}}
.cover .cbody{{position:absolute;left:20mm;right:20mm;top:62mm}}
.cover .ceye{{font-family:'Asap',sans-serif;font-weight:800;font-size:10pt;
  letter-spacing:3pt;color:#FF3B47;margin-bottom:14mm}}
.cover h1{{font-family:'Asap',sans-serif;font-weight:800;font-size:34pt;line-height:1.08;
  color:#fff;margin:0 0 6mm}}
.cover .csub{{font-family:'Cabin',sans-serif;font-weight:500;font-size:14pt;
  line-height:1.45;color:#A9BAC6;margin:0}}
.cover .cmeta{{margin-top:12mm;display:flex;flex-wrap:wrap;gap:3mm}}
.cover .chip{{font-family:'Asap',sans-serif;font-weight:800;font-size:8pt;
  letter-spacing:1.6pt;color:#A9BAC6;border:1.5pt solid #2C3841;border-radius:3mm;
  padding:2.5mm 4mm;background:#161C21}}
.cover .credits{{position:absolute;left:20mm;right:20mm;bottom:38mm;display:flex;gap:18mm}}
.cover .cl{{font-family:'Asap',sans-serif;font-weight:800;font-size:7.5pt;
  letter-spacing:2pt;color:#5E7080;margin-bottom:2mm}}
.cover .cv{{font-family:'Cabin',sans-serif;font-weight:700;font-size:13pt;color:#fff}}
.cover .cfoot{{position:absolute;left:20mm;right:20mm;bottom:16mm;
  border-top:.5pt solid #1C242B;padding-top:5mm;display:flex;justify-content:space-between;
  font-family:'IBM Plex Mono',monospace;font-size:8pt;color:#5E7080}}

/* ---- document body ------------------------------------------------------- */
h2{{font-family:'Asap',sans-serif;font-weight:800;font-size:17pt;color:#fff;
  margin:9mm 0 3mm;padding-bottom:2mm;border-bottom:1.5pt solid #243039;
  break-after:avoid;page-break-after:avoid}}
h3{{font-family:'Asap',sans-serif;font-weight:800;font-size:12.5pt;color:#FFB84D;
  margin:6mm 0 2mm;break-after:avoid;page-break-after:avoid}}
h4{{font-family:'Asap',sans-serif;font-weight:800;font-size:10.5pt;color:#5AA9FF;
  margin:5mm 0 2mm;break-after:avoid}}
p{{margin:0 0 3mm}}
ul,ol{{margin:0 0 3.5mm;padding-left:6mm}}
li{{margin:0 0 1.6mm}}
strong{{color:#fff;font-weight:700}}
em{{color:#A9BAC6}}
hr{{border:0;border-top:.5pt solid #243039;margin:7mm 0}}
a{{color:#6FD8C6;text-decoration:none;border-bottom:.5pt solid #2A5A52;
  word-break:break-all}}
code{{font-family:'IBM Plex Mono',monospace;font-size:9pt;color:#6FD8C6;
  background:#141A20;padding:.4mm 1.4mm;border-radius:1mm}}
pre{{background:#0B1013;border:.5pt solid #2A4A3A;border-radius:2mm;padding:3mm;
  margin:0 0 4mm;overflow:hidden;break-inside:avoid}}
pre code{{background:none;padding:0;font-size:8.5pt;color:#8CE8B8}}
blockquote{{margin:0 0 4mm;padding:3mm 4mm;border-left:1.5pt solid #E3000E;
  background:#161C21;color:#A9BAC6;font-size:10pt;break-inside:avoid}}
blockquote p:last-child{{margin-bottom:0}}
table{{border-collapse:collapse;width:100%;font-size:9pt;margin:0 0 4mm;
  break-inside:avoid;page-break-inside:avoid}}
th{{text-align:left;font-family:'Asap',sans-serif;font-weight:700;color:#7A8C99;
  font-size:7.5pt;letter-spacing:.9pt;text-transform:uppercase;padding:2mm;
  border-bottom:1.5pt solid #243039}}
td{{padding:2mm;border-bottom:.5pt solid #1C242B;vertical-align:top}}
td code{{font-size:8pt}}
</style></head><body>
<div class="cover"><div class="crule"></div><div class="ghost">{ghost}</div>
<div class="cbody"><div class="ceye">{PROGRAMME.upper()}</div>
<h1>{title}</h1>{f'<p class="csub">{sub}</p>' if sub else ''}
<div class="cmeta">{''.join(f'<span class="chip">{c.upper()}</span>' for c in chips)}</div>
</div>
<div class="credits">
<div><div class="cl">AUTHOR</div><div class="cv">{AUTHOR}</div></div>
<div><div class="cl">COMPANY</div><div class="cv">{COMPANY}</div></div>
<div><div class="cl">ISSUED</div><div class="cv">{issued}</div></div></div>
<div class="cfoot"><span>{MODULE}</span><span>A4 &#183; clickable links</span></div></div>
{body}
</body></html>"""

tmp = ROOT / MODULE / "_doc.html"
tmp.write_text(HTML, encoding="utf-8")

print(f"building {OUT.name} from {DOC.name} ...")
with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page()
    pg.goto(tmp.as_uri())
    pg.wait_for_timeout(2000)  # webfonts

    # every href in the rendered doc — the count must survive into the PDF
    hrefs = pg.evaluate("() => [...document.querySelectorAll('a[href]')].map(a => a.href)")

    # drop the cover out as a PNG, checkable without opening the PDF
    cov = pg.query_selector(".cover")
    if cov:
        cov.screenshot(path=str(OUT.with_name(OUT.stem + "_cover.png")))

    tmp_pdf = OUT.with_suffix(".building.pdf")
    pg.pdf(path=str(tmp_pdf), format="A4", print_background=True)
    b.close()

try:
    os.replace(tmp_pdf, OUT)
except PermissionError:
    print(f"  NOTE: {OUT.name} is locked - wrote {tmp_pdf.name} instead")
    OUT = tmp_pdf
tmp.unlink(missing_ok=True)

# Verify the links actually became PDF link annotations. A PDF that merely LOOKS like it
# has links is the failure mode this script exists to prevent.
try:
    from pypdf import PdfReader
    r = PdfReader(str(OUT))
    found = 0
    for page in r.pages:
        for a in page.get("/Annots") or []:
            o = a.get_object()
            uri = (o.get("/A") or {}).get("/URI")
            if uri:
                found += 1
    print(f"\n  {OUT}")
    print(f"  {len(r.pages)} pages · {OUT.stat().st_size/1048576:.1f} MB · A4 portrait")
    print(f"  anchors in HTML: {len(hrefs)}  ·  clickable in PDF: {found}")
    if found == 0:
        sys.exit("  !! NO clickable links in the PDF — anchors were lost")
except ImportError:
    print(f"\n  {OUT}  ({len(hrefs)} anchors; install pypdf to verify annotations)")
