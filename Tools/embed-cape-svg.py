#!/usr/bin/env python3
"""Embed an SVG as the optional per-cursor `VectorSVG` source of a cape.

Usage: Tools/embed-cape-svg.py CAPE.cape CURSOR_IDENTIFIER SOURCE.svg [--remove]
Example: Tools/embed-cape-svg.py ~/Library/"Application Support"/Mousecape/capes/x.cape \
         com.apple.coregraphics.ArrowS .scratch/arrow-hybrid.svg
Keeps the existing bitmap representations; Apply prefers the SVG when present.
"""
import plistlib, shutil, sys

KEY = "VectorSVG"

def main(argv):
    remove = "--remove" in argv
    args = [a for a in argv if a != "--remove"]
    if len(args) != (2 if remove else 3):
        sys.exit(__doc__)
    cape, ident = args[0], args[1]
    with open(cape, "rb") as f:
        data = plistlib.load(f)
    cursors = data.get("Cursors", {})
    if ident not in cursors:
        sys.exit(f"cursor {ident!r} not in cape (have: {sorted(cursors)[:8]}...)")
    shutil.copy2(cape, cape + ".bak")
    if remove:
        cursors[ident].pop(KEY, None)
    else:
        with open(args[2], encoding="utf-8") as f:
            cursors[ident][KEY] = f.read()
    with open(cape, "wb") as f:
        plistlib.dump(data, f, fmt=plistlib.FMT_BINARY)
    print(f"{'removed' if remove else 'embedded'} {KEY} for {ident} in {cape} (backup: {cape}.bak)")

main(sys.argv[1:])
