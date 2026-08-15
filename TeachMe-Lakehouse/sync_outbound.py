"""Copy every module PDF into outbound/ and report exactly what is current.

Run this after closing any PDF viewers. Windows locks an open PDF, so a copy over
a file you are reading fails silently in a plain `cp` loop — this reports it loudly
instead, and tells you which file to close.

Usage:  python sync_outbound.py            # copy and report
        python sync_outbound.py --check    # report only, copy nothing
"""
from __future__ import annotations
import filecmp, shutil, sys, pathlib

ROOT = pathlib.Path(__file__).parent
LECT = ROOT / "lectures"
OUT = ROOT / "outbound"
CHECK_ONLY = "--check" in sys.argv

OUT.mkdir(exist_ok=True)
pdfs = sorted(p for p in LECT.glob("*/*.pdf"))

ok, stale, copied = [], [], []
for src in pdfs:
    dst = OUT / src.name
    if dst.exists() and filecmp.cmp(src, dst, shallow=False):
        ok.append(src.name)
        continue
    if CHECK_ONLY:
        stale.append((src.name, "not synced"))
        continue
    try:
        shutil.copy2(src, dst)
        copied.append(src.name)
    except (PermissionError, OSError) as e:
        stale.append((src.name, f"LOCKED — close it in your PDF viewer ({e.errno})"))

w = max((len(p.name) for p in pdfs), default=10)
print(f"\noutbound/  ({len(pdfs)} module PDFs)\n")
for n in sorted(copied):
    print(f"  updated  {n.ljust(w)}")
for n in sorted(ok):
    print(f"  current  {n.ljust(w)}")
for n, why in sorted(stale):
    print(f"  STALE !! {n.ljust(w)}  {why}")

if stale:
    print(f"\n  {len(stale)} file(s) NOT updated. Close them and re-run: python sync_outbound.py")
    sys.exit(1)
print(f"\n  all {len(pdfs)} in sync")
