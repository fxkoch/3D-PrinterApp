#!/usr/bin/env python3
"""Sanity checks for G-code before it goes to a printer (used by the cloud-slice self-test and the
virtual printers): printer start macro, moves inside the bed, sane temperatures, extrusion, layers,
and the expected tool changes. Exit code 1 lists every problem found."""
from __future__ import annotations

import argparse
import re
import sys

PRINTERS = {
    "snapmakerU1": {"bed": 270.0, "height": 270.0, "start": "PRINT_START", "max_temp": 300},
    "kobraS1": {"bed": 250.0, "height": 250.0, "start": "G9111", "max_temp": 320},
}
WORD = re.compile(r"([XYZEFS])(-?\d*\.?\d+)")


def analyze(path: str) -> dict:
    info = {"layers": 0, "tools": set(), "max_temp": 0.0, "max_bed": 0.0, "extruded": 0.0,
            "moves": 0, "out_of_bed": [], "max_z": 0.0, "start_macros": set(), "relative_e": False}
    x = y = z = 0.0
    absolute_e = True
    last_e = 0.0
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for n, raw in enumerate(fh, 1):
            line = raw.split(";", 1)[0].strip()
            if raw.startswith(";LAYER_CHANGE") or raw.startswith("; CHANGE_LAYER"):
                info["layers"] += 1
            if not line:
                continue
            head = line.split()[0].upper()
            for macro in ("PRINT_START", "G9111"):
                if head == macro:
                    info["start_macros"].add(macro)
            if re.fullmatch(r"T\d+", head):
                info["tools"].add(int(head[1:]))
            elif head == "M83":
                absolute_e = False
                info["relative_e"] = True
            elif head == "M82":
                absolute_e = True
            elif head == "G92":
                m = re.search(r"E(-?\d*\.?\d+)", line)
                if m:
                    last_e = float(m.group(1))
            elif head in ("M104", "M109"):
                m = re.search(r"S(\d+\.?\d*)", line)
                if m:
                    info["max_temp"] = max(info["max_temp"], float(m.group(1)))
            elif head in ("M140", "M190"):
                m = re.search(r"S(\d+\.?\d*)", line)
                if m:
                    info["max_bed"] = max(info["max_bed"], float(m.group(1)))
            elif head in ("G0", "G1", "G2", "G3"):
                words = dict(WORD.findall(line))
                x = float(words.get("X", x))
                y = float(words.get("Y", y))
                z = float(words.get("Z", z))
                info["max_z"] = max(info["max_z"], z)
                if "E" in words:
                    e = float(words["E"])
                    delta = e if not absolute_e else e - last_e
                    if absolute_e:
                        last_e = e
                    if delta > 0 and ("X" in words or "Y" in words):
                        info["extruded"] += delta
                        info["moves"] += 1
                        info.setdefault("extrusion_points", []).append((x, y, n))
    return info


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("gcode")
    ap.add_argument("--printer", choices=PRINTERS, required=True)
    ap.add_argument("--tools", type=int, default=1, help="number of different tools/slots that must be used")
    ap.add_argument("--margin", type=float, default=12.0, help="tolerance outside the bed for purge lines")
    args = ap.parse_args()
    spec = PRINTERS[args.printer]
    info = analyze(args.gcode)
    problems = []
    if spec["start"] not in info["start_macros"]:
        problems.append(f"Startmakro {spec['start']} fehlt")
    if info["moves"] < 50 or info["extruded"] < 10:
        problems.append(f"zu wenig Extrusion ({info['moves']} Bewegungen, {info['extruded']:.1f} mm)")
    if info["layers"] < 2:
        problems.append("keine Schichtwechsel gefunden")
    if not (170 <= info["max_temp"] <= spec["max_temp"]):
        problems.append(f"Düsentemperatur unplausibel: {info['max_temp']}")
    if info["max_bed"] > 120:
        problems.append(f"Betttemperatur zu hoch: {info['max_bed']}")
    if info["max_z"] > spec["height"] + 1:
        problems.append(f"Z {info['max_z']} über Bauhöhe")
    lo, hi = -args.margin, spec["bed"] + args.margin
    outside = [(px, py, n) for px, py, n in info.get("extrusion_points", []) if not (lo <= px <= hi and lo <= py <= hi)]
    if outside:
        problems.append(f"{len(outside)} Extrusionen außerhalb des Betts, z. B. Zeile {outside[0][2]}: X{outside[0][0]} Y{outside[0][1]}")
    used = len(info["tools"]) if info["tools"] else 1
    if used < args.tools:
        problems.append(f"nur {used} Werkzeug(e) benutzt, erwartet {args.tools}")

    summary = (f"{args.gcode}: {info['layers']} Schichten, {info['moves']} Extrusionen, {info['extruded'] / 1000:.2f} m Filament, "
               f"Werkzeuge {sorted(info['tools']) or [0]}, Düse max {info['max_temp']:.0f} °C, Bett max {info['max_bed']:.0f} °C")
    print(summary)
    for p in problems:
        print("  FEHLER:", p)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
