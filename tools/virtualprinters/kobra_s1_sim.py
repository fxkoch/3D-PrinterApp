#!/usr/bin/env python3
"""Virtual Anycubic Kobra S1 with ACE Pro, speaking the printer's LAN-mode protocol.

What a real printer in LAN mode offers, as documented by the community projects anycubic-lan,
anycubic_ha_local and kobra-lan-cli:

  * HTTP :18910/info            discovery (token, control URL, model id)
  * HTTP POST /ctrl?ts&nonce&sign signed request → MQTT credentials, AES-128-CBC encrypted
  * MQTT 3.1.1 over TLS :9883     commands on .../web|slicer/printer/{model}/{device}/{type},
                                  reports on .../printer/public/{model}/{device}/{type}/report
  * HTTP POST /gcode_upload?s=…   multipart upload ("filename" + "gcode")

The print itself is simulated: progress, layers and temperatures move over time, pause/resume/stop
work, the ACE Pro reports four slots and can dry. Uploaded G-code is checked with
tools/cloudslice/validate_gcode.py. GET /sim/state shows everything the simulator received, for tests.

Only the standard library is used (AES is implemented below); openssl creates the TLS certificate.

    python3 tools/virtualprinters/kobra_s1_sim.py --speed 30
"""
from __future__ import annotations

import argparse
import asyncio
import base64
import hashlib
import json
import os
import random
import ssl
import string
import struct
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "cloudslice"))
import validate_gcode  # noqa: E402

PREFIX = "anycubic/anycubicCloud/v1"
MODEL_ID = "20025"

# ---------------------------------------------------------------------------- AES-128-CBC (encrypt)
SBOX = [
    0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
    0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
    0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
    0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
    0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
    0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
    0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
    0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
    0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
    0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
    0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
    0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
    0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
    0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
    0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
    0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16,
]


def _xtime(b: int) -> int:
    return ((b << 1) ^ 0x1B) & 0xFF if b & 0x80 else b << 1


def _expand_key(key: bytes) -> list[list[int]]:
    words = [list(key[i:i + 4]) for i in range(0, 16, 4)]
    rcon = 1
    for i in range(4, 44):
        w = list(words[i - 1])
        if i % 4 == 0:
            w = w[1:] + w[:1]
            w = [SBOX[b] for b in w]
            w[0] ^= rcon
            rcon = _xtime(rcon)
        words.append([a ^ b for a, b in zip(words[i - 4], w)])
    return [sum(words[r * 4:r * 4 + 4], []) for r in range(11)]


def _encrypt_block(block: list[int], round_keys: list[list[int]]) -> list[int]:
    s = [b ^ k for b, k in zip(block, round_keys[0])]
    for rnd in range(1, 11):
        s = [SBOX[b] for b in s]
        # ShiftRows on column-major state.
        s = [s[(i + 4 * (i % 4)) % 16] for i in range(16)]
        if rnd != 10:
            out = []
            for c in range(4):
                a = s[c * 4:c * 4 + 4]
                t = a[0] ^ a[1] ^ a[2] ^ a[3]
                out += [a[i] ^ t ^ _xtime(a[i] ^ a[(i + 1) % 4]) for i in range(4)]
            s = out
        s = [b ^ k for b, k in zip(s, round_keys[rnd])]
    return s


def aes128_cbc_encrypt(plain: bytes, key: bytes, iv: bytes) -> bytes:
    pad = 16 - len(plain) % 16
    data = plain + bytes([pad]) * pad
    round_keys = _expand_key(key)
    prev = list(iv)
    out = bytearray()
    for i in range(0, len(data), 16):
        block = [b ^ p for b, p in zip(data[i:i + 16], prev)]
        prev = _encrypt_block(block, round_keys)
        out += bytes(prev)
    return bytes(out)


# ---------------------------------------------------------------------------- printer state
def rand(n: int, alphabet: str = string.ascii_letters + string.digits) -> str:
    return "".join(random.choice(alphabet) for _ in range(n))


class Printer:
    def __init__(self, host: str, speed: float, duration: float):
        self.host = host
        self.speed = speed
        self.duration = duration
        self.token = rand(32)
        self.device = rand(32, "0123456789abcdef")
        self.username = "user" + rand(6)
        self.password = rand(16)
        self.upload_secret = rand(12)
        self.lock = threading.Lock()
        self.files: dict[str, dict] = {}
        self.commands: list[dict] = []
        self.state = "free"  # free | printing | paused | finished | stoped
        self.task: dict | None = None
        self.last_project: dict | None = None
        self.nozzle = [24.0, 0.0]
        self.bed = [23.0, 0.0]
        self.light = True
        self.fan = 0
        self.dry = {"status": 0, "target_temp": 0, "duration": 0, "remain_time": 0}
        self.slots = [
            {"index": 0, "type": "PLA", "color": [245, 245, 240], "sku": "HPLW", "status": 5},
            {"index": 1, "type": "PLA", "color": [30, 30, 32], "sku": "HPLB", "status": 5},
            {"index": 2, "type": "PETG", "color": [210, 40, 40], "sku": "", "status": 5},
            {"index": 3, "type": "", "color": [0, 0, 0], "sku": "", "status": 0},
        ]
        self.humidity = 46
        self.publish = lambda topic, payload: None

    # Reports -----------------------------------------------------------------
    def report(self, rtype: str, data: dict, action: str = "report", code: int = 200) -> None:
        msg = {"type": rtype, "action": action, "msgid": rand(8), "timestamp": int(time.time() * 1000),
               "state": "done", "code": code, "msg": "done", "data": data}
        self.publish(f"{PREFIX}/printer/public/{MODEL_ID}/{self.device}/{rtype}/report", msg)

    def respond(self, rtype: str, msgid: str, code: int = 200, msg: str = "done") -> None:
        self.publish(f"{PREFIX}/printer/public/{MODEL_ID}/{self.device}/{rtype}/response",
                     {"type": rtype, "msgid": msgid, "code": code, "msg": msg})

    def temps(self) -> dict:
        return {"curr_nozzle_temp": round(self.nozzle[0], 1), "target_nozzle_temp": self.nozzle[1],
                "curr_hotbed_temp": round(self.bed[0], 1), "target_hotbed_temp": self.bed[1]}

    def project(self) -> dict:
        t = self.task
        if not t:
            return {}
        progress = min(100.0, t["elapsed"] / t["duration"] * 100)
        layer = max(1, min(t["layers"], int(t["layers"] * progress / 100) + 1))
        return {"taskid": t["taskid"], "filename": t["filename"], "progress": int(progress),
                "curr_layer": layer, "total_layers": t["layers"], "print_time": int(t["elapsed"] / 60),
                "remain_time": int(max(0, t["duration"] - t["elapsed"]) / 60), "state": self.state,
                "pause": 1 if self.state == "paused" else 0, "print_speed_mode": 2}

    def info(self) -> dict:
        data = {
            "printerName": "Kobra S1 (virtuell)", "model": "Anycubic Kobra S1", "version": "2.5.8.3-sim",
            "state": "busy" if self.state in ("printing", "paused") else "free", "temp": self.temps(),
            "fan_speed_pct": self.fan, "aux_fan_speed_pct": 0, "print_speed_mode": 2,
            "urls": {"fileUploadurl": f"http://{self.host}:18910/gcode_upload?s={self.upload_secret}",
                     "rtspUrl": ""},
            "features": {"auto_leveling_support": 1, "drying_first_support": 1, "camera_timelapse_support": 1,
                         "gcode_3mf_support": 0, "fod_support": 0},
            "project": self.project(),
        }
        if not data["project"] and self.last_project:
            data["last_project"] = self.last_project
        return data

    def box(self) -> dict:
        return {"multi_color_box": [{"id": 0, "status": 1, "temp": 31, "humidity": self.humidity,
                                     "loaded_slot": 0 if self.task else -1,
                                     "drying_status": dict(self.dry, humidity=self.humidity), "slots": self.slots}]}

    # Commands ----------------------------------------------------------------
    def handle(self, topic: str, msg: dict) -> None:
        rtype, action = msg.get("type"), msg.get("action")
        msgid = msg.get("msgid", "")
        data = msg.get("data") or {}
        with self.lock:
            self.commands.append({"topic": topic, "type": rtype, "action": action, "data": data, "time": time.time()})
            code = 200
            if rtype == "info" and action == "query":
                self.report("info", self.info())
            elif rtype in ("tempature", "temperature") and action == "query":
                self.report("tempature", self.temps())
            elif rtype == "fan" and action == "query":
                self.report("fan", {"fan_speed_pct": self.fan, "aux_fan_speed_pct": 0})
            elif rtype == "light":
                if action == "control":
                    self.light = bool(data.get("status"))
                self.report("light", {"lights": [{"type": 2, "status": 1 if self.light else 0, "brightness": 100}]})
            elif rtype == "multiColorBox":
                if action == "setDry":
                    want = ((data.get("multi_color_box") or [{}])[0].get("drying_status") or {})
                    on = bool(want.get("status"))
                    self.dry = {"status": 1 if on else 0, "target_temp": want.get("target_temp", 45) if on else 0,
                                "duration": want.get("duration", 240) if on else 0,
                                "remain_time": want.get("duration", 240) if on else 0}
                self.report("multiColorBox", self.box())
            elif rtype == "print":
                code = self.print_command(action, data)
            else:
                code = 10001
            self.respond(rtype or "unknown", msgid, code, "done" if code == 200 else "rejected")

    def print_command(self, action: str, data: dict) -> int:
        if action == "start":
            name = data.get("filename")
            f = self.files.get(name)
            if not f:
                return 10002  # file not found
            if data.get("md5") and data["md5"] != f["md5"]:
                return 10003
            if self.state in ("printing", "paused"):
                return 10004
            mapping = (data.get("ams_settings") or {}).get("ams_box_mapping") or []
            for m in mapping:
                slot = m.get("ams_index", -1)
                if not (0 <= slot < 4) or not self.slots[slot]["type"]:
                    return 10005  # slot empty
            layers = f["analysis"]["layers"] or 100
            self.task = {"taskid": str(random.randint(10_000_000, 99_999_999)), "filename": name, "layers": layers,
                         "elapsed": 0.0, "duration": self.duration, "mapping": mapping}
            first = f["analysis"]
            self.nozzle[1] = first["max_temp"] or 210
            self.bed[1] = first["max_bed"] or 60
            self.state = "printing"
            self.report("print", self.project())
        elif action == "pause":
            if self.state != "printing":
                return 10006
            self.state = "paused"
            self.report("print", self.project())
        elif action == "resume":
            if self.state != "paused":
                return 10006
            self.state = "printing"
            self.report("print", self.project())
        elif action == "stop":
            if self.state not in ("printing", "paused"):
                return 10006
            self.finish("stoped")
        elif action == "update":
            settings = data.get("settings") or {}
            if "target_nozzle_temp" in settings:
                self.nozzle[1] = float(settings["target_nozzle_temp"])
            if "target_hotbed_temp" in settings:
                self.bed[1] = float(settings["target_hotbed_temp"])
            self.report("tempature", self.temps())
        else:
            return 10001
        return 200

    def finish(self, state: str) -> None:
        project = self.project()
        project["state"] = state
        if state == "finished":
            project["progress"] = 100
        self.last_project = project
        self.state = state
        self.report("print", project)
        self.task = None
        self.state = "free"
        self.nozzle[1] = 0
        self.bed[1] = 0

    def tick(self, dt: float) -> None:
        with self.lock:
            for heater in (self.nozzle, self.bed):
                heater[0] += (max(heater[1], 23) - heater[0]) * min(1.0, dt * 0.8)
            if self.dry["status"]:
                self.humidity = max(12, self.humidity - dt * 0.5 * self.speed)
            if self.task and self.state == "printing":
                self.task["elapsed"] += dt * self.speed
                if self.task["elapsed"] >= self.task["duration"]:
                    self.finish("finished")
                    return
            if self.task:
                self.report("print", self.project())
            self.report("tempature", self.temps())

    # Upload ------------------------------------------------------------------
    def store_upload(self, name: str, content: bytes) -> dict:
        directory = Path(tempfile.gettempdir()) / "kobra_sim_files"
        directory.mkdir(exist_ok=True)
        path = directory / Path(name).name
        path.write_bytes(content)
        info = validate_gcode.analyze(str(path))
        analysis = {"layers": info["layers"], "moves": info["moves"], "tools": sorted(info["tools"]),
                    "max_temp": info["max_temp"], "max_bed": info["max_bed"], "start_macros": sorted(info["start_macros"]),
                    "extruded_mm": round(info["extruded"], 1)}
        problems = []
        if "G9111" not in info["start_macros"]:
            problems.append("G9111 fehlt")
        out_of_bed = [p for p in info.get("extrusion_points", []) if not (-12 <= p[0] <= 262 and -12 <= p[1] <= 262)]
        if out_of_bed:
            problems.append(f"{len(out_of_bed)} Extrusionen außerhalb des Betts")
        if info["moves"] < 50:
            problems.append("zu wenig Extrusion")
        analysis["problems"] = problems
        with self.lock:
            self.files[Path(name).name] = {"size": len(content), "md5": hashlib.md5(content).hexdigest(), "analysis": analysis}
        return analysis


# ---------------------------------------------------------------------------- HTTP
def make_http_handler(printer: Printer):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):  # quiet
            pass

        def send_json(self, obj, code=200):
            body = json.dumps(obj).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            url = urlparse(self.path)
            if url.path == "/info":
                self.send_json({"modelId": MODEL_ID, "modelName": "Anycubic Kobra S1", "cn": "SIMKOBRAS1",
                                "token": printer.token, "ctrlType": "lan",
                                "ctrlInfoUrl": f"http://{printer.host}:18910/ctrl"})
            elif url.path == "/sim/state":
                with printer.lock:
                    self.send_json({"state": printer.state, "task": printer.task, "files": printer.files,
                                    "commands": printer.commands[-200:], "last_project": printer.last_project,
                                    "humidity": printer.humidity, "dry": printer.dry,
                                    "nozzle": printer.nozzle, "bed": printer.bed, "light": printer.light})
            else:
                self.send_json({"code": 404}, 404)

        def do_POST(self):
            url = urlparse(self.path)
            q = {k: v[0] for k, v in parse_qs(url.query).items()}
            length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(length) if length else b""
            if url.path == "/ctrl":
                ts, nonce, sign = q.get("ts", ""), q.get("nonce", ""), q.get("sign", "")
                inner = hashlib.md5(printer.token[:16].encode()).hexdigest()
                expected = hashlib.md5((inner + ts + nonce).encode()).hexdigest()
                if sign != expected or not q.get("did"):
                    self.send_json({"code": 10403, "message": "signature mismatch"})
                    return
                iv_token = rand(16)
                creds = json.dumps({"broker": f"mqtts://{printer.host}:9883", "username": printer.username,
                                    "password": printer.password, "deviceId": printer.device}).encode()
                cipher = aes128_cbc_encrypt(creds, printer.token[16:32].encode(), iv_token.encode())
                self.send_json({"code": 200, "message": "success",
                                "data": {"info": base64.b64encode(cipher).decode(), "token": iv_token}})
            elif url.path == "/gcode_upload":
                if q.get("s") != printer.upload_secret:
                    self.send_json({"code": 10401, "message": "bad upload secret"}, 403)
                    return
                fields = parse_multipart(body, self.headers.get("Content-Type", ""))
                name = fields.get("filename", (None, b""))[1].decode() or (fields.get("gcode") or ("upload.gcode", b""))[0]
                if "gcode" not in fields:
                    self.send_json({"code": 10400, "message": "missing gcode"}, 400)
                    return
                analysis = printer.store_upload(name, fields["gcode"][1])
                self.send_json({"code": 200, "message": "success", "data": {"analysis": analysis}})
            else:
                self.send_json({"code": 404}, 404)

    return Handler


def parse_multipart(body: bytes, content_type: str) -> dict[str, tuple[str | None, bytes]]:
    marker = "boundary="
    if marker not in content_type:
        return {}
    boundary = content_type.split(marker, 1)[1].strip().strip('"').encode()
    fields = {}
    for part in body.split(b"--" + boundary):
        if b"\r\n\r\n" not in part:
            continue
        head, _, content = part.partition(b"\r\n\r\n")
        if content.endswith(b"\r\n"):
            content = content[:-2]
        headers = head.decode(errors="replace")
        name = filename = None
        for token in headers.replace("\r\n", ";").split(";"):
            token = token.strip()
            if token.startswith("name="):
                name = token[5:].strip('"')
            elif token.startswith("filename="):
                filename = token[9:].strip('"')
        if name:
            fields[name] = (filename, content)
    return fields


# ---------------------------------------------------------------------------- MQTT broker (3.1.1, TLS)
def topic_matches(flt: str, topic: str) -> bool:
    f, t = flt.split("/"), topic.split("/")
    for i, part in enumerate(f):
        if part == "#":
            return True
        if i >= len(t) or (part != "+" and part != t[i]):
            return False
    return len(f) == len(t)


def encode_length(n: int) -> bytes:
    out = bytearray()
    while True:
        b = n % 128
        n //= 128
        out.append(b | (0x80 if n else 0))
        if not n:
            return bytes(out)


def mqtt_string(s: str) -> bytes:
    b = s.encode()
    return struct.pack(">H", len(b)) + b


class Broker:
    def __init__(self, printer: Printer):
        self.printer = printer
        self.clients: list[tuple[asyncio.StreamWriter, list[str]]] = []
        self.loop: asyncio.AbstractEventLoop | None = None

    def publish(self, topic: str, payload: dict) -> None:
        data = json.dumps(payload).encode()
        packet_body = mqtt_string(topic) + data
        packet = bytes([0x30]) + encode_length(len(packet_body)) + packet_body
        for writer, filters in list(self.clients):
            if any(topic_matches(f, topic) for f in filters):
                self.loop.call_soon_threadsafe(writer.write, packet)

    async def serve_client(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        filters: list[str] = []
        entry = (writer, filters)
        try:
            while True:
                header = await reader.readexactly(1)
                length, mult = 0, 1
                while True:
                    b = (await reader.readexactly(1))[0]
                    length += (b & 0x7F) * mult
                    mult *= 128
                    if not b & 0x80:
                        break
                body = await reader.readexactly(length) if length else b""
                ptype = header[0] >> 4
                if ptype == 1:  # CONNECT
                    pos = 2 + struct.unpack(">H", body[:2])[0] + 4  # protocol name, level, flags, keepalive
                    flags = body[pos - 3]
                    def read_str(p):
                        n = struct.unpack(">H", body[p:p + 2])[0]
                        return body[p + 2:p + 2 + n].decode(), p + 2 + n
                    _client, pos = read_str(pos)
                    user = pw = None
                    if flags & 0x80:
                        user, pos = read_str(pos)
                    if flags & 0x40:
                        pw, pos = read_str(pos)
                    ok = user == self.printer.username and pw == self.printer.password
                    writer.write(bytes([0x20, 2, 0, 0 if ok else 5]))
                    if not ok:
                        await writer.drain()
                        return
                    self.clients.append(entry)
                elif ptype == 8:  # SUBSCRIBE
                    pid = body[:2]
                    pos, granted = 2, bytearray()
                    while pos < len(body):
                        n = struct.unpack(">H", body[pos:pos + 2])[0]
                        filters.append(body[pos + 2:pos + 2 + n].decode())
                        pos += 2 + n + 1
                        granted.append(0)
                    writer.write(bytes([0x90]) + encode_length(2 + len(granted)) + pid + bytes(granted))
                elif ptype == 3:  # PUBLISH
                    qos = (header[0] >> 1) & 3
                    n = struct.unpack(">H", body[:2])[0]
                    topic = body[2:2 + n].decode()
                    pos = 2 + n
                    if qos:
                        pid = body[pos:pos + 2]
                        pos += 2
                        writer.write(bytes([0x40, 2]) + pid)
                    try:
                        msg = json.loads(body[pos:])
                    except ValueError:
                        msg = None
                    if msg and (f"/web/printer/{MODEL_ID}/{self.printer.device}/" in topic
                                or f"/slicer/printer/{MODEL_ID}/{self.printer.device}/" in topic):
                        threading.Thread(target=self.printer.handle, args=(topic, msg), daemon=True).start()
                elif ptype == 12:  # PINGREQ
                    writer.write(bytes([0xD0, 0]))
                elif ptype == 14:  # DISCONNECT
                    return
                await writer.drain()
        except (asyncio.IncompleteReadError, ConnectionError, ssl.SSLError):
            pass
        finally:
            if entry in self.clients:
                self.clients.remove(entry)
            writer.close()


def make_certificate(directory: Path) -> tuple[str, str]:
    cert, key = directory / "cert.pem", directory / "key.pem"
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "30", "-subj", "/CN=kobra-s1-sim",
                    "-keyout", str(key), "-out", str(cert)], check=True, capture_output=True)
    return str(cert), str(key)


async def main_async(args) -> None:
    printer = Printer(args.host, args.speed, args.duration)
    broker = Broker(printer)
    broker.loop = asyncio.get_running_loop()
    printer.publish = broker.publish

    http = ThreadingHTTPServer((args.bind, 18910), make_http_handler(printer))
    threading.Thread(target=http.serve_forever, daemon=True).start()

    cert, key = make_certificate(Path(tempfile.mkdtemp(prefix="kobra_sim_tls")))
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(cert, key)
    server = await asyncio.start_server(broker.serve_client, args.bind, 9883, ssl=ctx)
    print(f"Virtueller Kobra S1 läuft: http://{args.host}:18910/info, MQTT/TLS :9883, Geschwindigkeit ×{args.speed}", flush=True)

    async def ticker():
        while True:
            await asyncio.sleep(1)
            await asyncio.to_thread(printer.tick, 1.0)

    async with server:
        await asyncio.gather(server.serve_forever(), ticker())


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default="127.0.0.1", help="address reported to clients")
    ap.add_argument("--bind", default="0.0.0.0")
    ap.add_argument("--speed", type=float, default=1.0, help="simulation speed factor")
    ap.add_argument("--duration", type=float, default=600.0, help="simulated print duration in seconds")
    args = ap.parse_args()
    try:
        asyncio.run(main_async(args))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
