-- counter_items.lua - Counter Items для Umbrella (Dota 2, Lua API v2.0). Нужна библиотека ulib (папка ulib в корне чита).
-- Контр-предметы. В матче смотрит на вражеских героев - их способности и предметы -
-- и советует, что купить против них и против кого именно, с учётом твоей роли (кор / поддержка),
-- основного атрибута, ближнего боя и того, что уже куплено тобой или командой.
--
-- Откуда угрозы:
--   магия и контроль - из данных способностей игры: тип урона, пробивает ли BKB, снимается ли только
--     сильным развеиванием (Ability.GetDamageType / GetImmunityType / GetDispellableType);
--   инвиз, уклонение, лечение, иллюзии, пассивки под Break, сайленсы, точечный контроль, бурст с руки
--     (Focus Fire, Omnislash, Duel - в обычном DPS их не видно), контроль сквозь BKB (Berserker's Call,
--     Reverse Polarity, Doom - BKB от них не спасает) - таблицы ниже
--     (имена и смысл сверены с assets/data/npc_abilities.json 2026-09-23);
--   предметы врагов (Shadow Blade, Butterfly, Satanic, Linken's, сейвы...) - таблица ENEMY_ITEMS.
-- У каждого врага угроза каждого вида не больше 1; сила угрозы - сумма по врагам.
-- Оценка предмета = сумма по угрозам: сила угрозы x насколько предмет её закрывает.
-- Работает с пре-гейма (OnUpdate / OnDraw), только читает игру - приказов не отдаёт.
-- Окно - карточки ulib.panel: иконка предмета, причина, справа иконки врагов. Вне матча при открытом меню
-- можно включить предпросмотр (OnFrame), чтобы посмотреть и передвинуть окно.
-- Меню и окно - на языке чита (русский или английский), смена языка подхватывается без перезагрузки.

local Panel = require("ulib.panel")
local Icons = require("ulib.icons")
local Http = require("ulib.http")
local Timer = require("ulib.timer")
local Recommendations = require("ulib.recommendations")

local counter = {}

local VERSION <const> = "1.6.3"
local MAX_ABILITY_INDEX <const> = 31
local LAST_ITEM_SLOT <const> = 16 -- 0-5 инвентарь, 6-8 рюкзак, 9-14 тайник, 15 ТП, 16 нейтральный
local LAST_ACTIVE_ITEM_SLOT <const> = 5
local TP_SLOT <const> = 15
local NEUTRAL_ITEM_SLOT <const> = 16
local MIN_SCORE <const> = 0.5      -- слабее - не показываем
local MAX_ENEMIES_SHOWN <const> = 4
local MIN_ENEMY_SHARE <const> = 0.35 -- врага показываем, если его вклад не меньше 35% от главного
local NETWORTH_ROLE_AFTER <const> = 180 -- с 3:00 роль «Авто» можно угадать по нетворсу
-- Урон с руки по DPS (урон x атак в секунду) относительно ожидаемого DPS сильного кора к этой минуте:
-- 180 на 0:00, +11 в минуту (30:00 - 510). Меньше 60% ожидаемого - не угроза, 110% и больше - полная.
-- Абсолютный порог не годится: к 30-й минуте с руки на 200+ бьют и поддержки (WD 257 DPS).
local PHYS_REF_BASE <const> = 180
local PHYS_REF_PER_MIN <const> = 11
local PHYS_FROM <const> = 0.6
local PHYS_FULL <const> = 1.1
-- Стадия игры для этой шкалы - по часам, но не раньше, чем по среднему уровню врагов (уровень x 1.5 - 2 мин):
-- в демке часы стоят на нуле, а герои 25-го уровня. В обычном матче часы и уровни идут вместе.
local LEVEL_MINUTES <const> = 1.5
local MAX_DPS <const> = 5000
local SOURCE_SHARE <const> = 0.3 -- предмет врага подписываем причиной, если он дал от 30% угрозы
local NEW_FOR <const> = 30      -- столько секунд новый совет помечен «новое»
local NEW_COOLDOWN <const> = 60 -- совет, который был в списке меньше минуты назад, - не новый

-- Подходит ли предмет твоему герою - по тому, как часто герой его покупает (журналы покупок про-матчей
-- OpenDota за полгода; один запрос на героя, кэш неделя). Без статистики - по атрибуту (COUNTERS.core).
-- Пример (2026-09-23): Invoker - BKB 34%, Linken's 7%, Manta 1% -> Manta ему не советуем.
local EXPLORER <const> = "https://api.opendota.com/api/explorer?sql="
local FIT_DAYS <const> = 180
local FIT_TTL <const> = 7 * 24 * 3600
local FIT_RETRY <const> = 60
local FIT_LOADING_TIMEOUT <const> = 90
local FIT_MIN_GAMES <const> = 30 -- меньше матчей - статистике не верим
local FIT_FULL <const> = 0.05    -- покупает в 5%+ игр - подходит
local FIT_SOME <const> = 0.02    -- 2-5% - подходит иногда, оценка пополам

-- значения из документации - запасные: таблица Enum.ButtonCode в доке, например, сдвинута
local MAGICAL <const> = Enum.DamageTypes.DAMAGE_TYPE_MAGICAL or 2
local PIERCES_BKB <const> = Enum.ImmunityTypes.SPELL_IMMUNITY_ENEMIES_YES or 3
local STRONG_DISPEL <const> = Enum.DispellableTypes.SPELL_DISPELLABLE_YES_STRONG or 1
local UNIT_TARGET <const> = Enum.AbilityBehavior.DOTA_ABILITY_BEHAVIOR_UNIT_TARGET or 8
local TARGET_ENEMY <const> = Enum.TargetTeam.DOTA_UNIT_TARGET_TEAM_ENEMY or 2
local POST_GAME <const> = Enum.GameState.DOTA_GAMERULES_STATE_POST_GAME or 6
local ATTRIBUTES = {}
for name, key in pairs({ DOTA_ATTRIBUTE_STRENGTH = "str", DOTA_ATTRIBUTE_AGILITY = "agi",
    DOTA_ATTRIBUTE_INTELLECT = "int", DOTA_ATTRIBUTE_ALL = "all" }) do
    local value = Enum.Attributes[name]
    if value then
        ATTRIBUTES[value] = key
    end
end
-- роли из поиска матча (ELaneSelectionFlags): 1 - pos1, 4 - pos2, 2 - pos3, 8 - pos4, 16 - pos5
local CORE_FLAGS <const> = 1 | 2 | 4
local SUPPORT_FLAGS <const> = 8 | 16

local function log(fmt, ...)
    print("[counter] " .. fmt:format(...))
end

-- результат вызова или nil, если функция упала
local function safe(fn, ...)
    local ok, result = pcall(fn, ...)
    if ok then
        return result
    end
    return nil
end

--#region Tables

-- угроза -> цвет плашки в окне (по смыслу: магия синяя, урон с руки красный...); текст - TEXT.<язык>.threats
local THREAT_COLORS <const> = {
    magic = Color(110, 160, 255),
    disable = Color(255, 160, 70),
    targeted = Color(255, 125, 95),
    silence = Color(190, 135, 255),
    roots = Color(215, 150, 255),
    invis = Color(175, 180, 200),
    evasion = Color(110, 220, 175),
    heal = Color(120, 215, 110),
    illusions = Color(90, 205, 230),
    passives = Color(235, 200, 90),
    phys = Color(240, 105, 90),
    burst = Color(230, 55, 80),
    pierce = Color(240, 120, 30),
    escape = Color(255, 130, 200),
    linkens = Color(100, 195, 255),
    saves = Color(230, 225, 140),
}

-- срочность совета -> цвет отметки слева (по оценке); у остальных отметки нет
local PRIORITY <const> = {
    { score = 2.0, color = Color(235, 87, 87) },   -- очень нужно
    { score = 1.0, color = Color(242, 170, 60) },  -- нужно
}

-- способность -> сила угрозы (0..1). Магия и обычный контроль сюда не входят - они берутся из данных игры.
local ABILITY_LISTS <const> = {
    invis = {
        riki_backstab = 1, clinkz_wind_walk = 0.8, bounty_hunter_wind_walk = 0.8, weaver_shukuchi = 0.8,
        nyx_assassin_vendetta = 0.8, mirana_invis = 0.6, invoker_ghost_walk = 0.5, sandking_sand_storm = 0.5,
        visage_silent_as_the_grave = 0.5, templar_assassin_meld = 0.4, phantom_lancer_juxtapose = 0.3,
        techies_land_mines = 0.6, -- мины невидимы: сентри и Gem
    },
    evasion = {
        phantom_assassin_immaterial = 1, windrunner_windrun = 0.6, brewmaster_drunken_brawler = 0.5,
        arc_warden_magnetic_field = 0.5, phantom_lancer_phantom_edge = 0.5, naga_siren_eelskin = 0.4,
        hoodwink_scurry = 0.4, mirana_invis = 0.3,
    },
    heal = {
        alchemist_chemical_rage = 1, necrolyte_death_pulse = 0.8, omniknight_purification = 0.8,
        oracle_purifying_flames = 0.8, wisp_tether = 0.8, huskar_berserkers_blood = 0.6, oracle_false_promise = 0.6,
        dazzle_shadow_wave = 0.6, chen_hand_of_god = 0.6, treant_living_armor = 0.6,
        witch_doctor_voodoo_restoration = 0.6, juggernaut_healing_ward = 0.6, enchantress_natures_attendants = 0.6,
        life_stealer_feast = 0.6, abaddon_death_coil = 0.5, undying_soul_rip = 0.5, winter_wyvern_cold_embrace = 0.5,
        skeleton_king_vampiric_spirit = 0.5, troll_warlord_battle_trance = 0.5, dawnbreaker_luminosity = 0.5,
        phoenix_sun_ray = 0.5, warlock_shadow_word = 0.4, treant_leech_seed = 0.4, pugna_life_drain = 0.4,
        lycan_wolf_bite = 0.4, kez_kazurai_katana = 0.4, monkey_king_jingu_mastery = 0.4,
        dawnbreaker_solar_guardian = 0.3, omniknight_hammer_of_purity = 0.3, legion_commander_press_the_attack = 0.3,
        dragon_knight_dragon_blood = 0.3,
    },
    illusions = {
        phantom_lancer_juxtapose = 1, naga_siren_mirror_image = 1, meepo_divided_we_stand = 1,
        terrorblade_conjure_image = 0.8, chaos_knight_phantasm = 0.8, broodmother_spawn_spiderlings = 0.8,
        furion_force_of_nature = 0.5, lycan_summon_wolves = 0.5, lone_druid_spirit_bear = 0.5,
        arc_warden_tempest_double = 0.5, phantom_lancer_doppelwalk = 0.4, enigma_demonic_conversion = 0.4,
        venomancer_plague_ward = 0.4, shadow_shaman_mass_serpent_ward = 0.4, spectre_haunt = 0.3,
        beastmaster_call_of_the_wild = 0.3, invoker_forge_spirit = 0.3, warlock_rain_of_chaos = 0.3,
        visage_summon_familiars = 0.3, dark_seer_wall_of_replica = 0.3, undying_tombstone = 0.3,
    },
    -- пассивки, ради которых стоит брать Break (Silver Edge)
    passives = {
        bristleback_bristleback = 1, spectre_dispersion = 0.8, shredder_reactive_armor = 0.8,
        huskar_berserkers_blood = 0.8, ursa_fury_swipes = 0.7, slark_essence_shift = 0.7,
        phantom_assassin_coup_de_grace = 0.6, phantom_assassin_immaterial = 0.6, drow_ranger_marksmanship = 0.6,
        tidehunter_kraken_shell = 0.6, mars_bulwark = 0.6, faceless_void_time_lock = 0.5, troll_warlord_fervor = 0.5,
        chaos_knight_chaos_strike = 0.5, visage_gravekeepers_cloak = 0.5, slardar_bash = 0.4,
        spirit_breaker_greater_bash = 0.4, necrolyte_heartstopper_aura = 0.4, viper_corrosive_skin = 0.4,
        juggernaut_blade_dance = 0.4, skeleton_king_mortal_strike = 0.4, weaver_geminate_attack = 0.4,
        monkey_king_jingu_mastery = 0.4, axe_counter_helix = 0.4, luna_moon_glaive = 0.4, sniper_headshot = 0.3,
        antimage_mana_break = 0.3, legion_commander_moment_of_courage = 0.3, dragon_knight_dragon_blood = 0.3,
        templar_assassin_psi_blades = 0.3,
    },
    -- руты: снимаются развеиванием (Manta, Eul's, Lotus)
    roots = {
        naga_siren_ensnare = 0.5, ember_spirit_searing_chains = 0.5, meepo_earthbind = 0.4,
        crystal_maiden_frostbite = 0.4, treant_overgrowth = 0.4, dark_willow_bramble_maze = 0.4,
        lone_druid_entangle = 0.3,
    },
    silence = {
        skywrath_mage_ancient_seal = 0.6, silencer_global_silence = 0.6, disruptor_static_storm = 0.6,
        silencer_last_word = 0.5, drow_ranger_wave_of_silence = 0.5, night_stalker_crippling_fear = 0.5,
        death_prophet_silence = 0.5, riki_smoke_screen = 0.5, silencer_glaives_of_wisdom = 0.4,
        puck_waning_rift = 0.4, bloodseeker_blood_bath = 0.4, kez_talon_toss = 0.4, muerta_the_calling = 0.4,
        earth_spirit_magnetize = 0.3, templar_assassin_psionic_trap = 0.3, arc_warden_flux = 0.3,
        marci_unleash = 0.3,
    },
    -- побег и доджи: такого героя трудно поймать - нужен мгновенный контроль (хекс, сайленс, стан, рут)
    escape = {
        storm_spirit_ball_lightning = 1, puck_phase_shift = 0.6, puck_ethereal_jaunt = 0.5, puck_illusory_orb = 0.2,
        antimage_blink = 0.8, queenofpain_blink = 0.7, ember_spirit_fire_remnant = 0.7, morphling_waveform = 0.6,
        faceless_void_time_walk = 0.6, void_spirit_dissimilate = 0.5, void_spirit_astral_step = 0.4,
        slark_shadow_dance = 0.5, slark_pounce = 0.4, slark_dark_pact = 0.2, weaver_shukuchi = 0.5,
        weaver_time_lapse = 0.4, mirana_leap = 0.5, phantom_lancer_doppelwalk = 0.5, monkey_king_tree_dance = 0.5,
        dark_willow_shadow_realm = 0.5, shredder_timber_chain = 0.5, pangolier_swashbuckle = 0.4,
        pangolier_gyroshell = 0.4, earth_spirit_rolling_boulder = 0.4, nyx_assassin_vendetta = 0.4,
        windrunner_windrun = 0.4, hoodwink_scurry = 0.4, kez_grappling_claw = 0.4,
        phantom_assassin_phantom_strike = 0.4, marci_companion_run = 0.3, batrider_firefly = 0.3,
        furion_teleportation = 0.3, wisp_relocate = 0.3, riki_blink_strike = 0.3, sandking_burrowstrike = 0.3,
        magnataur_skewer = 0.3, tinker_keen_teleport = 0.4,
    },
    -- бурст с руки: ульта или режим, в котором герой бьёт одну цель очень быстро. В DPS до нажатия его
    -- не видно (у Windranger без Focus Fire - ~70-200), а Blade Mail возвращает этот урон ему самому
    burst = {
        windrunner_focusfire = 1, juggernaut_omni_slash = 0.9, legion_commander_duel = 0.7,
        troll_warlord_battle_trance = 0.6, huskar_berserkers_blood = 0.6, marci_unleash = 0.6,
        ursa_enrage = 0.5, ursa_fury_swipes = 0.3, phantom_assassin_coup_de_grace = 0.5,
        sven_gods_strength = 0.5, clinkz_strafe = 0.5, riki_tricks_of_the_trade = 0.4,
        terrorblade_metamorphosis = 0.4, ember_spirit_sleight_of_fist = 0.3, lycan_shapeshift = 0.3,
    },
    -- контроль и добивание сквозь BKB (SPELL_IMMUNITY_ENEMIES_YES в npc_abilities.json): в «контроль» не входят -
    -- от них не спасает BKB. Спасает додж на касте (Eul's: у Call 0.4 с, у Culling Blade 0.3 с - руками или
    -- Dodger'ом), Aeon Disk, Blade Mail (прыгнули на тебя - получили обратно). От Chronosphere и Black Hole
    -- Eul's спасает хуже (приземляешься в них же) - вес ниже.
    pierce = {
        axe_berserkers_call = 1, axe_culling_blade = 0.5, magnataur_reverse_polarity = 0.8, doom_bringer_doom = 0.7,
        enigma_black_hole = 0.7, faceless_void_chronosphere = 0.6, legion_commander_duel = 0.6,
        batrider_flaming_lasso = 0.6, bane_fiends_grip = 0.5, beastmaster_primal_roar = 0.5,
        primal_beast_pulverize = 0.5, winter_wyvern_winters_curse = 0.4, bloodseeker_rupture = 0.4,
        pudge_dismember = 0.4, medusa_stone_gaze = 0.4, spirit_breaker_nether_strike = 0.3,
        rattletrap_hookshot = 0.3, treant_overgrowth = 0.3, tusk_walrus_punch = 0.3,
    },
    -- контроль в одну цель: его отражает Linken's / Lotus
    targeted = {
        doom_bringer_doom = 1, legion_commander_duel = 1, batrider_flaming_lasso = 0.9, bane_fiends_grip = 0.8,
        pudge_dismember = 0.7, beastmaster_primal_roar = 0.7, necrolyte_reapers_scythe = 0.6, lion_voodoo = 0.5,
        shadow_shaman_voodoo = 0.5, shadow_shaman_shackles = 0.5, winter_wyvern_winters_curse = 0.5,
        rubick_telekinesis = 0.4, chaos_knight_chaos_bolt = 0.4, grimstroke_soul_chain = 0.4,
        lion_finger_of_death = 0.4, lina_laguna_blade = 0.4, axe_culling_blade = 0.5, vengefulspirit_magic_missile = 0.3,
        dragon_knight_dragon_tail = 0.3, bane_nightmare = 0.3,
        -- у этих героев кроме магии угроз почти нет, а главное - способность в цель (сверено 2026-09-24)
        razor_static_link = 0.4, shadow_demon_disruption = 0.4, shadow_demon_demonic_purge = 0.4,
        obsidian_destroyer_astral_imprisonment = 0.4, viper_viper_strike = 0.4, lich_sinister_gaze = 0.4,
        kunkka_x_marks_the_spot = 0.3, tinker_laser = 0.3,
    },
}

-- Предмет врага (без item_) -> угрозы. Урон с руки в основном считается по DPS героя (см. enemy_threats),
-- поэтому здесь для phys - только то, чего в DPS нет: криты, снижение брони, баши, сплеш, процы.
local ENEMY_ITEMS <const> = {
    invis_sword = { invis = 1, phys = 0.1 },
    silver_edge = { invis = 1, phys = 0.2 },
    shadow_amulet = { invis = 0.4 },
    glimmer_cape = { invis = 0.3, saves = 0.5 },
    butterfly = { evasion = 1, phys = 0.2 },
    talisman_of_evasion = { evasion = 0.4 },
    heavens_halberd = { evasion = 0.4, roots = 0.4, targeted = 0.3 },
    radiance = { evasion = 0.2, magic = 0.2 },
    satanic = { heal = 0.7, phys = 0.2 },
    heart = { heal = 0.6 },
    holy_locket = { heal = 0.4 },
    guardian_greaves = { heal = 0.4 },
    bloodstone = { heal = 0.4 },
    mekansm = { heal = 0.3 },
    vladmir = { heal = 0.2 },
    manta = { illusions = 0.4 },
    helm_of_the_overlord = { illusions = 0.2 },
    -- предметы в одну цель: их блокирует Linken's и отражает Lotus
    orchid = { silence = 0.6, targeted = 0.5 },
    bloodthorn = { silence = 0.8, targeted = 0.6, phys = 0.3 },
    sheepstick = { disable = 0.6, targeted = 0.8 },
    rod_of_atos = { roots = 0.5, targeted = 0.3 },
    gungir = { roots = 0.5 },
    nullifier = { targeted = 0.4 },
    dagon = { magic = 0.4, targeted = 0.3 },
    dagon_2 = { magic = 0.4, targeted = 0.3 },
    dagon_3 = { magic = 0.4, targeted = 0.3 },
    dagon_4 = { magic = 0.4, targeted = 0.3 },
    dagon_5 = { magic = 0.4, targeted = 0.3 },
    ethereal_blade = { magic = 0.4, saves = 0.3, targeted = 0.3 },
    veil_of_discord = { magic = 0.2 },
    revenants_brooch = { magic = 0.3 }, -- атаки магическим уроном
    phylactery = { magic = 0.2 },
    sphere = { linkens = 1 },
    blink = { escape = 0.4 },
    swift_blink = { escape = 0.4 },
    arcane_blink = { escape = 0.4 },
    overwhelming_blink = { escape = 0.4 },
    ghost = { saves = 0.5 },
    cyclone = { saves = 0.4 },
    wind_waker = { saves = 0.6 },
    force_staff = { saves = 0.3 },
    hurricane_pike = { saves = 0.4 },
    aeon_disk = { saves = 0.7 },
    lotus_orb = { saves = 0.3 },
    greater_crit = { phys = 0.6 },
    lesser_crit = { phys = 0.3 },
    desolator = { phys = 0.4 },
    abyssal_blade = { phys = 0.4, targeted = 0.5 },
    basher = { phys = 0.3 },
    monkey_king_bar = { phys = 0.3 },
    bfury = { phys = 0.3 },
    mjollnir = { phys = 0.3 },
    diffusal_blade = { phys = 0.2 },
    disperser = { phys = 0.2 },
    maelstrom = { phys = 0.1 },
    echo_sabre = { phys = 0.1 },
    skadi = { phys = 0.1 },
    armlet = { phys = 0.1 },
    moon_shard = { phys = 0.1 },
}

-- как называть предмет врага в причине
local ENEMY_ITEM_LABELS <const> = {
    invis_sword = "Shadow Blade", silver_edge = "Silver Edge", shadow_amulet = "Shadow Amulet",
    glimmer_cape = "Glimmer", butterfly = "Butterfly", talisman_of_evasion = "Talisman of Evasion",
    heavens_halberd = "Halberd", radiance = "Radiance", satanic = "Satanic", heart = "Heart",
    holy_locket = "Holy Locket", guardian_greaves = "Greaves", bloodstone = "Bloodstone", mekansm = "Mekansm",
    vladmir = "Vladmir", manta = "Manta", helm_of_the_overlord = "Overlord", orchid = "Orchid",
    bloodthorn = "Bloodthorn", sheepstick = "Scythe of Vyse", rod_of_atos = "Atos", gungir = "Gleipnir",
    nullifier = "Nullifier", dagon = "Dagon", dagon_2 = "Dagon", dagon_3 = "Dagon", dagon_4 = "Dagon",
    dagon_5 = "Dagon", ethereal_blade = "Ethereal Blade", veil_of_discord = "Veil", blink = "Blink",
    swift_blink = "Swift Blink", arcane_blink = "Arcane Blink", overwhelming_blink = "Overwhelming Blink",
    ghost = "Ghost", cyclone = "Eul's", wind_waker = "Wind Waker", force_staff = "Force Staff",
    hurricane_pike = "Pike", aeon_disk = "Aeon Disk", lotus_orb = "Lotus", greater_crit = "Daedalus",
    desolator = "Desolator", monkey_king_bar = "MKB", abyssal_blade = "Abyssal", mjollnir = "Mjollnir",
    bfury = "Battle Fury", skadi = "Skadi", basher = "Basher", lesser_crit = "Crystalys", echo_sabre = "Echo Sabre",
    armlet = "Armlet", maelstrom = "Maelstrom", diffusal_blade = "Diffusal", moon_shard = "Moon Shard",
    disperser = "Disperser", revenants_brooch = "Brooch", phylactery = "Phylactery",
}

-- Что советуем. vs - какие угрозы закрывает и насколько (0..1).
-- support - подходит поддержке; core - подходит кору: true или набор атрибутов (all - универсал);
-- melee - только ближнему бою; team - одного на команду хватит (есть у союзника - не советуем).
local COUNTERS <const> = {
    -- магия и контроль
    black_king_bar = { name = "BKB", core = true, vs = { magic = 0.5, disable = 0.5, silence = 0.4, roots = 0.4 } },
    pipe = { name = "Pipe", support = true, core = { str = true }, team = true, vs = { magic = 0.5 } },
    glimmer_cape = { name = "Glimmer Cape", support = true, vs = { magic = 0.4 } },
    mage_slayer = { name = "Mage Slayer", core = { agi = true, int = true }, vs = { magic = 0.35 } },
    sange_and_yasha = { name = "Sange and Yasha", core = { str = true, agi = true, all = true },
        vs = { disable = 0.25, silence = 0.25, roots = 0.25 } },
    -- в одну цель: Linken's блокирует, Lotus отражает
    sphere = { name = "Linken's Sphere", core = true, vs = { targeted = 1 } },
    lotus_orb = { name = "Lotus Orb", support = true, core = { str = true, int = true }, team = true,
        vs = { targeted = 0.7, silence = 0.5, roots = 0.5 } },
    -- сайленсы и руты снимает развеивание
    manta = { name = "Manta Style", core = { agi = true, all = true }, vs = { silence = 0.8, roots = 0.7 } },
    cyclone = { name = "Eul's Scepter", support = true, core = { int = true },
        vs = { silence = 0.6, roots = 0.5, pierce = 0.6, burst = 0.3 } },
    guardian_greaves = { name = "Guardian Greaves", support = true, team = true, vs = { silence = 0.5, roots = 0.4 } },
    -- побег и доджи: мгновенный контроль (Bloodthorn, Gleipnir, Disperser - улучшения, см. UPGRADES)
    sheepstick = { name = "Scythe of Vyse", core = { int = true }, vs = { escape = 1 } },
    orchid = { name = "Orchid Malevolence", core = { int = true, agi = true }, vs = { escape = 0.7 } },
    abyssal_blade = { name = "Abyssal Blade", core = { str = true, agi = true, all = true }, vs = { escape = 0.8 } },
    harpoon = { name = "Harpoon", core = { str = true, agi = true, all = true }, vs = { escape = 0.6 } },
    rod_of_atos = { name = "Rod of Atos", support = true, core = { int = true }, vs = { escape = 0.5 } },
    diffusal_blade = { name = "Diffusal Blade", core = { agi = true }, vs = { escape = 0.4 } },
    silver_edge = { name = "Silver Edge", core = { str = true, agi = true, all = true }, vs = { passives = 1 } },
    monkey_king_bar = { name = "MKB", core = { str = true, agi = true, all = true }, vs = { evasion = 1 } },
    mjollnir = { name = "Mjollnir", core = { str = true, agi = true, all = true }, vs = { illusions = 0.8 } },
    gungir = { name = "Gleipnir", core = { int = true }, vs = { illusions = 0.7 } },
    bfury = { name = "Battle Fury", core = { str = true, agi = true, all = true }, melee = true,
        vs = { illusions = 0.8 } },
    shivas_guard = { name = "Shiva's Guard", core = { str = true, int = true },
        vs = { illusions = 0.5, heal = 0.6, phys = 0.6 } },
    skadi = { name = "Eye of Skadi", core = { agi = true, all = true }, vs = { heal = 0.7, escape = 0.3 } },
    spirit_vessel = { name = "Spirit Vessel", support = true, core = { str = true }, team = true, vs = { heal = 1 } },
    dust = { name = "Dust", support = true, core = true, vs = { invis = 0.8 } },
    ward_sentry = { name = "Sentry Ward", support = true, vs = { invis = 1 } },
    gem = { name = "Gem", support = true, team = true, vs = { invis = 0.9 } },
    -- урон с руки и бурст с руки (Blade Mail возвращает урон, Ghost и Halberd выключают атаки)
    ghost = { name = "Ghost Scepter", support = true, vs = { phys = 0.9, burst = 0.8 } },
    solar_crest = { name = "Solar Crest", support = true, vs = { phys = 0.6 } },
    pavise = { name = "Pavise", support = true, vs = { phys = 0.5 } },
    ethereal_blade = { name = "Ethereal Blade", core = { int = true }, vs = { phys = 0.5 } },
    force_staff = { name = "Force Staff", support = true, core = { int = true }, vs = { linkens = 0.8, phys = 0.3 } },
    assault = { name = "Assault Cuirass", core = { str = true, agi = true, all = true }, vs = { phys = 0.8 } },
    butterfly = { name = "Butterfly", core = { agi = true, all = true }, vs = { phys = 0.7 } },
    heavens_halberd = { name = "Heaven's Halberd", core = { str = true }, vs = { phys = 0.8, burst = 0.6 } },
    blade_mail = { name = "Blade Mail", core = { str = true }, vs = { burst = 1, phys = 0.6, pierce = 0.5 } },
    crimson_guard = { name = "Crimson Guard", core = { str = true }, team = true, vs = { phys = 0.5 } },
    aeon_disk = { name = "Aeon Disk", core = true, vs = { pierce = 0.6, burst = 0.5, phys = 0.4, magic = 0.1 } },
    nullifier = { name = "Nullifier", core = { str = true, agi = true, all = true }, vs = { saves = 1, escape = 0.3 } },
}

-- Улучшения: если есть они, базовый предмет считаем купленным. Проверяется только по настоящим
-- предметам, без цепочек: Mjollnir закрывает Gleipnir, но не Rod of Atos (хотя Atos - часть Gleipnir).
local UPGRADES <const> = {
    cyclone = { "wind_waker" },
    ghost = { "ethereal_blade" },
    force_staff = { "hurricane_pike" },
    ward_sentry = { "ward_dispenser" },
    mjollnir = { "gungir" },
    gungir = { "mjollnir" },
    orchid = { "bloodthorn" },
    rod_of_atos = { "gungir" },
    diffusal_blade = { "disperser" },
}

-- Твои способности, которые уже закрывают часть угроз: какую долю угрозы снимают (0..1).
-- Не выученная способность считается наполовину. Купленные контр-предметы тоже закрывают угрозы -
-- по своему vs x OWNED_COVER. Смысл сверен с assets/data/npc_abilities.json (debuff_immunity,
-- magic_resist, status_resist, strong_dispel, true_sight, heal_reduction...) 2026-09-23.
local MY_ABILITIES <const> = {
    -- иммунитет и сопротивление магии, развеивание
    life_stealer_rage = { label = "Rage", covers = { magic = 0.6, disable = 0.6, silence = 0.7, roots = 0.7 } },
    juggernaut_blade_fury = { label = "Blade Fury", covers = { magic = 0.4, disable = 0.3, silence = 0.5, roots = 0.5 } },
    antimage_counterspell = { label = "Counterspell", covers = { magic = 0.35, targeted = 0.5 } },
    slark_dark_pact = { label = "Dark Pact", covers = { silence = 0.6, roots = 0.6 } },
    legion_commander_press_the_attack = { label = "Press the Attack", covers = { silence = 0.4, roots = 0.4 } },
    abaddon_aphotic_shield = { label = "Aphotic Shield", covers = { silence = 0.4, roots = 0.4, disable = 0.2 } },
    weaver_time_lapse = { label = "Time Lapse", covers = { silence = 0.4, roots = 0.4, disable = 0.2 } },
    troll_warlord_battle_trance = { label = "Battle Trance", covers = { silence = 0.4, roots = 0.4 } },
    phantom_assassin_blur = { label = "Blur", covers = { silence = 0.3, roots = 0.3 } },
    templar_assassin_refraction = { label = "Refraction",
        covers = { phys = 0.4, burst = 0.3, magic = 0.3, silence = 0.3, roots = 0.3 } },
    kez_raptor_dance = { label = "Raptor Dance", covers = { silence = 0.3, roots = 0.3, magic = 0.2 } },
    keeper_of_the_light_chakra_magic = { label = "Chakra Magic", covers = { silence = 0.3, roots = 0.3 } },
    marci_bodyguard = { label = "Bodyguard", covers = { silence = 0.3, roots = 0.3 } },
    pangolier_gyroshell = { label = "Rolling Thunder", covers = { magic = 0.3, disable = 0.2 } },
    omniknight_martyr = { label = "Martyr", covers = { magic = 0.3 } },
    oracle_fates_edict = { label = "Fate's Edict", covers = { magic = 0.3 } },
    huskar_berserkers_blood = { label = "Berserker's Blood", covers = { magic = 0.3 } },
    ember_spirit_flame_guard = { label = "Flame Guard", covers = { magic = 0.3 } },
    lina_flame_cloak = { label = "Flame Cloak", covers = { magic = 0.2 } },
    -- сопротивление эффектам
    ursa_enrage = { label = "Enrage", covers = { disable = 0.3, silence = 0.3, roots = 0.3, phys = 0.3 } },
    tiny_insurmountable = { label = "Insurmountable", covers = { disable = 0.2, silence = 0.2, roots = 0.2 } },
    spirit_breaker_bulldoze = { label = "Bulldoze", covers = { disable = 0.2 } },
    tinker_defense_matrix = { label = "Defense Matrix", covers = { disable = 0.2, magic = 0.2, phys = 0.2 } },
    -- меньше урона по тебе
    medusa_mana_shield = { label = "Mana Shield", covers = { phys = 0.3, magic = 0.3 } },
    bristleback_bristleback = { label = "Bristleback", covers = { phys = 0.3, magic = 0.2 } },
    phantom_assassin_immaterial = { label = "Immaterial", covers = { phys = 0.3 } },
    nyx_assassin_spiked_carapace = { label = "Spiked Carapace", covers = { targeted = 0.2, phys = 0.2, burst = 0.4 } },
    -- возвращают урон или переживают бурст
    abaddon_borrowed_time = { label = "Borrowed Time", covers = { burst = 0.5, pierce = 0.3 } },
    -- додж на касте: то, что делает Eul's против ульт сквозь BKB
    puck_phase_shift = { label = "Phase Shift", covers = { pierce = 0.5, targeted = 0.3 } },
    void_spirit_dissimilate = { label = "Dissimilate", covers = { pierce = 0.3 } },
    storm_spirit_ball_lightning = { label = "Ball Lightning", covers = { pierce = 0.3 } },
    -- исчезает на 1 с (каст 0,1 с, КД 22-10 с): срывает Duel, Hex, Dismember на касте
    phantom_lancer_doppelwalk = { label = "Doppelganger", covers = { pierce = 0.4, targeted = 0.3 } },
    spectre_dispersion = { label = "Dispersion", covers = { burst = 0.3, phys = 0.2 } },
    -- видят невидимых
    zuus_lightning_bolt = { label = "Lightning Bolt", covers = { invis = 0.3 } },
    rattletrap_rocket_flare = { label = "Rocket Flare", covers = { invis = 0.3 } },
    drow_ranger_wave_of_silence = { label = "Gust", covers = { invis = 0.3 } },
    slardar_amplify_damage = { label = "Corrosive Haze", covers = { invis = 0.3 } },
    void_spirit_aether_remnant = { label = "Aether Remnant", covers = { invis = 0.2 } },
    -- режут лечение
    ancient_apparition_ice_blast = { label = "Ice Blast", covers = { heal = 0.7 } },
    necrolyte_heartstopper_aura = { label = "Heartstopper", covers = { heal = 0.4 } },
    abaddon_withering_mist = { label = "Withering Mist", covers = { heal = 0.3 } },
    bane_enfeeble = { label = "Enfeeble", covers = { heal = 0.3 } },
    venomancer_poison_sting = { label = "Poison Sting", covers = { heal = 0.2 } },
    -- Break
    doom_bringer_doom = { label = "Doom", covers = { passives = 0.4, escape = 0.5 } },
    -- мгновенный контроль - ловит тех, кто убегает и доджит
    batrider_flaming_lasso = { label = "Flaming Lasso", covers = { escape = 0.5 } },
    lion_voodoo = { label = "Hex", covers = { escape = 0.4 } },
    shadow_shaman_voodoo = { label = "Hex", covers = { escape = 0.4 } },
    legion_commander_duel = { label = "Duel", covers = { escape = 0.4 } },
    bane_fiends_grip = { label = "Fiend's Grip", covers = { escape = 0.4 } },
    disruptor_glimpse = { label = "Glimpse", covers = { escape = 0.4 } },
    faceless_void_chronosphere = { label = "Chronosphere", covers = { escape = 0.4 } },
    shadow_shaman_shackles = { label = "Shackles", covers = { escape = 0.3 } },
    skywrath_mage_ancient_seal = { label = "Ancient Seal", covers = { escape = 0.3 } },
    silencer_last_word = { label = "Last Word", covers = { escape = 0.3 } },
    rubick_telekinesis = { label = "Telekinesis", covers = { escape = 0.3 } },
    enigma_black_hole = { label = "Black Hole", covers = { escape = 0.3 } },
    disruptor_kinetic_field = { label = "Kinetic Field", covers = { escape = 0.3 } },
    disruptor_static_storm = { label = "Static Storm", covers = { escape = 0.3 } },
    night_stalker_crippling_fear = { label = "Crippling Fear", covers = { escape = 0.3 } },
    beastmaster_primal_roar = { label = "Primal Roar", covers = { escape = 0.3 } },
    -- сплеш и мультишот - против иллюзий
    gyrocopter_flak_cannon = { label = "Flak Cannon", covers = { illusions = 0.3 } },
    medusa_split_shot = { label = "Split Shot", covers = { illusions = 0.3 } },
    luna_moon_glaive = { label = "Moon Glaive", covers = { illusions = 0.3 } },
    sven_great_cleave = { label = "Great Cleave", covers = { illusions = 0.3 } },
    kunkka_tidebringer = { label = "Tidebringer", covers = { illusions = 0.3 } },
    ember_spirit_sleight_of_fist = { label = "Sleight of Fist", covers = { illusions = 0.3 } },
}
local OWNED_COVER <const> = 0.7 -- купленный контр-предмет закрывает угрозы на 70% от своего vs
local TEAM_COVER <const> = 0.5  -- командный предмет союзника (Pipe, Gem, Greaves...) - на 50%
local MAX_COVER <const> = 0.8   -- совсем угрозу не обнуляем: предмет всё ещё может понадобиться

-- Улучшение, которое само не контр-предмет, -> базовый контр-предмет (для «Уже учтено»):
-- Wind Waker работает как Eul's, но в подписи должно стоять «Wind Waker».
local BASE_OF = {}
local OWNED_LABELS <const> = {
    wind_waker = "Wind Waker", hurricane_pike = "Hurricane Pike", ward_dispenser = "Sentry Ward",
    bloodthorn = "Bloodthorn", disperser = "Disperser",
}

-- для статистики покупок: кто покупает улучшение, покупает и базовый предмет
local FIT_ALIASES <const> = {
    cyclone = { "wind_waker" },
    ghost = { "ethereal_blade" },
    force_staff = { "hurricane_pike" },
    ward_sentry = { "ward_dispenser" },
    orchid = { "bloodthorn" },
    rod_of_atos = { "gungir" },
    diffusal_blade = { "disperser" },
}

for base, upgrades in pairs(UPGRADES) do
    for _, name in ipairs(upgrades) do
        if not COUNTERS[name] then
            BASE_OF[name] = base
        end
    end
end

-- способность -> { угроза = сила }, собирается из ABILITY_LISTS
local ABILITY_THREATS = {}
for threat, list in pairs(ABILITY_LISTS) do
    for name, weight in pairs(list) do
        local entry = ABILITY_THREATS[name] or {}
        entry[threat] = weight
        ABILITY_THREATS[name] = entry
    end
end

-- иконки советуемых предметов грузим сразу, а не в первом кадре матча
for id in pairs(COUNTERS) do
    Icons.Item(id)
end

-- пример для предпросмотра окна вне матча
local PREVIEW <const> = {
    { id = "black_king_bar", item = "BKB", threats = { "magic", "disable" }, score = 2.6,
        units = { "npc_dota_hero_lion", "npc_dota_hero_crystal_maiden" }, labels = { "Lion", "Crystal Maiden" } },
    { id = "assault", item = "Assault Cuirass", threats = { "phys" }, items = "Daedalus", new = true, score = 1.2,
        units = { "npc_dota_hero_muerta" }, labels = { "Muerta" }, sources = { "greater_crit" } },
    { id = "sheepstick", item = "Scythe of Vyse", threats = { "escape" }, items = "Blink", score = 1.5,
        units = { "npc_dota_hero_puck", "npc_dota_hero_antimage" }, labels = { "Puck", "Anti-Mage" },
        sources = { false, "blink" } },
    { id = "sphere", item = "Linken's Sphere", threats = { "targeted", "silence" }, items = "Bloodthorn", score = 1.1,
        units = { "npc_dota_hero_arc_warden", "npc_dota_hero_lion" }, labels = { "Arc Warden", "Lion" },
        sources = { "bloodthorn", false } },
    { id = "blade_mail", item = "Blade Mail", threats = { "burst", "pierce" }, score = 0.9,
        units = { "npc_dota_hero_windrunner", "npc_dota_hero_axe" }, labels = { "Windranger", "Axe" } },
}

--#endregion

--#region Language

-- Тексты меню и окна. Язык - как у чита: русский или английский (остальные языки чита - английский).
local TEXT <const> = {
    ru = {
        group = "Контр-предметы",
        enabled = "Включить",
        enabled_tip = "Карточка: что купить, цветные плашки - от чего помогает, справа - против кого\n"
            .. "(на портрете - предмет врага, из-за которого совет).\n"
            .. "Отметка слева: красная - очень нужно, оранжевая - нужно, без отметки - желательно.",
        role = "Моя роль",
        role_items = { "Авто", "Кор (1–3)", "Поддержка (4–5)" },
        role_tip = "Авто: роли, отмеченные при поиске матча; если отмечены и коры, и поддержки -\n"
            .. "с 3:00 по нетворсу (трое богатейших в команде - коры), до этого - кор.",
        show = "Показывать",
        -- чит хранит выбор по тексту пункта: пункты можно добавлять и переставлять, но не переименовывать
        show_items = { "Всегда", "Когда открыта лавка", "Когда открыта лавка или герой мёртв",
            "Только с открытым меню" },
        count = "Предметов в списке",
        preview = "Предпросмотр в главном меню",
        preview_tip = "Вне матча при открытом меню показывает окно с примером - чтобы посмотреть, как оно выглядит,\n"
            .. "и передвинуть его мышью.",
        title = "Против них",
        core = "кор",
        support = "поддержка",
        preview_hint = "предпросмотр",
        empty = "Пока нечего советовать",
        covered = "Уже учтено: %s",
        ally = "%s у союзника",
        new = "новое",
        preview_note = "Уже учтено: Counterspell, Manta Style, Pipe у союзника",
        threats = {
            magic = "магия", disable = "контроль", targeted = "в одну цель", silence = "сайленсы",
            roots = "руты и дизарм", invis = "инвиз", evasion = "уклонение", heal = "лечение",
            illusions = "иллюзии", passives = "пассивки → Break", phys = "урон с руки", burst = "бурст с руки",
            pierce = "сквозь BKB", escape = "побег и доджи", linkens = "Linken's у врага", saves = "сейвы у врага",
        },
    },
    en = {
        group = "Counter Items",
        enabled = "Enable",
        enabled_tip = "Card: what to buy, colored chips - what it helps against, on the right - against whom\n"
            .. "(an item on a portrait - the enemy item that caused the advice).\n"
            .. "Left mark: red - badly needed, orange - needed, no mark - nice to have.",
        role = "My role",
        role_items = { "Auto", "Core (1–3)", "Support (4–5)" },
        role_tip = "Auto: roles picked in matchmaking; if both core and support roles are picked -\n"
            .. "by net worth from 3:00 (the three richest in the team are cores), core before that.",
        show = "Show",
        show_items = { "Always", "When the shop is open", "When the shop is open or the hero is dead",
            "Only with the menu open" },
        count = "Items in the list",
        preview = "Preview in the main menu",
        preview_tip = "Outside a match, with the menu open, shows the window with an example - to see how it looks\n"
            .. "and drag it with the mouse.",
        title = "Counter them",
        core = "core",
        support = "support",
        preview_hint = "preview",
        empty = "Nothing to suggest yet",
        covered = "Already covered: %s",
        ally = "ally's %s",
        new = "new",
        preview_note = "Already covered: Counterspell, Manta Style, ally's Pipe",
        threats = {
            magic = "magic", disable = "disables", targeted = "single-target", silence = "silences",
            roots = "roots & disarms", invis = "invisibility", evasion = "evasion", heal = "healing",
            illusions = "illusions", passives = "passives → Break", phys = "right-click", burst = "right-click burst",
            pierce = "through BKB", escape = "escapes & dodges", linkens = "enemy Linken's", saves = "enemy saves",
        },
    },
}

-- Язык чита: перевод слова из его словаря (C:\Umbrella\localizer\<язык>.json) - «Enable» на русском
-- «Включить». Кириллица в UTF-8 начинается с байтов D0/D1.
local function cheat_language()
    local text = safe(Localizer.Get, "Enable")
    return (type(text) == "string" and text:find("[\208\209]")) and "ru" or "en"
end

local lang = cheat_language()
local L = TEXT[lang]

--#endregion

--#region UI

-- Пункты меню создаются с русскими именами на любом языке: по имени чит хранит настройку в gui.json,
-- на другом языке подпись меняется через ForceLocalization. Списки (комбо) чит хранит по тексту
-- выбранного пункта, поэтому их пункты - сразу на языке чита.
local ui_group = Menu.Create("General", "Main", "Counter Items", "Main"):Create(TEXT.ru.group)
local ui = {}
ui.enabled = ui_group:Switch(TEXT.ru.enabled, true)
ui.role = ui_group:Combo(TEXT.ru.role, L.role_items, 0)
ui.show = ui_group:Combo(TEXT.ru.show, L.show_items, 0)
ui.count = ui_group:Slider(TEXT.ru.count, 3, 8, 5)
ui.preview = ui_group:Switch(TEXT.ru.preview, false)

local panel = Panel.new("counter_items", { title = L.title, x = 40, y = 420, width = 260 })

-- пункты списка на текущем языке; выбранный пункт сохраняется по номеру
local function relabel_combo(widget, items)
    local ok, err = pcall(function()
        local list = widget:List()
        if list and list[1] == items[1] then
            return
        end
        local selected = widget:Get()
        widget:Update(items, selected)
        widget:Set(selected)
    end)
    if not ok then
        log("relabel %s: %s", widget:Name(), tostring(err))
    end
end

-- Подписи меню и окна на текущем языке. На русском при загрузке меню не трогаем - имена пунктов и так
-- русские; подменяем, только если раньше уже подменили на английские.
local labels_forced = false
local function apply_language()
    if lang ~= "ru" or labels_forced then
        ui_group:ForceLocalization(L.group)
        ui.enabled:ForceLocalization(L.enabled)
        ui.role:ForceLocalization(L.role)
        ui.show:ForceLocalization(L.show)
        ui.count:ForceLocalization(L.count)
        ui.preview:ForceLocalization(L.preview)
        labels_forced = true
    end
    ui.enabled:ToolTip(L.enabled_tip)
    ui.role:ToolTip(L.role_tip)
    ui.preview:ToolTip(L.preview_tip)
    relabel_combo(ui.role, L.role_items)
    relabel_combo(ui.show, L.show_items)
    panel.title = L.title
    for _, line in ipairs(PREVIEW) do
        line.entry = nil -- карточки собираются с текстом плашек
    end
end
apply_language()

-- язык чита сменили в меню: подписи меняются сразу, без перезагрузки скриптов
local every_language_check = Timer.Every(1)
local function follow_language()
    if not every_language_check() then
        return
    end
    local now_lang = cheat_language()
    if now_lang ~= lang then
        lang, L = now_lang, TEXT[now_lang]
        apply_language()
        log("language: %s", lang)
    end
end

log("v%s loaded, language: %s", VERSION, lang)

--#endregion

--#region Analysis

local kinds = {}       -- имя способности -> { magic, disable } из данных игры (не меняются за матч)
local peaks = {}       -- unit name врага -> { magic, disables } - максимум за матч
local hero_names = {}  -- unit name -> имя для панели
local lines = {}       -- готовые строки панели
local role_label = nil
local cover_note = nil      -- «Уже учтено: ...» - что закрыто твоими способностями, предметами и союзниками
local shown_at = {}         -- id показанного совета -> os.clock(), когда он появился
local listed_at = {}        -- id -> когда совет последний раз был в списке (за матч)
local first_list_done = false
local last_profile_key = nil -- герой, роль и источник классификации: их смена - не повод для «новое»
local last_game_time = -math.huge
local last_signature = nil
local last_enemies = nil
local last_enemies_at = -math.huge
local last_error = nil

-- состояние одного матча (кэши способностей, имён и статистики героев - общие)
local function reset_match()
    lines, role_label, peaks, cover_note = {}, nil, {}, nil
    shown_at, listed_at, first_list_done, last_profile_key = {}, {}, false, nil
    last_game_time = -math.huge
    last_signature, last_enemies, last_enemies_at, last_error = nil, nil, -math.huge, nil
end

local function strip_item(name)
    return (name:gsub("^item_", ""))
end

local function hero_label(h)
    local unit = NPC.GetUnitName(h)
    local label = hero_names[unit]
    if not label then
        -- пустое имя от игры склеило бы разных врагов в одного
        local name = safe(Engine.GetDisplayNameByUnitName, unit)
        label = (type(name) == "string" and name ~= "") and name or (unit:gsub("^npc_dota_hero_", ""))
        hero_names[unit] = label
    end
    return label
end

-- настоящий герой, а не иллюзия, копия Arc Warden или клон Meepo
local function is_real_hero(h)
    return not NPC.IsIllusion(h) and not safe(Hero.GetReplicatingOtherHeroModel, h)
end

local function ability_kind(ab, name)
    local kind = kinds[name]
    if kind then
        return kind
    end
    kind = {}
    if not Ability.IsPassive(ab, true) then
        kind.magic = Ability.GetDamageType(ab) == MAGICAL
        -- жёсткий контроль (стан, хекс...) снимается только сильным развеиванием; пробивающий BKB - не наш случай
        kind.disable = Ability.GetDispellableType(ab, true) == STRONG_DISPEL
            and Ability.GetImmunityType(ab, true) ~= PIERCES_BKB
    end
    kinds[name] = kind
    return kind
end

-- active_only исключает рюкзак и тайник: их эффекты не активны, пока предмет не перемещён в инвентарь.
-- Нейтральный предмет в слоте 16 активен; TP (15) не участвует ни в угрозах, ни в защите.
local function item_names(h, out, active_only)
    for slot = 0, LAST_ITEM_SLOT do
        local active_slot = slot <= LAST_ACTIVE_ITEM_SLOT or slot == NEUTRAL_ITEM_SLOT
        if slot ~= TP_SLOT and (not active_only or active_slot) then
            local item = NPC.GetItemByIndex(h, slot)
            local name = item and Ability.GetName(item)
            if name and name ~= "" then
                out[strip_item(name)] = true
            end
        end
    end
    return out
end

-- Угрозы одного врага: угроза -> { weight (<= 1), source (id предмета врага, если угроза от него) }.
-- ref_dps - ожидаемый DPS сильного кора к этой минуте. Второе значение - DPS героя (для лога).
local function enemy_threats(h, ref_dps)
    local threats = {}
    local function add(threat, weight, source)
        local t = threats[threat]
        if not t then
            t = { weight = 0 }
            threats[threat] = t
        end
        t.weight = t.weight + weight
        if source and (not t.source_weight or weight > t.source_weight) then
            t.source, t.source_weight = source, weight
        end
    end

    local magic, disables = 0, 0
    for i = 0, MAX_ABILITY_INDEX do
        local ab = NPC.GetAbilityByIndex(h, i)
        local name = ab and not Ability.IsAttributes(ab) and Ability.GetName(ab)
        if name and name ~= "" then
            for threat, weight in pairs(ABILITY_THREATS[name] or {}) do
                add(threat, weight)
            end
            if not Ability.IsHidden(ab) then
                local kind = ability_kind(ab, name)
                magic = magic + (kind.magic and 1 or 0)
                disables = disables + (kind.disable and 1 or 0)
            end
        end
    end
    -- Invoker и Rubick меняют способности: помним максимум, увиденный у героя за матч
    local unit = NPC.GetUnitName(h)
    local peak = peaks[unit] or {}
    peaks[unit] = peak
    magic, disables = math.max(magic, peak.magic or 0), math.max(disables, peak.disables or 0)
    peak.magic, peak.disables = magic, disables

    -- одна магическая способность у героя, который бьёт с руки (Juggernaut, Lifestealer), - почти не угроза
    if magic >= 2 then
        add("magic", magic / 3)
    elseif magic == 1 then
        add("magic", 0.15)
    end
    if disables > 0 then
        add("disable", disables * 0.5)
    end

    -- урон с руки растёт с каждым предметом на урон и скорость атаки; сглаживаем (~10 с),
    -- чтобы баффы в драке не дёргали список
    local raw_dps = (safe(NPC.GetTrueDamage, h) or 0) * (safe(NPC.GetAttacksPerSecond, h) or 0)
    if raw_dps ~= raw_dps then
        raw_dps = 0 -- NaN от игры не должен ломать расчёт
    end
    raw_dps = math.max(0, math.min(raw_dps, MAX_DPS)) -- и бесконечность или мусор тоже
    local dps = peak.dps and peak.dps + (raw_dps - peak.dps) * 0.1 or raw_dps
    peak.dps = dps
    local relative = dps / ref_dps
    if relative > PHYS_FROM then
        add("phys", math.min(1, (relative - PHYS_FROM) / (PHYS_FULL - PHYS_FROM)))
    end

    for name in pairs(item_names(h, {}, true)) do
        for threat, weight in pairs(ENEMY_ITEMS[name] or {}) do
            add(threat, weight, ENEMY_ITEM_LABELS[name] and name)
        end
    end

    for _, t in pairs(threats) do
        -- предмет - причина, только если дал заметную часть угрозы: Shadow Blade (+0.1) у Slark с высоким
        -- DPS - не причина «урона с руки», Dagon у Nyx с тремя магическими способностями - не причина «магии»
        if t.source and t.source_weight < SOURCE_SHARE * t.weight then
            t.source = nil
        end
        t.weight = math.min(1, t.weight)
    end
    return threats, dps
end

-- стадия игры в минутах: часы матча, но не меньше оценки по среднему уровню врагов
local function game_minutes(me)
    local clock = math.max(0, safe(GameRules.GetDOTATime) or 0) / 60
    local sum, count = 0, 0
    for _, h in pairs(Heroes.GetAll()) do
        if is_real_hero(h) and not Entity.IsSameTeam(h, me) then
            sum, count = sum + (safe(NPC.GetCurrentLevel, h) or 0), count + 1
        end
    end
    local by_level = count > 0 and LEVEL_MINUTES * sum / count - 2 or 0
    return math.max(clock, by_level)
end

local function has_targeted_spell(me)
    for i = 0, MAX_ABILITY_INDEX do
        local ab = NPC.GetAbilityByIndex(me, i)
        if ab and not Ability.IsAttributes(ab) and not Ability.IsHidden(ab) and not Ability.IsPassive(ab, true) then
            local behavior = math.tointeger(Ability.GetBehavior(ab, true)) or 0
            local team = math.tointeger(Ability.GetTargetTeam(ab, true)) or 0
            if (behavior & UNIT_TARGET) ~= 0 and (team & TARGET_ENEMY) ~= 0 then
                return true
            end
        end
    end
    return false
end

-- Что у тебя уже закрывает угрозы: свои способности (MY_ABILITIES), купленные контр-предметы (и их
-- улучшения) и командные предметы союзников (Pipe, Gem, Greaves... работают и на тебя).
-- owned - настоящие предметы героя, team_owned - предметы всей команды.
-- Возвращает угроза -> доля, которую закрыто (до MAX_COVER), и названия источников по пользе -
-- только тех, что закрывают угрозы, которые у врагов есть.
local function my_cover(me, owned, team_owned, threats)
    local keep, usefulness = {}, {} -- угроза -> какая доля остаётся; источник -> польза
    local function add(label, covers, k)
        for threat, x in pairs(covers) do
            local t = threats[threat]
            if t and x > 0 then
                keep[threat] = (keep[threat] or 1) * (1 - x * k)
                usefulness[label] = (usefulness[label] or 0) + x * k * t.total
            end
        end
    end
    for i = 0, MAX_ABILITY_INDEX do
        local ab = NPC.GetAbilityByIndex(me, i)
        -- скрытые (например, от шарда, которого ещё нет) не считаем
        local mine = ab and not Ability.IsHidden(ab) and MY_ABILITIES[Ability.GetName(ab)]
        if mine then
            add(mine.label, mine.covers, Ability.GetLevel(ab) > 0 and 1 or 0.5)
        end
    end
    for name in pairs(owned) do
        local id = COUNTERS[name] and name or BASE_OF[name]
        local c = id and COUNTERS[id]
        if c then
            add(OWNED_LABELS[name] or c.name, c.vs, OWNED_COVER)
        end
    end
    for name in pairs(team_owned) do
        local c = COUNTERS[name]
        if c and c.team and not owned[name] then
            add(L.ally:format(c.name), c.vs, TEAM_COVER)
        end
    end

    local cover = {}
    for threat, left in pairs(keep) do
        cover[threat] = math.min(MAX_COVER, 1 - left)
    end
    local labels = {}
    for label in pairs(usefulness) do
        labels[#labels + 1] = label
    end
    table.sort(labels, function(a, b)
        if usefulness[a] ~= usefulness[b] then
            return usefulness[a] > usefulness[b]
        end
        return a < b
    end)
    return cover, labels
end

local function networth(player)
    local data = player and safe(Player.GetTeamPlayer, player)
    return data and tonumber(data.networth) or 0
end

-- "core" / "support" и откуда это известно (для лога)
local function my_role(me)
    local choice = ui.role:Get()
    if choice == 1 then
        return "core", "вручную"
    elseif choice == 2 then
        return "support", "вручную"
    end

    local local_player = Players.GetLocal()
    local team_data = safe(Player.GetTeamData, local_player)
    local flags = team_data and math.tointeger(team_data.lane_selection_flags) or 0
    local core, support = (flags & CORE_FLAGS) ~= 0, (flags & SUPPORT_FLAGS) ~= 0
    if core ~= support then
        return core and "core" or "support", "поиск матча"
    end

    local clock = safe(GameRules.GetDOTATime) or 0
    if clock >= NETWORTH_ROLE_AFTER then
        local mine, richer = networth(local_player), 0
        for _, p in pairs(Players.GetAll()) do
            local h = p ~= local_player and safe(Player.GetAssignedHero, p)
            if h and Entity.IsSameTeam(h, me) and networth(p) > mine then
                richer = richer + 1
            end
        end
        return richer < 3 and "core" or "support", "нетворс"
    end
    return "core", "по умолчанию"
end

--#region Item fit (статистика покупок героя)

local fit = {} -- hero_id -> { state = "loading" | "ready" | "failed", at, games, rates = { предмет = доля матчей } }

-- все предметы, которые спрашиваем у OpenDota, без повторов и в постоянном порядке (от него зависит ключ кэша)
local FIT_ITEMS = {}
do
    local set = {}
    for id in pairs(COUNTERS) do
        set[id] = true
    end
    for _, names in pairs(FIT_ALIASES) do
        for _, name in ipairs(names) do
            set[name] = true
        end
    end
    for name in pairs(set) do
        FIT_ITEMS[#FIT_ITEMS + 1] = name
    end
    table.sort(FIT_ITEMS)
end

local function fit_sql(hero_id)
    local quoted = {}
    for i, name in ipairs(FIT_ITEMS) do
        quoted[i] = "'" .. name .. "'"
    end
    return ([[
WITH pm AS (
  SELECT pm.match_id, pm.purchase_log FROM player_matches pm JOIN matches m ON m.match_id = pm.match_id
  WHERE pm.hero_id = %d AND m.start_time > extract(epoch from now() - interval '%d days')::int
    AND pm.purchase_log IS NOT NULL
)
SELECT e->>'key' AS item, count(DISTINCT pm.match_id)::int AS games FROM pm, unnest(pm.purchase_log) e
WHERE e->>'key' IN (%s) GROUP BY 1
UNION ALL SELECT '' AS item, count(*)::int AS games FROM pm]]):format(hero_id, FIT_DAYS, table.concat(quoted, ","))
end

-- ответ explorer годится в кэш, только если в нём есть строки (ошибка приходит как {"err": ...})
local function explorer_rows(data)
    return type(data) == "table" and not data.err and type(data.rows) == "table"
end

-- Статистика покупок героя; запрос отправляется один раз (ошибка - повтор через минуту,
-- нет ответа 90 с - тоже повтор).
local function load_fit(hero_id)
    local entry = fit[hero_id]
    if entry then
        local age = os.clock() - entry.at
        if entry.state == "ready" or (entry.state == "loading" and age < FIT_LOADING_TIMEOUT)
            or (entry.state == "failed" and age < FIT_RETRY) then
            return entry
        end
    end
    entry = { state = "loading", at = os.clock() }
    fit[hero_id] = entry
    Http.GetJSON(EXPLORER .. Http.UrlEncode(fit_sql(hero_id)),
        { ttl = FIT_TTL, timeout = 30, accept = explorer_rows }, function(data, err)
        if fit[hero_id] ~= entry then
            return -- пока ждали, запрос уже отправили заново
        end
        local rows = explorer_rows(data) and data.rows
        if not rows then
            entry.state, entry.at = "failed", os.clock()
            log("item fit for hero %d failed: %s", hero_id, tostring(err or (type(data) == "table" and data.err)))
            return
        end
        local games, counts = 0, {}
        for _, row in ipairs(rows) do
            local n = tonumber(row.games) or 0
            if row.item == "" then
                games = n
            elseif type(row.item) == "string" then
                counts[row.item] = n
            end
        end
        local rates, shown = {}, {}
        for item, n in pairs(counts) do
            rates[item] = games > 0 and n / games or 0
            shown[#shown + 1] = ("%s %d%%"):format(item, math.floor(rates[item] * 100 + 0.5))
        end
        table.sort(shown)
        entry.state, entry.games, entry.rates = "ready", games, rates
        log("item fit for hero %d: %d games | %s", hero_id, games, table.concat(shown, ", "))
    end)
    return entry
end

-- Насколько предмет подходит тебе: 0 - нет, 0.5 - иногда, 1 - да.
-- Роль отсекает чужие предметы всегда; дальше решает статистика героя, а без неё - атрибут.
local function fit_of(id, c, me)
    if me.role == "support" then
        if not c.support then
            return 0
        end
    elseif not c.core then
        return 0
    end
    if c.melee and not me.melee then
        return 0
    end
    if me.rates then
        local rate = me.rates[id] or 0
        for _, alias in ipairs(FIT_ALIASES[id] or {}) do
            rate = math.max(rate, me.rates[alias] or 0)
        end
        if rate >= FIT_FULL then
            return 1
        end
        return rate >= FIT_SOME and 0.5 or 0
    end
    if me.role == "support" or c.core == true then
        return 1
    end
    return (type(c.core) == "table" and c.core[me.attr]) and 1 or 0
end

--#endregion

local function join_top(list, limit)
    local shown = {}
    for i = 1, math.min(#list, limit) do
        shown[i] = list[i]
    end
    local text = table.concat(shown, ", ")
    if #list > limit then
        text = text .. (" +%d"):format(#list - limit)
    end
    return text
end

-- Строка панели для рекомендации: против кого и почему. Враги - только те, против кого предмет
-- заметно нужен (вклад не меньше MIN_ENEMY_SHARE от главного), не больше MAX_ENEMIES_SHOWN.
local function describe(rec, threats)
    table.sort(rec.parts, function(a, b) return a.score > b.score end)
    local reasons, per_enemy, unit_of, source_of = {}, {}, {}, {}
    for i, part in ipairs(rec.parts) do
        if i > 2 or part.score < rec.score * 0.25 then
            break
        end
        reasons[#reasons + 1] = part.threat
        for label, e in pairs(threats[part.threat].enemies) do
            per_enemy[label] = (per_enemy[label] or 0) + e.weight * part.eff
            unit_of[label] = e.unit
            -- предмет врага, из-за которого совет (по главной угрозе)
            source_of[label] = source_of[label] or e.source
        end
    end

    local enemies = {}
    for label in pairs(per_enemy) do
        enemies[#enemies + 1] = label
    end
    table.sort(enemies, function(a, b)
        if per_enemy[a] ~= per_enemy[b] then
            return per_enemy[a] > per_enemy[b]
        end
        return a < b
    end)
    local top = enemies[1] and per_enemy[enemies[1]] or 0
    -- sources[i] - id предмета i-го врага (или false), source_labels - названия для подписи
    local labels, units, sources, source_labels, seen = {}, {}, {}, {}, {}
    for _, label in ipairs(enemies) do
        if #labels >= MAX_ENEMIES_SHOWN or per_enemy[label] < top * MIN_ENEMY_SHARE then
            break
        end
        labels[#labels + 1] = label
        units[#units + 1] = unit_of[label]
        local source = source_of[label]
        sources[#sources + 1] = source or false
        local source_label = source and ENEMY_ITEM_LABELS[source]
        if source_label and not seen[source_label] then
            seen[source_label] = true
            source_labels[#source_labels + 1] = source_label
        end
    end

    -- threats - ключи угроз (плашки), items - предметы врагов, из-за которых совет
    return { id = rec.id, item = rec.counter.name, threats = reasons,
        items = #source_labels > 0 and join_top(source_labels, 2) or nil,
        labels = labels, units = units, sources = sources, score = rec.score }
end

-- причина текстом (для лога)
local function reason_text(line)
    local parts = {}
    for i, threat in ipairs(line.threats) do
        parts[i] = L.threats[threat]
    end
    return table.concat(parts, ", ") .. (line.items and " · " .. line.items or "")
end

local function refresh()
    -- новый матч без OnGameEnd (выход из демки, реконнект в другую игру): игровое время пошло заново
    local game_time = safe(GameRules.GetGameTime) or 0
    if game_time + 5 < last_game_time then
        reset_match()
    end
    last_game_time = game_time

    local me = Heroes.GetLocal()
    if not me or safe(GameRules.GetGameState) == POST_GAME then
        lines, role_label = {}, nil
        return
    end

    -- угрозы всех врагов: угроза -> { total, enemies = { [имя] = { weight, source, unit } } }
    local threats, enemy_log = {}, {}
    local team_owned = {}
    local ref_dps = PHYS_REF_BASE + PHYS_REF_PER_MIN * game_minutes(me)
    for _, h in pairs(Heroes.GetAll()) do
        if is_real_hero(h) then
            if Entity.IsSameTeam(h, me) then
                item_names(h, team_owned, true)
            else
                local label, unit = hero_label(h), NPC.GetUnitName(h)
                local enemy, dps = enemy_threats(h, ref_dps)
                local parts = {}
                for threat, t in pairs(enemy) do
                    local total = threats[threat] or { total = 0, enemies = {} }
                    threats[threat] = total
                    total.total = total.total + t.weight
                    total.enemies[label] = { weight = t.weight, source = t.source, unit = unit }
                    if t.weight >= 0.05 then -- «phys 0.0» в логе - шум
                        parts[#parts + 1] = ("%s %.1f"):format(threat, t.weight)
                    end
                end
                table.sort(parts)
                enemy_log[#enemy_log + 1] = ("%s (dps %d): %s"):format(label, math.floor(dps + 0.5),
                    table.concat(parts, ", "))
            end
        end
    end

    -- owned_raw - что у героя есть на самом деле; profile.owned - плюс базовые предметы купленных улучшений
    local owned_raw = item_names(me, {}) -- весь инвентарь: не советуем второй экземпляр уже купленного предмета
    local owned_active = item_names(me, {}, true) -- только активные слоты учитываются как защита
    local profile = {
        attr = ATTRIBUTES[safe(Hero.GetPrimaryAttribute, me)] or "all",
        melee = not NPC.IsRanged(me),
        owned = {},
    }
    for name in pairs(owned_raw) do
        profile.owned[name] = true
    end
    local role_source
    profile.role, role_source = my_role(me)
    role_label = L[profile.role]
    -- какие предметы подходят герою: статистика покупок (пока грузится - по атрибуту)
    local hero_id = math.tointeger(safe(Engine.GetHeroIDByName, NPC.GetUnitName(me)) or 0) or 0
    local fit_entry = hero_id > 0 and load_fit(hero_id) or nil
    local fit_source = "атрибут"
    if fit_entry and fit_entry.state == "ready" and (fit_entry.games or 0) >= FIT_MIN_GAMES then
        profile.rates = fit_entry.rates
        fit_source = ("статистика %d игр"):format(fit_entry.games)
    elseif fit_entry and fit_entry.state == "loading" then
        fit_source = "атрибут, статистика грузится"
    end
    for base, upgrades in pairs(UPGRADES) do
        for _, name in ipairs(upgrades) do
            if owned_raw[name] then -- только по настоящим предметам: без цепочек
                profile.owned[base] = true
            end
        end
    end
    -- снимать Linken's есть смысл, только если у тебя есть заклинание в цель
    if threats.linkens and not has_targeted_spell(me) then
        threats.linkens = nil
    end
    -- что уже закрыто твоими способностями и предметами (Rage у Lifestealer, купленный BKB, Pipe союзника...)
    local cover, cover_labels = my_cover(me, owned_active, team_owned, threats)
    cover_note = #cover_labels > 0 and L.covered:format(join_top(cover_labels, 3)) or nil

    local recs = {}
    for id, c in pairs(COUNTERS) do
        local fit_k = fit_of(id, c, profile)
        if fit_k > 0 and not profile.owned[id] and not (c.team and team_owned[id]) then
            local score, parts = Recommendations.Score(c.vs, threats, fit_k, cover)
            -- Уже показанный совет держится до 80% порога, чтобы не мигать у границы.
            if Recommendations.MeetsThreshold(score, MIN_SCORE, shown_at[id] ~= nil) then
                recs[#recs + 1] = { id = id, counter = c, score = score, parts = parts }
            end
        end
    end
    Recommendations.Sort(recs)

    -- новый совет помечаем «новое» (кроме первого списка в матче). Если список поменялся из-за тебя -
    -- другой герой, роль или загрузилась статистика покупок, - это не новость: считаем список первым.
    local profile_key = ("%s|%s|%s"):format(NPC.GetUnitName(me), profile.role, profile.rates and "stats" or "attr")
    if profile_key ~= last_profile_key then
        last_profile_key, first_list_done = profile_key, false
        shown_at = {} -- не переносим метку «новое» и гистерезис между героями/ролями/источниками fit
    end
    local now = os.clock()
    local new_lines, new_shown, ids = {}, {}, {}
    for i = 1, math.min(#recs, ui.count:Get()) do
        local line = describe(recs[i], threats)
        -- вернувшийся после короткого выпадения совет - не новый
        local recent = listed_at[line.id] and now - listed_at[line.id] < NEW_COOLDOWN
        local since = shown_at[line.id] or ((first_list_done and not recent) and now or -math.huge)
        new_shown[line.id] = since
        listed_at[line.id] = now
        line.new = now - since < NEW_FOR
        new_lines[i] = line
        ids[i] = line.item
    end
    lines, shown_at, first_list_done = new_lines, new_shown, true

    -- лог: список советов - при каждом изменении, угрозы врагов - не чаще раза в минуту
    local signature = ("%s (%s) %s, %s, fit: %s, cover: %s | %s"):format(profile.role, role_source, profile.attr,
        profile.melee and "melee" or "ranged", fit_source, table.concat(cover_labels, ", "), table.concat(ids, ", "))
    local list_changed = signature ~= last_signature
    table.sort(enemy_log)
    local enemies = table.concat(enemy_log, " | ")
    if enemies ~= last_enemies and (list_changed or now - last_enemies_at >= 60) then
        last_enemies, last_enemies_at = enemies, now
        log("enemies: %s", enemies)
    end
    if list_changed then
        last_signature = signature
        local shown = {}
        for i, line in ipairs(lines) do
            shown[i] = ("%s %.1f (%s: %s)"):format(line.item, line.score, reason_text(line),
                table.concat(line.labels, ", "))
        end
        log("%s (%s) %s, %s, fit: %s, cover: %s | %s", profile.role, role_source, profile.attr,
            profile.melee and "melee" or "ranged", fit_source, table.concat(cover_labels, ", "),
            table.concat(shown, " | "))
    end
end

--#endregion

local every_second = Timer.Every(1)

function counter.OnUpdate()
    if not ui.enabled:Get() or not every_second() then
        return
    end
    local ok, err = pcall(refresh)
    if not ok and tostring(err) ~= last_error then
        last_error = tostring(err)
        log("error: %s", last_error)
    end
end

local function visible()
    if Menu.Opened() then
        return true -- при открытом меню панель видна всегда, чтобы её можно было передвинуть
    end
    -- номера - как в show_items: всегда / лавка / лавка или мёртв / только с меню
    local mode = ui.show:Get()
    if mode == 0 then
        return true
    elseif mode == 1 then
        return Engine.IsShopOpen()
    elseif mode == 2 then
        local me = Heroes.GetLocal()
        return Engine.IsShopOpen() or (me ~= nil and not Entity.IsAlive(me))
    end
    return false
end

-- Карточка для панели. Собирается при первом показе строки (строки пересобираются раз в секунду),
-- картинки - из кэша ulib.icons: портреты врагов, на портрете - предмет врага, из-за которого совет.
-- Цветные плашки - угрозы, отметка слева - срочность. Врагов без портрета дописываем в подпись именем.
local function entry_of(line)
    local e = line.entry
    if not e then
        local badges, missing = {}, {}
        for i, unit in ipairs(line.units) do
            local portrait = unit and Icons.HeroPortrait(unit)
            local source = line.sources and line.sources[i]
            badges[i] = { icon = portrait, overlay = source and Icons.Item(source) or nil }
            if not portrait then
                missing[#missing + 1] = line.labels[i]
            end
        end
        local chips = {}
        for i, threat in ipairs(line.threats) do
            chips[i] = { text = L.threats[threat], color = THREAT_COLORS[threat] }
        end
        local subtitle = line.items
        if #missing > 0 then
            local names = table.concat(missing, ", ")
            subtitle = subtitle and subtitle .. " · " .. names or names
        end
        local stripe
        for _, level in ipairs(PRIORITY) do
            if line.score >= level.score then
                stripe = level.color
                break
            end
        end
        e = {
            icon = Icons.Item(line.id), title = line.item, chips = chips, subtitle = subtitle,
            tag = line.new and L.new or nil, stripe = stripe, badges = badges, badge_w = 36, badge_h = 20,
        }
        line.entry = e
    end
    return e
end

local function draw(list, hint, note)
    panel.hint = hint
    panel:Begin()
    if #list == 0 then
        panel:Text(L.empty, Menu.Style("primary_widgets_text"))
    end
    for _, line in ipairs(list) do
        panel:Entry(entry_of(line))
    end
    if note then
        panel:Note(note)
    end
    panel:End()
end

function counter.OnDraw()
    if ui.enabled:Get() and role_label and visible() then
        draw(lines, role_label, cover_note)
    end
end

-- язык чита (и в меню, и в матче); предпросмотр вне матча: как выглядит окно и где оно стоит
function counter.OnFrame()
    follow_language()
    if ui.enabled:Get() and ui.preview:Get() and Menu.Opened() and not Engine.IsInGame() then
        draw(PREVIEW, L.preview_hint, L.preview_note)
    end
end

function counter.OnGameEnd()
    reset_match()
end

return counter
