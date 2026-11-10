#!/usr/bin/env python3
"""Adds the Bambu Lab P1S filament profiles (scope "p1s") to SliceKit/Resources/filaments.json.

    python3 tools/profiles/add_p1s_filaments.py <OrcaSlicer>/resources

The P1S shares the X1C's hotend, so Bambu's own filament presets for the X1C apply (a P1S-specific preset wins when it
exists). Existing "p1s" entries are replaced, all other entries stay as they are.
"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "cloudslice"))
from build_filaments import OUT, entry  # noqa: E402
from orca_slice import Profiles  # noqa: E402


def main():
    resources = Path(sys.argv[1])
    bbl = Profiles(resources, "BBL")
    names = sorted(n for (lib, n) in bbl.index if lib == "BBL")
    chosen = {}
    for n in names:
        if n.endswith("@BBL X1C") or n.endswith("@BBL P1S"):
            base = n.rsplit("@", 1)[0].strip()
            if base not in chosen or n.endswith("@BBL P1S"):
                chosen[base] = n
    entries = []
    for n in chosen.values():
        e = entry(bbl, n, "p1s")
        if e:
            e["source"] = f"OrcaSlicer (Bambu Lab): {n}"
            entries.append(e)
    data = [e for e in json.loads(OUT.read_text(encoding="utf-8")) if e.get("printer") != "p1s"]
    OUT.write_text(json.dumps(data + entries, indent=1, ensure_ascii=False))
    print(len(entries), "P1S-Profile hinzugefügt,", len(data), "andere unverändert")


if __name__ == "__main__":
    main()
