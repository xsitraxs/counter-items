-- ulib/threats.lua
-- Explicit threat classification shared by the game script and its offline tests.

local Threats = {}

-- Ability names with hard-control effects (stun, hex, sleep, fear, taunt, or banish).
-- Roots, silences, disarms, slows, and effects that merely happen to be strongly dispellable
-- are intentionally not included. Update this allowlist against current ability data.
local HARD_DISABLE_ABILITIES <const> = {
    alchemist_unstable_concoction = true,
    alchemist_unstable_concoction_throw = true, -- alternate cast ability name in some game states
    ancient_apparition_cold_feet = true,
    antimage_mana_void = true,
    axe_berserkers_call = true,
    bane_fiends_grip = true,
    bane_nightmare = true,
    batrider_flaming_lasso = true,
    beastmaster_primal_roar = true,
    bounty_hunter_shuriken_toss = true,
    brewmaster_earth_hurl_boulder = true,
    centaur_hoof_stomp = true,
    chaos_knight_chaos_bolt = true,
    dark_willow_cursed_crown = true,
    dark_willow_terrorize = true,
    dawnbreaker_solar_guardian = true,
    dawnbreaker_starbreaker = true,
    dragon_knight_dragon_tail = true,
    earth_spirit_boulder_smash = true,
    earth_spirit_rolling_boulder = true,
    earthshaker_aftershock = true,
    earthshaker_echo_slam = true,
    earthshaker_fissure = true,
    elder_titan_echo_stomp = true,
    elder_titan_echo_stomp_spirit = true,
    enigma_black_hole = true,
    enigma_malefice = true,
    faceless_void_chronosphere = true,
    faceless_void_time_lock = true,
    grimstroke_ink_creature = true,
    gyrocopter_homing_missile = true,
    hoodwink_bushwhack = true,
    invoker_cold_snap = true,
    invoker_tornado = true,
    jakiro_ice_path = true,
    kez_talon_toss = true,
    kunkka_torrent = true,
    legion_commander_duel = true,
    leshrac_split_earth = true,
    lina_light_strike_array = true,
    lion_impale = true,
    lion_voodoo = true,
    lone_druid_savage_roar = true,
    luna_lucent_beam = true,
    magnataur_reverse_polarity = true,
    marci_companion_run = true,
    marci_grapple = true,
    mars_spear = true,
    medusa_stone_gaze = true,
    mirana_arrow = true,
    monkey_king_boundless_strike = true,
    morphling_adaptive_strike = true,
    morphling_adaptive_strike_str = true,
    muerta_dead_shot = true,
    naga_siren_song_of_the_siren = true,
    necrolyte_reapers_scythe = true,
    nyx_assassin_impale = true,
    obsidian_destroyer_astral_imprisonment = true,
    ogre_magi_fireblast = true,
    ogre_magi_unrefined_fireblast = true,
    pangolier_gyroshell = true,
    phoenix_supernova = true,
    primal_beast_onslaught = true,
    primal_beast_pulverize = true,
    pudge_dismember = true,
    pudge_meat_hook = true,
    rattletrap_battery_assault = true,
    rattletrap_hookshot = true,
    ringmaster_tame_the_beasts = true,
    ringmaster_wheel = true,
    rubick_telekinesis = true,
    sandking_burrowstrike = true,
    shadow_demon_disruption = true,
    shadow_shaman_shackles = true,
    shadow_shaman_voodoo = true,
    skeleton_king_hellfire_blast = true,
    slardar_bash = true,
    slardar_slithereen_crush = true,
    snapfire_firesnap_cookie = true,
    spirit_breaker_charge_of_darkness = true,
    spirit_breaker_greater_bash = true,
    spirit_breaker_nether_strike = true,
    storm_spirit_electric_vortex = true,
    sven_storm_bolt = true,
    techies_suicide = true,
    tidehunter_arm_of_the_deep = true,
    tidehunter_ravage = true,
    tiny_avalanche = true,
    tusk_snowball = true,
    tusk_walrus_punch = true,
    vengefulspirit_magic_missile = true,
    visage_summon_familiars_stone_form = true,
    warlock_rain_of_chaos = true,
    windrunner_shackleshot = true,
    winter_wyvern_winters_curse = true,
    witch_doctor_paralyzing_cask = true,
    zuus_lightning_bolt = true,
}

function Threats.IsHardDisable(ability_name)
    return HARD_DISABLE_ABILITIES[ability_name] == true
end

-- A hard disable is not useful as a BKB threat when the ability pierces spell immunity.
function Threats.CountsAsHardDisable(ability_name, immunity_type, pierces_bkb_type)
    return Threats.IsHardDisable(ability_name)
        and immunity_type ~= nil
        and immunity_type ~= pierces_bkb_type
end

function Threats.ClassifyAbility(ability_name, damage_type, immunity_type, magical_type, pierces_bkb_type)
    return {
        magic = damage_type == magical_type,
        disable = Threats.CountsAsHardDisable(ability_name, immunity_type, pierces_bkb_type),
    }
end

local function nonnegative_number(value, fallback)
    value = tonumber(value)
    if value == nil or value ~= value or value < 0 then
        return fallback
    end
    return value
end

-- Average the API's minimum/maximum attack damage and convert to DPS. Invalid values fall back
-- conservatively; max_dps caps pathological game/API values.
function Threats.EstimatePhysicalDps(min_damage, max_damage, attacks_per_second, max_dps)
    local low = nonnegative_number(min_damage, 0)
    local high = nonnegative_number(max_damage, low)
    if high < low then
        low, high = high, low
    end
    local attacks = nonnegative_number(attacks_per_second, 0)
    local cap = nonnegative_number(max_dps, math.huge)
    local average_damage = low == high and low or low + (high - low) * 0.5
    local dps = average_damage * attacks
    if dps ~= dps or dps < 0 then
        return 0
    end
    return math.min(dps, cap)
end

return Threats
