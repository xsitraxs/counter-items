// Движок ситуационных рекомендаций Deadlock.
// Чистые функции без DOM: состояние -> угрозы -> ранжированные предметы.
// Формула: (base + Σ counters × norm(threat)) × fit × timing × opportunity × (1 - cover).

export const CATEGORY_LABELS = {
  weapon: "Оружие",
  vitality: "Живучесть",
  spirit: "Дух",
};

export const ROLE_LABELS = {
  auto: "Авто",
  core: "Кор",
  support: "Поддержка",
};

export const DAMAGE_LABELS = {
  weapon: "gun / физический",
  spirit: "spirit / способности",
  mixed: "гибридный",
};

const DEFAULT_MINUTES = 18;
const MAX_ENEMIES = 6;

// Наблюдаемые предметы врага — слабый сигнал. Не путаем «предмет контрит X»
// (это для наших рекомендаций) и «предмет врага создаёт угрозу X».
const ENEMY_ITEM_THREATS = {
  resist_physical: { tank: 0.55 },
  resist_spirit: { tank: 0.55 },
  health: { tank: 0.3 },
  silence: { silence: 0.5 },
  dot: { dot: 0.45 },
  mobility: { mobility: 0.4 },
  control: { control: 0.3 },
};

const clamp = (v, lo, hi) => Math.max(lo, Math.min(hi, v));

function heroById(data, id) {
  return data.heroes.find((h) => h.id === id) || null;
}

function itemById(data, id) {
  return data.items.find((i) => i.id === id) || null;
}

export function normalizeState(raw, data) {
  const state = raw && typeof raw === "object" ? raw : {};
  const myHero = heroById(data, state.myHero);
  if (!myHero) {
    throw new Error("Не выбран мой герой (myHero)");
  }

  const seen = new Set();
  const enemyHeroes = [];
  for (const id of Array.isArray(state.enemyHeroes) ? state.enemyHeroes : []) {
    const hero = heroById(data, id);
    if (!hero || seen.has(hero.id) || enemyHeroes.length >= MAX_ENEMIES) continue;
    seen.add(hero.id);
    enemyHeroes.push(hero.id);
  }

  const itemIds = new Set(data.items.map((i) => i.id));
  const cleanItems = (ids) => {
    const out = [];
    const local = new Set();
    for (const id of Array.isArray(ids) ? ids : []) {
      if (!itemIds.has(id) || local.has(id)) continue;
      local.add(id);
      out.push(id);
    }
    return out;
  };

  const minutes = Number(state.gameMinutes);
  const role = ["auto", "core", "support"].includes(state.role) ? state.role : "auto";
  const inferredRole = role === "auto"
    ? (myHero.roles.includes("support") ? "support" : "core")
    : role;

  return {
    myHero: myHero.id,
    enemyHeroes,
    gameMinutes: Number.isFinite(minutes) ? clamp(Math.round(minutes), 0, 90) : DEFAULT_MINUTES,
    role,
    effectiveRole: inferredRole,
    myItems: cleanItems(state.myItems),
    enemyItems: cleanItems(state.enemyItems),
  };
}

export function aggregateThreats(state, data) {
  const totals = {};
  const byHero = [];
  const byItem = [];

  for (const id of state.enemyHeroes) {
    const hero = heroById(data, id);
    if (!hero) continue;
    for (const [threat, weight] of Object.entries(hero.threats)) {
      totals[threat] = (totals[threat] || 0) + weight;
    }
    byHero.push({ id: hero.id, name: hero.name, threats: hero.threats });
  }

  for (const id of state.enemyItems) {
    const item = itemById(data, id);
    if (!item) continue;
    const mapped = {};
    for (const family of item.families) {
      const add = ENEMY_ITEM_THREATS[family];
      if (!add) continue;
      for (const [threat, weight] of Object.entries(add)) {
        mapped[threat] = (mapped[threat] || 0) + weight;
        totals[threat] = (totals[threat] || 0) + weight;
      }
    }
    byItem.push({ id: item.id, name: item.name, families: item.families, threats: mapped });
  }

  const max = Math.max(1, ...Object.values(totals));
  const norm = {};
  for (const threat of data.threatOrder) {
    norm[threat] = (totals[threat] || 0) / max;
  }

  return {
    totals,
    norm,
    max,
    byHero,
    byItem,
    labels: data.threats,
    order: data.threatOrder,
  };
}

function heroFit(item, hero, state) {
  const base = {
    weapon: { weapon: 1.0, vitality: 0.78, spirit: 0.55 },
    spirit: { spirit: 1.0, vitality: 0.78, weapon: 0.55 },
    mixed: { weapon: 0.85, vitality: 0.85, spirit: 0.85 },
  }[hero.damage] || { weapon: 0.8, vitality: 0.8, spirit: 0.8 };

  let fit = base[item.category] ?? 0.7;
  const tags = new Set(item.tags);
  const role = state.effectiveRole;

  if (role === "support") {
    if (tags.has("support") || tags.has("heal") || tags.has("cleanse") || tags.has("sustain") || tags.has("vision")) fit += 0.12;
    if (tags.has("damage") || tags.has("burst") || tags.has("crit")) fit -= 0.06;
  } else {
    if (tags.has("damage") || tags.has("burst") || tags.has("crit") || tags.has("weapon") || tags.has("spirit")) fit += 0.1;
    if (tags.has("support") || tags.has("economy")) fit -= 0.06;
  }

  if (hero.attack === "melee") {
    if (tags.has("survive") || tags.has("barrier") || tags.has("resist_physical") || tags.has("resist_spirit") || tags.has("health") || tags.has("sustain") || tags.has("mobility")) fit += 0.08;
    if (tags.has("range")) fit -= 0.08;
  } else {
    if (tags.has("range") || tags.has("escape") || tags.has("mobility")) fit += 0.06;
    if (tags.has("close_range") || tags.has("melee")) fit -= 0.08;
  }

  if (hero.roles.includes("support") && (tags.has("support") || tags.has("cleanse") || tags.has("sustain"))) fit += 0.05;

  return clamp(fit, 0.25, 1.25);
}

function itemCover(item, myItems, data) {
  if (myItems.includes(item.id)) return 1;
  const owned = myItems.map((id) => itemById(data, id)).filter(Boolean);
  let cover = 0;
  for (const family of item.families) {
    if (owned.some((other) => other.families.includes(family))) cover = Math.max(cover, 0.7);
  }
  if (owned.some((other) => other.category === item.category && other.tier === item.tier)) {
    cover = Math.max(cover, 0.15);
  }
  return cover;
}

function timingFactor(item, minutes) {
  const tier = item.tier;
  if (minutes < 8) return [1.1, 1.0, 0.65, 0.35][tier - 1] ?? 1;
  if (minutes < 18) return [0.9, 1.1, 1.0, 0.55][tier - 1] ?? 1;
  if (minutes < 30) return [0.7, 0.95, 1.1, 0.9][tier - 1] ?? 1;
  return [0.5, 0.8, 0.95, 1.1][tier - 1] ?? 1;
}

function opportunityFactor(item, myItems, data) {
  const owned = myItems.map((id) => itemById(data, id)).filter(Boolean);
  const sameCategory = owned.filter((other) => other.category === item.category).length;
  let factor = 1;
  if (sameCategory >= 4) factor *= 0.55;
  else if (sameCategory === 3) factor *= 0.8;
  if (owned.length >= 8) factor *= 0.9;
  return factor;
}

function decorate(scored, hero, enemies, threats, state) {
  const { item } = scored;
  const reasons = [];
  const against = new Set();

  const counterEntries = Object.entries(item.counters)
    .map(([threat, effectiveness]) => ({
      threat,
      effectiveness,
      contribution: effectiveness * (threats.norm[threat] || 0),
    }))
    .filter((entry) => entry.contribution > 0.12)
    .sort((a, b) => b.contribution - a.contribution);

  for (const entry of counterEntries.slice(0, 3)) {
    const label = threats.labels[entry.threat] || entry.threat;
    const names = enemies
      .filter((enemy) => (enemy.threats[entry.threat] || 0) > 0.25)
      .map((enemy) => enemy.name);
    if (names.length) {
      names.forEach((name) => against.add(name));
      reasons.push({
        kind: "threat",
        text: `Против ${names.slice(0, 3).join(", ")}: ${label.toLowerCase()}`,
      });
    } else {
      reasons.push({ kind: "threat", text: `${label} по наблюдаемым предметам` });
    }
  }

  const damageLabel = DAMAGE_LABELS[hero.damage] || hero.damage;
  reasons.push({
    kind: "fit",
    text: `Подходит ${hero.name}: ${CATEGORY_LABELS[item.category].toLowerCase()} для ${damageLabel} героя`,
  });

  if (scored.timing >= 1.05) {
    reasons.push({
      kind: "timing",
      text: `T${item.tier} на ${state.gameMinutes} мин — своевременно`,
    });
  }

  const tags = new Set(item.tags);
  if (state.effectiveRole === "support" && (tags.has("support") || tags.has("heal") || tags.has("cleanse") || tags.has("sustain"))) {
    reasons.push({ kind: "role", text: "Полезно поддержке" });
  } else if (state.effectiveRole === "core" && (tags.has("damage") || tags.has("burst") || tags.has("crit") || tags.has("weapon") || tags.has("spirit"))) {
    reasons.push({ kind: "role", text: "Усиливает керри" });
  }

  return {
    id: item.id,
    name: item.name,
    category: item.category,
    tier: item.tier,
    cost: item.cost,
    active: item.active,
    summary: item.summary,
    score: scored.score,
    reasons: reasons.slice(0, 4),
    against: [...against].slice(0, 4),
    tags: item.tags,
    families: item.families,
  };
}

export function recommend(rawState, data, options = {}) {
  const state = normalizeState(rawState, data);
  const hero = heroById(data, state.myHero);
  if (!hero) throw new Error("Не выбран мой герой (myHero)");

  const threats = aggregateThreats(state, data);
  const limit = clamp(Number(options.limit) || 6, 1, 20);

  const scored = data.items
    .map((item) => {
      const fit = heroFit(item, hero, state);
      const cover = itemCover(item, state.myItems, data);
      const timing = timingFactor(item, state.gameMinutes);
      const opportunity = opportunityFactor(item, state.myItems, data);
      const counterScore = Object.entries(item.counters).reduce(
        (sum, [threat, effectiveness]) => sum + effectiveness * (threats.norm[threat] || 0),
        0,
      );
      const raw = (item.base + counterScore) * fit * timing * opportunity * (1 - cover);
      const score = Math.round(100 * (1 - Math.exp(-raw * 1.6)));
      return { item, fit, cover, timing, opportunity, counterScore, raw, score };
    })
    .filter((entry) => entry.score > 0 && entry.cover < 1);

  scored.sort((a, b) => b.score - a.score || a.item.name.localeCompare(b.item.name));

  const enemies = state.enemyHeroes
    .map((id) => heroById(data, id))
    .filter(Boolean);

  const recommendations = scored.slice(0, limit).map((entry) => decorate(entry, hero, enemies, threats, state));
  const alternatives = scored.slice(limit, limit + 3).map((entry) => decorate(entry, hero, enemies, threats, state));

  return {
    state,
    hero,
    enemies,
    threats,
    recommendations,
    alternatives,
    myItems: state.myItems.map((id) => itemById(data, id)).filter(Boolean),
  };
}

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

export function parseScoreboard(text, data) {
  if (typeof text !== "string" || !text.trim()) return [];
  const found = [];
  for (const hero of data.heroes) {
    const pattern = new RegExp(`\\b${escapeRegExp(hero.name)}\\b`, "i");
    const match = pattern.exec(text);
    if (match) found.push({ hero, index: match.index });
  }
  found.sort((a, b) => a.index - b.index);
  const seen = new Set();
  const heroes = [];
  for (const entry of found) {
    if (seen.has(entry.hero.id)) continue;
    seen.add(entry.hero.id);
    heroes.push(entry.hero);
  }
  return heroes;
}

export function demoState(data) {
  const heroIds = new Set(data.heroes.map((h) => h.id));
  const enemyHeroes = ["haze", "kelvin", "lash", "vindicta", "lady_geist", "bebop"].filter((id) => heroIds.has(id));
  return {
    myHero: heroIds.has("grey_talon") ? "grey_talon" : data.heroes[0].id,
    enemyHeroes,
    gameMinutes: 18,
    role: "core",
    myItems: ["extra_health", "improved_cooldown"].filter((id) => data.items.some((i) => i.id === id)),
    enemyItems: [],
  };
}

export function threatSummary(result) {
  const labels = result.threats.labels;
  return result.threats.order
    .map((threat) => ({
      threat,
      label: labels[threat] || threat,
      value: result.threats.norm[threat] || 0,
      total: result.threats.totals[threat] || 0,
      heroes: result.threats.byHero.filter((h) => (h.threats[threat] || 0) > 0).map((h) => h.name),
    }))
    .filter((entry) => entry.total > 0)
    .sort((a, b) => b.value - a.value);
}
