--!nonstrict
-- =====================================================================
-- IDARoblox / UI / Widgets / Menu
-- ---------------------------------------------------------------------
-- Top menu bar with cascading dropdowns.
--
-- Props:
--   items = {
--     { label = "File", submenu = {
--         { label = "Open Script…", shortcut = "Ctrl+O", onClick = fn,
--           icon = "📂" },
--         { separator = true },
--         { label = "Quit",         onClick = fn },
--       } },
--     { label = "Edit", submenu = { … } },
--     …
--   }
--
-- Optional props:
--   router         — InputRouter; if provided, shortcut text is resolved
--                    from `action` ids on submenu items rather than the
--                    static `shortcut` field
--   Size, Position — overrides default UDim2.new(1, 0, 0, theme.size.menuBar)
-- =====================================================================

local Component = _G.IDARo.require("UI.Framework.Component")
local Element   = _G.IDARo.require("UI.Framework.Element")
local e         = Element.create
local Event     = Element.Event

local Menu = Component.extend("Menu")

Component.setDefaultProps(Menu, {
    items     = {},
    router    = nil,
    Size      = nil,                                                -- defaults below from theme
    Position  = UDim2.fromOffset(0, 0),
})

local TOP_BUTTON_PAD_X    = 12
local DROPDOWN_ROW_HEIGHT = 22
local DROPDOWN_MIN_WIDTH  = 200
local SEP_HEIGHT          = 7

-- ---------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------

function Menu:init(props)
    self.state = {
        openIndex = nil,                                            -- which top-level submenu is open
        hoverIndex = nil,
        triggerWidths = {},                                         -- pixel widths of top-level buttons
    }
end

function Menu:didMount()
    -- ESC dismiss via the router if available.
    if self.props.router then
        self._escBinding = self.props.router:onChord(function(chord)
            if chord == "escape" and self.state.openIndex ~= nil then
                self:setState({ openIndex = nil })
            end
        end)
    end
end

function Menu:willUnmount()
    if self._escBinding then self._escBinding:disconnect() end
end

-- ---------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------

function Menu:_shortcutFor(item)
    if item.action and self.props.router then
        return self.props.router:chordForAction(item.action)
    end
    return item.shortcut
end

function Menu:_openSubmenu(index)
    self:setState({ openIndex = index })
end

function Menu:_closeSubmenu()
    self:setState({ openIndex = nil })
end

function Menu:_onTriggerActivate(index)
    if self.logger then
        self.logger:info("Menu: trigger %d activated (current open=%s)",
            index, tostring(self.state.openIndex))
    end
    if self.state.openIndex == index then
        self:_closeSubmenu()
    else
        self:_openSubmenu(index)
    end
end

function Menu:_onTriggerHover(index, hovering)
    if hovering then
        -- If any menu is open, switch to the hovered trigger's submenu.
        if self.state.openIndex ~= nil and self.state.openIndex ~= index then
            self:setState({ openIndex = index, hoverIndex = index })
        else
            self:setState({ hoverIndex = index })
        end
    else
        if self.state.hoverIndex == index then
            self:setState({ hoverIndex = nil })
        end
    end
end

function Menu:_onItemClick(topIndex, item)
    self:_closeSubmenu()
    if item.onClick then
        local ok, err = pcall(item.onClick)
        if not ok and self.logger then
            self.logger:warn("Menu item '%s' click error: %s", tostring(item.label), tostring(err))
        end
    elseif item.action and self.props.router then
        self.props.router:fireAction(item.action)
    end
end

-- ---------------------------------------------------------------------
-- Render helpers
-- ---------------------------------------------------------------------

function Menu:_renderTrigger(item, index, cumulativeX)
    local theme = self.theme
    local label = item.label or "?"
    local approxWidth = math.max(56, #label * 7 + TOP_BUTTON_PAD_X * 2)
    self.state.triggerWidths[index] = approxWidth                   -- direct write OK, no re-render needed

    local isOpen = self.state.openIndex == index
    local isHover = self.state.hoverIndex == index
    local bg
    if isOpen then bg = theme:color("surfaceAlt")
    elseif isHover then bg = theme:color("surfaceHover")
    else bg = theme:color("background") end

    return e("TextButton", {
        key                  = "trigger:" .. index,
        Size                 = UDim2.fromOffset(approxWidth, theme:size("menuBar")),
        Position             = UDim2.fromOffset(cumulativeX, 0),
        Text                 = label,
        Font                 = Enum.Font.GothamMedium,
        TextSize             = theme:size("font.ui"),
        TextColor3           = theme:color("text"),
        BackgroundColor3     = bg,
        BorderSizePixel      = 0,
        AutoButtonColor      = false,
        ZIndex               = 10,
        [Event.Activated]    = function() self:_onTriggerActivate(index) end,
        [Event.MouseEnter]   = function() self:_onTriggerHover(index, true) end,
        [Event.MouseLeave]   = function() self:_onTriggerHover(index, false) end,
    })
end

function Menu:_renderDropdownRow(item, idx, topIndex)
    local theme = self.theme
    if item.separator then
        return e("Frame", {
            key              = string.format("sep:%d", idx),
            Size             = UDim2.new(1, 0, 0, SEP_HEIGHT),
            BackgroundTransparency = 1,
            LayoutOrder      = idx,
        }, {
            e("Frame", {
                AnchorPoint      = Vector2.new(0, 0.5),
                Position         = UDim2.new(0, theme:spacing("sm"), 0.5, 0),
                Size             = UDim2.new(1, -theme:spacing("sm") * 2, 0, 1),
                BackgroundColor3 = theme:color("divider"),
                BorderSizePixel  = 0,
            }),
        })
    end

    local shortcut = self:_shortcutFor(item)
    local disabled = item.disabled == true
    local iconText = item.icon or " "
    local label = item.label or ""
    return e("TextButton", {
        key              = "item:" .. idx,
        Size             = UDim2.new(1, 0, 0, DROPDOWN_ROW_HEIGHT),
        Text             = "",
        BackgroundColor3 = theme:color("surface"),
        AutoButtonColor  = false,
        BorderSizePixel  = 0,
        LayoutOrder      = idx,
        Active           = not disabled,
        ZIndex           = 12,
        [Event.Activated] = function()
            if disabled then return end
            self:_onItemClick(topIndex, item)
        end,
        [Event.MouseEnter] = function(btn)
            if disabled then return end
            btn.BackgroundColor3 = theme:color("primaryMuted")
        end,
        [Event.MouseLeave] = function(btn)
            btn.BackgroundColor3 = theme:color("surface")
        end,
    }, {
        e("UIPadding", {
            PaddingLeft  = UDim.new(0, theme:spacing("sm")),
            PaddingRight = UDim.new(0, theme:spacing("sm")),
        }),
        e("TextLabel", {
            key              = "icon",
            Size             = UDim2.fromOffset(20, DROPDOWN_ROW_HEIGHT),
            Text             = iconText,
            Font             = Enum.Font.Gotham,
            TextSize         = theme:size("font.ui"),
            TextColor3       = if disabled then theme:color("textDisabled") else theme:color("textMuted"),
            TextXAlignment   = Enum.TextXAlignment.Left,
            BackgroundTransparency = 1,
            ZIndex           = 13,
        }),
        e("TextLabel", {
            key              = "label",
            Position         = UDim2.fromOffset(24, 0),
            Size             = UDim2.new(1, -120, 1, 0),
            Text             = label,
            Font             = Enum.Font.Gotham,
            TextSize         = theme:size("font.ui"),
            TextColor3       = if disabled then theme:color("textDisabled") else theme:color("text"),
            TextXAlignment   = Enum.TextXAlignment.Left,
            TextTruncate     = Enum.TextTruncate.AtEnd,
            BackgroundTransparency = 1,
            ZIndex           = 13,
        }),
        shortcut and e("TextLabel", {
            key              = "shortcut",
            AnchorPoint      = Vector2.new(1, 0),
            Position         = UDim2.new(1, 0, 0, 0),
            Size             = UDim2.fromOffset(96, DROPDOWN_ROW_HEIGHT),
            Text             = shortcut,
            Font             = Enum.Font.RobotoMono,
            TextSize         = math.max(10, theme:size("font.ui") - 1),
            TextColor3       = theme:color("textSubtle"),
            TextXAlignment   = Enum.TextXAlignment.Right,
            BackgroundTransparency = 1,
            ZIndex           = 13,
        }),
    })
end

function Menu:_renderDropdown(topIndex, item)
    local theme = self.theme
    if not item.submenu then return nil end

    -- Position the dropdown beneath the trigger. Use cumulative X of
    -- prior triggers (precomputed in render()).
    local left = 0
    for i = 1, topIndex - 1 do
        left = left + (self.state.triggerWidths[i] or 60)
    end
    local rowCount = 0
    local height = 0
    for _, it in item.submenu do
        if it.separator then height = height + SEP_HEIGHT
        else
            height = height + DROPDOWN_ROW_HEIGHT
            rowCount = rowCount + 1
        end
    end

    local rows = {}
    for i, sub in item.submenu do
        rows[i] = self:_renderDropdownRow(sub, i, topIndex)
    end

    return e("Frame", {
        key              = "dropdown:" .. topIndex,
        Position         = UDim2.fromOffset(left, theme:size("menuBar")),
        Size             = UDim2.fromOffset(DROPDOWN_MIN_WIDTH, height + theme:spacing("xs") * 2),
        BackgroundColor3 = theme:color("surface"),
        BorderSizePixel  = 0,
        ZIndex           = 11,
    }, {
        e("UICorner",  { CornerRadius = UDim.new(0, theme:radius("sm")) }),
        e("UIStroke",  { Color = theme:color("border"), Thickness = 1 }),
        e("UIPadding", {
            PaddingTop    = UDim.new(0, theme:spacing("xs")),
            PaddingBottom = UDim.new(0, theme:spacing("xs")),
        }),
        e("UIListLayout", {
            FillDirection = Enum.FillDirection.Vertical,
            SortOrder     = Enum.SortOrder.LayoutOrder,
            Padding       = UDim.new(0, 0),
        }),
        Element.fragment(rows),
    })
end

-- ---------------------------------------------------------------------
-- Render
-- ---------------------------------------------------------------------

function Menu:render()
    local theme = self.theme
    local items = self.props.items or {}
    local size  = self.props.Size or UDim2.new(1, 0, 0, theme:size("menuBar"))

    local children = {}
    local cumulativeX = 0
    for i, item in items do
        children[#children + 1] = self:_renderTrigger(item, i, cumulativeX)
        cumulativeX = cumulativeX + (self.state.triggerWidths[i] or
            math.max(56, #(item.label or "?") * 7 + TOP_BUTTON_PAD_X * 2))
    end

    -- Click-outside catcher and dropdown live as siblings of the bar
    -- so they paint above other UI. The catcher is intentionally massive
    -- (it lives inside the menu Frame, which has ClipsDescendants=false)
    -- so any click below the menu bar — anywhere in the app — closes
    -- the dropdown.
    local floats = {}
    if self.state.openIndex then
        local item = items[self.state.openIndex]
        floats[#floats + 1] = e("TextButton", {
            key              = "catcher",
            Position         = UDim2.fromOffset(-4000, theme:size("menuBar")),
            Size             = UDim2.fromOffset(8000, 8000),
            BackgroundTransparency = 1,
            Text             = "",
            AutoButtonColor  = false,
            ZIndex           = 9,
            [Event.Activated] = function() self:_closeSubmenu() end,
        })
        local dd = self:_renderDropdown(self.state.openIndex, item)
        if dd then floats[#floats + 1] = dd end
    end

    return e("Frame", {
        Size              = size,
        Position          = self.props.Position,
        BackgroundColor3  = theme:color("background"),
        BorderSizePixel   = 0,
        ZIndex            = 10,
        ClipsDescendants  = false,
    }, {
        -- Bottom border
        e("Frame", {
            key              = "underline",
            Size             = UDim2.new(1, 0, 0, 1),
            Position         = UDim2.new(0, 0, 1, -1),
            BackgroundColor3 = theme:color("border"),
            BorderSizePixel  = 0,
            ZIndex           = 10,
        }),
        Element.fragment(children),
        Element.fragment(floats),
    })
end

return Menu
