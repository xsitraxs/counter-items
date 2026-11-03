#!/usr/bin/env python3
"""Локальный сервер для веб-прототипа Deadlock.

Слушает 0.0.0.0:PORT (по умолчанию 8765), отдаёт:
  /                -> web/index.html
  /web/...         -> статика
  /data/...        -> JSON базы
  /state.json      -> последнее состояние от агента (если есть)
  POST /state      -> сохранить состояние от агента в agent/state.json

Запуск:  python3 agent/serve.py
Порт можно передать через PORT=... или --port.
"""

from __future__ import annotations

import argparse
import json
import os
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
STATE_PATH = Path(__file__).resolve().parent / "state.json"


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(ROOT), **kwargs)

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        self.send_header("Access-Control-Allow-Origin", "*")
        super().end_headers()

    def do_OPTIONS(self):
        self.send_response(204)
        self.end_headers()

    def do_GET(self):
        if self.path in ("/", "/index.html"):
            self.path = "/web/index.html"
        elif self.path == "/state.json":
            self._serve_state()
            return
        elif self.path == "/health":
            self._send_json({"ok": True})
            return
        super().do_GET()

    def do_POST(self):
        if self.path != "/state":
            self.send_error(404)
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length <= 0 or length > 1_000_000:
                raise ValueError("bad content length")
            payload = json.loads(self.rfile.read(length).decode("utf-8"))
            if not isinstance(payload, dict):
                raise ValueError("state must be an object")
            STATE_PATH.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            self._send_json({"ok": True, "path": str(STATE_PATH)})
        except Exception as error:  # noqa: BLE001 - вернуть ошибку агенту
            self._send_json({"ok": False, "error": str(error)}, status=400)

    def _serve_state(self):
        if not STATE_PATH.exists():
            self.send_error(404, "state.json not found")
            return
        payload = STATE_PATH.read_text(encoding="utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload.encode("utf-8"))))
        self.end_headers()
        self.wfile.write(payload.encode("utf-8"))

    def _send_json(self, payload, status=200):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main():
    parser = argparse.ArgumentParser(description="Deadlock prototype web server")
    parser.add_argument("--port", type=int, default=int(os.environ.get("PORT", "8765")))
    parser.add_argument("--host", default="0.0.0.0")
    args = parser.parse_args()
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f"Deadlock prototype: http://{args.host}:{args.port}/")
    print(f"State endpoint:     http://{args.host}:{args.port}/state.json")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
