#!/usr/bin/env python3
"""Slice a MakerSlice job with the real OrcaSlicer (headless) – used by the cloud-slice workflow.

Job directory layout (written by the app):
    job.json     {"printer": "snapmakerU1"|"kobraS1", "model": "model.3mf",
                  "process": {orca_key: value}, "filaments": [{"preset", "type", "overrides"}]}
    model.3mf    model (3MF or STL)

Output (same directory):
    result.gcode, result.json (estimate + warnings), orca.log

Profiles are resolved from Orca's own resources and flattened, because the CLI does not resolve
"inherits" chains reliably (wrong material/temperatures otherwise – see snapmaker-u1-toolkit notes).
Only the standard library is used.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

PRINTERS = {
    "snapmakerU1": {
        "vendor": "Snapmaker",
        "machine": "Snapmaker U1 (0.4 nozzle)",
        "process": "0.20 Standard @Snapmaker U1 (0.4 nozzle)",
        "filament_tag": "@U1",
        "brand": "Snapmaker",
    },
    "kobraS1": {
        "vendor": "Anycubic",
        "machine": "Anycubic Kobra S1 0.4 nozzle",
        "process": "0.20mm Standard @Anycubic Kobra S1 0.4 nozzle",
        "filament_tag": "@Anycubic Kobra S1 0.4 nozzle",
        "brand": "Anycubic",
    },
}

DROP_KEYS = {"inherits", "compatible_printers", "compatible_printers_condition",
             "compatible_prints", "compatible_prints_condition", "instantiation", "setting_id", "base_id"}


class Profiles:
    """Index of every profile JSON (by vendor and name) inside Orca's resources."""

    def __init__(self, resources: Path, vendor: str):
        self.vendor = vendor
        self.index: dict[tuple[str, str], Path] = {}
        for root in (resources / "profiles" / vendor, resources / "profiles" / "OrcaFilamentLibrary"):
            for f in root.rglob("*.json"):
                try:
                    data = json.loads(f.read_text(encoding="utf-8"))
                except (OSError, ValueError):
                    continue
                if isinstance(data, dict) and "name" in data:
                    self.index.setdefault((root.name, data["name"]), f)
        self.library_of = {path: lib for (lib, _), path in self.index.items()}

    def path(self, name: str, prefer: str | None = None) -> Path | None:
        """Like Orca: parents are looked up in the library of the child first."""
        for lib in (prefer, self.vendor, "OrcaFilamentLibrary"):
            if lib and (lib, name) in self.index:
                return self.index[(lib, name)]
        return None

    def flat(self, name: str) -> dict:
        """Profile with its whole inherits chain merged (leaf wins)."""
        chain: list[dict] = []
        seen: set[str] = set()
        current: str | None = name
        library: str | None = None
        while current and current not in seen:
            seen.add(current)
            p = self.path(current, prefer=library)
            library = self.library_of.get(p, library)
            if p is None:
                if not chain:
                    raise SystemExit(f"Profil nicht gefunden: {current}")
                break
            data = json.loads(p.read_text(encoding="utf-8"))
            chain.append(data)
            current = data.get("inherits")
        merged: dict = {}
        for layer in reversed(chain):
            merged.update(layer)
        for k in DROP_KEYS:
            merged.pop(k, None)
        merged["name"] = name
        return merged

    def filaments(self) -> list[tuple[str, dict]]:
        out = []
        for (vendor, name), p in self.index.items():
            if "/filament/" in str(p).replace("\\", "/"):
                out.append((name, p))
        return out


def find_filament(profiles: Profiles, preset: str | None, ftype: str, tag: str, brand: str) -> str:
    """Exact preset if Orca has it, otherwise the printer's own profile for the type, else Generic."""
    if preset and profiles.path(preset):
        return preset
    ftype = (ftype or "PLA").upper()
    candidates = []
    for name, p in profiles.filaments():
        if name.endswith(" base") or name.endswith("@base") or "template" in name.lower():
            continue
        try:
            raw = json.loads(p.read_text(encoding="utf-8"))
            if raw.get("instantiation") == "false":
                continue
            types = profiles.flat(name).get("filament_type") or []
        except (OSError, ValueError, SystemExit):
            continue
        t = (types[0] if isinstance(types, list) and types else str(types)).upper()
        if t == ftype:
            candidates.append(name)
    special = re.compile(r"support|breakaway|silk|matte|cf|gf|metal|marble|wood|glow|translucent|rapid|hs|high speed|esd|lite",
                         re.IGNORECASE)
    plain = [n for n in candidates if not special.search(n.split("@")[0])]
    for wanted in (f"Generic {ftype} {tag}", f"{brand} {ftype} {tag}", f"Generic {ftype} @System"):
        for n in candidates:
            if n.upper() == wanted.upper():
                return n
    for pool in ([n for n in plain if n.endswith(tag)], [n for n in candidates if n.endswith(tag)],
                 [n for n in plain if n.endswith("@System")], plain, candidates):
        if pool:
            return sorted(pool, key=lambda n: (len(n), n))[0]
    return "Generic PLA @System"


def as_orca(value, like):
    """Formats an override the way the base profile stores it (string or list of strings)."""
    if isinstance(value, bool):
        value = "1" if value else "0"
    if isinstance(like, list):
        if isinstance(value, list):
            return [str(v) for v in value]
        return [str(value)] * max(1, len(like))
    if isinstance(value, list):
        return str(value[0]) if value else ""
    return str(value)


def apply(profile: dict, overrides: dict) -> dict:
    for k, v in (overrides or {}).items():
        profile[k] = as_orca(v, profile.get(k, ""))
    return profile


def propagate_plate_temps(f: dict) -> None:
    """Snapmaker filaments often only set hot_plate_temp; Orca would otherwise print 0 °C for other plates."""
    def zero(v):
        if v is None:
            return True
        if isinstance(v, list):
            return not v or str(v[0]).strip() in ("0", "0.0", "")
        return str(v).strip() in ("0", "0.0", "")
    for suffix in ("", "_initial_layer"):
        hot = f.get("hot_plate_temp" + suffix)
        if hot and not zero(hot):
            for k in ("textured_plate_temp", "eng_plate_temp", "cool_plate_temp"):
                if zero(f.get(k + suffix)):
                    f[k + suffix] = hot


def find_resources(orca_bin: Path) -> Path:
    for cand in (orca_bin.parent.parent / "resources", orca_bin.parent / "resources"):
        if (cand / "profiles").is_dir():
            return cand
    raise SystemExit(f"Orca-Ressourcen nicht gefunden neben {orca_bin}")


def parse_metadata(gcode: Path) -> dict:
    meta: dict = {}
    pattern = re.compile(r"^; ([^=]+?) = (.*)$")
    with gcode.open("r", encoding="utf-8", errors="replace") as fh:
        for i, line in enumerate(fh):
            m = pattern.match(line.rstrip("\n"))
            if m:
                meta[m.group(1)] = m.group(2)
            if i > 400 and len(meta) > 20:
                break
    # Estimates are in the footer for Orca.
    size = gcode.stat().st_size
    with gcode.open("rb") as fh:
        fh.seek(max(0, size - 200_000))
        for raw in fh.read().decode("utf-8", "replace").splitlines():
            m = pattern.match(raw)
            if m:
                meta[m.group(1)] = m.group(2)
    return meta


def seconds(text: str | None) -> int | None:
    if not text:
        return None
    total = 0
    for value, unit in re.findall(r"(\d+)\s*([dhms])", text):
        total += int(value) * {"d": 86400, "h": 3600, "m": 60, "s": 1}[unit]
    return total or None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("job_dir", type=Path)
    ap.add_argument("--orca", type=Path, required=True)
    ap.add_argument("--timeout", type=int, default=1500)
    args = ap.parse_args()

    job_dir: Path = args.job_dir
    job = json.loads((job_dir / "job.json").read_text(encoding="utf-8"))
    printer = PRINTERS[job.get("printer", "snapmakerU1")]
    resources = find_resources(args.orca)
    profiles = Profiles(resources, printer["vendor"])

    work = job_dir / "profiles"
    work.mkdir(exist_ok=True)
    # The flattened profiles keep their system identity, and process and filaments name the printer
    # explicitly: the CLI refuses a process it cannot match to the printer (exit -17).
    compat = {"compatible_printers": [printer["machine"]], "compatible_printers_condition": ""}
    machine = profiles.flat(printer["machine"])
    machine.update({"type": "machine", "from": "system"})
    apply(machine, job.get("machine", {}))
    process = profiles.flat(printer["process"])
    process.update({"type": "process", "from": "system", **compat})
    apply(process, job.get("process", {}))
    (work / "machine.json").write_text(json.dumps(machine, indent=1))
    (work / "process.json").write_text(json.dumps(process, indent=1))

    filament_paths = []
    used_presets = []
    for i, entry in enumerate(job.get("filaments") or [{"type": "PLA"}]):
        preset = find_filament(profiles, entry.get("preset"), entry.get("type", "PLA"),
                               printer["filament_tag"], printer["brand"])
        f = profiles.flat(preset)
        f.update({"type": "filament", "from": "system", **compat})
        propagate_plate_temps(f)
        apply(f, entry.get("overrides", {}))
        p = work / f"filament_{i + 1}.json"
        p.write_text(json.dumps(f, indent=1))
        filament_paths.append(str(p))
        used_presets.append(preset)

    model = job_dir / job.get("model", "model.3mf")
    out_dir = job_dir / "out"
    out_dir.mkdir(exist_ok=True)
    cmd = [str(args.orca),
           "--load-settings", f"{work / 'machine.json'};{work / 'process.json'}",
           "--load-filaments", ";".join(filament_paths),
           "--allow-newer-file", "--debug", "2",
           "--outputdir", str(out_dir),
           "--slice", str(job.get("plate", 0)),
           str(model)]
    if job.get("arrange"):
        cmd[1:1] = ["--arrange", "1"]
    print("Orca:", " ".join(cmd), flush=True)
    env = dict(os.environ)
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                          env=env, timeout=args.timeout)
    (job_dir / "orca.log").write_text(proc.stdout)
    print(proc.stdout[-6000:])

    produced = sorted(out_dir.glob("*.gcode"), key=lambda p: p.stat().st_mtime, reverse=True)
    result = {"ok": False, "returncode": proc.returncode, "presets": {
        "machine": printer["machine"], "process": printer["process"], "filaments": used_presets}}
    warnings = [l.strip() for l in proc.stdout.splitlines() if "warning" in l.lower()][:20]
    result["warnings"] = warnings
    if not produced or produced[0].stat().st_size == 0:
        tail = "\n".join(proc.stdout.strip().splitlines()[-15:])
        result["error"] = f"OrcaSlicer hat keinen G-Code erzeugt (Code {proc.returncode}).\n{tail}"
        (job_dir / "result.json").write_text(json.dumps(result, indent=1))
        print(result["error"], file=sys.stderr)
        return 1
    gcode = job_dir / "result.gcode"
    produced[0].replace(gcode)
    meta = parse_metadata(gcode)
    result.update({
        "ok": True,
        "bytes": gcode.stat().st_size,
        "seconds": seconds(meta.get("estimated printing time (normal mode)") or meta.get("model printing time")),
        "filament_g": meta.get("filament used [g]") or meta.get("total filament used [g]"),
        "filament_mm": meta.get("filament used [mm]"),
        "layers": meta.get("total layer number") or meta.get("total layers count"),
        "printer_model": meta.get("printer_model"),
        "filament_type": meta.get("filament_type"),
    })
    (job_dir / "result.json").write_text(json.dumps(result, indent=1))
    print(json.dumps(result, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
