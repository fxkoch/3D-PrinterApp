#!/usr/bin/env python3
"""Virtual Snapmaker U1 with the multiACE add-on (Anycubic ACE Pro 2), speaking Moonraker on :17125.

It answers what the app asks a real U1 that runs multiACE v1.27b ("mode": "multi"): the `ace` Klipper object with the
same fields a real printer reported (software 2.1.0), and the ACE_* commands the app sends. Nothing is heated or moved;
the commands only change the reported state. GET /sim/state lists every G-code script the simulator received.

    python3 tools/virtualprinters/u1_multiace_sim.py            # then start the UI test with -uiTestVirtualU1ACE
"""
from __future__ import annotations

import argparse
import json
import re
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

LOCK = threading.Lock()
SCRIPTS: list[str] = []

# Slots of the ACE, as read from the real printer: slot 1 PETG brown, 2 PLA beige, 3 PETG black, 0 empty.
SLOTS = [
    {"index": 0, "status": "unknown", "material": "", "subtype": "", "brand": "", "color": [0, 0, 0]},
    {"index": 1, "status": "ready", "material": "PETG", "subtype": "", "brand": "", "color": [169, 117, 79]},
    {"index": 2, "status": "ready", "material": "PLA", "subtype": "Basic", "brand": "Generic", "color": [232, 220, 192]},
    {"index": 3, "status": "ready", "material": "PETG", "subtype": "Basic", "brand": "Generic", "color": [0, 0, 0]},
]
STATE = {
    "head_source": {str(h): None for h in range(4)},
    "dryer": {"status": "stop", "target_temp": 0, "duration": 0, "remain_time": 0},
    "print_state": "standby",
}


def head_source(slot: dict) -> dict | None:
    if not slot["material"]:
        return None
    return {"ace_index": 0, "slot": slot["index"], "type": slot["material"], "subtype": slot["subtype"],
            "color": "%02X%02X%02X" % tuple(slot["color"]), "brand": slot["brand"]}


def ace_object() -> dict:
    d = STATE["dryer"]
    return {
        "mode": "multi", "status": "ready", "swap_in_progress": False, "device_count": 1,
        "head_source": STATE["head_source"],
        "aces": [{
            "idx": 0, "connected": True, "protocol": "v2", "model": "ACE 2 Pro", "firmware": "V1.1.36",
            "temp": 51 if d["status"] != "stop" else 24, "humidity": 22, "humidity_effective": 22.0,
            "dryer_status": d, "gate_status": [1, 1, 1, 1], "slots": SLOTS,
        }],
    }


def objects() -> dict:
    heater = {"temperature": 24.0, "target": 0.0}
    return {
        "print_stats": {"state": STATE["print_state"], "filename": "", "message": "", "print_duration": 0.0,
                        "info": {"total_layer": None, "current_layer": None}},
        "virtual_sdcard": {"progress": 0.0}, "display_status": {"progress": 0.0},
        "heater_bed": dict(heater), "extruder": dict(heater), "extruder1": dict(heater),
        "extruder2": dict(heater), "extruder3": dict(heater),
        "toolhead": {"extruder": "extruder", "position": [0, 0, 0, 0]},
        "print_task_config": {"filament_exist": [False] * 4, "filament_vendor": [""] * 4, "filament_type": [""] * 4,
                              "filament_sub_type": [""] * 4, "filament_color_rgba": ["FFFFFFFF"] * 4},
        "ace": ace_object(),
    }


def run_script(script: str) -> None:
    with LOCK:
        SCRIPTS.append(script)
        for line in script.splitlines():
            m = re.match(r"ACE_LOAD_HEAD HEAD=(\d)", line)
            if m:
                h = int(m.group(1))
                STATE["head_source"][str(h)] = head_source(SLOTS[h])
            m = re.match(r"ACE_UNLOAD_HEAD HEAD=(\d)", line)
            if m:
                STATE["head_source"][m.group(1)] = None
            m = re.match(r"ACE_START_DRYING TEMP=(\d+) DURATION=(\d+)", line)
            if m:
                STATE["dryer"] = {"status": "drying", "target_temp": int(m.group(1)),
                                  "duration": int(m.group(2)) * 60, "remain_time": int(m.group(2)) * 60}
            if line.startswith("ACE_STOP_DRYING"):
                STATE["dryer"] = {"status": "stop", "target_temp": 0, "duration": 0, "remain_time": 0}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args) -> None:  # quiet
        pass

    def reply(self, body: dict, code: int = 200) -> None:
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def handle_any(self) -> None:
        url = urlparse(self.path)
        query = parse_qs(url.query, keep_blank_values=True)
        if url.path == "/server/info":
            self.reply({"result": {"klippy_state": "ready", "moonraker_version": "v0.9.3-sim"}})
        elif url.path == "/machine/system_info":
            self.reply({"result": {"system_info": {"network": {"wlan0": {}}}}})
        elif url.path == "/printer/info":
            self.reply({"result": {"state": "ready", "state_message": "Printer is ready", "software_version": "2.1.0-sim"}})
        elif url.path == "/printer/objects/query":
            wanted = [k for k in query] or list(objects())
            all_objects = objects()
            self.reply({"result": {"eventtime": 0, "status": {k: all_objects[k] for k in wanted if k in all_objects}}})
        elif url.path == "/printer/gcode/script":
            run_script(query.get("script", [""])[0])
            self.reply({"result": "ok"})
        elif url.path == "/sim/state":
            with LOCK:
                self.reply({"scripts": SCRIPTS, "head_source": STATE["head_source"], "dryer": STATE["dryer"]})
        elif url.path == "/server/gcode_store":
            self.reply({"result": {"gcode_store": []}})
        else:
            self.reply({"result": {}})

    do_GET = do_POST = handle_any


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=17125)
    args = parser.parse_args()
    ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()
