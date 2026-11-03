#!/usr/bin/env python3
"""Агент чтения экрана Deadlock (прототип, Windows-first).

Что делает:
  1. Захватывает экран (mss -> PIL.ImageGrab fallback).
  2. Ищет героев: OCR Tab-скорборда и/или template matching верхней панели.
  3. Публикует состояние в agent/state.json (его отдаёт serve.py по /state.json).
  4. Опционально отправляет состояние POST-ом в --server.

Чего НЕ делает: не читает память игры, не инжектит DLL, не эмулирует ввод.
Только пиксели экрана. Это осознанное ограничение прототипа.

Режимы:
  python3 agent/capture.py --mock          # демо-состояния без игры, для проверки UI
  python3 agent/capture.py --once          # один кадр + OCR/шаблоны
  python3 agent/capture.py --watch         # цикл захвата
  python3 agent/capture.py --watch --server http://127.0.0.1:8765

Зависимости для live-режима: mss, pillow, numpy, opencv-python, pytesseract
+ бинарник Tesseract OCR. Для --mock зависимостей нет.
"""

from __future__ import annotations

import argparse
import json
import re
import time
from datetime import datetime, timezone
from pathlib import Path

AGENT_DIR = Path(__file__).resolve().parent
ROOT = AGENT_DIR.parent
DATA_DIR = ROOT / "data"
TEMPLATES_DIR = AGENT_DIR / "templates"
ROI_PATH = AGENT_DIR / "roi.json"
STATE_PATH = AGENT_DIR / "state.json"

DEFAULT_ROI = {
    # Нормализованные координаты (0..1) от левого верхнего угла экрана.
    # Откалибруйте под своё разрешение и масштаб HUD.
    "scoreboard": [0.18, 0.12, 0.64, 0.62],
    "topbar": [0.18, 0.0, 0.64, 0.08],
    "hud": [0.0, 0.86, 1.0, 0.14],
}


def load_json(path: Path):
    return json.loads(path.read_text(encoding="utf-8"))


def load_heroes():
    payload = load_json(DATA_DIR / "heroes.json")
    return payload["heroes"]


def load_roi():
    if ROI_PATH.exists():
        try:
            return {**DEFAULT_ROI, **load_json(ROI_PATH)}
        except Exception:
            pass
    return DEFAULT_ROI


def now_iso():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def write_state(state: dict, server: str | None = None):
    STATE_PATH.write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    if server:
        try:
            import urllib.request

            request = urllib.request.Request(
                server.rstrip("/") + "/state",
                data=json.dumps(state, ensure_ascii=False).encode("utf-8"),
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with urllib.request.urlopen(request, timeout=5) as response:
                if response.status >= 400:
                    raise RuntimeError(f"HTTP {response.status}")
        except Exception as error:  # noqa: BLE001 - агент не должен падать из-за сети
            print(f"[agent] POST {server} failed: {error}")


def capture_screen():
    """Возвращает PIL.Image RGB или None, если захват недоступен."""
    try:
        import mss
        from PIL import Image

        with mss.mss() as sct:
            monitor = sct.monitors[1] if len(sct.monitors) > 1 else sct.monitors[0]
            shot = sct.grab(monitor)
            return Image.frombytes("RGB", shot.size, shot.bgra, "raw", "BGRX")
    except Exception as first_error:  # noqa: BLE001
        try:
            from PIL import ImageGrab

            return ImageGrab.grab()
        except Exception as second_error:  # noqa: BLE001
            print(f"[agent] capture unavailable: {first_error} / {second_error}")
            return None


def crop_normalized(image, roi):
    width, height = image.size
    x, y, w, h = roi
    box = (
        max(0, int(x * width)),
        max(0, int(y * height)),
        min(width, int((x + w) * width)),
        min(height, int((y + h) * height)),
    )
    if box[2] <= box[0] or box[3] <= box[1]:
        return image
    return image.crop(box)


def ocr_image(image):
    try:
        import pytesseract

        return pytesseract.image_to_string(image)
    except Exception as error:  # noqa: BLE001
        print(f"[agent] OCR unavailable: {error}")
        return ""


def detect_heroes_from_text(text: str, heroes):
    found = []
    for hero in heroes:
        pattern = r"\b" + re.escape(hero["name"]) + r"\b"
        if re.search(pattern, text, flags=re.IGNORECASE):
            found.append(hero["id"])
    return found


def detect_scoreboard(image, heroes, roi):
    """OCR Tab-скорборда. Возвращает (ids, text, confidence)."""
    crop = crop_normalized(image, roi["scoreboard"])
    text = ocr_image(crop)
    ids = detect_heroes_from_text(text, heroes)
    confidence = 0.0
    if ids:
        confidence = min(0.95, 0.55 + 0.08 * len(ids))
    return ids, text, confidence


def detect_topbar(image, heroes, roi):
    """Template matching верхней панели. Без шаблонов возвращает пустой список."""
    if not TEMPLATES_DIR.exists():
        return [], 0.0
    manifest_path = TEMPLATES_DIR / "manifest.json"
    if not manifest_path.exists():
        return [], 0.0
    try:
        import cv2
        import numpy as np
        from PIL import Image

        manifest = load_json(manifest_path)
        crop = crop_normalized(image, roi["topbar"])
        frame = cv2.cvtColor(np.array(crop), cv2.COLOR_RGB2BGR)
        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        found = []
        scores = []
        for template in manifest.get("templates", []):
            path = TEMPLATES_DIR / template["file"]
            if not path.exists():
                continue
            template_image = cv2.imread(str(path), cv2.IMREAD_GRAYSCALE)
            if template_image is None:
                continue
            result = cv2.matchTemplate(gray, template_image, cv2.TM_CCOEFF_NORMED)
            _, score, _, _ = cv2.minMaxLoc(result)
            threshold = float(template.get("threshold", 0.8))
            if score >= threshold:
                found.append(template["hero"])
                scores.append(score)
        confidence = max(scores) if scores else 0.0
        return list(dict.fromkeys(found)), confidence
    except Exception as error:  # noqa: BLE001
        print(f"[agent] template matching unavailable: {error}")
        return [], 0.0


def detect_hud(image, heroes, roi):
    """OCR нижнего HUD: пытается найти имя моего героя. Возвращает (hero_id, text)."""
    crop = crop_normalized(image, roi["hud"])
    text = ocr_image(crop)
    ids = detect_heroes_from_text(text, heroes)
    return (ids[0] if ids else None), text


def mock_scenarios(heroes):
    valid = {hero["id"] for hero in heroes}
    scenarios = [
        {
            "myHero": "grey_talon",
            "enemyHeroes": ["haze", "kelvin", "lash", "vindicta", "lady_geist", "bebop"],
            "gameMinutes": 18,
            "role": "core",
            "myItems": ["extra_health", "improved_cooldown"],
            "enemyItems": [],
        },
        {
            "myHero": "abrams",
            "enemyHeroes": ["celeste", "graves", "grey_talon", "seven", "lady_geist", "mina"],
            "gameMinutes": 25,
            "role": "core",
            "myItems": ["extra_health", "spirit_armor", "fortitude"],
            "enemyItems": ["spirit_armor"],
        },
        {
            "myHero": "kelvin",
            "enemyHeroes": ["lash", "bebop", "dynamo", "baba", "viscous", "doorman"],
            "gameMinutes": 12,
            "role": "support",
            "myItems": ["debuff_remover", "spirit_shielding"],
            "enemyItems": ["debuff_remover"],
        },
    ]
    return [
        {
            **scenario,
            "enemyHeroes": [hero for hero in scenario["enemyHeroes"] if hero in valid],
            "confidence": 0.0,
            "source": "mock",
            "updatedAt": now_iso(),
        }
        for scenario in scenarios
    ]


def run_mock(interval: float, server: str | None, once: bool):
    heroes = load_heroes()
    scenarios = mock_scenarios(heroes)
    index = 0
    while True:
        scenario = dict(scenarios[index % len(scenarios)])
        scenario["updatedAt"] = now_iso()
        write_state(scenario, server)
        print(
            f"[agent] mock #{index + 1}: {scenario['myHero']} vs "
            f"{', '.join(scenario['enemyHeroes'])} | {scenario['gameMinutes']} min"
        )
        index += 1
        if once:
            return
        time.sleep(interval)


def run_live(interval: float, server: str | None, once: bool):
    heroes = load_heroes()
    roi = load_roi()
    last_state = None
    while True:
        image = capture_screen()
        if image is None:
            print("[agent] no screen; is the game running in borderless/windowed mode?")
            if once:
                return
            time.sleep(interval)
            continue

        scoreboard_ids, scoreboard_text, scoreboard_confidence = detect_scoreboard(image, heroes, roi)
        topbar_ids, topbar_confidence = detect_topbar(image, heroes, roi)
        hud_hero, hud_text = detect_hud(image, heroes, roi)

        detected = scoreboard_ids or topbar_ids
        confidence = max(scoreboard_confidence, topbar_confidence)
        source = "scoreboard_ocr" if scoreboard_ids else ("topbar_templates" if topbar_ids else "none")

        if not detected:
            print(f"[agent] no heroes detected (scoreboard={len(scoreboard_ids)}, topbar={len(topbar_ids)})")
            if once:
                return
            time.sleep(interval)
            continue

        state = {
            "myHero": hud_hero or (last_state or {}).get("myHero"),
            "enemyHeroes": detected[:6],
            "gameMinutes": (last_state or {}).get("gameMinutes", 0),
            "role": (last_state or {}).get("role", "auto"),
            "myItems": (last_state or {}).get("myItems", []),
            "enemyItems": (last_state or {}).get("enemyItems", []),
            "confidence": round(confidence, 2),
            "source": source,
            "updatedAt": now_iso(),
            "debug": {
                "scoreboardText": scoreboard_text[:500],
                "hudText": hud_text[:200],
            },
        }
        if not state.get("myHero"):
            print("[agent] my hero not detected; keeping previous value")
            if once:
                return
            time.sleep(interval)
            continue
        last_state = state
        write_state(state, server)
        print(f"[agent] {source}: my={state['myHero']} enemies={', '.join(state['enemyHeroes'])}")
        if once:
            return
        time.sleep(interval)


def main():
    parser = argparse.ArgumentParser(description="Deadlock screen-reading agent prototype")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--mock", action="store_true", help="демо-состояния без игры")
    mode.add_argument("--once", action="store_true", help="один кадр и выход")
    mode.add_argument("--watch", action="store_true", help="непрерывный захват")
    parser.add_argument("--interval", type=float, default=3.0, help="интервал между кадрами, сек")
    parser.add_argument("--server", default=None, help="например http://127.0.0.1:8765")
    args = parser.parse_args()

    if args.mock:
        run_mock(args.interval, args.server, once=False)
    elif args.once:
        run_live(args.interval, args.server, once=True)
    elif args.watch:
        run_live(args.interval, args.server, once=False)
    else:
        # По умолчанию — mock, чтобы прототип можно было проверить без игры.
        run_mock(args.interval, args.server, once=False)


if __name__ == "__main__":
    main()
