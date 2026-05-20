--!nonstrict
-- =====================================================================
-- IDARoblox / UI / Views / OutputView
-- ---------------------------------------------------------------------
-- Live log feed. Subscribes to the Logger and renders a filterable,
-- virtualized list of records.
--
-- Props:
--   logger          — Core.Logger instance (defaults to self.logger from
--                     service injection if not passed)
--   maxEntries      — ring cap; default 4096
--   showLevelFilter — default true
--   showSearchBox   — default true
--
-- Filter UI:
--   buttons [ALL] [DEBUG] [INFO] [WARN] [ERROR] — multi-select toggle
--   search "..."   — substring match against tag + message
--   [Clear]        — drops all current entries
--
-- Auto-scroll: when the user is within 30 px of the bottom, new entries
-- keep them anchored to the bottom. If they've scrolled up, the view
-- stays put.
-- =====================================================================

local Component         = _G.IDARo.require("UI.Framework.Component")
local Element           = _G.IDARo.require("UI.Framework.Element")
local ScrollVirtualizer = _G.IDARo.require("UI.Framework.ScrollVirtualizer")
local e                 = Element.create
local Event             = Element.Event

local OutputView = Component.extend("OutputView")

Component.setDefaultProps(OutputView, {
    logger          = nil,
    maxEntries      = 4096,
    showLevelFilter = true,
    showSearchBox   = true,
    Size            = UDim2.fromScale(1, 1),
    Position        = UDim2.fromOffset(0, 0),
})

local LEVEL_NAMES = {
    [10] = "TRACE", [20] = "DEBUG", [30] = "INFO",
    [40] = "WARN",  [50] = "ERROR", [60] = "FATAL",
}
local LEVEL_BUTTONS = {
    { name = "ALL",   level = 0  },
    { name = "DEBUG", level = 20 },
    { name = "INFO",  level = 30 },
    { name = "WARN",  level = 40 },
    { name = "ERROR", level = 50 },
}
local ROW_HEIGHT = 16
local HEADER_H   = 26
local FOOTER_H   = 24

-- ---------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------

function OutputView:init(props)
    self.state = {
        entries     = {},
        filtered    = {},
        levelMask   = 0,                                            -- 0 = show all
        searchText  = "",
        anchored    = true,                                         -- following the tail
    }
    self._sinkRemover = nil
    self._appendQueue = {}
    self._appendScheduled = false
end

function OutputView:didMount()
    local logger = self.props.logger or self.logger
    if not logger then
        if self.logger then self.logger:warn("OutputView: no logger available") end
        return
    end
    self._sinkRemover = logger:addSink(function(rec)
        -- Coalesce many rapid log calls into a single setState per frame
        table.insert(self._appendQueue, rec)
        if not self._appendScheduled then
            self._appendScheduled = true
            task.defer(function()
                if not self._mounted then return end
                self._appendScheduled = false
                local newEntries = self.state.entries
                local maxKeep = self.props.maxEntries
                for _, r in self._appendQueue do
                    newEntries[#newEntries + 1] = r
                end
                table.clear(self._appendQueue)
                -- Trim ring
                if #newEntries > maxKeep then
                    local drop = #newEntries - maxKeep
                    table.move(newEntries, drop + 1, #newEntries, 1)
                    for i = #newEntries - drop + 1, #newEntries do newEntries[i] = nil end
                end
                self:setState({
                    entries  = newEntries,
                    filtered = self:_recomputeFiltered(newEntries, self.state.levelMask, self.state.searchText),
                })
            end)
        end
    end)
end

function OutputView:willUnmount()
    if self._sinkRemover then self._sinkRemover() end
end

-- ---------------------------------------------------------------------
-- Filtering
-- ---------------------------------------------------------------------

function OutputView:_recomputeFiltered(entries, levelMask, search)
    local out = {}
    local needle = (search ~= "" and string.lower(search)) or nil
    for _, r in entries do
        if levelMask > 0 and r.level < levelMask then
            -- skipped
        else
            local pass = true
            if needle then
                local hay = string.lower((r.tag or "") .. " " .. (r.message or ""))
                pass = string.find(hay, needle, 1, true) ~= nil
            end
            if pass then out[#out + 1] = r end
        end
    end
    return out
end

function OutputView:_setLevel(level)
    self:setState({
        levelMask = level,
        filtered  = self:_recomputeFiltered(self.state.entries, level, self.state.searchText),
    })
end

function OutputView:_setSearch(text)
    self:setState({
        searchText = text,
        filtered   = self:_recomputeFiltered(self.state.entries, self.state.levelMask, text),
    })
end

function OutputView:_clear()
    self:setState({
        entries  = {},
        filtered = {},
    })
end

-- ---------------------------------------------------------------------
-- Row colour by level
-- ---------------------------------------------------------------------

local function colorForLevel(theme, level)
    if level >= 50 then return theme:color("danger")
    elseif level == 40 then return theme:color("warning")
    elseif level == 30 then return theme:color("text")
    elseif level == 20 then return theme:color("textMuted")
    else return theme:color("textSubtle")
    end
end

-- ---------------------------------------------------------------------
-- Row renderer
-- ---------------------------------------------------------------------

function OutputView:_renderRow(rec, index, isOdd)
    local theme = self.theme
    local lvl = LEVEL_NAMES[rec.level] or "?"
    local levelColor = colorForLevel(theme, rec.level)
    local bg = isOdd and theme:color("surface") or theme:color("background")
    local timestamp = rec.timestamp and os.date("%H:%M:%S", rec.timestamp) or ""

    return e("Frame", {
        Size             = UDim2.new(1, 0, 1, 0),
        BackgroundColor3 = bg,
        BorderSizePixel  = 0,
    }, {
        e("TextLabel", {
            key            = "time",
            Position       = UDim2.fromOffset(4, 0),
            Size           = UDim2.fromOffset(60, ROW_HEIGHT),
            Text           = timestamp,
            Font           = Enum.Font.RobotoMono,
            TextSize       = theme:size("font.mono") - 1,
            TextColor3     = theme:color("textSubtle"),
            TextXAlignment = Enum.TextXAlignment.Left,
            BackgroundTransparency = 1,
        }),
        e("TextLabel", {
            key            = "level",
            Position       = UDim2.fromOffset(68, 0),
            Size           = UDim2.fromOffset(48, ROW_HEIGHT),
            Text           = lvl,
            Font           = Enum.Font.RobotoMono,
            TextSize       = theme:size("font.mono") - 1,
            TextColor3     = levelColor,
            TextXAlignment = Enum.TextXAlignment.Left,
            BackgroundTransparency = 1,
        }),
        e("TextLabel", {
            key            = "tag",
            Position       = UDim2.fromOffset(120, 0),
            Size           = UDim2.fromOffset(180, ROW_HEIGHT),
            Text           = rec.tag or "",
            Font           = Enum.Font.RobotoMono,
            TextSize       = theme:size("font.mono") - 1,
            TextColor3     = theme:color("textMuted"),
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate   = Enum.TextTruncate.AtEnd,
            BackgroundTransparency = 1,
        }),
        e("TextLabel", {
            key            = "msg",
            Position       = UDim2.fromOffset(304, 0),
            Size           = UDim2.new(1, -310, 0, ROW_HEIGHT),
            Text           = rec.message or "",
            Font           = Enum.Font.RobotoMono,
            TextSize       = theme:size("font.mono") - 1,
            TextColor3     = levelColor,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate   = Enum.TextTruncate.AtEnd,
            BackgroundTransparency = 1,
        }),
    })
end

-- ---------------------------------------------------------------------
-- Header (filter + search)
-- ---------------------------------------------------------------------

function OutputView:_renderHeader()
    local theme = self.theme
    local buttons = {}
    for i, lvl in LEVEL_BUTTONS do
        local active = self.state.levelMask == lvl.level
        buttons[i] = e("TextButton", {
            key              = "lvl:" .. lvl.name,
            Size             = UDim2.fromOffset(56, HEADER_H - 8),
            Text             = lvl.name,
            Font             = if active then Enum.Font.GothamBold else Enum.Font.Gotham,
            TextSize         = theme:size("font.ui") - 1,
            TextColor3       = if active then theme:color("textOnPrimary") else theme:color("textMuted"),
            BackgroundColor3 = if active then theme:color("primary") else theme:color("surface"),
            BorderSizePixel  = 0,
            AutoButtonColor  = false,
            LayoutOrder      = i,
            [Event.Activated] = function() self:_setLevel(lvl.level) end,
        }, {
            e("UICorner", { CornerRadius = UDim.new(0, theme:radius("sm")) }),
        })
    end

    return e("Frame", {
        key              = "header",
        Size             = UDim2.new(1, 0, 0, HEADER_H),
        BackgroundColor3 = theme:color("surfaceAlt"),
        BorderSizePixel  = 0,
    }, {
        e("UIPadding", {
            PaddingLeft   = UDim.new(0, 6),
            PaddingRight  = UDim.new(0, 6),
            PaddingTop    = UDim.new(0, 4),
            PaddingBottom = UDim.new(0, 4),
        }),
        e("UIListLayout", {
            FillDirection = Enum.FillDirection.Horizontal,
            VerticalAlignment = Enum.VerticalAlignment.Center,
            SortOrder     = Enum.SortOrder.LayoutOrder,
            Padding       = UDim.new(0, 4),
        }),
        Element.fragment(buttons),
        self.props.showSearchBox and e("TextBox", {
            key              = "search",
            Size             = UDim2.fromOffset(220, HEADER_H - 8),
            PlaceholderText  = "  search…",
            Text             = self.state.searchText,
            Font             = Enum.Font.RobotoMono,
            TextSize         = theme:size("font.ui") - 1,
            TextColor3       = theme:color("text"),
            PlaceholderColor3 = theme:color("textSubtle"),
            BackgroundColor3 = theme:color("background"),
            BorderSizePixel  = 0,
            ClearTextOnFocus = false,
            LayoutOrder      = 10,
            [Event.FocusLost] = function(inst)
                self:_setSearch(inst.Text)
            end,
        }, {
            e("UICorner", { CornerRadius = UDim.new(0, theme:radius("sm")) }),
            e("UIPadding", { PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6) }),
        }),
        e("TextButton", {
            key              = "clear",
            Size             = UDim2.fromOffset(60, HEADER_H - 8),
            Text             = "Clear",
            Font             = Enum.Font.Gotham,
            TextSize         = theme:size("font.ui") - 1,
            TextColor3       = theme:color("text"),
            BackgroundColor3 = theme:color("surface"),
            BorderSizePixel  = 0,
            AutoButtonColor  = false,
            LayoutOrder      = 99,
            [Event.Activated] = function() self:_clear() end,
        }, {
            e("UICorner", { CornerRadius = UDim.new(0, theme:radius("sm")) }),
        }),
    })
end

-- ---------------------------------------------------------------------
-- Footer
-- ---------------------------------------------------------------------

function OutputView:_renderFooter()
    local theme = self.theme
    return e("Frame", {
        key              = "footer",
        Size             = UDim2.new(1, 0, 0, FOOTER_H),
        Position         = UDim2.new(0, 0, 1, -FOOTER_H),
        BackgroundColor3 = theme:color("surfaceAlt"),
        BorderSizePixel  = 0,
    }, {
        e("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) }),
        e("TextLabel", {
            Text             = string.format("%d entries (showing %d)",
                #self.state.entries, #self.state.filtered),
            Font             = Enum.Font.Gotham,
            TextSize         = theme:size("font.ui") - 2,
            TextColor3       = theme:color("textMuted"),
            TextXAlignment   = Enum.TextXAlignment.Left,
            BackgroundTransparency = 1,
            Size             = UDim2.fromScale(1, 1),
        }),
    })
end

-- ---------------------------------------------------------------------
-- Render
-- ---------------------------------------------------------------------

function OutputView:render()
    local theme = self.theme
    local body = e(ScrollVirtualizer, {
        key            = "body",
        Position       = UDim2.fromOffset(0, HEADER_H),
        Size           = UDim2.new(1, 0, 1, -(HEADER_H + FOOTER_H)),
        items          = self.state.filtered,
        itemCount      = #self.state.filtered,
        rowHeight      = ROW_HEIGHT,
        overscan       = 16,
        autoScrollToBottom = true,
        background     = "background",
        renderItem     = function(item, idx, isOdd) return self:_renderRow(item, idx, isOdd) end,
    })

    return e("Frame", {
        Size             = self.props.Size,
        Position         = self.props.Position,
        BackgroundColor3 = theme:color("background"),
        BorderSizePixel  = 0,
    }, {
        self.props.showLevelFilter and self:_renderHeader(),
        body,
        self:_renderFooter(),
    })
end

return OutputView
