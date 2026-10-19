-- ulib/panel.lua
-- Панель-оверлей для OnDraw/OnFrame: заголовок, строки «название — значение», карточки с иконками,
-- полоски, разделители. Позиция сохраняется между запусками (Config -> db.json, ключи ulib_panels.<id>_x / _y).
-- Двигается левой кнопкой мыши, пока открыто меню чита. Цвета и масштаб берутся из темы меню.
--
--   local Panel = require("ulib.panel")
--   local panel = Panel.new("farm", { title = "Фарм", x = 40, y = 300 }) -- на верхнем уровне скрипта
--   function script.OnDraw()
--       panel.hint = "мид"            -- необязательный текст справа в шапке
--       panel:Begin()
--       panel:Row("Добито", "45 / 60")
--       panel:Bar(0.75)
--       panel:Entry({ icon = Icons.Item("bfury"), title = "Battle Fury", subtitle = "к 14:30", badges = { ... } })
--       panel:Note("мелкая сноска внизу")
--       panel:End()
--   end

local Panel = {}
Panel.__index = Panel

local CONFIG <const> = "ulib_panels"
local MOUSE1 <const> = Enum.ButtonCode.KEY_MOUSE1
local THEME_REFRESH <const> = 1.0
local DRAG_TIMEOUT <const> = 0.5
local SHRINK_DELAY <const> = 3
local SHADOW_OUTSIDE <const> = Enum.DrawFlags.ShadowCutOutShapeBackground or 512
local WHITE <const> = Color(255, 255, 255, 255)

local floor, max, min = math.floor, math.max, math.min

-- координата по целому пикселю: иначе текст и картинки размываются
local function px(v)
    return floor(v + 0.5)
end

-- Модуль загружается один раз на все скрипты, поэтому тема, шрифты и захват мыши общие.
local theme = { next_refresh = 0 }
local fonts = {}
local dragging = nil      -- панель, которую сейчас тащат
local dragging_seen = 0   -- когда она последний раз обработала мышь

local function refresh_theme()
    local now = os.clock()
    if now < theme.next_refresh then
        return
    end
    theme.next_refresh = now + THEME_REFRESH
    local bg = Menu.Style("main_background")
    local card = Menu.Style("additional_background")
    local dim = Menu.Style("primary_widgets_text")
    theme.background = Color(bg.r, bg.g, bg.b, min(bg.a, 230))
    theme.card = Color(card.r, card.g, card.b, min(card.a, 170))
    theme.shadow = Color(0, 0, 0, 120)
    theme.outline = Menu.Style("outline")
    theme.accent = Menu.Style("primary")
    theme.text = Menu.Style("active_widgets_text")
    theme.dim = dim
    theme.separator = Color(dim.r, dim.g, dim.b, 50)
    theme.bar = Menu.Style("slider_background")
    local scale = Menu.Scale()
    theme.scale = (scale >= 50 and scale <= 300) and scale / 100 or 1
end

local function load_font(name, weight)
    local key = name .. "@" .. weight
    fonts[key] = fonts[key] or Render.LoadFont(name, Enum.FontCreate.FONTFLAG_ANTIALIAS, weight)
    return fonts[key]
end

-- Настоящая высота строки шрифта: она больше размера шрифта, и если центрировать по размеру,
-- текст сидит ниже середины строки или плашки.
local text_heights = {} -- "шрифт@размер" -> высота
local function text_height(font, size)
    local key = font .. "@" .. size
    local h = text_heights[key]
    if not h then
        local measured = Render.TextSize(font, size, "Ay").y
        h = (measured and measured > 0) and measured or size
        text_heights[key] = h
    end
    return h
end

-- id - уникальное имя панели (ключ сохранённой позиции).
-- opts: title, x, y (позиция по умолчанию), width (минимальная), font, font_size.
-- Поле panel.hint (строка или nil) можно менять в любой момент - это подпись справа в шапке.
function Panel.new(id, opts)
    assert(type(id) == "string" and id:match("^[%w_]+$"), "panel id: only letters, digits and _")
    opts = opts or {}
    local font = opts.font or "MuseoSansEx"
    return setmetatable({
        id = id,
        title = opts.title,
        hint = nil,
        min_width = opts.width or 160,
        font_size = opts.font_size or 14,
        font = load_font(font, 500),
        font_title = load_font(font, 700),
        x = Config.ReadInt(CONFIG, id .. "_x", opts.x or 100),
        y = Config.ReadInt(CONFIG, id .. "_y", opts.y or 300),
        w = 0,
        h = 0,
        items = {},
        count = 0,
        metrics = {},
        mouse_was_down = false,
        drag_dx = 0,
        drag_dy = 0,
    }, Panel)
end

--#region Content

-- элементы кадра переиспользуются, чтобы не создавать таблицы каждый кадр
local function push(self, kind)
    local n = self.count + 1
    self.count = n
    local item = self.items[n]
    if not item then
        item = {}
        self.items[n] = item
    end
    item.kind = kind
    return item
end

-- Начинает кадр панели; дальше Row / Text / Entry / Bar / Separator и End.
function Panel:Begin()
    self.count = 0
end

-- Строка: название слева, значение справа. value и цвета необязательны.
function Panel:Row(label, value, value_color, label_color)
    local item = push(self, "row")
    item.label = tostring(label)
    item.value = value ~= nil and tostring(value) or nil
    item.value_color = value_color
    item.label_color = label_color
end

function Panel:Text(text, color)
    self:Row(text, nil, nil, color)
end

-- Сноска: мелкий приглушённый текст (например, пояснение под списком).
function Panel:Note(text, color)
    local item = push(self, "note")
    item.label = tostring(text)
    item.label_color = color
end

-- Карточка: иконка слева, заголовок и подпись под ним, справа ряд маленьких иконок.
-- e.icon - handle картинки (ulib.icons); e.icon_w / e.icon_h - её размер при масштабе 100%
--   (по умолчанию 40x29 - пропорции иконки предмета);
-- e.title, e.subtitle (необязательно), e.title_color, e.subtitle_color;
-- e.chips - цветные плашки во второй строке перед подписью: { { text = "магия", color = Color(...) }, ... };
-- e.tag - короткая метка после заголовка («новое»), e.tag_color (по умолчанию акцентный);
-- e.badges - картинки справа: handle или { icon = handle, overlay = handle } (overlay - маленькая
--   иконка в правом нижнем углу, например предмет героя); нет картинки - серый прямоугольник;
--   e.badge_w / e.badge_h - размер (по умолчанию 20x20; для портретов героев - 36x20);
-- e.stripe - цвет отметки слева (например, срочность), e.highlight - та же отметка акцентного цвета.
-- Таблицу e можно создать один раз и передавать каждый кадр: панель её не меняет и не хранит.
function Panel:Entry(e)
    local item = push(self, "entry")
    item.icon = e.icon
    item.icon_w = e.icon_w or 40
    item.icon_h = e.icon_h or 29
    item.title = tostring(e.title or "")
    item.subtitle = e.subtitle and tostring(e.subtitle) or nil
    item.chips = e.chips and #e.chips > 0 and e.chips or nil
    item.stripe = e.stripe
    item.title_color = e.title_color
    item.subtitle_color = e.subtitle_color
    item.tag = e.tag and tostring(e.tag) or nil
    item.tag_color = e.tag_color
    item.badges = e.badges
    item.badge_w = e.badge_w or e.badge_size or 20
    item.badge_h = e.badge_h or e.badge_size or 20
    item.highlight = e.highlight
end

-- Полоска прогресса, fraction в 0..1.
function Panel:Bar(fraction, color)
    local item = push(self, "bar")
    item.fraction = max(0, min(1, fraction or 0))
    item.color = color
end

function Panel:Separator()
    push(self, "separator")
end

--#endregion

--#region Mouse

local function cursor_over_menu(x, y)
    local pos, size = Menu.Pos(), Menu.Size()
    return x >= pos.x and x <= pos.x + size.x and y >= pos.y and y <= pos.y + size.y
end

function Panel:_clamp()
    local screen = Render.ScreenSize()
    self.x = max(0, min(self.x, screen.x - self.w))
    self.y = max(0, min(self.y, screen.y - self.h))
end

function Panel:_handle_mouse()
    local now = os.clock()
    -- панель, которую перестали рисовать посреди перетаскивания, не должна держать мышь
    if dragging and dragging ~= self and now - dragging_seen > DRAG_TIMEOUT then
        dragging = nil
    end

    local down = Menu.Opened() and Input.IsKeyDown(MOUSE1, true)
    local pressed = down and not self.mouse_was_down
    self.mouse_was_down = down
    local cx, cy = Input.GetCursorPos()

    if dragging == self then
        dragging_seen = now
        if down then
            self.x, self.y = cx - self.drag_dx, cy - self.drag_dy
            self:_clamp()
            return
        end
        dragging = nil
        Config.WriteInt(CONFIG, self.id .. "_x", floor(self.x))
        Config.WriteInt(CONFIG, self.id .. "_y", floor(self.y))
    elseif pressed and not dragging and Input.IsCursorInRect(self.x, self.y, self.w, self.h)
        and not cursor_over_menu(cx, cy) then
        dragging, dragging_seen = self, now
        self.drag_dx, self.drag_dy = cx - self.x, cy - self.y
        return
    end
    self:_clamp() -- размер панели или экрана мог измениться
end

--#endregion

--#region Layout and drawing

-- Размеры считаются в End по накопленным элементам, поэтому панель без задержки подстраивается под содержимое.
function Panel:End()
    refresh_theme()
    local s = theme.scale
    local m = self.metrics -- размеры кадра; таблица одна на панель
    m.s = s
    m.size = floor(self.font_size * s + 0.5)
    m.small = floor(self.font_size * 0.86 * s + 0.5)
    m.size_h = text_height(self.font_title, m.size) -- жирный заголовок
    m.row_h = text_height(self.font, m.size)        -- обычный текст
    m.small_h = text_height(self.font, m.small)     -- мелкий текст и плашки
    m.pad = 10 * s
    m.line_h = px(max(m.size_h, m.row_h) + 6 * s)
    m.note_h = px(m.small_h + 6 * s)

    local width, height = self.min_width * s, m.pad * 2
    if self.title then
        local title_w = Render.TextSize(self.font_title, m.size, self.title).x
        -- подпись в шапке - плашка: текст + поля по 6 px
        self.hint_w = self.hint and Render.TextSize(self.font, m.small, self.hint).x + 12 * s or 0
        width = max(width, title_w + (self.hint and self.hint_w + 16 * s or 0) + m.pad * 2)
        height = height + m.line_h + 8 * s
    end
    for i = 1, self.count do
        local item = self.items[i]
        if item.kind == "row" then
            item.label_w = Render.TextSize(self.font, m.size, item.label).x
            item.value_w = item.value and Render.TextSize(self.font, m.size, item.value).x or 0
            width = max(width, item.label_w + item.value_w + (item.value and 16 * s or 0) + m.pad * 2)
            height = height + m.line_h
        elseif item.kind == "note" then
            width = max(width, Render.TextSize(self.font, m.small, item.label).x + m.pad * 2)
            height = height + m.note_h
        elseif item.kind == "entry" then
            width = max(width, self:_measure_entry(item, m) + m.pad * 2)
            height = height + item.h + 4 * s
        elseif item.kind == "bar" then
            height = height + 10 * s
        else
            height = height + 8 * s
        end
    end
    self.w, self.h = self:_stable_width(px(width)), px(height)

    self:_handle_mouse()
    self:_draw(m)
end

-- Ширина растёт сразу, а уменьшается, только если содержимое уже SHRINK_DELAY с стало уже:
-- иначе окно «дышит», когда меняется текст (метка «новое», подписи). После паузы в показе - сразу.
function Panel:_stable_width(width)
    local now = os.clock()
    local was_hidden = now - (self.drawn_at or -math.huge) > 0.5
    self.drawn_at = now
    if was_hidden or width >= self.w then
        self.shrink_at = nil
        return width
    end
    if not self.shrink_at then
        self.shrink_at = now + SHRINK_DELAY
    elseif now >= self.shrink_at then
        self.shrink_at = nil
        return width
    end
    return self.w
end

-- ширина плашки с текстом (поля по 5 px)
function Panel:_chip_w(text, m)
    return Render.TextSize(self.font, m.small, text).x + 10 * m.s
end

-- ширина содержимого карточки; высоту кладёт в item.h
function Panel:_measure_entry(item, m)
    local s = m.s
    item.title_w = Render.TextSize(self.font_title, m.size, item.title).x
    item.tag_w = item.tag and self:_chip_w(item.tag, m) or 0
    local title_line_w = item.title_w + (item.tag and 6 * s + item.tag_w or 0)
    -- вторая строка: плашки, затем подпись
    local line2_w = 0
    if item.chips then
        for _, chip in ipairs(item.chips) do
            line2_w = line2_w + self:_chip_w(chip.text, m) + 4 * s
        end
    end
    if item.subtitle then
        line2_w = line2_w + (item.chips and 2 * s or 0) + Render.TextSize(self.font, m.small, item.subtitle).x
    end
    local count = item.badges and #item.badges or 0
    item.bw, item.bh = px(item.badge_w * s), px(item.badge_h * s)
    item.badges_w = count > 0 and count * item.bw + (count - 1) * px(4 * s) or 0
    item.line2_h = item.chips and px(m.small_h + 4 * s) or (item.subtitle and px(m.small_h) or 0)
    item.text_h = m.size_h + (item.line2_h > 0 and 3 * s + item.line2_h or 0)

    local width = 10 * s + max(title_line_w, line2_w) + 10 * s
    local content_h = item.text_h
    if item.icon then
        width = width + item.icon_w * s + 10 * s
        content_h = max(content_h, item.icon_h * s)
    end
    if item.badges_w > 0 then
        -- уголок-иконка на картинке выступает за край на 3 px
        width = width + item.badges_w + 16 * s + 3 * s
        content_h = max(content_h, item.bh + 3 * s)
    end
    item.h = px(content_h + 14 * s)
    return width
end

function Panel:_draw(m)
    local s, size, pad = m.s, m.size, m.pad
    local x, y, w, h = px(self.x), px(self.y), self.w, self.h
    local rounding = 6 * s
    Render.Shadow(Vec2(x, y), Vec2(x + w, y + h), theme.shadow, 18 * s, rounding, SHADOW_OUTSIDE, Vec2(0, 2 * s))
    Render.FilledRect(Vec2(x, y), Vec2(x + w, y + h), theme.background, rounding)
    -- рамка акцентного цвета подсказывает, что панель сейчас можно двигать
    Render.Rect(Vec2(x, y), Vec2(x + w, y + h), Menu.Opened() and theme.accent or theme.outline, rounding)

    local left, right = px(x + pad), px(x + w - pad)
    local cy = y + pad
    if self.title then
        Render.Text(self.font_title, size, self.title, Vec2(left, px(cy + (m.line_h - m.size_h) / 2)), theme.text)
        if self.hint then
            -- плашка по центру строки заголовка
            local chip_h = px(m.small_h + 4 * s)
            local chip_top = px(cy + (m.line_h - chip_h) / 2)
            local chip_left = px(right - self.hint_w)
            Render.FilledRect(Vec2(chip_left, chip_top), Vec2(right, chip_top + chip_h), theme.card, 3 * s)
            Render.Text(self.font, m.small, self.hint,
                Vec2(chip_left + px(6 * s), chip_top + px((chip_h - m.small_h) / 2)), theme.dim)
        end
        cy = cy + m.line_h
        Render.FilledRect(Vec2(left, px(cy)), Vec2(left + px(24 * s), px(cy + 2 * s)), theme.accent)
        cy = cy + 8 * s
    end

    for i = 1, self.count do
        local item = self.items[i]
        if item.kind == "row" then
            local label_color = item.label_color or (item.value and theme.dim or theme.text)
            local ty = px(cy + (m.line_h - m.row_h) / 2)
            Render.Text(self.font, size, item.label, Vec2(left, ty), label_color)
            if item.value then
                Render.Text(self.font, size, item.value, Vec2(px(right - item.value_w), ty),
                    item.value_color or theme.text)
            end
            cy = cy + m.line_h
        elseif item.kind == "note" then
            Render.Text(self.font, m.small, item.label, Vec2(left, px(cy + (m.note_h - m.small_h) / 2)),
                item.label_color or theme.dim)
            cy = cy + m.note_h
        elseif item.kind == "entry" then
            self:_draw_entry(item, m, left, right, px(cy))
            cy = cy + item.h + 4 * s
        elseif item.kind == "bar" then
            local top, bottom = px(cy + 2 * s), px(cy + 8 * s)
            Render.FilledRect(Vec2(left, top), Vec2(right, bottom), theme.bar, 3 * s)
            if item.fraction > 0 then
                Render.FilledRect(Vec2(left, top), Vec2(px(left + (right - left) * item.fraction), bottom),
                    item.color or theme.accent, 3 * s)
            end
            cy = cy + 10 * s
        else
            local mid = floor(cy + 4 * s) + 0.5
            Render.Line(Vec2(left, mid), Vec2(right, mid), theme.separator)
            cy = cy + 8 * s
        end
    end
end

-- картинка справа в карточке: handle или { icon, overlay }
function Panel:_draw_badge(badge, x, y, w, h, s)
    local icon, overlay = badge, nil
    if type(badge) == "table" then
        icon, overlay = badge.icon, badge.overlay
    end
    if icon then
        Render.Image(icon, Vec2(x, y), Vec2(w, h), WHITE, 3 * s)
    else
        Render.FilledRect(Vec2(x, y), Vec2(x + w, y + h), theme.bar, 3 * s)
    end
    if overlay then
        -- уголок: иконка предмета (88:64) в тёмной рамке, выступает за край картинки на 3 px
        local oh = px(h * 0.62)
        local ow = px(oh * 1.375)
        local ox, oy = x + w - ow + px(3 * s), y + h - oh + px(3 * s)
        local border = px(1 * s)
        Render.FilledRect(Vec2(ox - border, oy - border), Vec2(ox + ow + border, oy + oh + border), theme.background, 2 * s)
        Render.Image(overlay, Vec2(ox, oy), Vec2(ow, oh), WHITE, 2 * s)
    end
end

-- фон плашки - цвет текста с прозрачностью; кэш, чтобы не создавать Color каждый кадр
local chip_backgrounds = setmetatable({}, { __mode = "k" })

-- плашка: полупрозрачный фон цвета color и текст этим цветом; возвращает ширину
function Panel:_draw_chip(text, color, x, y, h, m)
    local w = px(self:_chip_w(text, m))
    local bg = chip_backgrounds[color]
    if not bg then
        bg = Color(color.r, color.g, color.b, 45)
        chip_backgrounds[color] = bg
    end
    Render.FilledRect(Vec2(x, y), Vec2(x + w, y + h), bg, 3 * m.s)
    Render.Text(self.font, m.small, text, Vec2(x + px(5 * m.s), y + px((h - m.small_h) / 2)), color)
    return w
end

function Panel:_draw_entry(item, m, left, right, top)
    local s = m.s
    local bottom = top + item.h
    local mid = (top + bottom) / 2
    Render.FilledRect(Vec2(left, top), Vec2(right, bottom), theme.card, 4 * s)
    local stripe = item.stripe or (item.highlight and theme.accent)
    if stripe then
        -- узкая отметка по центру левого края
        local inset = px(7 * s)
        Render.FilledRect(Vec2(left, top + inset), Vec2(left + px(3 * s), bottom - inset), stripe, 2 * s)
    end

    local tx = left + 10 * s
    if item.icon then
        local iw, ih = px(item.icon_w * s), px(item.icon_h * s)
        Render.Image(item.icon, Vec2(px(tx), px(mid - ih / 2)), Vec2(iw, ih), WHITE, 3 * s)
        tx = tx + iw + 10 * s
    end
    local ty = px(mid - item.text_h / 2)
    tx = px(tx)
    Render.Text(self.font_title, m.size, item.title, Vec2(tx, ty), item.title_color or theme.text)
    if item.tag then
        local chip_h = px(m.small_h + 2 * s)
        self:_draw_chip(item.tag, item.tag_color or theme.accent, px(tx + item.title_w + 6 * s),
            px(ty + (m.size_h - chip_h) / 2), chip_h, m)
    end
    if item.line2_h > 0 then
        local y2 = px(ty + m.size_h + 3 * s)
        local x2 = tx
        if item.chips then
            for _, chip in ipairs(item.chips) do
                x2 = x2 + self:_draw_chip(chip.text, chip.color, x2, y2, item.line2_h, m) + px(4 * s)
            end
            x2 = x2 + px(2 * s)
        end
        if item.subtitle then
            Render.Text(self.font, m.small, item.subtitle, Vec2(x2, y2 + px((item.line2_h - m.small_h) / 2)),
                item.subtitle_color or theme.dim)
        end
    end

    if item.badges_w > 0 then
        local bw, bh = item.bw, item.bh
        local bx = px(right - 10 * s - 3 * s - item.badges_w)
        local by = px(mid - bh / 2)
        for _, badge in ipairs(item.badges) do
            self:_draw_badge(badge, bx, by, bw, bh, s)
            bx = bx + bw + px(4 * s)
        end
    end
end

--#endregion

return Panel
