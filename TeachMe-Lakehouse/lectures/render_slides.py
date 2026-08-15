"""Batch-render every lecture slide HTML -> 1920x1080 PNG.

Usage:  python render_slides.py [module_folder]
Default module folder: Module-01-Foundations

Renders every `_render/L*.html` to `<module>/L*.png`, then reports any slide
whose text overflows its slide bounds (the one defect that keeps recurring).
"""
from __future__ import annotations
import sys, pathlib, re
from playwright.sync_api import sync_playwright

ROOT = pathlib.Path(__file__).parent
MODULE = sys.argv[1] if len(sys.argv) > 1 else "Module-01-Foundations"
SRC = ROOT / MODULE / "_render"
OUT = ROOT / MODULE

files = sorted(SRC.glob("[LDM]*.html"))  # L##=lesson, D##=diagram, M##=master flow
if not files:
    print(f"no slides found in {SRC}")
    sys.exit(1)

print(f"rendering {len(files)} slides from {SRC}\n")

# A missing icon renders as NOTHING — no error, just a hole in the diagram that
# you only catch by eye. Verify every referenced path up front instead.
missing_icons = []
for f in files:
    for ref in re.findall(r'href="((?:\.\./)+_icons/[^"]+)"', f.read_text(encoding="utf-8")):
        if not (SRC / ref).resolve().exists():
            missing_icons.append((f.name, ref))
if missing_icons:
    print(f"  !! {len(missing_icons)} MISSING ICON(S) — fix before rendering:")
    for n, ref in missing_icons:
        print(f"     {n}: {ref}")
    sys.exit(1)

ok, bad = [], []

with sync_playwright() as p:
    browser = p.chromium.launch()
    page = browser.new_page(viewport={"width": 1920, "height": 1080})
    for f in files:
        page.goto(f.as_uri())
        # Gate on the real webfonts: a cold-cache miss silently falls back to a
        # taller face and the 62px title collides with the eyebrow. Never render
        # until all three families report loaded.
        try:
            # Google serves ~28 unicode-range subset faces per family, and
            # fonts.check() is false if ANY matching subset is unfetched — too
            # strict. What matters: loading has settled AND at least one real
            # face of each family actually downloaded.
            page.wait_for_function(
                """() => {
                    if (document.fonts.status !== 'loaded') return false;
                    const fam = n => [...document.fonts].some(
                        f => f.family.replace(/["']/g,'') === n && f.status === 'loaded');
                    return fam('Asap') && fam('Cabin') && fam('IBM Plex Mono');
                }""",
                timeout=20000,
            )
        except Exception:
            print(f"  !! {f.name}: webfonts did NOT load - render would use fallback metrics; SKIPPED")
            bad.append((f.name, "webfonts failed to load"))
            continue
        page.wait_for_timeout(300)
        el = page.query_selector("#slide")
        if el is None:
            bad.append((f.name, "no #slide element"))
            continue
        png = OUT / (f.stem + ".png")
        el.screenshot(path=str(png))

        # Defect check, two levels:
        #  (1) text outside the 1920x1080 canvas / safe margins
        #  (2) text escaping the box it visually sits in  <- the one that actually
        #      shows up as ugly on a projector, and which a canvas-only check misses
        overflow = page.evaluate("""() => {
            const PAD = 5;
            const bad = [];
            const rects = [...document.querySelectorAll('#slide svg rect')].map(r => {
                const b = r.getBBox();
                return {x:b.x, y:b.y, w:b.width, h:b.height, area:b.width*b.height};
            }).filter(r => r.w > 40 && r.h > 24 && r.area < 1920*1080*0.9);

            document.querySelectorAll('#slide svg text').forEach(t => {
                const b = t.getBBox();
                const txt = (t.textContent || '').trim().slice(0, 40);
                if (!txt) return;
                if (b.x < 84 || b.y < 0 || b.x + b.width > 1836 || b.y + b.height > 1080) {
                    bad.push('CANVAS: "' + txt + '" @x=' + Math.round(b.x) + ' w=' + Math.round(b.width));
                    return;
                }
                // smallest rect whose area contains the text's centre = its visual owner
                const cx = b.x + b.width/2, cy = b.y + b.height/2;
                let owner = null;
                for (const r of rects) {
                    if (cx >= r.x && cx <= r.x+r.w && cy >= r.y && cy <= r.y+r.h) {
                        if (!owner || r.area < owner.area) owner = r;
                    }
                }
                if (owner) {
                    if (b.x < owner.x + PAD || b.x + b.width > owner.x + owner.w - PAD ||
                        b.y < owner.y + PAD || b.y + b.height > owner.y + owner.h - PAD) {
                        bad.push('BOX: "' + txt + '" escapes its panel');
                    }
                }
            });
            return bad;
        }""")
        size_kb = png.stat().st_size // 1024
        if overflow:
            bad.append((f.name, f"{len(overflow)} text(s) outside canvas"))
            print(f"  !! {png.name:44} {size_kb:>4} KB   OVERFLOW: {overflow[:2]}")
        else:
            ok.append(png.name)
            print(f"  ok {png.name:44} {size_kb:>4} KB")
    browser.close()

print(f"\n{len(ok)} clean, {len(bad)} with issues")
for n, why in bad:
    print(f"  FIX {n}: {why}")
