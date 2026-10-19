-- ulib/icons.lua
-- Иконки Dota из файлов игры (panorama/images/...): каждая загружается один раз, дальше - из кэша.
--
--   local Icons = require("ulib.icons")
--   Icons.Item("black_king_bar")       -- можно и "item_black_king_bar"; пропорции 88:64
--   Icons.Hero("npc_dota_hero_lion")   -- маленькая квадратная иконка героя (как на миникарте)
--   Icons.HeroPortrait("npc_dota_hero_lion") -- портрет, как в таблице счёта; пропорции 128:72
--   Icons.Spell("lion_voodoo")
--   Icons.Image("panorama/images/...") -- любой путь
-- Возвращают handle для Render.Image / Panel:Entry или nil, если картинку загрузить не удалось.
-- Предметы, которые понадобятся точно, лучше загрузить на верхнем уровне скрипта, а не в первом кадре.

local Icons = {}

-- модуль общий для всех скриптов, поэтому кэш тоже общий
local cache = {}     -- путь -> handle | false
local retry_at = {}  -- путь -> время следующей попытки после ошибки
local RETRY_AFTER <const> = 5 -- не вызываем загрузчик каждый кадр при временной ошибке

function Icons.Image(path)
    local handle = cache[path]
    if handle and handle ~= false then
        return handle
    end
    if handle == false and os.clock() < (retry_at[path] or 0) then
        return nil
    end

    local ok, result = pcall(Render.LoadImage, path)
    if ok and result and result ~= 0 then
        cache[path], retry_at[path] = result, nil
        return result
    end

    cache[path], retry_at[path] = false, os.clock() + RETRY_AFTER
    return nil
end

function Icons.Item(name)
    return Icons.Image("panorama/images/items/" .. name:gsub("^item_", "") .. "_png.vtex_c")
end

function Icons.Hero(unit_name)
    return Icons.Image("panorama/images/heroes/icons/" .. unit_name .. "_png.vtex_c")
end

function Icons.HeroPortrait(unit_name)
    return Icons.Image("panorama/images/heroes/" .. unit_name .. "_png.vtex_c")
end

function Icons.Spell(ability_name)
    return Icons.Image("panorama/images/spellicons/" .. ability_name .. "_png.vtex_c")
end

return Icons
