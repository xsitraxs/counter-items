#!/usr/bin/env python3
"""Тесты агента: мок-состояния, парсер имён, запись state.json."""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

AGENT_DIR = Path(__file__).resolve().parent.parent / "agent"
sys.path.insert(0, str(AGENT_DIR))

import capture  # noqa: E402


class MockScenariosTest(unittest.TestCase):
    def setUp(self):
        self.heroes = capture.load_heroes()
        self.valid = {hero["id"] for hero in self.heroes}

    def test_three_scenarios(self):
        scenarios = capture.mock_scenarios(self.heroes)
        self.assertEqual(len(scenarios), 3)
        for scenario in scenarios:
            self.assertIn(scenario["myHero"], self.valid)
            self.assertLessEqual(len(scenario["enemyHeroes"]), 6)
            for hero_id in scenario["enemyHeroes"]:
                self.assertIn(hero_id, self.valid)
            self.assertEqual(scenario["source"], "mock")
            self.assertIn("updatedAt", scenario)

    def test_no_duplicate_enemies(self):
        for scenario in capture.mock_scenarios(self.heroes):
            self.assertEqual(len(scenario["enemyHeroes"]), len(set(scenario["enemyHeroes"])))


class DetectTextTest(unittest.TestCase):
    def setUp(self):
        self.heroes = capture.load_heroes()

    def test_finds_known_heroes(self):
        text = "Haze 5 12,345\nLady Geist 6 15,000\nMo & Krill 4 8,000"
        ids = capture.detect_heroes_from_text(text, self.heroes)
        self.assertIn("haze", ids)
        self.assertIn("lady_geist", ids)
        self.assertIn("mo_krill", ids)

    def test_word_boundary_rem(self):
        ids = capture.detect_heroes_from_text("Remove the barrier, then use Rem.", self.heroes)
        self.assertIn("rem", ids)
        self.assertNotIn("rem", capture.detect_heroes_from_text("Remove the barrier.", self.heroes))

    def test_empty(self):
        self.assertEqual(capture.detect_heroes_from_text("", self.heroes), [])


class RoiTest(unittest.TestCase):
    def test_default_keys(self):
        roi = capture.load_roi()
        for key in ("scoreboard", "topbar", "hud"):
            self.assertIn(key, roi)
            self.assertEqual(len(roi[key]), 4)



class WriteStateTests(unittest.TestCase):
    def test_writes_json(self):
        original = capture.STATE_PATH
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "state.json"
            capture.STATE_PATH = path
            try:
                capture.write_state({"myHero": "haze", "enemyHeroes": ["kelvin"], "source": "test"})
            finally:
                capture.STATE_PATH = original
            payload = json.loads(path.read_text(encoding="utf-8"))
            self.assertEqual(payload["myHero"], "haze")
            self.assertEqual(payload["enemyHeroes"], ["kelvin"])
            self.assertEqual(payload["source"], "test")


if __name__ == "__main__":
    unittest.main()
