#!/usr/bin/env python3
"""Помощник калибровки: сохраняет фрагмент экрана как шаблон героя/HUD.

Пример:
  python3 agent/capture_templates.py --name haze --x 300 --y 20 --w 90 --h 90
  python3 agent/capture_templates.py --name scoreboard --x 200 --y 100 --w 900 --h 700

Затем добавьте запись в agent/templates/manifest.json:
  {"templates": [{"hero": "haze", "file": "haze.png", "threshold": 0.8}]}

Захват работает в borderless/windowed. В exclusive fullscreen ОС может не отдать кадр.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

AGENT_DIR = Path(__file__).resolve().parent
TEMPLATES_DIR = AGENT_DIR / "templates"


def main():
    parser = argparse.ArgumentParser(description="Capture a screen region as a template")
    parser.add_argument("--name", required=True, help="имя файла без расширения, например haze")
    parser.add_argument("--x", type=int, required=True)
    parser.add_argument("--y", type=int, required=True)
    parser.add_argument("--w", type=int, required=True)
    parser.add_argument("--h", type=int, required=True)
    parser.add_argument("--monitor", type=int, default=1)
    parser.add_argument("--manifest", action="store_true", help="добавить/обновить запись в manifest.json")
    parser.add_argument("--hero", default=None, help="id героя для manifest (по умолчанию --name)")
    parser.add_argument("--threshold", type=float, default=0.8)
    args = parser.parse_args()

    try:
        import mss
        from PIL import Image
    except Exception as error:  # noqa: BLE001
        raise SystemExit(f"Нужны mss и pillow: pip install mss pillow ({error})")

    TEMPLATES_DIR.mkdir(parents=True, exist_ok=True)
    with mss.mss() as sct:
        monitors = sct.monitors
        if args.monitor >= len(monitors):
            raise SystemExit(f"Нет монитора {args.monitor}; доступно: {len(monitors) - 1}")
        monitor = monitors[args.monitor]
        region = {
            "left": monitor["left"] + args.x,
            "top": monitor["top"] + args.y,
            "width": args.w,
            "height": args.h,
        }
        shot = sct.grab(region)
        image = Image.frombytes("RGB", shot.size, shot.bgra, "raw", "BGRX")

    path = TEMPLATES_DIR / f"{args.name}.png"
    image.save(path)
    print(f"saved {path} ({image.size[0]}x{image.size[1]})")

    if args.manifest:
        manifest_path = TEMPLATES_DIR / "manifest.json"
        manifest = {"templates": []}
        if manifest_path.exists():
            try:
                manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            except Exception:
                pass
        manifest.setdefault("templates", [])
        manifest["templates"] = [
            entry for entry in manifest["templates"]
            if not (entry.get("hero") == (args.hero or args.name) and entry.get("file") == path.name)
        ]
        manifest["templates"].append({
            "hero": args.hero or args.name,
            "file": path.name,
            "threshold": args.threshold,
        })
        manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(f"updated {manifest_path}")


if __name__ == "__main__":
    main()
