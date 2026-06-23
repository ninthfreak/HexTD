#!/usr/bin/env python3
"""
Hex TD Editor — local helper.

Run this from your game folder (the one containing project.godot / data / maps):

    python editor.py

It opens the editor in your browser, auto-loads data/enemies.json,
data/waves.json, data/towers.json and every map in maps/, and the Save buttons
write straight back to those files. Stop it with Ctrl+C.

Requires Python 3 and editor.html sitting next to this file.
"""
import http.server
import socketserver
import socket
import json
import re
import threading
import webbrowser
from pathlib import Path

HERE = Path(__file__).resolve().parent


def find_root() -> Path:
    """Locate the game folder by walking up from here / the working dir."""
    for base in (HERE, Path.cwd()):
        cur = base
        for _ in range(6):
            if (cur / "project.godot").exists() or (cur / "data").is_dir():
                return cur
            if cur.parent == cur:
                break
            cur = cur.parent
    return HERE


ROOT = find_root()
DATA = ROOT / "data"
MAPS = ROOT / "maps"


def read_json(path: Path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None


def sanitize(name: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "_", (name or "map").lower()).strip("_")
    return s or "map"


class Handler(http.server.BaseHTTPRequestHandler):
    def _send(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path in ("/", "/index.html"):
            html_path = HERE / "editor.html"
            if not html_path.exists():
                return self._send(500, "editor.html not found next to editor.py", "text/plain")
            return self._send(200, html_path.read_text(encoding="utf-8"), "text/html; charset=utf-8")
        if self.path == "/api/state":
            maps = {}
            if MAPS.is_dir():
                for f in sorted(MAPS.glob("*.json")):
                    m = read_json(f)
                    if m is not None:
                        maps[f.stem] = m
            state = {
                "root": str(ROOT),
                "hasData": DATA.is_dir(),
                "data": {
                    "enemies": read_json(DATA / "enemies.json"),
                    "waves": read_json(DATA / "waves.json"),
                    "towers": read_json(DATA / "towers.json"),
                },
                "maps": maps,
            }
            return self._send(200, json.dumps(state))
        return self._send(404, json.dumps({"error": "not found"}))

    def do_POST(self):
        if self.path != "/api/save":
            return self._send(404, json.dumps({"error": "not found"}))
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length)
        try:
            payload = json.loads(raw)
        except Exception as e:
            return self._send(400, json.dumps({"error": "bad json: " + str(e)}))
        target = payload.get("target")
        content = payload.get("content")
        try:
            if target in ("enemies", "waves", "towers"):
                DATA.mkdir(exist_ok=True)
                path = DATA / (target + ".json")
            elif target == "map":
                MAPS.mkdir(exist_ok=True)
                path = MAPS / (sanitize(payload.get("name")) + ".json")
            else:
                return self._send(400, json.dumps({"error": "unknown target"}))
            path.write_text(json.dumps(content, indent=2), encoding="utf-8")
            return self._send(200, json.dumps({"ok": True, "path": str(path)}))
        except Exception as e:
            return self._send(500, json.dumps({"error": str(e)}))

    def log_message(self, *args):
        pass  # quiet


def free_port(start=8765, end=8800) -> int:
    for p in range(start, end):
        with socket.socket() as s:
            try:
                s.bind(("127.0.0.1", p))
                return p
            except OSError:
                continue
    return start


def main():
    port = free_port()
    url = f"http://127.0.0.1:{port}/"
    print("Hex TD Editor")
    print(f"  game folder : {ROOT}")
    print(f"  open        : {url}")
    if not DATA.is_dir():
        print("  WARNING: no data/ folder found here — run this from your game folder.")
    print("  (Ctrl+C to stop)")
    threading.Timer(0.6, lambda: webbrowser.open(url)).start()
    with socketserver.TCPServer(("127.0.0.1", port), Handler) as httpd:
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\nStopped.")


if __name__ == "__main__":
    main()
