"""Full detail for every containment defect in a module — what to fix, and by how much.

render_slides.py reports only the first two defects per slide, which is enough to
know a slide is broken but not enough to fix it. This prints every offending text
with its bounding box, its owning panel, and the overflow on each edge.

Usage:  python diagnose_overflow.py [module_folder]
"""
from __future__ import annotations
import sys, pathlib, json
from playwright.sync_api import sync_playwright

ROOT = pathlib.Path(__file__).parent
MODULE = sys.argv[1] if len(sys.argv) > 1 else "Module-02-Tamimi"
SRC = ROOT / MODULE / "_render"

JS = """() => {
    const PAD = 5, out = [];
    const rects = [...document.querySelectorAll('#slide svg rect')].map(r => {
        const b = r.getBBox();
        return {x:b.x, y:b.y, w:b.width, h:b.height, area:b.width*b.height};
    }).filter(r => r.w > 40 && r.h > 24 && r.area < 1920*1080*0.9);

    document.querySelectorAll('#slide svg text').forEach(t => {
        const b = t.getBBox(), txt = (t.textContent || '').trim();
        if (!txt) return;
        const rec = {text: txt, x: Math.round(b.x), y: Math.round(b.y),
                     w: Math.round(b.width), h: Math.round(b.height),
                     ax: t.getAttribute('x'), ay: t.getAttribute('y'),
                     anchor: t.getAttribute('text-anchor') || 'start'};
        if (b.x < 84 || b.y < 0 || b.x + b.width > 1836 || b.y + b.height > 1080) {
            rec.kind = 'CANVAS';
            rec.over = {left: Math.round(84 - b.x), right: Math.round(b.x + b.width - 1836)};
            out.push(rec); return;
        }
        const cx = b.x + b.width/2, cy = b.y + b.height/2;
        let o = null;
        for (const r of rects)
            if (cx >= r.x && cx <= r.x+r.w && cy >= r.y && cy <= r.y+r.h)
                if (!o || r.area < o.area) o = r;
        if (!o) return;
        const over = {
            left:   Math.round((o.x + PAD) - b.x),
            right:  Math.round((b.x + b.width) - (o.x + o.w - PAD)),
            top:    Math.round((o.y + PAD) - b.y),
            bottom: Math.round((b.y + b.height) - (o.y + o.h - PAD)),
        };
        if (over.left > 0 || over.right > 0 || over.top > 0 || over.bottom > 0) {
            rec.kind = 'BOX';
            rec.panel = {x: Math.round(o.x), y: Math.round(o.y),
                         w: Math.round(o.w), h: Math.round(o.h)};
            rec.over = Object.fromEntries(Object.entries(over).filter(([, v]) => v > 0));
            out.push(rec);
        }
    });
    return out;
}"""

total = 0
with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page(viewport={"width": 1920, "height": 1080})
    for f in sorted(SRC.glob("[LDM]*.html")):
        pg.goto(f.as_uri())
        try:
            pg.wait_for_function(
                """() => document.fonts.status === 'loaded' &&
                   ['Asap','Cabin','IBM Plex Mono'].every(n =>
                     [...document.fonts].some(x =>
                       x.family.replace(/["']/g,'') === n && x.status === 'loaded'))""",
                timeout=15000)
        except Exception:
            print(f"{f.name}: WEBFONTS FAILED")
            continue
        pg.wait_for_timeout(120)
        bad = pg.evaluate(JS)
        if not bad:
            continue
        total += len(bad)
        print(f"\n### {f.name}  ({len(bad)} defect(s))")
        for d in bad:
            print(f'  [{d["kind"]}] x={d["ax"]} y={d["ay"]} anchor={d["anchor"]} '
                  f'w={d["w"]}  over={json.dumps(d["over"])}')
            print(f'         "{d["text"][:88]}"')
            if "panel" in d:
                print(f'         panel {d["panel"]}')
    b.close()

print(f"\n{total} defect(s) total")
