--!nonstrict
-- =====================================================================
-- IDARoblox / UI / Widgets / SearchBar
-- ---------------------------------------------------------------------
-- Search input with mode switcher (plain | regex | fuzzy), debounced
-- typing, prev/next match navigation, clear button, and a result-count
-- pill. Drives the SearchEngine without owning it — parent components
-- pass onQuery/onPrev/onNext/onClear callbacks.
--
-- Props
--   placeholder        default "Search…"
--   mode               "plain" | "regex" | "fuzzy"  (default plain)
--   showModeSwitcher   default true
--   debounceMs         default 200
--   resultCount        integer (parent-provided, after a query completes)
--   activeIndex        integer (parent-provided, 1-based)
--   onQuery            fn(text, mode)        — fires after debounce
--   onPrev             fn()                  — Shift+Enter or "▴" button
--   onNext             fn()                  — Enter or "▾" button
--   onClear            fn()                  — Esc or "×" button
--   onModeChange       fn(mode)              — switcher click
--   sources            optional source-filter chips: { id, label, active }
--   onSourceToggle     fn(sourceId, newActive)
-- =====================================================================

local Component = _G.IDARo.require("UI.Framework.Component")
local Element   = _G.IDARo.require("UI.Framework.Element")
local e = Element.create
local Event = Element.Event

local SearchBar = Component.extend("SearchBar")

Component.setDefaultProps(SearchBar, {
    placeholder      = "Search…",
    mode             = "plain",
    showModeSwitcher = true,
    debounceMs       = 200,
    resultCount      = nil,
    activeIndex      = nil,
    onQuery          = nil,
    onPrev           = nil,
    onNext           = nil,
    onClear          = nil,
    onModeChange     = nil,
    sources          = nil,
    onSourceToggle   = nil,
    height           = 28,
})

function SearchBar:init()
    self.state = {
        text         = "",
        focused      = false,
        currentMode  = self.props.mode,
    }
    self._debounceToken = 0
end

function SearchBar:_setText(text)
    self:setState({ text = text })
    -- Debounce
    self._debounceToken = self._debounceToken + 1
    local token = self._debounceToken
    task.delay(self.props.debounceMs / 1000, function()
        if token == self._debounceToken and self.props.onQuery then
            self.props.onQuery(text, self.state.currentMode)
        end
    end)
end

function SearchBar:_setMode(mode)
    if mode == self.state.currentMode then return end
    self:setState({ currentMode = mode })
    if self.props.onModeChange then self.props.onModeChange(mode) end
    -- Re-fire query immediately so the result list updates
    if self.props.onQuery and self.state.text ~= "" then
        self.props.onQuery(self.state.text, mode)
    end
end

function SearchBar:_clear()
    self:setState({ text = "" })
    if self.props.onClear then self.props.onClear() end
end

-- ---------------------------------------------------------------------
-- Mode switcher
-- ---------------------------------------------------------------------

local MODES = {
    { id = "plain", label = "Aa",  tip = "Plain substring" },
    { id = "regex", label = ".*",  tip = "Lua pattern"     },
    { id = "fuzzy", label = "~",   tip = "Fuzzy match"     },
}

function SearchBar:_renderModeSwitcher()
    local theme = self.theme
    local buttons = { e("UIListLayout", {
        FillDirection = Enum.FillDirection.Horizontal,
        SortOrder = Enum.SortOrder.LayoutOrder,
        Padding = UDim.new(0, 2),
    }) }
    for i, m in MODES do
        local active = m.id == self.state.currentMode
        buttons[#buttons + 1] = e("TextButton", {
            Size = UDim2.new(0, 24, 1, -4),
            LayoutOrder = i,
            Text = m.label,
            Font = Enum.Font.Code,
            TextSize = 12,
            TextColor3 = theme:color(active and "searchModeActiveFg" or "searchModeFg"),
            BackgroundColor3 = theme:color(active and "searchModeActiveBg" or "searchModeBg"),
            BorderSizePixel = 0,
            [Event "Activated"] = function() self:_setMode(m.id) end,
        })
    end
    return e("Frame", {
        Size = UDim2.new(0, 76, 1, 0),
        Position = UDim2.new(1, -188, 0, 0),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
    }, buttons)
end

-- ---------------------------------------------------------------------
-- Result pill
-- ---------------------------------------------------------------------

function SearchBar:_renderResultPill()
    local theme = self.theme
    local txt
    if self.props.resultCount == nil then
        return nil
    elseif self.props.resultCount == 0 then
        txt = "no matches"
    elseif self.props.activeIndex then
        txt = string.format("%d / %d", self.props.activeIndex, self.props.resultCount)
    else
        txt = string.format("%d match%s",
            self.props.resultCount, self.props.resultCount == 1 and "" or "es")
    end
    return e("TextLabel", {
        Size = UDim2.new(0, 100, 1, -4),
        Position = UDim2.new(1, -108, 0, 2),
        Text = txt,
        Font = Enum.Font.SourceSans,
        TextSize = 12,
        TextColor3 = theme:color("searchResultFg"),
        BackgroundColor3 = theme:color("searchResultBg"),
        BorderSizePixel = 0,
    })
end

-- ---------------------------------------------------------------------
-- Render
-- ---------------------------------------------------------------------

function SearchBar:render()
    local theme = self.theme
    local h = self.props.height
    local children = {}

    -- The actual TextBox
    children[#children + 1] = e("TextBox", {
        Size = UDim2.new(1, -200, 1, -6),
        Position = UDim2.new(0, 26, 0, 3),
        Text = self.state.text,
        PlaceholderText = self.props.placeholder,
        Font = Enum.Font.SourceSans,
        TextSize = 14,
        TextColor3 = theme:color("searchInputFg"),
        PlaceholderColor3 = theme:color("searchPlaceholder"),
        BackgroundColor3 = theme:color("searchInputBg"),
        BorderSizePixel = 0,
        TextXAlignment = Enum.TextXAlignment.Left,
        ClearTextOnFocus = false,
        [Event "FocusLost"] = function(rbx, enterPressed)
            self:setState({ focused = false, text = rbx.Text })
            if enterPressed and self.props.onNext then self.props.onNext() end
        end,
        [Event "Focused"] = function() self:setState({ focused = true }) end,
        [Event "Changed"] = function(rbx, prop)
            if prop == "Text" then self:_setText(rbx.Text) end
        end,
    })

    -- Magnifying-glass icon
    children[#children + 1] = e("TextLabel", {
        Size = UDim2.new(0, 20, 1, 0),
        Position = UDim2.new(0, 4, 0, 0),
        Text = "🔍",
        Font = Enum.Font.SourceSans,
        TextSize = 14,
        TextColor3 = theme:color("searchPlaceholder"),
        BackgroundTransparency = 1,
    })

    -- Mode switcher
    if self.props.showModeSwitcher then
        children[#children + 1] = self:_renderModeSwitcher()
    end

    -- Prev / Next
    children[#children + 1] = e("TextButton", {
        Size = UDim2.new(0, 22, 1, -6),
        Position = UDim2.new(1, -112, 0, 3),
        Text = "▴",
        Font = Enum.Font.SourceSans,
        TextSize = 14,
        TextColor3 = theme:color("searchNavFg"),
        BackgroundColor3 = theme:color("searchNavBg"),
        BorderSizePixel = 0,
        [Event "Activated"] = function()
            if self.props.onPrev then self.props.onPrev() end
        end,
    })
    children[#children + 1] = e("TextButton", {
        Size = UDim2.new(0, 22, 1, -6),
        Position = UDim2.new(1, -88, 0, 3),
        Text = "▾",
        Font = Enum.Font.SourceSans,
        TextSize = 14,
        TextColor3 = theme:color("searchNavFg"),
        BackgroundColor3 = theme:color("searchNavBg"),
        BorderSizePixel = 0,
        [Event "Activated"] = function()
            if self.props.onNext then self.props.onNext() end
        end,
    })

    -- Result pill
    local pill = self:_renderResultPill()
    if pill then children[#children + 1] = pill end

    -- Clear button
    if self.state.text ~= "" then
        children[#children + 1] = e("TextButton", {
            Size = UDim2.new(0, 18, 1, -6),
            Position = UDim2.new(1, -22, 0, 3),
            Text = "×",
            Font = Enum.Font.SourceSans,
            TextSize = 16,
            TextColor3 = theme:color("searchClearFg"),
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            [Event "Activated"] = function() self:_clear() end,
        })
    end

    -- Source chips row (below the input)
    local rootChildren = { e("Frame", {
        Size = UDim2.new(1, 0, 0, h),
        BackgroundColor3 = theme:color("searchBarBg"),
        BorderSizePixel = 0,
    }, children) }

    if self.props.sources and #self.props.sources > 0 then
        local chips = { e("UIListLayout", {
            FillDirection = Enum.FillDirection.Horizontal,
            SortOrder = Enum.SortOrder.LayoutOrder,
            Padding = UDim.new(0, 4),
        }) }
        for i, src in self.props.sources do
            local active = src.active ~= false
            chips[#chips + 1] = e("TextButton", {
                Size = UDim2.new(0, math.max(40, #src.label * 8 + 12), 1, -6),
                LayoutOrder = i,
                Text = src.label,
                Font = Enum.Font.SourceSans,
                TextSize = 11,
                TextColor3 = theme:color(active and "searchChipActiveFg" or "searchChipFg"),
                BackgroundColor3 = theme:color(active and "searchChipActiveBg" or "searchChipBg"),
                BorderSizePixel = 0,
                [Event "Activated"] = function()
                    if self.props.onSourceToggle then
                        self.props.onSourceToggle(src.id, not active)
                    end
                end,
            })
        end
        rootChildren[#rootChildren + 1] = e("Frame", {
            Size = UDim2.new(1, 0, 0, 22),
            Position = UDim2.new(0, 0, 0, h + 2),
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
        }, chips)
    end

    return e("Frame", {
        Size = self.props.Size or UDim2.new(1, 0, 0, h + (self.props.sources and 24 or 0)),
        Position = self.props.Position or UDim2.new(0, 0, 0, 0),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
    }, rootChildren)
end

return SearchBar
