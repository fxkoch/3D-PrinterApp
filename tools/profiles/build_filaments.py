#!/usr/bin/env python3
"""Builds SliceKit/Resources/filaments.json from OrcaSlicer's profile resources.

    python3 tools/profiles/build_filaments.py <OrcaSlicer>/resources

Kobra S1 and U1 profiles come from the vendors' own presets, brand filaments from Orca's
filament library. Inheritance is resolved like Orca does (parents from the child's own library first).
"""
import json
import re
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "cloudslice"))
from orca_slice import Profiles  # noqa: E402

OUT = Path(__file__).resolve().parents[2] / "Packages/MakerSliceCore/Sources/SliceKit/Resources/filaments.json"


def first(v):
    if isinstance(v, list):
        v = v[0] if v else None
    return v


def num(v, default=None):
    v = first(v)
    if v is None or v in ("", "nil"):
        return default
    try:
        return float(str(v).replace("%", ""))
    except ValueError:
        return default


def entry(profiles, name, printer):
    raw = json.loads(profiles.path(name).read_text(encoding="utf-8"))
    if raw.get("instantiation") == "false":
        return None
    d = profiles.flat(name)
    t = first(d.get("filament_type"))
    nt = num(d.get("nozzle_temperature"))
    if not t or nt is None:
        return None
    if t == "PET":
        t = "PETG"  # Orca's U1 data labels some PETG as PET
    bed = num(d.get("textured_plate_temp")) or num(d.get("hot_plate_temp")) or 60
    bed0 = num(d.get("textured_plate_temp_initial_layer")) or num(d.get("hot_plate_temp_initial_layer")) or bed
    hot = num(d.get("hot_plate_temp")) or bed
    clean = re.sub(r"\s*@.*$", "", name).strip()
    return dict(
        name=clean, vendor=first(d.get("filament_vendor")) or clean.split()[0], type=t, printer=printer,
        nozzleTemp=int(nt), firstLayerNozzleTemp=int(num(d.get("nozzle_temperature_initial_layer"), nt)),
        nozzleTempMin=int(num(d.get("nozzle_temperature_range_low"), nt - 10)),
        nozzleTempMax=int(num(d.get("nozzle_temperature_range_high"), nt + 10)),
        bedTemp=int(bed), firstLayerBedTemp=int(bed0), smoothPlateBedTemp=int(hot),
        fanMax=num(d.get("fan_max_speed"), 100) / 100, fanMin=num(d.get("fan_min_speed"), 100) / 100,
        fanOffLayers=int(num(d.get("close_fan_the_first_x_layers"), 1)),
        overhangFan=num(d.get("overhang_fan_speed"), 100) / 100,
        maxVolumetricSpeed=num(d.get("filament_max_volumetric_speed"), 12),
        retractLength=num(d.get("filament_retraction_length")), flowRatio=num(d.get("filament_flow_ratio"), 0.98),
        pressureAdvance=num(d.get("pressure_advance")) if first(d.get("enable_pressure_advance")) == "1" else None,
        vitrificationTemp=int(num(d.get("temperature_vitrification"), 60)), density=num(d.get("filament_density"), 1.24),
        minLayerTime=num(d.get("slow_down_layer_time"), 4), chamberTemp=int(num(d.get("chamber_temperature"), 0) or 0),
        color=(first(d.get("default_filament_colour")) or "").strip() or None,
        source=f"OrcaSlicer: {name}")


def main():
    resources = Path(sys.argv[1])
    anycubic = Profiles(resources, "Anycubic")
    snapmaker = Profiles(resources, "Snapmaker")
    out, seen = [], set()

    def add(e):
        if e and (e["printer"], e["name"]) not in seen:
            seen.add((e["printer"], e["name"]))
            out.append(e)

    names = lambda p, lib: sorted(n for (l, n) in p.index if l == lib)
    for n in names(anycubic, "Anycubic"):
        if n.endswith("@Anycubic Kobra S1 0.4 nozzle"):
            add(entry(anycubic, n, "kobraS1"))
    for n in names(anycubic, "Anycubic"):
        if n.endswith("@Anycubic Kobra S1 Max 0.4 nozzle"):
            e = entry(anycubic, n, "kobraS1")
            if e and ("kobraS1", e["name"]) not in seen:
                e["source"] += " (S1 Max, gleiche Hotend-Familie)"
                add(e)
    for n in names(snapmaker, "Snapmaker"):
        if "@U1 0.4 nozzle" in n or n.endswith("@Snapmaker U1"):
            add(entry(snapmaker, n, "u1"))
    for n in names(snapmaker, "OrcaFilamentLibrary"):
        if n.endswith("@System") and not n.startswith("fdm_") and "Generic" not in n:
            add(entry(snapmaker, n, "any"))
    OUT.write_text(json.dumps(out, indent=1, ensure_ascii=False))
    print(len(out), Counter(e["printer"] for e in out))


if __name__ == "__main__":
    main()
