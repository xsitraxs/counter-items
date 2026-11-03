# Deadlock Situational Build — прототип

Веб-прототип ситуационной сборки для **Deadlock**: выбираешь своего героя и
противников — получаешь список контр-предметов с объяснением, таймингом и
учётом уже купленных вещей.

Это отдельный подпроект внутри `counter-items`. Родительский репозиторий — это
Lua-скрипт контр-предметов для **Dota 2** (Umbrella). Для Deadlock нет
публичного live API и нет аналога Umbrella, поэтому здесь другая архитектура:
**веб-движок + ручной/скорборд-ввод + отдельный агент чтения экрана**.

> Важно: данные стартовые, собранные из community-источников и ручной разметки.
> Это не официальные данные Valve и не полная база текущего патча. Проверяйте
> актуальность имён, цен и эффектов.

## Быстрый старт

```sh
cd deadlock
python3 agent/serve.py
# откройте http://localhost:8765/
```

Сервер слушает `0.0.0.0:8765`, отдаёт `/web/` как интерфейс, `/data/` как базу
и `/state.json` как состояние от агента. Порт можно изменить: `PORT=9000 python3 agent/serve.py`.

Тесты движка и парсера:

```sh
cd deadlock
npm run test:all
# или: node --test tests/engine.test.js
# или: python3 -m unittest discover -s tests -p "test_agent.py"
```

Демо-агент без игры (пишет `agent/state.json`, его можно забрать на вкладке
«Захват экрана»):

```sh
cd deadlock
python3 agent/capture.py --mock
```

## Что уже работает

- **44 героя**, **121 предмет**, **13 типов угроз** в `data/`.
- Движок рекомендаций на чистых функциях: `web/engine.js`.
- Веб-интерфейс: свой герой, 6 противников, роль, время матча, купленные вещи.
- Таблица угроз с вкладом героев и полосами силы.
- Карточки рекомендаций: категория, тир, цена, score, причины, против кого.
- Альтернативы и список уже купленных предметов.
- Импорт скорборда: парсер находит героев по именам из текста Tab-скорборда
  (или из вывода OCR).
- Вкладка «Захват экрана»: забирает `state.json` от агента и применяет его.
- Агент-заготовка: `agent/capture.py` (OCR + template matching), `serve.py`,
  `capture_templates.py` для калибровки, `overlay.py` для always-on-top окна.
- 24 автотеста: 17 JS (угрозы, fit, cover, timing, анти-лечение, контроль,
  физическая броня, сопротивление духу, парсер, демо-состояние) + 7 Python
  (мок-состояния агента, парсер имён, ROI, запись state.json).

## Формула рекомендаций

```text
counterScore = Σ item.counters[threat] × norm(threat)
raw          = (item.base + counterScore) × fit × timing × opportunity × (1 - cover)
score        = round(100 × (1 - exp(-raw × 1.6)))
```

- `fit` — тип урона героя (weapon / spirit / mixed), роль, ближний/дальний бой,
  поддержка/керри.
- `timing` — тир предмета и время матча: T1–T2 раньше, T3–T4 позже.
- `opportunity` — слоты категории (4 на цвет + flex) и количество купленных вещей.
- `cover` — уже купленный предмет или тот же эффект (`families`), чтобы не
  советовать дубль.
- `norm(threat)` — сила угрозы относительно максимума по команде.

`base` — базовая полезность предмета для героя; `counters` — насколько он
контрит конкретную угрозу. Поэтому движок советует и «ситуативные» контр-пики,
и обычные базовые предметы, если угроз мало.

## Структура

```text
deadlock/
  data/
    build_data.py      # генератор JSON из компактных Python-таблиц
    heroes.json        # 44 героя
    items.json         # 121 предмет
    threats.json       # подписи угроз
  web/
    index.html         # интерфейс
    style.css
    app.js             # UI-логика
    engine.js          # чистый движок рекомендаций и парсер
  agent/
    serve.py           # локальный сервер + /state.json
    capture.py         # агент чтения экрана (OCR + template matching)
    capture_templates.py
    requirements.txt
    roi.example.json
    templates/README.md
  tests/
    engine.test.js
```

## Схема данных

Герой:

```json
{
  "id": "haze",
  "name": "Haze",
  "roles": ["assassin"],
  "damage": "weapon",
  "attack": "ranged",
  "threats": {"physical": 0.9, "stealth": 0.9, "burst": 0.8, "mobility": 0.6},
  "notes": "Невидимость и смертельный бурст; ищет одиночные цели.",
  "tags": []
}
```

Предмет:

```json
{
  "id": "debuff_remover",
  "name": "Debuff Remover",
  "category": "vitality",
  "tier": 2,
  "cost": 1600,
  "active": true,
  "families": ["cleanse"],
  "counters": {"control": 0.95, "debuff": 0.85, "silence": 0.4},
  "base": 0.12,
  "tags": ["cleanse", "active", "survive"],
  "summary": "Снимает контроль и дебаффы — ответ на хексы, сайленс и дизейблы."
}
```

Состояние для движка:

```json
{
  "myHero": "grey_talon",
  "enemyHeroes": ["haze", "kelvin", "lash", "vindicta", "lady_geist", "bebop"],
  "gameMinutes": 18,
  "role": "core",
  "myItems": ["extra_health", "improved_cooldown"],
  "enemyItems": []
}
```

## Чего пока нет

- **Полноценного чтения экрана.** Агент — заготовка: OCR скорборда и
  template matching верхней панели нужно откалибровать под разрешение и HUD.
- **Инвентаря врагов.** В базовом Deadlock он не виден целиком; `enemyItems` —
  слабый сигнал (только если предмет засветился в килл-фиде/наблюдении).
- **Способностей и талантов.** Профили героев пока заданы тегами угроз, а не
  полным набором способностей.
- **Нативного оверлея.** Сейчас UI — веб-страница; для игры поверх Deadlock
  понадобится отдельное always-on-top окно.
- **Статистики винрейтов и патчей.** Базу нужно обновлять под текущий патч.

## Ограничения и риски

- Нет официального live API для Deadlock; community-статика не заменяет
  состояние матча.
- Prime-источник — пиксели экрана. OCR/шаблоны ломаются от скинов, цветовых
  режимов, масштаба HUD и патчей.
- Эмуляция ввода (Tab, наведение) не используется. Если добавлять — это уже
  другой класс риска.
- Агент читает только экран: без чтения памяти, без DLL-инъекций, без отключения
  VAC. Но сторонняя автоматизация всё равно может нарушать ToS; Valve не
  публиковал официальную позицию по оверлеям. Решение о запуске — за вами.

## Как расширять

1. Добавьте героя/предмет в `data/build_data.py` и перегенерируйте JSON:
   `python3 data/build_data.py`.
2. Для новых контр-пиков добавьте `families` и `counters` в `items.json`.
3. Для новых угроз добавьте ключ в `THREAT_LABELS` и `THREAT_ORDER`.
4. Тесты: `npm run test:all`. Если меняется формула — обновите ожидания.
5. Откалибруйте ROI и шаблоны агента под свой экран.

## Источники

- [deadlock.io](https://deadlock.io/en) — статические JSON героев/предметов/способностей.
- [Deadlock API](https://deadlock-api.com/) — community REST API по матчам и статистике.
- [dramalock: какой API использовать](https://dramalock.org/guides/deadlock-api-guide-stats-data-endpoints/) — официального Valve API для Deadlock нет.
- [Metabot: категории предметов](https://metabot.gg/en/deadlock/guides/deadlock-items-shop-system-explained) — Weapon/Vitality/Spirit и flex-слоты.
- [Backgrind: anti-cheat/overlay](https://backgrind.com/overlay-anticheat-checker/deadlock/) — VAC user-mode, plain overlay не инжектит.
- [Reddit: моды со скорбордом](https://www.reddit.com/r/DeadlockTheGame/comments/1oe65yw/mod_roundup_advantageous_mods_for_a_competitive/) — базово инвентарь врагов не виден целиком.

Не связан с Valve. Deadlock — торговая марка Valve.
