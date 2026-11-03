# Агент чтения экрана Deadlock

Заготовка внешнего агента: захват экрана → поиск героев → публикация состояния
в `state.json`. Веб-интерфейс забирает состояние через `/state.json` и может
применить его одной кнопкой.

## Принципы

- **Только пиксели.** Агент не читает память игры, не инжектит DLL, не ставит
  хуки и не эмулирует ввод.
- **Никаких «читерских» функций.** Это прототип пассивного чтения HUD.
- **Прозрачность.** Агент пишет `source` и `confidence`, чтобы UI понимал,
  откуда пришло состояние.

## Установка

Нужен Python 3.10+.

```sh
cd deadlock
python3 -m pip install -r agent/requirements.txt
```

Для OCR также нужен бинарник **Tesseract**:

- Windows: установщик с GitHub (tesseract-ocr), при установке отметьте English.
- Linux: `sudo apt install tesseract-ocr`.
- macOS: `brew install tesseract`.

Проверка:

```sh
tesseract --version
```

## Always-on-top окно

```sh
python3 -m pip install pywebview
python3 agent/overlay.py --url http://127.0.0.1:8765/web/
```

Откроет веб-интерфейс в отдельном окне поверх игры (если установлен pywebview).
Без pywebview просто откроет URL в браузере.

## Режимы

### Mock без игры

```sh
cd deadlock
python3 agent/capture.py --mock
```

Агент циклически пишет три демо-состояния в `agent/state.json`. Никаких
зависимостей не нужно. В веб-интерфейсе откройте вкладку «Захват экрана» и
нажмите «Применить состояние агента».

### Один кадр

```sh
python3 agent/capture.py --once
```

Захватывает экран, OCR-ит скорборд, пробует template matching верхней панели,
пишет состояние. Без шаблонов и без открытого скорборда, скорее всего, ничего
не найдёт — это нормально.

### Непрерывный захват

```sh
python3 agent/capture.py --watch --interval 3
```

Параллельно запустите сервер:

```sh
python3 agent/serve.py
```

Агент можно отправлять POST-ом:

```sh
python3 agent/capture.py --watch --server http://127.0.0.1:8765
```

## Калибровка

1. Запустите Deadlock в **borderless fullscreen** (в exclusive fullscreen
   захват может не работать).
2. Снимите шаблоны героев с верхней панели:

   ```sh
   python3 agent/capture_templates.py --name haze --x 300 --y 20 --w 90 --h 90 --manifest --hero haze
   ```

   Координаты — относительно монитора. Размер иконки зависит от разрешения и
   масштаба HUD.
3. Скопируйте `roi.example.json` в `roi.json` и подгоните области:
   `scoreboard`, `topbar`, `hud`.
4. Запустите `--once` и проверьте `agent/state.json`.

Подробности — в `agent/templates/README.md`.

## Формат состояния

```json
{
  "myHero": "grey_talon",
  "enemyHeroes": ["haze", "kelvin", "lash", "vindicta", "lady_geist", "bebop"],
  "gameMinutes": 18,
  "role": "core",
  "myItems": ["extra_health"],
  "enemyItems": [],
  "confidence": 0.71,
  "source": "scoreboard_ocr",
  "updatedAt": "2026-11-03T12:00:00+00:00"
}
```

`confidence` — 0..1, `source` — `mock`, `scoreboard_ocr`, `topbar_templates`,
`hud_ocr` или `none`. `debug` может содержать OCR-текст для диагностики.

## Что нужно доделать

- **Надёжный OCR скорборда.** Сейчас берётся весь ROI; нужна предобработка
  (порог, бинаризация, масштаб) и разбиение на две команды.
- **Шаблоны верхней панели.** Нужно снять иконки всех героев и добавить
  `manifest.json`. Сейчас `detect_topbar` возвращает всех найденных без
  разделения на союзников/врагов.
- **HUD.** OCR имени героя, времени и предметов; template matching иконок
  предметов.
- **Слияние источников.** Скорборд надёжнее, но требует открытого Tab;
  верхняя панель всегда видна, но не даёт команд. Нужен приоритет и confidence.
- **Стабильность.** Патчи Valve меняют HUD; нужна система обновления шаблонов.
- **Оверлей.** Веб-страница — не всегда удобный оверлей; для игры поверх
  Deadlock понадобится отдельное always-on-top окно (C#/Rust/Tauri).

## Ограничения

- OCR и template matching не работают вслепую: нужна калибровка под ваш экран.
- В базовом Deadlock инвентарь врагов не виден целиком; не выдумывайте его.
- Агент не читает память и не эмулирует ввод. Если добавлять эмуляцию Tab —
  это уже другой риск.
- Сторонняя автоматизация может нарушать ToS. Valve не публиковал официальную
  позицию по оверлеям. Запуск — на ваш риск.
