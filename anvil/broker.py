#!/usr/bin/env python3
"""
Smart-bulb status broker — anvil :9130.

Single writer to the Tapo L530 bulb (192.168.1.225). Owns the base state, the
pattern library, and a priority mutex so only one pattern drives the bulb at a
time. Hermes emits events; waybar and anything else read /status.

Endpoints:
  GET /status            -> {"state","since","seq","connected","uptime"}
  GET /bar               -> {"text","class","tooltip"}   (waybar custom module)
  GET /set/<state>       -> set state, return /bar JSON
  POST /state {"state":} -> set state, return /status JSON

States: idle, working, needs_input, done, error, off, mail_checked, git_updated, backup_fail
"""
from __future__ import annotations

import asyncio
import json
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
ENV_FILE = HERE / ".env"
HOST, PORT = "0.0.0.0", 9130
START = time.time()


def load_env() -> dict:
    cfg: dict[str, str] = {}
    if ENV_FILE.exists():
        for raw in ENV_FILE.read_text().splitlines():
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            cfg[k.strip()] = v.strip().strip('"').strip("'")
    for k in ("SMARTBULB_TAPO_USER", "SMARTBULB_TAPO_PASS", "SMARTBULB_IP"):
        if os.environ.get(k):
            cfg[k] = os.environ[k]
    return cfg


CFG = load_env()
IP = CFG.get("SMARTBULB_IP", "192.168.1.225")
USER = CFG.get("SMARTBULB_TAPO_USER", "")
PASS = CFG.get("SMARTBULB_TAPO_PASS", "")

# ── Pattern library ──────────────────────────────────────────────────────────
# Each pattern = {"loop": bool, "steps": [(kind, params, hold_seconds), ...]}
# kind: "ct"  -> (kelvin, brightness)
#       "hue" -> (hue, saturation, brightness)
#       "off" -> ()
# Every non-loop pattern must end parked at base state (cool white, bri 5).
BASE = ("ct", (4000, 5), 0)

PATTERNS: dict[str, dict] = {
    "idle": {
        "loop": False,
        "steps": [BASE],
    },
    "working": {
        "loop": False,
        "steps": [BASE],
    },
    "needs_input": {
        "loop": False,
        "steps": [("ct", (4000, 100), 0.5), BASE],
    },
    "done": {
        "loop": False,
        "steps": (
            [("ct", (4000, 21), 0.3), ("hue", (0, 100, 100), 0.3)] * 5
            + [("hue", (120, 100, 100), 0.8), BASE]
        ),
    },
    "error": {
        "loop": False,
        "steps": (
            [("hue", (0, 100, 100), 0.5), ("off", (), 0.3)] * 2 + [BASE]
        ),
    },
    "off": {
        "loop": False,
        "steps": [("off", (), 0)],
    },
    "mail_checked": {
        "loop": False,
        "steps": [
            ("hue", (240, 100, 100), 0.3),    # blue flash
            BASE
        ],
    },
    "git_updated": {
        "loop": False,
        "steps": [
            ("hue", (120, 100, 100), 0.3),    # green flash  
            BASE
        ],
    },
    "backup_fail": {
        "loop": False,
        "steps": [
            ("hue", (0, 100, 100), 0.2), ("hue", (0, 0, 0), 0.1),  # red flash
            ("hue", (240, 100, 100), 0.2), ("hue", (0, 0, 0), 0.1),  # blue flash
            BASE
        ],
    },
}

LABELS = {
    "idle": "idle",
    "working": "working",
    "needs_input": "NEEDS INPUT",
    "done": "done",
    "error": "error",
    "off": "off",
    "mail_checked": "MAIL CHECKED",
    "git_updated": "GIT UPDATED",
    "backup_fail": "BACKUP FAILED",
}

# ── Shared state (HTTP thread <-> asyncio worker) ────────────────────────────
_lock = threading.Lock()
_desired = {"state": "idle", "seq": 0}
_applied = {"state": "idle", "since": time.time(), "connected": False}

# Backup fail tracking: triggers police light flash every 10 min for 1 hour
_backup_fail_state = {"active": False, "last_flash": 0, "end_time": 0}


# Precedence: higher number = higher priority. needs_input sticks until cleared.
PRECEDENCE = {"off": 0, "idle": 1, "done": 1, "error": 2, "working": 3, "needs_input": 4, "mail_checked": 3, "git_updated": 3, "backup_fail": 2}

def set_state(state: str) -> bool:
    if state not in PATTERNS:
        return False
    with _lock:
        cur = _desired["state"]
        # needs_input is sticky: only a same-or-higher precedence state can override it
        if cur == "needs_input" and PRECEDENCE.get(state, 0) < PRECEDENCE["needs_input"]:
            return False
        _desired["state"] = state
        _desired["seq"] += 1
        # Start backup_fail timer when triggered
        if state == "backup_fail":
            _backup_fail_state["active"] = True
            _backup_fail_state["last_flash"] = time.time()
            _backup_fail_state["end_time"] = time.time() + 3600  # 1 hour
            # Log the event for catch-up reporting
            try:
                import subprocess
                subprocess.run(["python3", str(HERE / "log_backup_event.py")], check=False)
            except Exception:
                pass  # Don't fail the state change if logging fails
    return True


def snapshot() -> dict:
    with _lock:
        backup_info = {
            "active": _backup_fail_state["active"],
            "started_at": _backup_fail_state["last_flash"] if _backup_fail_state["active"] else None,
            "end_time": _backup_fail_state["end_time"] if _backup_fail_state["active"] else None,
        }
        return {
            "state": _desired["state"],          # desired (what Hermes/waybar asked for)
            "applied": _applied["state"],         # what the bulb is actually doing
            "since": _applied["since"],
            "seq": _desired["seq"],
            "connected": _applied["connected"],
            "uptime": round(time.time() - START, 1),
            "backup_fail_active": backup_info,
        }


# ── Bulb worker (asyncio) ────────────────────────────────────────────────────
async def _apply(dev, kind: str, params: tuple) -> None:
    if kind == "off":
        await dev.off()
    elif kind == "ct":
        k, b = params
        await dev.set().on().color_temperature(k).brightness(b).send(dev)
    elif kind == "hue":
        h, s, b = params
        await dev.set().on().hue_saturation(h, s).brightness(b).send(dev)


async def _run_pattern(dev, state: str, seq: int) -> None:
    pat = PATTERNS[state]
    while True:
        for kind, params, hold in pat["steps"]:
            with _lock:
                if _desired["seq"] != seq:
                    return
            try:
                await _apply(dev, kind, params)
            except Exception:
                pass
            if hold > 0:
                await asyncio.sleep(hold)
        with _lock:
            _applied["state"] = state
            _applied["since"] = time.time()
            if _desired["seq"] != seq:
                return
        if not pat["loop"]:
            # Non-loop patterns that should auto-return to idle
            if state in ("needs_input", "mail_checked", "git_updated"):
                with _lock:
                    _desired["state"] = "idle"
                    _desired["seq"] += 1
            return


async def _worker() -> None:
    from tapo import ApiClient

    dev = None
    last_seq = -1
    cur = None
    fails = 0
    while True:
        try:
            if dev is None:
                if not USER or not PASS:
                    with _lock:
                        _applied["connected"] = False
                    await asyncio.sleep(5)
                    continue
                dev = await ApiClient(USER, PASS).l530(IP)
                with _lock:
                    _applied["connected"] = True
                fails = 0
        except Exception:
            dev = None
            with _lock:
                _applied["connected"] = False
            await asyncio.sleep(5)
            continue

        # Handle periodic backup_fail flashing (every 10 minutes for 1 hour)
        now = time.time()
        with _lock:
            state = _desired["state"]
            seq = _desired["seq"]
            backup_active = _backup_fail_state["active"]
            backup_end = _backup_fail_state["end_time"]
            backup_last = _backup_fail_state["last_flash"]
        
        if backup_active:
            if backup_end > now and (now - backup_last >= 600):
                # Time for another flash
                with _lock:
                    _backup_fail_state["last_flash"] = now
                    seq += 1
                if cur and not cur.done():
                    cur.cancel()
                cur = asyncio.create_task(_run_pattern(dev, "backup_fail", seq))
            elif backup_end <= now:
                # End of 1-hour period - clear backup state and return to idle
                with _lock:
                    _backup_fail_state = {"active": False, "last_flash": 0, "end_time": 0}
                    if _desired["state"] not in ("working", "needs_input"):
                        _desired["state"] = "idle"
                        _desired["seq"] += 1
        else:
            if seq != last_seq:
                last_seq = seq
                if cur and not cur.done():
                    cur.cancel()
                cur = asyncio.create_task(_run_pattern(dev, state, seq))
        
        if cur and cur.done():
            try:
                cur.result()
            except Exception:
                fails += 1
        if fails >= 3:
            dev = None
            fails = 0
        await asyncio.sleep(0.15)


def start_worker() -> None:
    def runner():
        asyncio.run(_worker())

    threading.Thread(target=runner, daemon=True).start()


# ── HTTP ─────────────────────────────────────────────────────────────────────
def bar_json() -> str:
    s = snapshot()
    st = s["state"]
    return json.dumps(
        {
            "text": "●",
            "class": st,
            "tooltip": f"smart bulb: {LABELS.get(st, st)}"
            + ("" if s["connected"] else "  (disconnected)"),
        }
    )


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):  # silence default logging
        pass

    def _send(self, code: int, body: str, ctype: str = "application/json") -> None:
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/status":
            self._send(200, json.dumps(snapshot()))
        elif path == "/bar":
            self._send(200, bar_json())
        elif path.startswith("/set/"):
            state = path[len("/set/"):]
            ok = set_state(state)
            self._send(200 if ok else 400, bar_json() if ok else json.dumps({"error": "bad state", "valid": list(PATTERNS)}))
        elif path in ("/", "/health"):
            self._send(200, json.dumps({"ok": True, "service": "smartbulb-broker"}))
        else:
            self._send(404, json.dumps({"error": "not found"}))

    def do_POST(self):
        if self.path.split("?", 1)[0] == "/state":
            try:
                n = int(self.headers.get("Content-Length", 0))
                body = json.loads(self.rfile.read(n) or b"{}")
                ok = set_state(body.get("state", ""))
                self._send(200 if ok else 400, json.dumps(snapshot()))
            except Exception as e:
                self._send(400, json.dumps({"error": str(e)}))
        else:
            self._send(404, json.dumps({"error": "not found"}))


def main() -> None:
    start_worker()
    srv = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"smartbulb-broker listening on {HOST}:{PORT}  ip={IP}  creds={'yes' if USER and PASS else 'MISSING'}", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
