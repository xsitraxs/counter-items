import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import {
  normalizeState,
  aggregateThreats,
  recommend,
  parseScoreboard,
  demoState,
  threatSummary,
} from "../web/engine.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const dataDir = path.join(here, "..", "data");
const heroes = JSON.parse(fs.readFileSync(path.join(dataDir, "heroes.json"), "utf8"));
const items = JSON.parse(fs.readFileSync(path.join(dataDir, "items.json"), "utf8"));
const threats = JSON.parse(fs.readFileSync(path.join(dataDir, "threats.json"), "utf8"));

const data = {
  version: heroes.version,
  heroes: heroes.heroes,
  items: items.items,
  threats: threats.threats,
  threatOrder: threats.order,
};

const baseState = {
  myHero: "grey_talon",
  enemyHeroes: ["haze", "kelvin", "lash", "vindicta", "lady_geist", "bebop"],
  gameMinutes: 18,
  role: "core",
  myItems: [],
  enemyItems: [],
};

const ids = (result) => result.recommendations.map((entry) => entry.id);
const hasFamily = (result, family) =>
  result.recommendations.some((entry) => entry.families.includes(family));

test("normalizeState: подставляет значения по умолчанию и отбрасывает мусор", () => {
  const state = normalizeState(
    {
      myHero: "abrams",
      enemyHeroes: ["haze", "haze", "nope", "kelvin"],
      gameMinutes: 999,
      role: "wrong",
      myItems: ["extra_health", "extra_health", "nope"],
    },
    data,
  );
  assert.equal(state.myHero, "abrams");
  assert.deepEqual(state.enemyHeroes, ["haze", "kelvin"]);
  assert.equal(state.gameMinutes, 90);
  assert.equal(state.role, "auto");
  assert.equal(state.effectiveRole, "core");
  assert.deepEqual(state.myItems, ["extra_health"]);
});

test("normalizeState: роль support выводится из героя", () => {
  const state = normalizeState({ myHero: "kelvin", enemyHeroes: [], role: "auto" }, data);
  assert.equal(state.effectiveRole, "support");
});

test("aggregateThreats: суммирует угрозы и нормализует по максимуму", () => {
  const state = normalizeState({ myHero: "abrams", enemyHeroes: ["haze", "kelvin"] }, data);
  const threatsResult = aggregateThreats(state, data);
  assert.ok(threatsResult.totals.physical >= 0.9);
  assert.ok(threatsResult.totals.spirit >= 0.7);
  assert.ok(Math.abs(threatsResult.norm.physical - threatsResult.totals.physical / Math.max(1, threatsResult.max)) < 1e-9);
  assert.ok(threatsResult.byHero.length === 2);
});

test("recommend: возвращает отсортированный список валидных предметов", () => {
  const result = recommend(baseState, data);
  assert.equal(result.recommendations.length, 6);
  assert.equal(result.hero.id, "grey_talon");
  assert.equal(result.enemies.length, 6);
  const scores = result.recommendations.map((entry) => entry.score);
  for (let i = 1; i < scores.length; i += 1) {
    assert.ok(scores[i - 1] >= scores[i], "оценки должны идти по убыванию");
  }
  for (const entry of result.recommendations) {
    assert.ok(entry.name && entry.category && entry.summary);
    assert.ok(entry.reasons.length > 0);
    assert.ok(entry.score > 0 && entry.score <= 100);
  }
});

test("recommend: анти-лечение против sustain-команды", () => {
  const sustainTeam = {
    ...baseState,
    myHero: "grey_talon",
    enemyHeroes: ["lady_geist", "rem", "nurse_harrow", "mo_krill", "kelvin", "ivy"],
    myItems: [],
  };
  const result = recommend(sustainTeam, data);
  assert.ok(hasFamily(result, "antiheal"), `ожидали анти-лечение, получили ${ids(result).join(", ")}`);
});

test("recommend: cleanse / иммунитет к контролю против control-команды", () => {
  const controlTeam = {
    ...baseState,
    myHero: "abrams",
    enemyHeroes: ["lash", "bebop", "kelvin", "baba", "viscous", "doorman"],
    myItems: [],
  };
  const result = recommend(controlTeam, data);
  assert.ok(
    hasFamily(result, "cleanse") || hasFamily(result, "cc_immune") || hasFamily(result, "spell_immune"),
    `ожидали cleanse/CC-иммунитет, получили ${ids(result).join(", ")}`,
  );
});

test("recommend: физическая броня против gun-команды", () => {
  const gunTeam = {
    ...baseState,
    myHero: "kelvin",
    enemyHeroes: ["haze", "vindicta", "venator", "wraith", "holliday", "deadman"],
    myItems: [],
  };
  const result = recommend(gunTeam, data);
  assert.ok(hasFamily(result, "resist_physical"), `ожидали физическую броню, получили ${ids(result).join(", ")}`);
});

test("recommend: сопротивление духу против spirit-команды", () => {
  const spiritTeam = {
    ...baseState,
    myHero: "abrams",
    enemyHeroes: ["celeste", "graves", "grey_talon", "seven", "lady_geist", "mina"],
    myItems: [],
  };
  const result = recommend(spiritTeam, data);
  assert.ok(hasFamily(result, "resist_spirit"), `ожидали сопротивление духу, получили ${ids(result).join(", ")}`);
});

test("recommend: fit героя — без угроз weapon-герой получает weapon/vitality", () => {
  const state = { myHero: "abrams", enemyHeroes: [], gameMinutes: 20, role: "core", myItems: [] };
  const result = recommend(state, data);
  const top = result.recommendations[0];
  assert.ok(["weapon", "vitality"].includes(top.category), `top: ${top.name} (${top.category})`);
});

test("recommend: fit героя — без угроз spirit-герой получает spirit/vitality", () => {
  const state = { myHero: "grey_talon", enemyHeroes: [], gameMinutes: 20, role: "core", myItems: [] };
  const result = recommend(state, data);
  const top = result.recommendations[0];
  assert.ok(["spirit", "vitality"].includes(top.category), `top: ${top.name} (${top.category})`);
});

test("recommend: купленный предмет не рекомендуется повторно", () => {
  const state = {
    ...baseState,
    myHero: "abrams",
    enemyHeroes: ["lash", "bebop", "kelvin"],
    myItems: ["debuff_remover"],
  };
  const result = recommend(state, data);
  assert.ok(!ids(result).includes("debuff_remover"), "купленный Debuff Remover не должен попадать в список");
});

test("recommend: тайминг — T4 не лезет в топ на 5-й минуте без угроз", () => {
  const state = { myHero: "grey_talon", enemyHeroes: [], gameMinutes: 5, role: "core", myItems: [] };
  const result = recommend(state, data);
  assert.ok(result.recommendations.every((entry) => entry.tier <= 2), `T4 на 5 мин: ${ids(result).join(", ")}`);
});

test("recommend: demoState валиден и даёт рекомендации", () => {
  const state = demoState(data);
  const normalized = normalizeState(state, data);
  assert.equal(normalized.enemyHeroes.length, 6);
  const result = recommend(state, data);
  assert.ok(result.recommendations.length > 0);
  assert.ok(result.recommendations[0].score > 0);
});

test("parseScoreboard: находит героев по порядку и не дублирует", () => {
  const text = `
    Team A
    Haze       5   12,345   3/2/1
    Kelvin     4    9,100   1/4/8
    Lady Geist 6   15,000   5/1/2
    Team B
    Grey Talon 5   11,000   2/3/4
    Mo & Krill 4    8,000   0/5/6
    The Doorman 3   6,000   1/2/9
  `;
  const found = parseScoreboard(text, data);
  assert.deepEqual(found.map((hero) => hero.id), ["haze", "kelvin", "lady_geist", "grey_talon", "mo_krill", "doorman"]);
});

test("parseScoreboard: не путает Rem с Remove и учитывает границы слов", () => {
  const found = parseScoreboard("Remove the barrier, then use Rem.", data);
  assert.deepEqual(found.map((hero) => hero.id), ["rem"]);
});

test("parseScoreboard: пустой текст -> пустой список", () => {
  assert.deepEqual(parseScoreboard("", data), []);
  assert.deepEqual(parseScoreboard("no heroes here", data), []);
});

test("threatSummary: сортирует по силе и подписывает героев", () => {
  const result = recommend(baseState, data);
  const summary = threatSummary(result);
  assert.ok(summary.length > 0);
  for (let i = 1; i < summary.length; i += 1) {
    assert.ok(summary[i - 1].value >= summary[i].value);
  }
  const physical = summary.find((entry) => entry.threat === "physical");
  assert.ok(physical);
  assert.ok(physical.heroes.includes("Haze"));
  assert.ok(physical.label.length > 0);
});
