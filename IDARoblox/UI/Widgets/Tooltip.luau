--!nonstrict
-- =====================================================================
-- IDARoblox / UI / Widgets / Tooltip
-- ---------------------------------------------------------------------
-- Hover tooltip. Two usage modes:
--
--   1. Wrapper mode — Tooltip wraps a child and shows the tooltip when
--      hovered for `hoverDelay` ms (default 500).
--
--   2. Imperative mode — Tooltip.show(layer, text, pos) / Tooltip.hide(layer)
--      mounts a transient tooltip programmatically.
--
-- Wrapper props
--   text         — plain string to show
--   renderContent — fn(theme) → Element  (overrides text)
--   hoverDelay   — ms before showing  (default 500)
--   showDelay    — ms before fade-in  (default 60)
--   hideDelay    — ms before fade-out (default 120)
--   maxWidth     — pixels (default 360)
--   placement    — "auto" | "above" | "below" | "right" | "left"
--   child        — the wrapped element
-- =====================================================================

local Component = _G.IDARo.require("UI.Framework.Component")
local Element   = _G.IDARo.require("UI.Framework.Element")
local e = Element.create
local Event = Element.Event

local TweenService = game:GetService("TweenService")

local Tooltip = Component.extend("Tooltip")

Component.setDefaultProps(Tooltip, {
    text           = "",
    renderContent  = nil,
    hoverDelay     = 0.5,
    showDelay      = 0.06,
    hideDelay      = 0.12,
    maxWidth       = 360,
    placement      = "auto",
    child          = nil,
})

function Tooltip:init()
    self.state = { visible = false, hovering = false, anchor = nil }
    self._showTimer = nil
    self._hideTimer = nil
end

function Tooltip:willUnmount()
    self:_cancelTimers()
end

function Tooltip:_cancelTimers()
    if self._showTimer then task.cancel(self._showTimer); self._showTimer = nil end
    if self._hideTimer then task.cancel(self._hideTimer); self._hideTimer = nil end
end

function Tooltip:_onEnter()
    self:setState({ hovering = true })
    self:_cancelTimers()
    self._showTimer = task.delay(self.props.hoverDelay, function()
        if self.state.hovering then self:setState({ visible = true }) end
    end)
end

function Tooltip:_onLeave()
    self:setState({ hovering = false })
    self:_cancelTimers()
    self._hideTimer = task.delay(self.props.hideDelay, function()
        if not self.state.hovering then self:setState({ visible = false }) end
    end)
end

local function measureTooltip(text, maxW)
    -- Cheap measurement: 7 px per char, wrap at maxW
    local lineCount = 1
    local w = 0
    local lineW = 0
    for i = 1, #text do
        lineW = lineW + 7
        if string.sub(text, i, i) == "\n" then
            w = math.max(w, lineW); lineW = 0; lineCount = lineCount + 1
        elseif lineW > maxW then
            w = maxW; lineW = 0; lineCount = lineCount + 1
        end
    end
    w = math.max(w, lineW)
    return w + 12, lineCount * 16 + 6
end

function Tooltip:render()
    local theme = self.theme
    local children = {}
    -- The child element with hover capture
    if self.props.child then
        children[#children + 1] = e("Frame", {
            Size = UDim2.new(1, 0, 1, 0),
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            [Event "MouseEnter"] = function() self:_onEnter() end,
            [Event "MouseLeave"] = function() self:_onLeave() end,
            [Element.Ref] = function(rbx) self._anchorRef = rbx end,
        }, { self.props.child })
    end
    -- Tooltip layer
    if self.state.visible then
        local text = self.props.text or ""
        local tw, th = measureTooltip(text, self.props.maxWidth)
        -- Compute placement relative to anchor
        local placement = self.props.placement
        local px, py = 0, 0
        if self._anchorRef then
            local abs = self._anchorRef.AbsolutePosition
            local sz  = self._anchorRef.AbsoluteSize
            if placement == "auto" or placement == "below" then
                px = abs.X; py = abs.Y + sz.Y + 4
            elseif placement == "above" then
                px = abs.X; py = abs.Y - th - 4
            elseif placement == "right" then
                px = abs.X + sz.X + 4; py = abs.Y
            elseif placement == "left" then
                px = abs.X - tw - 4; py = abs.Y
            end
            local cam = workspace.CurrentCamera
            local vs  = cam and cam.ViewportSize or Vector2.new(1920, 1080)
            if px + tw > vs.X then px = vs.X - tw end
            if py + th > vs.Y then py = abs.Y - th - 4 end             -- flip above
            if px < 0 then px = 0 end
            if py < 0 then py = 0 end
        end
        children[#children + 1] = e("Frame", {
            Size = UDim2.new(0, tw, 0, th),
            Position = UDim2.new(0, px, 0, py),
            BackgroundColor3 = theme:color("tooltipBg"),
            BorderSizePixel = 0,
            ZIndex = 5000,
        }, {
            self.props.renderContent and self.props.renderContent(theme) or
            e("TextLabel", {
                Size = UDim2.new(1, -8, 1, -4),
                Position = UDim2.new(0, 6, 0, 2),
                Text = text,
                Font = Enum.Font.SourceSans,
                TextSize = 13,
                TextColor3 = theme:color("tooltipFg"),
                TextXAlignment = Enum.TextXAlignment.Left,
                TextWrapped = true,
                BackgroundTransparency = 1,
            }),
            e("UIStroke", {
                Color = theme:color("tooltipBorder"),
                Thickness = 1,
            }),
        })
    end

    return e("Frame", {
        Size = self.props.Size or UDim2.new(0, 0, 0, 0),
        Position = self.props.Position or UDim2.new(0, 0, 0, 0),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
    }, children)
end

return Tooltip
