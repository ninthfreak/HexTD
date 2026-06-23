#!/usr/bin/env python3
"""
Hex TD content editor -- native desktop app.

Opens the editor in a real window. No terminal server to babysit:
launch it, close the window when you're done, and the app exits.

First time only, install the one dependency:

    pip install pywebview

Then run it:

    python editor_app.py        (shows a console on Windows)
    pythonw editor_app.py        (no console window on Windows)

On Windows you can also rename it to  editor_app.pyw  and double-click it.

It finds your game folder automatically by looking next to this file and
walking up for project.godot / data / maps. Pass a path to override:

    python editor_app.py /path/to/HexTowerDefense
"""

import os
import re
import sys
import json

HERE = os.path.dirname(os.path.abspath(__file__))


def find_root(start):
    """Walk up from `start` looking for the game folder."""
    d = os.path.abspath(start)
    for _ in range(8):
        if (os.path.isfile(os.path.join(d, "project.godot"))
                or os.path.isdir(os.path.join(d, "data"))
                or os.path.isdir(os.path.join(d, "maps"))):
            return d
        parent = os.path.dirname(d)
        if parent == d:
            break
        d = parent
    return os.path.abspath(start)


def sanitize_map_name(name):
    base = re.sub(r"[^A-Za-z0-9_-]+", "_", (name or "map").strip().lower()).strip("_")
    return base or "map"


class Api:
    """Methods here are callable from the page as window.pywebview.api.<name>(...)."""

    def __init__(self, root):
        self.root = root
        self.data_dir = os.path.join(root, "data")
        self.maps_dir = os.path.join(root, "maps")

    # ---- read everything the editor needs on boot ----
    def get_state(self):
        data = {}
        for key in ("enemies", "towers", "waves"):
            p = os.path.join(self.data_dir, key + ".json")
            if os.path.isfile(p):
                try:
                    with open(p, encoding="utf-8") as f:
                        data[key] = json.load(f)
                except Exception:
                    pass
        maps = {}
        if os.path.isdir(self.maps_dir):
            for fn in sorted(os.listdir(self.maps_dir)):
                if fn.endswith(".json"):
                    try:
                        with open(os.path.join(self.maps_dir, fn), encoding="utf-8") as f:
                            maps[fn[:-5]] = json.load(f)
                    except Exception:
                        pass
        return {
            "root": self.root,
            "data": data,
            "maps": maps,
            "hasData": os.path.isdir(self.data_dir),
        }

    # ---- write one file ----
    def save(self, target, name, content):
        try:
            if target in ("enemies", "towers", "waves"):
                os.makedirs(self.data_dir, exist_ok=True)
                p = os.path.join(self.data_dir, target + ".json")
            elif target == "map":
                os.makedirs(self.maps_dir, exist_ok=True)
                p = os.path.join(self.maps_dir, sanitize_map_name(name) + ".json")
            else:
                return {"error": "unknown target: %r" % (target,)}
            with open(p, "w", encoding="utf-8") as f:
                json.dump(content, f, indent=2)
            return {"ok": True, "path": p}
        except Exception as e:
            return {"error": str(e)}


def load_html(root):
    with open(os.path.join(HERE, "editor.html"), encoding="utf-8") as f:
        html = f.read()
    # Tell the page it's running inside the native window so it waits for the
    # bridge instead of trying to reach a server.
    inject = '<script>window.__HOST__="pywebview";</script>'
    if "<head>" in html:
        html = html.replace("<head>", "<head>\n" + inject, 1)
    else:
        html = inject + html
    return html


def main():
    root = find_root(sys.argv[1] if len(sys.argv) > 1 else HERE)
    try:
        import webview
    except ImportError:
        sys.stderr.write(
            "\nThis editor needs the 'pywebview' package (one-time install):\n\n"
            "    pip install pywebview\n\n"
            "Then run it again.\n\n"
        )
        sys.exit(1)

    api = Api(root)
    webview.create_window(
        "Hex TD \u2014 Content Editor",
        html=load_html(root),
        js_api=api,
        width=1280,
        height=860,
        min_size=(900, 600),
    )
    webview.start()


if __name__ == "__main__":
    main()
