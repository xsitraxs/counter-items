-- ulib/store.lua
-- Таблицы скриптов в JSON-файлах configs/ulib_<name>.json (история матчей, кэш и т.п.).
-- Для отдельных чисел и строк проще Config.Read*/Write* (он пишет в db.json).
-- Запись идёт во временный файл. На системах, где rename не заменяет существующий файл,
-- старый файл сначала сохраняется как .bak и восстанавливается при неудаче.
--
--   local Store = require("ulib.store")
--   local diary = Store.Load("diary", { matches = {} })
--   Store.Save("diary", diary)
--
-- JSON не различает массив и объект с числовыми ключами: у разреженных массивов ключи
-- после загрузки станут строками. Храним либо массивы подряд, либо объекты со строковыми ключами.

local JSON = require("assets.JSON")

local Store = {}

local function file_path(name)
    assert(type(name) == "string" and name:match("^[%w_]+$"), "store name: only letters, digits and _")
    local dir = Engine.GetCheatDirectory()
    if not dir:match("[\\/]$") then
        dir = dir .. "\\"
    end
    return dir .. "configs\\ulib_" .. name .. ".json"
end

local function path_exists(path)
    local f = io.open(path, "rb")
    if not f then
        return false
    end
    f:close()
    return true
end

local function remove_if_exists(path)
    if not path_exists(path) then
        return true
    end
    local ok, err = os.remove(path)
    if not ok and path_exists(path) then
        return nil, err or "could not remove file"
    end
    return true
end

local function write_file(path, text)
    local f, open_err = io.open(path, "wb")
    if not f then
        error(("could not open %s: %s"):format(path, tostring(open_err)), 2)
    end

    local written, write_err = f:write(text)
    if not written then
        f:close()
        error(("could not write %s: %s"):format(path, tostring(write_err)), 2)
    end
    local flushed, flush_err = f:flush()
    if not flushed then
        f:close()
        error(("could not flush %s: %s"):format(path, tostring(flush_err)), 2)
    end
    local closed, close_err = f:close()
    if not closed then
        error(("could not close %s: %s"):format(path, tostring(close_err)), 2)
    end
end

local function read_table(path)
    local f = io.open(path, "rb")
    if not f then
        return nil, "missing"
    end
    local text, read_err = f:read("a")
    f:close()
    if text == nil then
        return nil, read_err or "could not read file"
    end

    local ok, data = pcall(JSON.decode, JSON, text)
    if ok and type(data) == "table" then
        return data
    end
    return nil, tostring(data)
end

-- Возвращает сохранённую таблицу или default, если файла нет или он повреждён.
-- Если процесс прервался между переименованием исходного файла и нового, восстанавливаем .bak.
function Store.Load(name, default)
    local target = file_path(name)
    local backup = target .. ".bak"
    local data, err = read_table(target)
    if data then
        return data
    end

    local backup_data = read_table(backup)
    if backup_data then
        if path_exists(target) then
            -- Не оставляем повреждённый основной файл рядом с рабочей копией: следующий Save
            -- на Windows иначе мог бы удалить .bak, сохранив именно повреждённый файл.
            local damaged = target .. ".corrupt"
            local cleared, clear_err = remove_if_exists(damaged)
            if cleared then
                local preserved, preserve_err = os.rename(target, damaged)
                if preserved then
                    local restored, restore_err = os.rename(backup, target)
                    if restored then
                        remove_if_exists(damaged)
                    else
                        local rolled_back, rollback_err = os.rename(damaged, target)
                        if not rolled_back then
                            print(("[ulib.store] %s: could not restore damaged primary (%s) or roll it back (%s)")
                                :format(name, tostring(restore_err), tostring(rollback_err)))
                        end
                    end
                else
                    print(("[ulib.store] %s: using backup but could not preserve damaged primary (%s)")
                        :format(name, tostring(preserve_err)))
                end
            else
                print(("[ulib.store] %s: using backup but could not clear stale damaged file (%s)")
                    :format(name, tostring(clear_err)))
            end
        else
            local restored, restore_err = os.rename(backup, target)
            if not restored then
                print(("[ulib.store] %s: recovered from backup but could not restore it (%s)")
                    :format(name, tostring(restore_err)))
            end
        end
        print(("[ulib.store] %s: using backup after primary file error (%s)"):format(name, tostring(err)))
        return backup_data
    end

    if err ~= "missing" then
        print(("[ulib.store] %s: damaged file, using default (%s)"):format(name, tostring(err)))
    end
    return default
end

function Store.Save(name, data)
    local target = file_path(name)
    local tmp = target .. ".tmp"
    local backup = target .. ".bak"
    local text = JSON:encode(data)

    -- До успешной записи и закрытия временного файла исходный файл не меняется.
    local write_ok, write_err = pcall(write_file, tmp, text)
    if not write_ok then
        remove_if_exists(tmp)
        error(write_err, 2)
    end

    -- POSIX заменяет target атомарно. Windows обычно отказывает, если target уже существует.
    local installed, install_err = os.rename(tmp, target)
    if installed then
        return
    end
    if not path_exists(target) then
        remove_if_exists(tmp)
        error(("could not install %s: %s"):format(target, tostring(install_err)), 2)
    end

    -- Переносим старую копию в резервную, чтобы не удалять её до готовности новой.
    local cleared, clear_err = remove_if_exists(backup)
    if not cleared then
        remove_if_exists(tmp)
        error(("could not clear backup %s: %s"):format(backup, tostring(clear_err)), 2)
    end
    local backed_up, backup_err = os.rename(target, backup)
    if not backed_up then
        remove_if_exists(tmp)
        error(("could not preserve existing file %s: %s"):format(target, tostring(backup_err)), 2)
    end

    installed, install_err = os.rename(tmp, target)
    if not installed then
        local restored, restore_err = os.rename(backup, target)
        remove_if_exists(tmp)
        if not restored then
            error(("could not install %s (%s); original is preserved at %s (%s)")
                :format(target, tostring(install_err), backup, tostring(restore_err)), 2)
        end
        error(("could not install %s: %s"):format(target, tostring(install_err)), 2)
    end

    -- Если удалить резервную копию не удалось, сохранение уже завершено; оставляем её для восстановления.
    local removed, remove_err = remove_if_exists(backup)
    if not removed then
        print(("[ulib.store] %s: new data saved, but backup was retained (%s)")
            :format(name, tostring(remove_err)))
    end
end

return Store
