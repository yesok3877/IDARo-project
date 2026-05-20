--!nonstrict
-- =====================================================================
-- IDARoblox / UI / Widgets / Toolbar
-- ---------------------------------------------------------------------
-- Horizontal button strip with grouped buttons and dividers.
--
-- Props:
--   groups = {
--     {
--       { icon = "📂", label = "Open",   onClick = fn, shortcut = "Ctrl+O",
--         tooltip = "Open a Roblox script for analysis" },
--       { icon = "🔄", label = "Reload", onClick = fn },
--     },
--     {
--       { icon = "▶",  label = "Analyze", onClick = fn, primary = true },
--     },
--   }
--   router (optional)   — for shortcut resolution + action dispatch
--   onTooltip (fn)      — invoked with text or nil; if omitted Toolbar
--                         renders its own inline tooltip frame
-- =====================================================================

local Component = _G.IDARo.require("UI.Framework.Component")
local Element   = _G.IDARo.require("UI.Framework.Element")
local e         = Element.create
local Event     = Element.Event

local Toolbar = Component.extend("Toolbar")

Component.setDefaultProps(Toolbar, {
    groups       = {},
    router       = nil,
    onTooltip    = nil,
    showLabels   = true,
    buttonHeight = nil,
})

local BUTTON_PAD_X = 10
local ICON_GAP     = 4

function Toolbar:init()
    self.state = {
        hoverButton  = nil,                                         -- "groupIdx:btnIdx" or nil
        pressedButton = nil,
        tooltipText  = nil,
        tooltipX     = 0,
    }
end

function Toolbar:_chordFor(btn)
    if btn.action and self.props.router then
        return self.props.router:chordForAction(btn.action)
    end
    return btn.shortcut
end

function Toolbar:_onClick(btn)
    if btn.onClick then
        local ok, err = pcall(btn.onClick)
        if not ok and self.logger then
            self.logger:warn("Toolbar '%s' error: %s", tostring(btn.label), tostring(err))
        end
    elseif btn.action and self.props.router then
        self.props.router:fireAction(btn.action)
    end
end

function Toolbar:_renderButton(btn, key, primary)
    local theme = self.theme
    local label = btn.label
    local icon  = btn.icon
    local height = self.props.buttonHeight or (theme:size("toolbar") - 6)
    local shortcut = self:_chordFor(btn)

    local hoverKey = key
    local isHover = self.state.hoverButton == hoverKey
    local isPressed = self.state.pressedButton == hoverKey
    local disabled = btn.disabled == true

    -- Approximate text width for sizing.
    local textPart = label and (self.props.showLabels and label) or ""
    local widthEstimate = BUTTON_PAD_X * 2
    if icon then widthEstimate = widthEstimate + 16 + (textPart ~= "" and ICON_GAP or 0) end
    if textPart ~= "" then widthEstimate = widthEstimate + math.max(20, #textPart * 7) end
    if widthEstimate < 32 then widthEstimate = 32 end

    local bg
    if disabled then bg = theme:color("surfaceAlt")
    elseif isPressed then bg = theme:color("primaryPressed")
    elseif isHover and primary then bg = theme:color("primaryHover")
    elseif isHover then bg = theme:color("surfaceHover")
    elseif primary then bg = theme:color("primary")
    else bg = theme:color("surface") end

    local textColor = if primary and not disabled then theme:color("textOnPrimary")
        elseif disabled then theme:color("textDisabled")
        else theme:color("text")

    local kids = {}
    if icon then
        kids[#kids + 1] = e("TextLabel", {
            key            = "icon",
            Size           = UDim2.fromOffset(16, height),
            Text           = icon,
            Font           = Enum.Font.Gotham,
            TextSize       = math.max(11, height - 6),
            TextColor3     = textColor,
            BackgroundTransparency = 1,
            TextXAlignment = Enum.TextXAlignment.Center,
        })
    end
    if textPart ~= "" then
        kids[#kids + 1] = e("TextLabel", {
            key            = "label",
            Size           = UDim2.fromOffset(widthEstimate - (icon and 20 or 0) - BUTTON_PAD_X * 2, height),
            Text           = textPart,
            Font           = if primary then Enum.Font.GothamMedium else Enum.Font.Gotham,
            TextSize       = theme:size("font.ui"),
            TextColor3     = textColor,
            BackgroundTransparency = 1,
            TextXAlignment = Enum.TextXAlignment.Left,
        })
    end

    return e("TextButton", {
        key              = key,
        Size             = UDim2.fromOffset(widthEstimate, height),
        Text             = "",
        BackgroundColor3 = bg,
        BorderSizePixel  = 0,
        AutoButtonColor  = false,
        Active           = not disabled,
        ZIndex           = 4,
        [Event.Activated] = function() if not disabled then self:_onClick(btn) end end,
        [Event.MouseEnter] = function(inst)
            if self.state.hoverButton == hoverKey then return end
            task.defer(function()
                if not self.state then return end
                if self.state.hoverButton == hoverKey then return end
                self:setState({
                    hoverButton = hoverKey,
                    tooltipText = btn.tooltip or (label and shortcut and (label .. " (" .. shortcut .. ")") or label),
                    tooltipX    = inst.AbsolutePosition.X,
                })
                if self.props.onTooltip then
                    pcall(self.props.onTooltip, btn.tooltip or label, btn)
                end
            end)
        end,
        [Event.MouseLeave] = function()
            if self.state.hoverButton ~= hoverKey then return end
            task.defer(function()
                if not self.state then return end
                if self.state.hoverButton == hoverKey then
                    self:setState({ hoverButton = nil, tooltipText = nil })
                end
                if self.props.onTooltip then pcall(self.props.onTooltip, nil) end
            end)
        end,
        [Event.MouseButton1Down] = function() self:setState({ pressedButton = hoverKey }) end,
        [Event.MouseButton1Up]   = function() if self.state.pressedButton == hoverKey then self:setState({ pressedButton = nil }) end end,
    }, {
        e("UICorner", { CornerRadius = UDim.new(0, theme:radius("sm")) }),
        e("UIPadding", {
            PaddingLeft  = UDim.new(0, BUTTON_PAD_X),
            PaddingRight = UDim.new(0, BUTTON_PAD_X),
        }),
        e("UIListLayout", {
            FillDirection = Enum.FillDirection.Horizontal,
            VerticalAlignment = Enum.VerticalAlignment.Center,
            SortOrder = Enum.SortOrder.LayoutOrder,
            Padding   = UDim.new(0, ICON_GAP),
        }),
        Element.fragment(kids),
    })
end

function Toolbar:render()
    local theme = self.theme
    local height = theme:size("toolbar")

    local children = {}
    children[#children + 1] = e("UIListLayout", {
        FillDirection = Enum.FillDirection.Horizontal,
        SortOrder     = Enum.SortOrder.LayoutOrder,
        VerticalAlignment = Enum.VerticalAlignment.Center,
        Padding       = UDim.new(0, 4),
    })
    children[#children + 1] = e("UIPadding", {
        PaddingLeft  = UDim.new(0, theme:spacing("sm")),
        PaddingRight = UDim.new(0, theme:spacing("sm")),
    })

    local layoutOrder = 0
    for groupIdx, group in self.props.groups do
        if groupIdx > 1 then
            -- Separator
            layoutOrder = layoutOrder + 1
            children[#children + 1] = e("Frame", {
                key              = "sep:" .. groupIdx,
                Size             = UDim2.fromOffset(1, height - 10),
                BackgroundColor3 = theme:color("divider"),
                BorderSizePixel  = 0,
                LayoutOrder      = layoutOrder,
            })
        end
        for btnIdx, btn in group do
            layoutOrder = layoutOrder + 1
            local btnKey = string.format("btn:%d:%d", groupIdx, btnIdx)
            local rendered = self:_renderButton(btn, btnKey, btn.primary == true)
            -- inject LayoutOrder
            rendered.props.LayoutOrder = layoutOrder
            children[#children + 1] = rendered
        end
    end

    -- Inline tooltip near hovered button (skip if onTooltip handler claimed it)
    if self.state.tooltipText and not self.props.onTooltip then
        children[#children + 1] = e("Frame", {
            key              = "tooltip",
            AnchorPoint      = Vector2.new(0, 0),
            Position         = UDim2.fromOffset(self.state.tooltipX, height + 2),
            Size             = UDim2.fromOffset(220, 22),
            BackgroundColor3 = theme:color("surfaceAlt"),
            BorderSizePixel  = 0,
            ZIndex           = 20,
        }, {
            e("UICorner", { CornerRadius = UDim.new(0, theme:radius("sm")) }),
            e("UIStroke", { Color = theme:color("border"), Thickness = 1 }),
            e("UIPadding", {
                PaddingLeft  = UDim.new(0, 8),
                PaddingRight = UDim.new(0, 8),
            }),
            e("TextLabel", {
                Text           = self.state.tooltipText,
                Font           = Enum.Font.Gotham,
                TextSize       = theme:size("font.ui") - 1,
                TextColor3     = theme:color("text"),
                TextXAlignment = Enum.TextXAlignment.Left,
                BackgroundTransparency = 1,
                Size           = UDim2.fromScale(1, 1),
            }),
        })
    end

    return e("Frame", {
        Size              = self.props.Size or UDim2.new(1, 0, 0, height),
        Position          = self.props.Position or UDim2.fromOffset(0, 0),
        BackgroundColor3  = theme:color("background"),
        BorderSizePixel   = 0,
        ZIndex            = 3,
    }, {
        -- Bottom border
        e("Frame", {
            key              = "underline",
            Size             = UDim2.new(1, 0, 0, 1),
            Position         = UDim2.new(0, 0, 1, -1),
            BackgroundColor3 = theme:color("border"),
            BorderSizePixel  = 0,
            ZIndex           = 3,
        }),
        Element.fragment(children),
    })
end

return Toolbar
