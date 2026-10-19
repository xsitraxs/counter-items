-- Run from the repository root with a Lua 5.4 interpreter: lua tests/run.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local passed = 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if not ok then
        error(("FAIL: %s\n%s"):format(name, tostring(err)), 0)
    end
    passed = passed + 1
    print("ok - " .. name)
end

local function approx(actual, expected, epsilon)
    assert(math.abs(actual - expected) <= (epsilon or 1e-9),
        ("expected %.12f, got %.12f"):format(expected, actual))
end

local Timer = require("ulib.timer")
local Recommendations = require("ulib.recommendations")
local Threats = require("ulib.threats")

test("Timer.Every respects its interval and fires immediately", function()
    local now = 10
    local every = Timer.Every(1, function() return now end)
    assert(every())
    assert(not every())
    now = 10.99
    assert(not every())
    now = 11
    assert(every())
end)

test("Timer.Every resets when the clock moves backwards", function()
    local now = 20
    local every = Timer.Every(2, function() return now end)
    assert(every())
    now = 21
    assert(not every())
    now = 0
    assert(every())
end)

test("Timer.Format handles minutes, fractions, and negative values", function()
    assert(Timer.Format(754.3) == "12:34")
    assert(Timer.Format(-35.9) == "-0:35")
end)

test("recommendation score combines threat, fit, and uncovered fraction", function()
    local score, parts = Recommendations.Score(
        { magic = 0.5, disable = 0.25, ignored = 1 },
        { magic = { total = 2 }, disable = { total = 1 } },
        0.5,
        { magic = 0.2 }
    )
    approx(score, 0.525)
    assert(#parts == 2)
    local by_threat = {}
    for _, part in ipairs(parts) do
        by_threat[part.threat] = part
    end
    approx(by_threat.magic.eff, 0.2)
    approx(by_threat.magic.score, 0.4)
    approx(by_threat.disable.eff, 0.125)
    approx(by_threat.disable.score, 0.125)
end)

test("recommendation score is empty when the item does not fit", function()
    local score, parts = Recommendations.Score({ magic = 1 }, { magic = { total = 3 } }, 0, {})
    assert(score == 0)
    assert(#parts == 0)
end)

test("recommendation threshold applies hysteresis only to displayed items", function()
    assert(Recommendations.MeetsThreshold(0.5, 0.5, false))
    assert(not Recommendations.MeetsThreshold(0.49, 0.5, false))
    assert(Recommendations.MeetsThreshold(0.4, 0.5, true))
    assert(not Recommendations.MeetsThreshold(0.39, 0.5, true))
end)

test("recommendations sort by score and then id", function()
    local recommendations = {
        { id = "z", score = 1 },
        { id = "b", score = 2 },
        { id = "a", score = 2 },
    }
    assert(Recommendations.Sort(recommendations) == recommendations)
    assert(recommendations[1].id == "a")
    assert(recommendations[2].id == "b")
    assert(recommendations[3].id == "z")
end)

test("hard-control classification distinguishes stuns and hexes from roots and dispels", function()
    local stun = Threats.ClassifyAbility("sven_storm_bolt", 0, 0, 2, 3)
    local hex = Threats.ClassifyAbility("lion_voodoo", 0, 0, 2, 3)
    local root = Threats.ClassifyAbility("crystal_maiden_frostbite", 0, 1, 2, 3)
    local dispellable_silence = Threats.ClassifyAbility("drow_ranger_wave_of_silence", 0, 1, 2, 3)
    -- Planar Pocket has strong-dispel metadata but grants magic resistance, not hard control.
    local strong_dispellable_non_control = Threats.ClassifyAbility("spirit_breaker_planar_pocket", 0, 0, 2, 3)
    local bkb_piercing_stun = Threats.ClassifyAbility("axe_berserkers_call", 0, 3, 2, 3)
    assert(stun.disable, "stuns should be classified from the explicit ability list")
    assert(hex.disable, "hexes should be classified from the explicit ability list")
    assert(not root.disable, "a root is not automatically a hard disable")
    assert(not dispellable_silence.disable, "dispel type alone must not imply hard control")
    assert(not strong_dispellable_non_control.disable,
        "strong-dispel metadata must not turn a non-control ability into hard control")
    assert(not bkb_piercing_stun.disable, "BKB-piercing control belongs to the separate pierce threat")
end)

test("physical DPS averages minimum and maximum attack damage", function()
    approx(Threats.EstimatePhysicalDps(100, 200, 1.5, 5000), 225)
    approx(Threats.EstimatePhysicalDps(200, 100, 1.5, 5000), 225)
    approx(Threats.EstimatePhysicalDps(100, nil, 2, 5000), 200)
    approx(Threats.EstimatePhysicalDps(-10, 50, 2, 5000), 50)
    approx(Threats.EstimatePhysicalDps(100, 200, 100, 5000), 5000)
end)

-- Fake JSON and filesystem keep persistence tests hermetic and exercise Windows-style rename semantics.
local encoded_values, next_encoded_id = {}, 0
local JSON = {}
function JSON:encode(value)
    next_encoded_id = next_encoded_id + 1
    encoded_values[next_encoded_id] = value
    return "FAKEJSON:" .. next_encoded_id
end
function JSON:decode(text)
    local id = type(text) == "string" and text:match("^FAKEJSON:(%d+)$")
    local value = id and encoded_values[tonumber(id)]
    if not value then
        error("invalid test JSON")
    end
    return value
end
package.preload["assets.JSON"] = function() return JSON end
package.loaded["ulib.store"] = nil

local files = {}
local fail_tmp_install = false
local fail_write = false
local fake_clock = 0
local fail_backup_restore = false
local fake_io = {}
function fake_io.open(path, mode)
    if mode == "rb" then
        if files[path] == nil then
            return nil, "file not found"
        end
        return {
            read = function() return files[path] end,
            close = function() return true end,
        }
    elseif mode == "wb" then
        local buffer = ""
        return {
            write = function(_, text)
                if fail_write then
                    return nil, "injected write failure"
                end
                buffer = buffer .. text
                return true
            end,
            flush = function() return true end,
            close = function()
                files[path] = buffer
                return true
            end,
        }
    end
    return nil, "unsupported mode"
end

local fake_os = {
    clock = function() return fake_clock end,
    time = function() return 1000 end,
}
function fake_os.remove(path)
    if files[path] == nil then
        return nil, "file not found"
    end
    files[path] = nil
    return true
end
function fake_os.rename(source, destination)
    if fail_backup_restore and source:sub(-4) == ".bak" and destination:sub(-5) == ".json" then
        return nil, "injected backup restore failure"
    end
    if fail_tmp_install and source:sub(-4) == ".tmp" and destination:sub(-5) == ".json" then
        return nil, "injected install failure"
    end
    if files[source] == nil then
        return nil, "source not found"
    end
    if files[destination] ~= nil then
        return nil, "destination exists"
    end
    files[destination] = files[source]
    files[source] = nil
    return true
end

_G.Engine = { GetCheatDirectory = function() return "sandbox" end }
_G.io = fake_io
_G.os = fake_os
_G.print = print

local Store = require("ulib.store")
local target = "sandbox\\configs\\ulib_fixture.json"
local backup = target .. ".bak"
local temp = target .. ".tmp"

test("Store.Save replaces an existing file without losing the old file first", function()
    files[target] = "old-data"
    files[backup] = "stale-backup"
    local payload = { answer = 42 }
    Store.Save("fixture", payload)
    assert(files[target] == "FAKEJSON:1")
    assert(files[backup] == nil)
    assert(files[temp] == nil)
    assert(Store.Load("fixture", {}) == payload)
end)

test("Store.Save preserves the original if writing the temporary file fails", function()
    files[target] = "last-good-data"
    fail_write = true
    local ok = pcall(Store.Save, "fixture", { answer = 7 })
    fail_write = false
    assert(not ok, "save should report the injected write failure")
    assert(files[target] == "last-good-data")
    assert(files[temp] == nil)
end)

test("Store.Save restores the original if installing the new file fails", function()
    files[target] = "previous-good-data"
    fail_tmp_install = true
    local ok = pcall(Store.Save, "fixture", { answer = 99 })
    fail_tmp_install = false
    assert(not ok, "save should report the injected failure")
    assert(files[target] == "previous-good-data")
    assert(files[backup] == nil)
    assert(files[temp] == nil)
end)

test("Store.Load recovers data when both install and immediate restore fail", function()
    local previous = { previous = "survives" }
    files[target] = JSON:encode(previous)
    fail_tmp_install = true
    fail_backup_restore = true
    local ok = pcall(Store.Save, "fixture", { replacement = true })
    fail_tmp_install = false
    fail_backup_restore = false
    assert(not ok, "save should report that the replacement and immediate restore failed")
    assert(files[target] == nil)
    assert(files[backup] ~= nil, "the old file should remain in the backup")
    assert(files[temp] == nil)
    assert(Store.Load("fixture", {}) == previous)
    assert(files[target] ~= nil and files[backup] == nil)
end)

test("Store.Load restores a backup left by an interrupted save", function()
    files[target] = nil
    local recovered = { recovered = true }
    local backup_data = JSON:encode(recovered)
    files[backup] = backup_data
    assert(Store.Load("fixture", {}) == recovered)
    assert(files[target] == backup_data)
    assert(files[backup] == nil)
end)

test("Store.Load replaces a damaged primary with a valid backup", function()
    local recovered = { recovered = "backup" }
    local backup_data = JSON:encode(recovered)
    files[target] = "not-json"
    files[backup] = backup_data
    assert(Store.Load("fixture", {}) == recovered)
    assert(files[target] == backup_data)
    assert(files[backup] == nil)
    assert(files[target .. ".corrupt"] == nil)
    local next_value = { after_recovery = true }
    Store.Save("fixture", next_value)
    assert(Store.Load("fixture", {}) == next_value)
end)

local http_requests = {}
local http_request_handler
_G.HTTP = {
    Request = function(method, url, options, callback, key)
        local request = { method = method, url = url, options = options, callback = callback, key = key }
        http_requests[#http_requests + 1] = request
        if http_request_handler then
            return http_request_handler(request)
        end
        return true
    end,
}
local Http = require("ulib.http")

test("Http.UrlEncode escapes query-string characters", function()
    assert(Http.UrlEncode("a b&c") == "a%20b%26c")
end)

test("Http.GetJSON coalesces simultaneous requests", function()
    local before = #http_requests
    local first, second
    local url = "https://example.test/coalesced"
    Http.GetJSON(url, { ttl = 0 }, function(data, err, cached)
        first = { data = data, err = err, cached = cached }
    end)
    Http.GetJSON(url, { ttl = 0 }, function(data, err, cached)
        second = { data = data, err = err, cached = cached }
    end)
    assert(#http_requests == before + 1)
    local payload = { ok = true }
    http_requests[#http_requests].callback({ code = 200, response = JSON:encode(payload) })
    assert(first and first.data == payload and first.err == nil and first.cached == false)
    assert(second and second.data == payload and second.err == nil and second.cached == false)
end)

test("Http.GetJSON keeps requests with different accept validators separate", function()
    local before = #http_requests
    local url = "https://example.test/different-accept"
    local unvalidated, validated
    Http.GetJSON(url, { ttl = 0 }, function(data, err)
        unvalidated = { data = data, err = err }
    end)
    Http.GetJSON(url, { ttl = 0, accept = function(data)
        return type(data) == "table" and data.accepted == true
    end }, function(data, err)
        validated = { data = data, err = err }
    end)
    assert(#http_requests == before + 2,
        "requests with different response validators must not share a pending request")

    local raw_data = { accepted = false }
    http_requests[before + 1].callback({ code = 200, response = JSON:encode(raw_data) })
    assert(unvalidated.data == raw_data and unvalidated.err == nil)

    local accepted_data = { accepted = true }
    http_requests[before + 2].callback({ code = 200, response = JSON:encode(accepted_data) })
    assert(validated.data == accepted_data and validated.err == nil)
end)

test("Http.GetJSON clears failed requests and ignores duplicate responses", function()
    local before = #http_requests
    local url = "https://example.test/send-failure"
    local failed_calls, failed_error = 0, nil
    http_request_handler = function() return false end
    Http.GetJSON(url, { ttl = 0 }, function(data, err)
        failed_calls = failed_calls + 1
        failed_error = err
    end)
    http_request_handler = nil
    assert(failed_calls == 1 and failed_error == "request was not sent")

    local success_calls, success_data = 0, nil
    Http.GetJSON(url, { ttl = 0 }, function(data, err)
        success_calls = success_calls + 1
        assert(err == nil)
        success_data = data
    end)
    assert(#http_requests == before + 2, "failed request must not leave a pending entry")
    local payload = { ok = "retry" }
    local response = { code = 200, response = JSON:encode(payload) }
    http_requests[#http_requests].callback(response)
    http_requests[#http_requests].callback(response)
    assert(success_calls == 1 and success_data == payload)
end)

test("Http.GetJSON revalidates in-memory cache entries with accept", function()
    local before = #http_requests
    local url = "https://example.test/cache-accept-memory"
    local invalid = { err = "stale cached error" }
    Http.GetJSON(url, { ttl = 100 }, function(data, err)
        assert(data == invalid and err == nil)
    end)
    http_requests[#http_requests].callback({ code = 200, response = JSON:encode(invalid) })

    local accepted_result
    Http.GetJSON(url, { ttl = 100, accept = function(data)
        return type(data) == "table" and type(data.rows) == "table"
    end }, function(data, err, cached)
        accepted_result = { data = data, err = err, cached = cached }
    end)
    assert(#http_requests == before + 2, "invalid memory cache should trigger a fresh request")
    local valid = { rows = {} }
    http_requests[#http_requests].callback({ code = 200, response = JSON:encode(valid) })
    assert(accepted_result.data == valid and accepted_result.err == nil and accepted_result.cached == false)
end)

test("Http.GetJSON revalidates disk cache entries with accept", function()
    local before = #http_requests
    local url = "https://example.test/cache-accept-disk"
    local invalid = { err = "stale disk error" }
    Http.GetJSON(url, { ttl = 100 }, function(data, err)
        assert(data == invalid and err == nil)
    end)
    http_requests[#http_requests].callback({ code = 200, response = JSON:encode(invalid) })

    local loaded_http = package.loaded["ulib.http"]
    package.loaded["ulib.http"] = nil
    local cold_http = require("ulib.http")
    local accepted_result
    cold_http.GetJSON(url, { ttl = 100, accept = function(data)
        return type(data) == "table" and type(data.rows) == "table"
    end }, function(data, err, cached)
        accepted_result = { data = data, err = err, cached = cached }
    end)
    assert(#http_requests == before + 2, "invalid disk cache should trigger a fresh request")
    local valid = { rows = {} }
    http_requests[#http_requests].callback({ code = 200, response = JSON:encode(valid) })
    assert(accepted_result.data == valid and accepted_result.err == nil and accepted_result.cached == false)
    package.loaded["ulib.http"] = loaded_http
end)

test("Http.GetJSON reports request exceptions and allows retry", function()
    local before = #http_requests
    local url = "https://example.test/request-exception"
    local calls, err = 0, nil
    http_request_handler = function() error("injected request exception") end
    Http.GetJSON(url, { ttl = 0 }, function(data, request_err)
        calls = calls + 1
        err = request_err
    end)
    http_request_handler = nil
    assert(calls == 1 and err:find("request failed:", 1, true))

    Http.GetJSON(url, { ttl = 0 }, function() end)
    assert(#http_requests == before + 2, "exception must not leave a pending entry")
    http_requests[#http_requests].callback({ code = 200, response = JSON:encode({ ok = true }) })
end)

test("Http.GetJSON timeout callbacks can retry the same URL reentrantly", function()
    local before = #http_requests
    local url = "https://example.test/reentrant-timeout"
    local expired_notices, outer_result, retry_result = 0, nil, nil
    fake_clock = 0
    Http.GetJSON(url, { ttl = 0, timeout = 1 }, function(data, err)
        if err == "no response" then
            expired_notices = expired_notices + 1
            Http.GetJSON(url, { ttl = 0, timeout = 1 }, function(retry_data, retry_err)
                retry_result = { data = retry_data, err = retry_err }
            end)
        end
    end)
    local old_request = http_requests[#http_requests]

    fake_clock = 17
    Http.GetJSON(url, { ttl = 0, timeout = 1 }, function(data, err)
        outer_result = { data = data, err = err }
    end)
    local retry_request = http_requests[#http_requests]
    assert(expired_notices == 1)
    assert(#http_requests == before + 2, "reentrant retry must join the pending request")

    local payload = { ok = "reentrant retry" }
    retry_request.callback({ code = 200, response = JSON:encode(payload) })
    assert(outer_result.data == payload and outer_result.err == nil)
    assert(retry_result.data == payload and retry_result.err == nil)
    old_request.callback({ code = 200, response = JSON:encode({ ok = "late" }) })
    assert(expired_notices == 1)
end)

test("Http.GetJSON keeps colliding URL hashes isolated", function()
    local before = #http_requests
    local url_a = "https://collision.test/NXVbZpMiGj"
    local url_b = "https://collision.test/tIUJipCoCE"
    local data_a, data_b
    Http.GetJSON(url_a, { ttl = 100 }, function(data) data_a = data end)
    Http.GetJSON(url_b, { ttl = 100 }, function(data) data_b = data end)
    assert(#http_requests == before + 2, "different URLs must not share a pending request")
    assert(http_requests[before + 1].key == http_requests[before + 2].key,
        "fixture URLs should exercise the same 32-bit disk-cache hash")

    local response_a = { value = "A" }
    local response_b = { value = "B" }
    http_requests[before + 1].callback({ code = 200, response = JSON:encode(response_a) })
    http_requests[before + 2].callback({ code = 200, response = JSON:encode(response_b) })
    assert(data_a == response_a and data_b == response_b)

    local cached_a, cached_b
    Http.GetJSON(url_a, { ttl = 100 }, function(data, err, cached)
        cached_a = { data = data, err = err, cached = cached }
    end)
    Http.GetJSON(url_b, { ttl = 100 }, function(data, err, cached)
        cached_b = { data = data, err = err, cached = cached }
    end)
    assert(cached_a.data == response_a and cached_a.cached == true)
    assert(cached_b.data == response_b and cached_b.cached == true)
    assert(#http_requests == before + 2, "each URL should keep its own in-memory cache entry")

    -- Simulate a restart: only the last response for this colliding disk filename remains.
    local loaded_http = package.loaded["ulib.http"]
    package.loaded["ulib.http"] = nil
    local cold_http = require("ulib.http")
    local request_before_cold = #http_requests
    local cold_a, cold_b
    cold_http.GetJSON(url_a, { ttl = 100 }, function(data, err)
        cold_a = { data = data, err = err }
    end)
    cold_http.GetJSON(url_b, { ttl = 100 }, function(data, err, cached)
        cold_b = { data = data, err = err, cached = cached }
    end)
    assert(#http_requests == request_before_cold + 1,
        "a colliding disk entry must be rejected for the other URL")
    assert(cold_b.data == response_b and cold_b.cached == true)
    local response_a_after_restart = { value = "A after restart" }
    http_requests[#http_requests].callback({ code = 200, response = JSON:encode(response_a_after_restart) })
    assert(cold_a.data == response_a_after_restart and cold_a.err == nil)
    package.loaded["ulib.http"] = loaded_http
end)

test("Http.GetJSON ignores a late response after a retry", function()
    local before = #http_requests
    local url = "https://example.test/late-response"
    local old_calls, old_error = 0, nil
    local fresh_data, fresh_cached
    fake_clock = 0
    Http.GetJSON(url, { ttl = 100, timeout = 1 }, function(data, err)
        old_calls = old_calls + 1
        old_error = err
    end)
    local old_request = http_requests[#http_requests]

    fake_clock = 17 -- timeout plus the 15-second lost-request grace period
    Http.GetJSON(url, { ttl = 100, timeout = 1 }, function(data, err)
        fresh_data = data
        old_error = old_error or err
    end)
    local new_request = http_requests[#http_requests]
    assert(#http_requests == before + 2)
    assert(old_calls == 1 and old_error == "no response")

    local fresh = { version = 2 }
    new_request.callback({ code = 200, response = JSON:encode(fresh) })
    assert(fresh_data == fresh)

    old_request.callback({ code = 200, response = JSON:encode({ version = 1 }) })
    assert(old_calls == 1)
    Http.GetJSON(url, { ttl = 100 }, function(data, err, cached)
        assert(err == nil)
        fresh_data, fresh_cached = data, cached
    end)
    assert(fresh_data == fresh and fresh_cached == true)
    assert(#http_requests == before + 2)
end)

test("counter-item script loads with the host API and exports callbacks", function()
    local function color(r, g, b, a)
        return { r = r, g = g, b = b, a = a or 255 }
    end
    _G.Color = color
    local rendered_texts = {}
    local function rendered_has(text)
        for _, rendered in ipairs(rendered_texts) do
            if rendered == text then
                return true
            end
        end
        return false
    end
    _G.Enum = {
        ButtonCode = { KEY_MOUSE1 = 119 },
        DrawFlags = { ShadowCutOutShapeBackground = 512 },
        FontCreate = { FONTFLAG_ANTIALIAS = 16 },
        DamageTypes = { DAMAGE_TYPE_MAGICAL = 2 },
        ImmunityTypes = { SPELL_IMMUNITY_ENEMIES_YES = 3 },
        DispellableTypes = { SPELL_DISPELLABLE_YES_STRONG = 1 },
        AbilityBehavior = { DOTA_ABILITY_BEHAVIOR_UNIT_TARGET = 8 },
        TargetTeam = { DOTA_UNIT_TARGET_TEAM_ENEMY = 2 },
        GameState = { DOTA_GAMERULES_STATE_POST_GAME = 6 },
        Attributes = {
            DOTA_ATTRIBUTE_STRENGTH = 0,
            DOTA_ATTRIBUTE_AGILITY = 1,
            DOTA_ATTRIBUTE_INTELLECT = 2,
            DOTA_ATTRIBUTE_ALL = 3,
        },
    }
    _G.Vec2 = function(x, y) return { x = x, y = y } end
    _G.Render = {
        LoadImage = function(path) return path end,
        LoadFont = function(name, _, weight) return name .. "@" .. tostring(weight) end,
        TextSize = function(_, size, text) return Vec2(#text * size * 0.5, size * 1.2) end,
        ScreenSize = function() return Vec2(1920, 1080) end,
        FilledRect = function() end,
        Image = function() end,
        Line = function() end,
        Rect = function() end,
        Shadow = function() end,
        Text = function(_, _, text) rendered_texts[#rendered_texts + 1] = text end,
    }
    _G.Config = { ReadInt = function(_, _, default) return default end, WriteInt = function() end }
    _G.Localizer = { Get = function() return "Enable" end }
    _G.Menu = {
        Opened = function() return false end,
        Scale = function() return 100 end,
        Pos = function() return Vec2(10, 10) end,
        Size = function() return Vec2(300, 500) end,
        Style = function() return color(70, 80, 90, 220) end,
        Create = function()
            local group = {}
            function group:Create() return self end
            function group:ForceLocalization() end
            function group:Switch(_, default)
                local value = default
                return {
                    Get = function() return value end,
                    Set = function(_, next_value) value = next_value end,
                    ForceLocalization = function() end,
                    ToolTip = function() end,
                }
            end
            local function combo(_, _, items, default)
                local value = default
                local list = items
                return {
                    Get = function() return value end,
                    Set = function(_, next_value) value = next_value end,
                    List = function() return list end,
                    Update = function(_, next_items) list = next_items end,
                    ForceLocalization = function() end,
                    ToolTip = function() end,
                }
            end
            group.Combo = combo
            group.Slider = function(_, _, _, _, default)
                return {
                    Get = function() return default end,
                    ForceLocalization = function() end,
                    ToolTip = function() end,
                }
            end
            return group
        end,
    }
    _G.Input = {
        GetCursorPos = function() return 0, 0 end,
        IsCursorInRect = function() return false end,
        IsKeyDown = function() return false end,
    }

    _G.GameRules = { GetGameTime = function() return 0 end, GetGameState = function() return 0 end }
    _G.Heroes = { GetLocal = function() return nil end }
    local counter = dofile("counter-item.lua")
    assert(type(counter) == "table")
    assert(type(counter.OnUpdate) == "function")
    assert(type(counter.OnDraw) == "function")
    assert(type(counter.OnFrame) == "function")
    assert(type(counter.OnGameEnd) == "function")
    counter.OnFrame()
    counter.OnUpdate()
    counter.OnDraw()

    local local_hero = { team = 2, unit = "npc_dota_hero_drow_ranger", items = {} }
    local team_ally = { team = 2, unit = "npc_dota_hero_crystal_maiden", items = {} }
    local enemy = {
        team = 3,
        unit = "npc_dota_hero_phantom_assassin",
        items = {},
    }
    _G.GameRules = {
        GetGameTime = function() return 0 end,
        GetDOTATime = function() return 0 end,
        GetGameState = function() return 0 end,
    }
    _G.Heroes = {
        GetLocal = function() return local_hero end,
        GetAll = function() return { local_hero, team_ally, enemy } end,
    }
    _G.Hero = {
        GetReplicatingOtherHeroModel = function() return nil end,
        GetPrimaryAttribute = function() return 1 end,
    }
    _G.NPC = {
        IsIllusion = function() return false end,
        GetUnitName = function(hero) return hero.unit end,
        GetCurrentLevel = function() return 10 end,
        GetItemByIndex = function(hero, slot) return hero.items[slot] end,
        GetAbilityByIndex = function(hero, slot) return hero.abilities and hero.abilities[slot] end,
        IsRanged = function() return true end,
        GetTrueDamage = function(hero) return hero.min_damage or 0 end,
        GetTrueMaximumDamage = function(hero) return hero.max_damage or hero.min_damage or 0 end,
        GetAttacksPerSecond = function(hero) return hero.attacks_per_second or 0 end,
    }
    _G.Entity = { IsSameTeam = function(a, b) return a.team == b.team end }
    _G.Ability = {
        GetName = function(item) return item.name end,
        IsAttributes = function(item) return item.attributes or false end,
        IsPassive = function(item) return item.passive or false end,
        IsHidden = function(item) return item.hidden or false end,
        GetDamageType = function(item) return item.damage_type or 0 end,
        GetDispellableType = function(item) return item.dispellable or 0 end,
        GetImmunityType = function(item) return item.immunity or 0 end,
        GetBehavior = function(item) return item.behavior or 0 end,
        GetTargetTeam = function(item) return item.target_team or 0 end,
        GetLevel = function(item) return item.level or 0 end,
    }
    _G.Players = { GetLocal = function() return 1 end }
    local lane_selection_flags = 1
    _G.Player = { GetTeamData = function() return { lane_selection_flags = lane_selection_flags } end }
    _G.Engine = {
        GetHeroIDByName = function() return 0 end,
        GetDisplayNameByUnitName = function(unit)
            return unit == enemy.unit and "Phantom Assassin" or "Drow Ranger"
        end,
    }

    local messages, original_print = {}, _G.print
    _G.print = function(...)
        local values = { ... }
        for i, value in ipairs(values) do
            values[i] = tostring(value)
        end
        messages[#messages + 1] = table.concat(values, " ")
    end
    enemy.items[6] = { name = "item_butterfly" } -- backpack: owned, but not an active threat
    fake_clock = fake_clock + 1
    counter.OnUpdate()
    assert(not table.concat(messages, "\n"):find("MKB", 1, true),
        "a Butterfly in the backpack should not be treated as an active threat")

    enemy.items[6] = nil
    enemy.items[9] = { name = "item_butterfly" } -- stash: not active until delivered and moved
    fake_clock = fake_clock + 1
    counter.OnUpdate()
    assert(not table.concat(messages, "\n"):find("MKB", 1, true),
        "a Butterfly in the stash should not be treated as an active threat")

    enemy.items[9] = nil
    enemy.items[0] = { name = "item_butterfly" }
    fake_clock = fake_clock + 1
    counter.OnUpdate() -- active recommendation appears after the first list
    _G.print = original_print
    local output = table.concat(messages, "\n")
    assert(output:find("MKB", 1, true), "expected the Butterfly counter recommendation")
    assert(output:find("Butterfly", 1, true), "expected the enemy item to appear in the explanation")

    rendered_texts = {}
    counter.OnDraw() -- exercise the panel against the documented Render/Menu/Input API shape
    assert(table.concat(rendered_texts, "\n"):find("new", 1, true), "new advice should carry the new tag")

    local_hero.unit = "npc_dota_hero_sniper"
    fake_clock = fake_clock + 1
    counter.OnUpdate() -- changing the profile should reset the new tag
    rendered_texts = {}
    counter.OnDraw()
    assert(not table.concat(rendered_texts, "\n"):find("new", 1, true),
        "profile changes should not keep a stale new tag")

    lane_selection_flags = 8 -- support role, so Gem is an eligible team counter
    enemy.items = { [0] = { name = "item_invis_sword" } }
    team_ally.items = { [9] = { name = "item_gem" } } -- ally stash is not active team protection
    fake_clock = fake_clock + 1
    counter.OnUpdate()
    rendered_texts = {}
    counter.OnDraw()
    assert(rendered_has("Gem"), "a Gem in an ally stash should not suppress the recommendation")

    team_ally.items = { [0] = { name = "item_gem" } }
    fake_clock = fake_clock + 1
    counter.OnUpdate()
    rendered_texts = {}
    counter.OnDraw()
    assert(not rendered_has("Gem"), "an active team Gem should suppress a duplicate recommendation")

    team_ally.items = {}
    local_hero.abilities = {
        [0] = { name = "test_targeted_spell", behavior = 8, target_team = 2, level = 1 },
    }
    enemy.items = { [0] = { name = "item_sphere" } }
    fake_clock = fake_clock + 1
    counter.OnUpdate()
    rendered_texts = {}
    counter.OnDraw()
    assert(rendered_has("Linken's Sphere"),
        "the enemy Linken's item should be named in the recommendation source")

    counter.OnGameEnd()
    enemy.items, enemy.abilities = {}, {}
    enemy.min_damage, enemy.max_damage, enemy.attacks_per_second = 100, 200, 2
    local dps_messages = {}
    _G.print = function(...)
        local values = { ... }
        for i, value in ipairs(values) do
            values[i] = tostring(value)
        end
        dps_messages[#dps_messages + 1] = table.concat(values, " ")
    end
    fake_clock = fake_clock + 1
    counter.OnUpdate()
    _G.print = original_print
    assert(table.concat(dps_messages, "\n"):find("dps 300", 1, true),
        "the game scan should use the average of minimum and maximum damage")
    counter.OnGameEnd()
end)

test("Icons.Image retries a failed load after a delay", function()
    local loaded_icons = package.loaded["ulib.icons"]
    local original_load_image = Render.LoadImage
    local load_calls = 0
    Render.LoadImage = function()
        load_calls = load_calls + 1
        if load_calls == 1 then
            error("injected temporary image load failure")
        end
        return 123
    end
    package.loaded["ulib.icons"] = nil
    local Icons = require("ulib.icons")
    local start = fake_clock

    assert(Icons.Image("panorama/images/test/retry.vtex_c") == nil)
    assert(Icons.Image("panorama/images/test/retry.vtex_c") == nil and load_calls == 1,
        "a failed path should not be loaded again on every frame")
    fake_clock = start + 4
    assert(Icons.Image("panorama/images/test/retry.vtex_c") == nil and load_calls == 1)
    fake_clock = start + 5
    assert(Icons.Image("panorama/images/test/retry.vtex_c") == 123 and load_calls == 2,
        "the loader should retry after the backoff interval")
    assert(Icons.Image("panorama/images/test/retry.vtex_c") == 123 and load_calls == 2,
        "a successful handle should be cached")

    fake_clock = start
    Render.LoadImage = original_load_image
    package.loaded["ulib.icons"] = loaded_icons
end)

print(("%d tests passed"):format(passed))
