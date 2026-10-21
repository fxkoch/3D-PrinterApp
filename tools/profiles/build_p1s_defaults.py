#!/usr/bin/env python3
"""Writes SliceKit/Resources/p1s_process_defaults.json: the values of Bambu's own "0.20mm Standard @BBL X1C" process
(the P1S shares it) for every slicer option the app knows, so the P1S gets the same expert settings as the other printers.

    python3 tools/profiles/build_p1s_defaults.py <OrcaSlicer>/resources
"""
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "cloudslice"))
from orca_slice import Profiles  # noqa: E402

ROOT = Path(__file__).resolve().parents[2] / "Packages/MakerSliceCore/Sources/SliceKit"


def main():
    process = Profiles(Path(sys.argv[1]), "BBL").flat("0.20mm Standard @BBL X1C")
    keys = set(re.findall(r'SlicerOption\(key: "([^"]+)"', (ROOT / "Settings/SlicerOptions.generated.swift").read_text()))
    out = {}
    for k in keys:
        if k in process:
            v = process[k]
            out[k] = str(v[0] if isinstance(v, list) and v else v)
    (ROOT / "Resources/p1s_process_defaults.json").write_text(json.dumps(out, indent=1, ensure_ascii=False, sort_keys=True))
    print(len(out), "von", len(keys), "Optionen mit Bambu-Wert")


if __name__ == "__main__":
    main()
