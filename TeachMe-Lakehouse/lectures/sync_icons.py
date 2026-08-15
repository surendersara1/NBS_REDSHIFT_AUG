"""Populate the shared architecture-icon library at lectures/_icons/.

Source: the AWS/on-prem/SaaS icon set bundled with the `diagrams` package
(pip install diagrams) — derived from the official AWS Architecture Icons.

Why a SHARED library and not a copy per module: 30 architecture diagrams across
several modules would otherwise duplicate the same PNGs five times over and drift.
Slides reference it relatively:

    <image href="../../_icons/aws/analytics/redshift.png" .../>

That path resolves for BOTH render paths, because both load a file out of
<module>/_render/ :
    render_slides.py -> _render/L##.html        make_pdf.py -> _render/_deck.html

Usage:  python sync_icons.py            # copy + write ICONS.md index
"""
from __future__ import annotations
import shutil, pathlib, importlib.util

ROOT = pathlib.Path(__file__).parent
DEST = ROOT / "_icons"

spec = importlib.util.find_spec("diagrams")
if spec is None:
    raise SystemExit("the `diagrams` package is not installed — pip install diagrams")
SRC = pathlib.Path(spec.origin).parent.parent / "resources"
if not SRC.is_dir():
    raise SystemExit(f"icon resources not found at {SRC}")

# Whole AWS set (every service we could plausibly need), plus the on-prem
# databases that appear as SOURCES, plus a few SaaS marks.
WANT = [
    ("aws", None),                       # None = every category
    ("onprem", ["database", "analytics", "queue", "workflow", "monitoring", "client"]),
    ("saas", ["analytics", "logging", "chat", "crm"]),
]

copied = 0
index: dict[str, dict[str, list[str]]] = {}

for provider, cats in WANT:
    pdir = SRC / provider
    if not pdir.is_dir():
        print(f"  -- no {provider} in resources, skipping")
        continue
    for cat in sorted(p for p in pdir.iterdir() if p.is_dir()):
        if cats is not None and cat.name not in cats:
            continue
        out = DEST / provider / cat.name
        out.mkdir(parents=True, exist_ok=True)
        names = []
        for f in sorted(cat.glob("*.png")):
            shutil.copy2(f, out / f.name)
            names.append(f.stem)
            copied += 1
        if names:
            index.setdefault(provider, {})[cat.name] = names

lines = [
    "# Architecture icon library",
    "",
    "Shared across every module. Reference from a slide in `<module>/_render/` as:",
    "",
    "```xml",
    '<image href="../../_icons/aws/analytics/redshift.png" x="756" y="396" width="66" height="66"/>',
    "```",
    "",
    "Regenerate with `python sync_icons.py`. Source: the icon set bundled with the",
    "`diagrams` package, derived from the official AWS Architecture Icons.",
    "For a client-facing deliverable, consider the canonical pack at",
    "<https://aws.amazon.com/architecture/icons/> — it is updated quarterly and a",
    "generation ahead of this bundle on some services.",
    "",
    f"**{copied} icons available.**",
    "",
]
for provider in sorted(index):
    lines.append(f"## {provider}")
    lines.append("")
    for cat in sorted(index[provider]):
        names = index[provider][cat]
        lines.append(f"**`{provider}/{cat}/`** ({len(names)}) — " + " · ".join(f"`{n}`" for n in names))
        lines.append("")

(DEST / "ICONS.md").write_text("\n".join(lines), encoding="utf-8")

print(f"copied {copied} icons -> {DEST}")
for provider in sorted(index):
    tot = sum(len(v) for v in index[provider].values())
    print(f"  {provider:<10} {tot:>4} icons across {len(index[provider])} categories")
print(f"index written -> {DEST / 'ICONS.md'}")
