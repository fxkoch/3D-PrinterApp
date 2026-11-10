#!/usr/bin/env python3
"""Virtual Bambu Lab P1S with AMS in LAN mode.

What a real printer offers in LAN mode (OpenBambuAPI, bambulabs_api, ha-bambulab):

  * MQTT 3.1.1 over TLS  user "bblp", password = access code
      subscribe  device/<serial>/report      request  device/<serial>/request
      pushall / get_version / project_file / pause / resume / stop / gcode_line / ledctrl
  * FTPS implicit (TLS from the first byte), passive mode, protected data channel; files land in the root folder

The print is simulated (progress, layers, temperatures move over time; pause/resume/stop work). An uploaded
.gcode.3mf is unpacked and checked: Metadata/plate_1.gcode must be there and match its .md5.
GET /sim/state (HTTP) lists everything the simulator received, for tests.

Defaults avoid privileged ports so no root is needed:
    python3 tools/virtualprinters/bambu_p1s_sim.py --mqtt-port 18883 --ftps-port 18990 --http-port 18884 --speed 30
"""
from __future__ import annotations

import argparse
import asyncio
import hashlib
import io
import json
import ssl
import struct
import subprocess
import tempfile
import threading
import time
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from kobra_s1_sim import encode_length, make_certificate, mqtt_string, topic_matches

SERIAL = "01P00A000000001"
ACCESS_CODE = "12345678"


class Printer:
    def __init__(self, speed: float, duration: float):
        self.speed, self.duration = speed, duration
        self.state = "IDLE"
        self.progress = 0.0
        self.layer, self.total_layers = 0, 0
        self.file = ""
        self.nozzle, self.bed = 25.0, 25.0
        self.nozzle_target, self.bed_target = 0.0, 0.0
        self.light = True
        self.error = 0
        self.tray_now = 0
        self.received: list[dict] = []
        self.uploads: dict[str, dict] = {}
        self.dir = Path(tempfile.mkdtemp(prefix="p1s_sim_"))
        self.publish = lambda payload: None

    def ams(self) -> dict:
        trays = [
            {"id": "0", "tray_type": "PLA", "tray_sub_brands": "PLA Basic", "tray_color": "F5F5F0FF", "tray_uuid": "A1" * 16},
            {"id": "1", "tray_type": "PETG", "tray_sub_brands": "PETG HF", "tray_color": "2B2B2EFF", "tray_uuid": "B2" * 16},
            {"id": "2", "tray_type": "", "tray_color": "00000000", "tray_uuid": "0" * 32},
            {"id": "3", "tray_type": "PLA", "tray_sub_brands": "PLA Matte", "tray_color": "E5483CFF", "tray_uuid": "C3" * 16},
        ]
        return {"ams": [{"id": "0", "humidity": "4", "humidity_raw": "31", "tray": trays}], "tray_now": str(self.tray_now)}

    def report(self, full: bool) -> dict:
        p = {
            "gcode_state": self.state, "mc_percent": int(self.progress * 100),
            "mc_remaining_time": int(max(0, (1 - self.progress) * self.duration / 60)),
            "layer_num": self.layer, "total_layer_num": self.total_layers,
            "nozzle_temper": round(self.nozzle, 1), "nozzle_target_temper": self.nozzle_target,
            "bed_temper": round(self.bed, 1), "bed_target_temper": self.bed_target,
            "chamber_temper": 31.0, "cooling_fan_speed": "15" if self.state == "RUNNING" else "0", "big_fan1_speed": "8",
            "spd_lvl": 2, "print_error": self.error, "gcode_file": self.file, "subtask_name": self.file,
            "lights_report": [{"node": "chamber_light", "mode": "on" if self.light else "off"}],
        }
        if full:
            p["ams"] = self.ams()
            p["command"] = "push_status"
        return {"print": p}

    def ack(self, command: str, seq: str, ok: bool = True, reason: str = "") -> None:
        self.publish({"print": {"command": command, "sequence_id": seq, "result": "success" if ok else "failed", "reason": reason}})

    def handle(self, msg: dict) -> None:
        self.received.append(msg)
        if "pushing" in msg:
            self.publish(self.report(True))
        elif "info" in msg:
            self.publish({"info": {"command": "get_version", "sequence_id": msg["info"].get("sequence_id", "0"),
                                   "module": [{"name": "ota", "sw_ver": "01.08.02.00", "hw_ver": "OTA"}]}})
        elif "system" in msg:
            if msg["system"].get("command") == "ledctrl":
                self.light = msg["system"].get("led_mode") == "on"
                self.publish(self.report(False))
        elif "print" in msg:
            p = msg["print"]
            cmd, seq = p.get("command"), str(p.get("sequence_id", "0"))
            if cmd == "project_file":
                name = str(p.get("url", "")).rsplit("/", 1)[-1]
                if name not in self.uploads:
                    return self.ack(cmd, seq, False, "file not found on SD card")
                if not self.uploads[name].get("valid"):
                    return self.ack(cmd, seq, False, "invalid 3mf: " + self.uploads[name].get("problem", ""))
                self.file, self.state, self.progress, self.layer = p.get("subtask_name", name), "RUNNING", 0.0, 0
                self.total_layers = self.uploads[name].get("layers", 100)
                self.nozzle_target, self.bed_target, self.error = 220.0, 60.0, 0
                self.ack(cmd, seq)
            elif cmd == "pause" and self.state == "RUNNING":
                self.state = "PAUSE"; self.ack(cmd, seq)
            elif cmd == "resume" and self.state == "PAUSE":
                self.state = "RUNNING"; self.ack(cmd, seq)
            elif cmd == "stop" and self.state in ("RUNNING", "PAUSE"):
                self.state, self.error, self.nozzle_target, self.bed_target = "FAILED", 50348044, 0.0, 0.0
                self.ack(cmd, seq)
            elif cmd == "ams_change_filament":
                if self.state in ("RUNNING", "PAUSE"):
                    return self.ack(cmd, seq, False, "printing")
                self.tray_now = int(p.get("target", 255))
                self.ack(cmd, seq)
            elif cmd == "gcode_line":
                line = str(p.get("param", ""))
                for token in line.split():
                    if token.startswith("S") and line.startswith("M140"): self.bed_target = float(token[1:])
                    if token.startswith("S") and line.startswith("M104"): self.nozzle_target = float(token[1:])
                self.ack(cmd, seq)
            else:
                self.ack(cmd or "?", seq, False, "not allowed in state " + self.state)
            self.publish(self.report(False))

    def tick(self, dt: float) -> None:
        self.nozzle += (self.nozzle_target - self.nozzle) * min(1, dt * 0.2)
        self.bed += (self.bed_target - self.bed) * min(1, dt * 0.1)
        if self.state == "RUNNING":
            self.progress = min(1.0, self.progress + dt * self.speed / self.duration)
            self.layer = int(self.progress * self.total_layers)
            if self.progress >= 1.0:
                self.state, self.nozzle_target, self.bed_target = "FINISH", 0.0, 0.0
        self.publish(self.report(False))

    def check_upload(self, name: str, data: bytes) -> None:
        info: dict = {"size": len(data)}
        try:
            z = zipfile.ZipFile(io.BytesIO(data))
            names = z.namelist()
            gcode = z.read("Metadata/plate_1.gcode")
            md5 = z.read("Metadata/plate_1.gcode.md5").decode().strip().upper()
            real = hashlib.md5(gcode).hexdigest().upper()
            info["valid"] = md5 == real
            if not info["valid"]:
                info["problem"] = "md5 mismatch"
            text = gcode.decode(errors="replace")
            info["layers"] = text.count(";LAYER_CHANGE") or 100
            info["has_ams_change"] = "M620 S" in text
            info["klipper_commands"] = [c for c in ("SET_PRESSURE_ADVANCE", "SET_VELOCITY_LIMIT", "BED_MESH_CALIBRATE", "SM_PRINT", "G9111") if c in text]
            info["files"] = names
            (self.dir / name).write_bytes(data)
        except Exception as e:  # noqa: BLE001
            info["valid"], info["problem"] = False, str(e)
        self.uploads[name] = info


# ---------------------------------------------------------------- MQTT

class Broker:
    def __init__(self, printer: Printer):
        self.printer = printer
        self.clients: list[tuple[asyncio.StreamWriter, list[str]]] = []
        self.loop: asyncio.AbstractEventLoop | None = None

    def publish(self, payload: dict) -> None:
        topic = f"device/{SERIAL}/report"
        body = mqtt_string(topic) + json.dumps(payload).encode()
        packet = bytes([0x30]) + encode_length(len(body)) + body
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
                if ptype == 1:
                    pos = 2 + struct.unpack(">H", body[:2])[0] + 4
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
                    ok = user == "bblp" and pw == ACCESS_CODE
                    writer.write(bytes([0x20, 2, 0, 0 if ok else 5]))
                    if not ok:
                        await writer.drain()
                        return
                    self.clients.append(entry)
                elif ptype == 8:
                    pid, pos, granted = body[:2], 2, bytearray()
                    while pos < len(body):
                        n = struct.unpack(">H", body[pos:pos + 2])[0]
                        filters.append(body[pos + 2:pos + 2 + n].decode())
                        pos += 2 + n + 1
                        granted.append(0)
                    writer.write(bytes([0x90]) + encode_length(2 + len(granted)) + pid + bytes(granted))
                elif ptype == 3:
                    n = struct.unpack(">H", body[:2])[0]
                    topic = body[2:2 + n].decode()
                    try:
                        msg = json.loads(body[2 + n:])
                    except ValueError:
                        msg = None
                    if msg and topic == f"device/{SERIAL}/request":
                        threading.Thread(target=self.printer.handle, args=(msg,), daemon=True).start()
                elif ptype == 12:
                    writer.write(bytes([0xD0, 0]))
                elif ptype == 14:
                    return
                await writer.drain()
        except (asyncio.IncompleteReadError, ConnectionError, ssl.SSLError):
            pass
        finally:
            if entry in self.clients:
                self.clients.remove(entry)
            writer.close()


# ---------------------------------------------------------------- FTPS

class FTPServer:
    def __init__(self, printer: Printer, ctx: ssl.SSLContext, bind: str):
        self.printer, self.ctx, self.bind = printer, ctx, bind

    async def serve(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        async def say(line: str) -> None:
            writer.write((line + "\r\n").encode())
            await writer.drain()
        data_server = None
        data_future: asyncio.Future | None = None
        authed, user, protected = False, None, False
        try:
            await say("220 Bambu FTP ready")
            while True:
                raw = await reader.readline()
                if not raw:
                    return
                line = raw.decode(errors="replace").strip()
                cmd, _, arg = line.partition(" ")
                cmd = cmd.upper()
                if cmd == "USER":
                    user = arg
                    await say("331 password please")
                elif cmd == "PASS":
                    authed = user == "bblp" and arg == ACCESS_CODE
                    await say("230 logged in" if authed else "530 Login incorrect")
                elif not authed and cmd != "QUIT":
                    await say("530 Please login")
                elif cmd == "PBSZ":
                    await say("200 PBSZ=0")
                elif cmd == "PROT":
                    protected = arg.upper() == "P"
                    await say("200 PROT set")
                elif cmd == "TYPE":
                    await say("200 Binary")
                elif cmd == "PASV":
                    loop = asyncio.get_running_loop()
                    data_future = loop.create_future()

                    async def on_data(r, w, fut=data_future):
                        if not fut.done():
                            fut.set_result((r, w))
                    data_server = await asyncio.start_server(on_data, self.bind, 0, ssl=self.ctx if protected else None)
                    port = data_server.sockets[0].getsockname()[1]
                    await say(f"227 Entering Passive Mode (127,0,0,1,{port >> 8},{port & 255})")
                elif cmd == "STOR":
                    if data_future is None:
                        await say("425 Use PASV first")
                        continue
                    await say("150 Ok to send data")
                    dr, dw = await asyncio.wait_for(data_future, 10)
                    blob = await dr.read()
                    dw.close()
                    self.printer.check_upload(arg.lstrip("/"), blob)
                    data_server.close()
                    data_future = None
                    await say("226 Transfer complete")
                elif cmd == "QUIT":
                    await say("221 Bye")
                    return
                else:
                    await say("502 Not implemented")
        except (ConnectionError, ssl.SSLError, asyncio.TimeoutError):
            pass
        finally:
            writer.close()


def make_http_handler(printer: Printer):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def do_GET(self):
            if self.path.startswith("/sim/state"):
                body = json.dumps({"state": printer.state, "progress": printer.progress, "received": printer.received,
                                   "uploads": printer.uploads, "light": printer.light}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            else:
                self.send_response(404)
                self.end_headers()
    return Handler


async def main_async(args) -> None:
    printer = Printer(args.speed, args.duration)
    broker = Broker(printer)
    broker.loop = asyncio.get_running_loop()
    printer.publish = broker.publish
    cert, key = make_certificate(Path(tempfile.mkdtemp(prefix="p1s_sim_tls")))
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(cert, key)
    http = ThreadingHTTPServer((args.bind, args.http_port), make_http_handler(printer))
    threading.Thread(target=http.serve_forever, daemon=True).start()
    mqtt = await asyncio.start_server(broker.serve_client, args.bind, args.mqtt_port, ssl=ctx)
    ftps = await asyncio.start_server(FTPServer(printer, ctx, args.bind).serve, args.bind, args.ftps_port, ssl=ctx)
    print(f"Virtueller Bambu P1S läuft: MQTT/TLS :{args.mqtt_port}, FTPS :{args.ftps_port}, Zustand http://127.0.0.1:{args.http_port}/sim/state"
          f" (Seriennummer {SERIAL}, Zugangscode {ACCESS_CODE})", flush=True)

    async def ticker():
        while True:
            await asyncio.sleep(1)
            await asyncio.to_thread(printer.tick, 1.0)

    async with mqtt, ftps:
        await asyncio.gather(mqtt.serve_forever(), ftps.serve_forever(), ticker())


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bind", default="127.0.0.1")
    ap.add_argument("--mqtt-port", type=int, default=18883)
    ap.add_argument("--ftps-port", type=int, default=18990)
    ap.add_argument("--http-port", type=int, default=18884)
    ap.add_argument("--speed", type=float, default=1.0)
    ap.add_argument("--duration", type=float, default=600.0)
    args = ap.parse_args()
    try:
        asyncio.run(main_async(args))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
