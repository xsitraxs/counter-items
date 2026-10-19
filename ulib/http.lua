-- ulib/http.lua
-- GET-запросы с JSON-ответом: кэш в памяти и на диске, склейка одинаковых запросов.
--
--   local Http = require("ulib.http")
--   Http.GetJSON("https://api.opendota.com/api/heroes", { ttl = 24 * 3600 }, function(data, err, cached)
--       if data then ... end
--   end)
--   Http.UrlEncode(sql) -- для параметров запроса (например, OpenDota explorer?sql=)
--
-- ttl - сколько секунд ответ считается свежим (0 - без кэша). Если сеть не ответила, callback
-- получает устаревший кэш вместе с ошибкой. При попадании в кэш callback вызывается сразу,
-- ещё внутри GetJSON. Кэш на диске - configs/ulib_http_<хэш url>.json.
-- accept(data) -> bool (необязательно): ответ, который не прошёл проверку (например, {"err": ...}
-- с кодом 200), считается ошибкой и в кэш не попадает.
-- Запрос, на который нет ответа дольше timeout + 15 с, считается потерянным: ожидающие получают
-- ошибку, следующий такой же запрос уходит заново. Ответ устаревшего запроса после повтора игнорируется.

local JSON = require("assets.JSON")
local Store = require("ulib.store")

local Http = {}

local HEADERS <const> = { ["User-Agent"] = "Umbrella/ulib", ["Accept"] = "application/json" }

-- модуль общий для всех скриптов, поэтому кэш и ожидающие запросы тоже общие
local memory = {}  -- полный url -> { url, time, data }
local pending = {} -- полный url -> { at, limit, callbacks, done }
local LOST_AFTER <const> = 15 -- сверх timeout запроса

-- FNV-1a, 32 бита: короткое имя файла кэша по url
local function hash(s)
    local h = 2166136261
    for i = 1, #s do
        h = ((h ~ s:byte(i)) * 16777619) & 0xFFFFFFFF
    end
    return ("%08x"):format(h)
end

local function cached_entry(url, cache_id, use_disk)
    local entry = memory[url]
    if not entry and use_disk then
        entry = Store.Load("http_" .. cache_id, nil)
        if entry and entry.url ~= url then
            entry = nil -- совпал хэш другого url; кэш не должен отдавать чужой ответ
        end
        memory[url] = entry
    end
    return entry
end

-- ошибка в callback одного скрипта не должна ломать остальных ожидающих
local function notify(callbacks, ...)
    for _, cb in ipairs(callbacks) do
        local ok, err = pcall(cb, ...)
        if not ok then
            print("[ulib.http] callback error: " .. tostring(err))
        end
    end
end

-- Кодирование для query-строки: Http.UrlEncode("a b") --> "a%20b".
function Http.UrlEncode(s)
    return (s:gsub("[^%w%-_%.~]", function(c)
        return ("%%%02X"):format(c:byte())
    end))
end

-- callback(data, err, cached): data - разобранный JSON или nil; cached - данные из кэша.
function Http.GetJSON(url, opts, callback)
    opts = opts or {}
    local ttl = opts.ttl or 0
    local cache_id = hash(url) -- только имя файла/идентификатор запроса; в памяти используется полный URL
    local entry = cached_entry(url, cache_id, ttl > 0)
    if entry and ttl > 0 and os.time() - entry.time < ttl then
        notify({ callback }, entry.data, nil, true)
        return
    end

    local timeout = opts.timeout or 15
    local previous = pending[url]
    if previous and os.clock() - previous.at < previous.limit then
        previous.callbacks[#previous.callbacks + 1] = callback
        return
    end

    -- Сначала публикуем новый запрос, затем уведомляем старых ожидающих: callback может
    -- повторно вызвать GetJSON для этого URL и должен присоединиться к новому запросу.
    if previous then
        previous.done = true
    end
    local waiting = { at = os.clock(), limit = timeout + LOST_AFTER, callbacks = { callback } }
    pending[url] = waiting
    if previous then
        notify(previous.callbacks, entry and entry.data, "no response", entry ~= nil)
    end

    local function on_response(res)
        if waiting.responded then
            return -- HTTP-библиотека не должна завершать один запрос дважды
        end
        waiting.responded = true
        if pending[url] ~= waiting then
            return -- запрос уже заменён повтором; его поздний ответ не должен затереть свежий кэш
        end
        pending[url] = nil

        res = type(res) == "table" and res or {}
        local data, err
        if tostring(res.code) == "200" then
            local ok, decoded = pcall(JSON.decode, JSON, res.response)
            if ok then
                data = decoded
            else
                err = "bad json: " .. tostring(decoded)
            end
        else
            err = ("http %s %s"):format(tostring(res.code), tostring(res.error_message or ""))
        end
        if data ~= nil and opts.accept then
            local ok, accepted = pcall(opts.accept, data)
            if not (ok and accepted) then
                err, data = "response rejected", nil
            end
        end

        if data == nil then
            if not waiting.done then
                notify(waiting.callbacks, entry and entry.data, err, entry ~= nil)
            end
            return
        end
        memory[url] = { url = url, time = os.time(), data = data }
        if ttl > 0 then
            local ok, save_err = pcall(Store.Save, "http_" .. cache_id, memory[url])
            if not ok then
                print("[ulib.http] cache not saved: " .. tostring(save_err))
            end
        end
        -- в кэш попадают только успешные ответы актуального запроса
        if not waiting.done then
            notify(waiting.callbacks, data, nil, false)
        end
    end

    local request_ok, sent = pcall(HTTP.Request, "GET", url, { headers = HEADERS, timeout = timeout }, on_response, cache_id)
    if (not request_ok or not sent) and not waiting.responded then
        waiting.responded = true
        if pending[url] == waiting then
            pending[url] = nil
        end
        local err = request_ok and "request was not sent" or ("request failed: " .. tostring(sent))
        notify(waiting.callbacks, entry and entry.data, err, entry ~= nil)
    end
end

return Http
