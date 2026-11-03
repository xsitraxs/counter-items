#!/usr/bin/env python3
"""Always-on-top окно с веб-интерфейсом прототипа.

Требует pywebview (Windows: WebView2, macOS: WKWebView, Linux: GTK/Qt):
  python3 -m pip install pywebview

Запуск при уже работающем сервере:
  python3 agent/serve.py
  python3 agent/overlay.py --url http://127.0.0.1:8765/web/

Если pywebview не установлен, просто откроет URL в системном браузере.
"""

from __future__ import annotations

import argparse
import webbrowser


def main():
    parser = argparse.ArgumentParser(description="Deadlock prototype always-on-top window")
    parser.add_argument("--url", default="http://127.0.0.1:8765/web/")
    parser.add_argument("--width", type=int, default=430)
    parser.add_argument("--height", type=int, default=900)
    parser.add_argument("--no-on-top", action="store_true")
    args = parser.parse_args()

    try:
        import webview  # type: ignore
    except Exception:
        print("pywebview не установлен; открываю в браузере.")
        print("Для always-on-top окна: python3 -m pip install pywebview")
        webbrowser.open(args.url)
        return

    webview.create_window(
        "Deadlock — Situational Build",
        args.url,
        width=args.width,
        height=args.height,
        on_top=not args.no_on_top,
        confirm_close=True,
    )
    webview.start()


if __name__ == "__main__":
    main()
