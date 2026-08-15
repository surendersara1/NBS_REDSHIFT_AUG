"""Fix: SVG presentation attributes are overridden by CSS class rules.

`_style.css` sets `fill` (and font props) inside class selectors. A CSS rule ALWAYS
beats an SVG presentation attribute, so `<text class="bxt-s" fill="#E8A54D">` renders
white, silently discarding the semantic palette.

Fix: promote presentation attributes on <text> elements to an inline `style=`,
which outranks the class rule. Structure and classes are unchanged.

Usage:  python fix_svg_fills.py [module_folder]
Idempotent — safe to re-run.
"""
from __future__ import annotations
import re, sys, pathlib

ROOT = pathlib.Path(__file__).parent
MODULE = sys.argv[1] if len(sys.argv) > 1 else "Module-01-Foundations"
SRC = ROOT / MODULE / "_render"

# presentation attributes that a class rule would clobber
ATTRS = ("fill", "font-size", "font-weight", "font-family", "opacity", "letter-spacing")
TEXT_TAG = re.compile(r"<text\b[^>]*>", re.I)

def fix_tag(tag: str) -> tuple[str, int]:
    if "class=" not in tag:          # no class -> attribute already wins
        return tag, 0
    moved = {}
    out = tag
    for a in ATTRS:
        m = re.search(rf'\s{a}="([^"]*)"', out)
        if m:
            moved[a] = m.group(1)
            out = out[:m.start()] + out[m.end():]
    if not moved:
        return tag, 0
    decl = ";".join(f"{k}:{v}" for k, v in moved.items())
    m = re.search(r'\sstyle="([^"]*)"', out)
    if m:                            # merge into existing style (existing wins)
        merged = decl + ";" + m.group(1)
        out = out[:m.start()] + f' style="{merged}"' + out[m.end():]
    else:
        out = out[:-1].rstrip() + f' style="{decl}">'
    return out, len(moved)

total_files = total_moves = 0
for f in sorted(SRC.glob("L*.html")):
    src = f.read_text(encoding="utf-8")
    moves = 0
    def _sub(m):
        global moves
        new, n = fix_tag(m.group(0))
        moves += n
        return new
    out = TEXT_TAG.sub(_sub, src)
    if moves:
        f.write_text(out, encoding="utf-8")
        total_files += 1
        total_moves += moves
        print(f"  fixed {f.name:44} {moves:>3} attribute(s) promoted")
    else:
        print(f"  ok    {f.name:44}   (nothing to fix)")

print(f"\n{total_files} file(s) changed, {total_moves} attribute(s) promoted to inline style")
