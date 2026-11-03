import {
  recommend,
  parseScoreboard,
  demoState,
  threatSummary,
  CATEGORY_LABELS,
  ROLE_LABELS,
  DAMAGE_LABELS,
} from "./engine.js";

const $ = (selector, root = document) => root.querySelector(selector);
const $$ = (selector, root = document) => [...root.querySelectorAll(selector)];
const CATEGORY_COLORS = {
  weapon: "var(--weapon)",
  vitality: "var(--vitality)",
  spirit: "var(--spirit)",
};

const ENEMY_SLOTS = 6;
const DEFAULT_HERO = "grey_talon";

const toSlots = (heroes) => Array.from({ length: ENEMY_SLOTS }, (_, index) => heroes?.[index] || null);

let data = null;
let state = null;
let lastResult = null;
let parsedHeroes = [];
let agentState = null;
let analyzeTimer = 0;

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function el(tag, className = "", text = "") {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text) node.textContent = text;
  return node;
}

function debounceAnalyze() {
  window.clearTimeout(analyzeTimer);
  analyzeTimer = window.setTimeout(() => analyze(), 120);
}

function sortedHeroes() {
  return [...data.heroes].sort((a, b) => a.name.localeCompare(b.name));
}

function sortedItems() {
  return [...data.items].sort((a, b) => {
    const order = { weapon: 0, vitality: 1, spirit: 2 };
    return order[a.category] - order[b.category] || a.tier - b.tier || a.name.localeCompare(b.name);
  });
}

function heroName(id) {
  return data.heroes.find((hero) => hero.id === id)?.name || id;
}

function itemName(id) {
  return data.items.find((item) => item.id === id)?.name || id;
}

function populateStaticUI() {
  const heroSelect = $("#my-hero");
  heroSelect.innerHTML = "";
  for (const hero of sortedHeroes()) {
    const option = document.createElement("option");
    option.value = hero.id;
    option.textContent = hero.name;
    heroSelect.append(option);
  }

  const enemyGrid = $("#enemy-selects");
  enemyGrid.innerHTML = "";
  for (let index = 0; index < ENEMY_SLOTS; index += 1) {
    const select = document.createElement("select");
    select.dataset.slot = String(index);
    select.setAttribute("aria-label", `Противник ${index + 1}`);
    const placeholder = document.createElement("option");
    placeholder.value = "";
    placeholder.textContent = "— герой —";
    select.append(placeholder);
    for (const hero of sortedHeroes()) {
      const option = document.createElement("option");
      option.value = hero.id;
      option.textContent = hero.name;
      select.append(option);
    }
    select.addEventListener("change", () => {
      const slot = Number(select.dataset.slot);
      const next = toSlots(state.enemyHeroes);
      next[slot] = select.value || null;
      state.enemyHeroes = next;
      syncEnemySelects();
      analyze();
    });
    enemyGrid.append(select);
  }

  renderItemPicker();
}

function syncControlsFromState() {
  $("#my-hero").value = state.myHero;
  $$("#role-control button").forEach((button) => {
    button.classList.toggle("active", button.dataset.role === state.role);
  });
  $("#minutes").value = String(state.gameMinutes);
  $("#minutes-value").textContent = String(state.gameMinutes);
  syncEnemySelects();
  renderItemPicker();
  renderMyItemsChips();
}

function syncEnemySelects() {
  const used = new Set(state.enemyHeroes.filter(Boolean));
  $$("#enemy-selects select").forEach((select, index) => {
    const value = state.enemyHeroes[index] || "";
    select.value = value;
    for (const option of select.options) {
      if (!option.value) continue;
      const isUsed = used.has(option.value) && option.value !== value;
      option.disabled = isUsed || option.value === state.myHero;
    }
  });
}

function renderItemPicker() {
  if (!state) return;
  const picker = $("#item-picker");
  const query = ($("#item-search").value || "").trim().toLowerCase();
  const filtered = sortedItems().filter((item) => {
    if (!query) return true;
    return (
      item.name.toLowerCase().includes(query) ||
      item.category.includes(query) ||
      item.tags.some((tag) => tag.includes(query))
    );
  });
  picker.innerHTML = "";
  if (!filtered.length) {
    picker.append(el("div", "muted", "Ничего не найдено"));
    return;
  }
  for (const item of filtered) {
    const label = document.createElement("label");
    label.className = "item-option";
    const checkbox = document.createElement("input");
    checkbox.type = "checkbox";
    checkbox.value = item.id;
    checkbox.checked = state.myItems.includes(item.id);
    checkbox.addEventListener("change", () => {
      if (checkbox.checked) {
        if (!state.myItems.includes(item.id)) state.myItems.push(item.id);
      } else {
        state.myItems = state.myItems.filter((id) => id !== item.id);
      }
      renderMyItemsChips();
      analyze();
    });
    const dot = el("span", "dot");
    dot.style.background = CATEGORY_COLORS[item.category];
    const name = el("span", "", item.name);
    const tier = el("span", "tier", `T${item.tier}`);
    const cost = el("span", "cost", item.cost.toLocaleString("ru-RU"));
    label.append(checkbox, dot, name, tier, cost);
    picker.append(label);
  }
}

function renderMyItemsChips() {
  const wrap = $("#my-items-chips");
  wrap.innerHTML = "";
  if (!state.myItems.length) {
    wrap.append(el("span", "hint", "Ничего не куплено"));
    return;
  }
  for (const id of state.myItems) {
    const item = data.items.find((entry) => entry.id === id);
    if (!item) continue;
    const chip = el("span", `chip ${item.category}`, item.name);
    const remove = el("button", "", "×");
    remove.setAttribute("aria-label", `Убрать ${item.name}`);
    remove.addEventListener("click", () => {
      state.myItems = state.myItems.filter((entry) => entry !== id);
      renderItemPicker();
      renderMyItemsChips();
      analyze();
    });
    chip.append(remove);
    wrap.append(chip);
  }
}

function setEnemyHeroes(heroes) {
  state.enemyHeroes = toSlots(heroes.filter(Boolean).slice(0, ENEMY_SLOTS));
  syncEnemySelects();
  analyze();
}

function randomEnemies() {
  const pool = data.heroes.filter((hero) => hero.id !== state.myHero);
  for (let i = pool.length - 1; i > 0; i -= 1) {
    const j = Math.floor(Math.random() * (i + 1));
    [pool[i], pool[j]] = [pool[j], pool[i]];
  }
  setEnemyHeroes(pool.slice(0, ENEMY_SLOTS).map((hero) => hero.id));
}

function loadDemo() {
  const demo = demoState(data);
  state = { ...demo, enemyHeroes: toSlots(demo.enemyHeroes) };
  syncControlsFromState();
  analyze();
}

function resetState() {
  state = {
    myHero: state?.myHero || DEFAULT_HERO,
    enemyHeroes: toSlots([]),
    gameMinutes: 18,
    role: "core",
    myItems: [],
    enemyItems: [],
  };
  syncControlsFromState();
  analyze();
}

function analyze() {
  if (!data || !state) return;
  try {
    lastResult = recommend(state, data, { limit: 6 });
    renderSummary(lastResult);
    renderThreats(lastResult);
    renderRecommendations(lastResult);
    renderAlternatives(lastResult);
  } catch (error) {
    console.error(error);
    $("#recommendations").innerHTML = "";
    const box = el("div", "panel");
    box.append(el("h2", "", "Не удалось собрать билд"));
    box.append(el("p", "muted", error instanceof Error ? error.message : String(error)));
    $("#recommendations").append(box);
    $("#threat-list").innerHTML = "";
    $("#match-summary").innerHTML = "";
  }
}

function renderSummary(result) {
  const summary = $("#match-summary");
  summary.innerHTML = "";

  const heroCard = el("div", "hero-card");
  heroCard.append(el("div", "eyebrow", "Мой герой"));
  heroCard.append(el("h2", "", result.hero.name));
  const meta = el("div", "hero-meta");
  for (const role of result.hero.roles) {
    const chip = el("span", "chip", role === "support" ? "поддержка" : role === "carry" ? "керри" : role);
    meta.append(chip);
  }
  meta.append(el("span", "chip", DAMAGE_LABELS[result.hero.damage] || result.hero.damage));
  meta.append(el("span", "chip", result.hero.attack === "melee" ? "ближний бой" : "дальний бой"));
  heroCard.append(meta);
  if (result.hero.notes) heroCard.append(el("p", "hero-note", result.hero.notes));
  summary.append(heroCard);

  const enemyCard = el("div", "enemy-card");
  enemyCard.append(el("h3", "", "Противники"));
  const enemyList = el("div", "enemy-list");
  if (result.enemies.length) {
    for (const enemy of result.enemies) {
      enemyList.append(el("span", "chip enemy", enemy.name));
    }
  } else {
    enemyList.append(el("span", "hint", "Не выбраны — базовые рекомендации по герою"));
  }
  enemyCard.append(enemyList);
  const metaRow = el("div", "meta-row");
  const time = el("span", "", "Время: ");
  time.append(el("b", "", `${result.state.gameMinutes} мин`));
  const role = el("span", "", "Роль: ");
  role.append(el("b", "", ROLE_LABELS[result.state.effectiveRole] || result.state.effectiveRole));
  const count = el("span", "", "Угроз: ");
  count.append(el("b", "", String(Object.values(result.threats.totals).filter((value) => value > 0).length)));
  metaRow.append(time, role, count);
  enemyCard.append(metaRow);
  summary.append(enemyCard);
}

function renderThreats(result) {
  const list = $("#threat-list");
  list.innerHTML = "";
  const summary = threatSummary(result);
  $("#threat-hint").textContent = summary.length
    ? `${result.enemies.length} героев · топ-${Math.min(8, summary.length)}`
    : "угроз не найдено";
  if (!summary.length) {
    list.append(el("div", "hint", "Выберите противников, чтобы увидеть их профили угроз."));
    return;
  }
  for (const entry of summary.slice(0, 8)) {
    const row = el("div", "threat-row");
    row.append(el("span", "threat-label", entry.label));
    const bar = el("div", "threat-bar");
    const fill = el("span");
    fill.style.width = `${Math.round(entry.value * 100)}%`;
    bar.append(fill);
    row.append(bar);
    row.append(el("span", "threat-value", `${Math.round(entry.value * 100)}`));
    const heroes = el("div", "threat-heroes", entry.heroes.join(" · "));
    row.append(heroes);
    list.append(row);
  }
}

function renderRecommendations(result) {
  const wrap = $("#recommendations");
  wrap.innerHTML = "";
  $("#rec-hint").textContent = `${result.recommendations.length} из ${data.items.length} · ${result.hero.name}`;
  if (!result.recommendations.length) {
    wrap.append(el("div", "hint", "Нет рекомендаций — выберите героя и противников."));
    return;
  }
  for (const entry of result.recommendations) {
    const card = el("article", `rec-card ${entry.category}`);
    const top = el("div", "rec-top");
    const left = el("div");
    left.append(el("h3", "rec-name", entry.name));
    const sub = el("div", "rec-sub");
    sub.append(el("span", "chip", CATEGORY_LABELS[entry.category] || entry.category));
    sub.append(el("span", "tier-badge", `T${entry.tier} · ${entry.cost.toLocaleString("ru-RU")}`));
    if (entry.active) sub.append(el("span", "active-badge", "актив"));
    left.append(sub);
    const score = el("div", "rec-score");
    score.append(el("b", "", String(entry.score)));
    score.append(el("span", "", "score"));
    top.append(left, score);
    card.append(top);

    const bar = el("div", "score-bar");
    const fill = el("span");
    fill.style.width = `${entry.score}%`;
    bar.append(fill);
    card.append(bar);

    if (entry.summary) card.append(el("p", "rec-summary", entry.summary));

    const reasons = el("ul", "reasons");
    for (const reason of entry.reasons) {
      reasons.append(el("li", "", reason.text));
    }
    card.append(reasons);

    if (entry.against.length) {
      const against = el("div", "rec-against");
      for (const name of entry.against) {
        against.append(el("span", "chip", name));
      }
      card.append(against);
    }
    wrap.append(card);
  }
}

function renderAlternatives(result) {
  const wrap = $("#alternatives-wrap");
  const list = $("#alternatives");
  list.innerHTML = "";
  if (!result.alternatives.length) {
    wrap.classList.add("hidden");
    return;
  }
  wrap.classList.remove("hidden");
  for (const entry of result.alternatives) {
    const row = el("div", "alt-row");
    const dot = el("span", "dot");
    dot.style.background = CATEGORY_COLORS[entry.category];
    row.append(dot);
    row.append(el("span", "", entry.name));
    row.append(el("span", "hint", `${CATEGORY_LABELS[entry.category]} · T${entry.tier}`));
    row.append(el("span", "score", String(entry.score)));
    list.append(row);
  }
}

function switchTab(name) {
  $$(".tab").forEach((tab) => tab.classList.toggle("active", tab.dataset.tab === name));
  $$(".tab-panel").forEach((panel) => panel.classList.add("hidden"));
  const panel = $(`#tab-${name}`);
  if (panel) panel.classList.remove("hidden");
  if (name === "capture") refreshAgent();
}

function renderScoreboardFound() {
  const wrap = $("#scoreboard-found");
  wrap.innerHTML = "";
  if (!parsedHeroes.length) {
    wrap.append(el("span", "hint", "Герои не найдены. Вставьте имена из скорборда."));
    return;
  }
  for (const hero of parsedHeroes) {
    wrap.append(el("span", "chip", hero.name));
  }
  wrap.append(el("span", "hint", `Найдено: ${parsedHeroes.length}. Будут взяты первые ${ENEMY_SLOTS}.`));
}

async function refreshAgent() {
  const dot = $("#agent-dot");
  const status = $("#agent-status");
  const apply = $("#agent-apply");
  const output = $("#agent-state");
  dot.className = "status-dot";
  status.textContent = "Проверка агента…";
  apply.disabled = true;
  try {
    const response = await fetch("../state.json", { cache: "no-store" });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    agentState = await response.json();
    dot.classList.add("online");
    status.textContent = "Агент подключён";
    apply.disabled = false;
    output.textContent = JSON.stringify(agentState, null, 2);
  } catch (error) {
    agentState = null;
    dot.classList.add("error");
    status.textContent = "Агент не запущен — ручной режим";
    output.textContent = `Нет данных: ${error instanceof Error ? error.message : String(error)}\n\nЗапустите: python3 agent/capture.py --mock`;
  }
}

function applyAgentState() {
  if (!agentState) return;
  const next = {
    ...state,
    ...agentState,
    enemyHeroes: Array.isArray(agentState.enemyHeroes) ? agentState.enemyHeroes : state.enemyHeroes,
    myItems: Array.isArray(agentState.myItems) ? agentState.myItems : state.myItems,
  };
  state = { ...next, enemyHeroes: toSlots(next.enemyHeroes) };
  syncControlsFromState();
  analyze();
  switchTab("build");
}

function bindEvents() {
  $("#my-hero").addEventListener("change", (event) => {
    state.myHero = event.target.value;
    state.enemyHeroes = toSlots(state.enemyHeroes.filter((id) => id && id !== state.myHero));
    syncEnemySelects();
    analyze();
  });

  $$("#role-control button").forEach((button) => {
    button.addEventListener("click", () => {
      state.role = button.dataset.role;
      $$("#role-control button").forEach((entry) => entry.classList.toggle("active", entry === button));
      analyze();
    });
  });

  $("#minutes").addEventListener("input", (event) => {
    state.gameMinutes = Number(event.target.value);
    $("#minutes-value").textContent = String(state.gameMinutes);
    debounceAnalyze();
  });

  $("#random-enemies").addEventListener("click", randomEnemies);
  $("#clear-enemies").addEventListener("click", () => setEnemyHeroes([]));
  $("#demo-btn").addEventListener("click", loadDemo);
  $("#reset-btn").addEventListener("click", resetState);
  $("#analyze-btn").addEventListener("click", analyze);

  $("#item-search").addEventListener("input", renderItemPicker);

  $$(".tab").forEach((tab) => {
    tab.addEventListener("click", () => switchTab(tab.dataset.tab));
  });

  $("#parse-btn").addEventListener("click", () => {
    parsedHeroes = parseScoreboard($("#scoreboard-input").value, data);
    renderScoreboardFound();
  });

  $("#scoreboard-demo").addEventListener("click", () => {
    $("#scoreboard-input").value = `Team A
Haze       5   12,345   3/2/1
Kelvin     4    9,100   1/4/8
Lady Geist 6   15,000   5/1/2
Team B
Grey Talon 5   11,000   2/3/4
Mo & Krill 4    8,000   0/5/6
The Doorman 3   6,000   1/2/9`;
    parsedHeroes = [];
    renderScoreboardFound();
  });

  $("#apply-scoreboard").addEventListener("click", () => {
    if (!parsedHeroes.length) return;
    setEnemyHeroes(parsedHeroes.slice(0, ENEMY_SLOTS).map((hero) => hero.id));
    switchTab("build");
  });

  $("#agent-refresh").addEventListener("click", refreshAgent);
  $("#agent-apply").addEventListener("click", applyAgentState);
}

async function loadData() {
  try {
    const [heroesResponse, itemsResponse, threatsResponse] = await Promise.all([
      fetch("../data/heroes.json", { cache: "no-store" }),
      fetch("../data/items.json", { cache: "no-store" }),
      fetch("../data/threats.json", { cache: "no-store" }),
    ]);
    if (!heroesResponse.ok || !itemsResponse.ok || !threatsResponse.ok) {
      throw new Error("Не удалось загрузить JSON базы данных");
    }
    const [heroes, items, threats] = await Promise.all([
      heroesResponse.json(),
      itemsResponse.json(),
      threatsResponse.json(),
    ]);
    data = {
      version: heroes.version,
      heroes: heroes.heroes,
      items: items.items,
      threats: threats.threats,
      threatOrder: threats.order,
    };
    $("#data-status").textContent = `${data.heroes.length} героев · ${data.items.length} предметов`;
    const demo = demoState(data);
    state = { ...demo, enemyHeroes: toSlots(demo.enemyHeroes) };
    populateStaticUI();
    bindEvents();
    syncControlsFromState();
    analyze();
    refreshAgent();
  } catch (error) {
    console.error(error);
    $("#data-status").textContent = "ошибка загрузки данных";
    $("#match-summary").innerHTML = "";
    const box = el("div", "panel");
    box.append(el("h2", "", "Данные не загрузились"));
    box.append(el("p", "muted", "Запустите сервер из папки deadlock: python3 agent/serve.py и откройте /web/."));
    box.append(el("p", "muted", error instanceof Error ? error.message : String(error)));
    $("#match-summary").append(box);
  }
}

loadData();
