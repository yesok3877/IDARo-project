--!nonstrict
-- =====================================================================
-- IDARoblox / UI / Widgets / StatusBar
-- ---------------------------------------------------------------------
-- Bottom status bar.
--
-- Props:
--   statusText   — string shown at the LHS
--   items        — array of indicator pills shown at the RHS:
--                  { label = "proto 12/47", icon = "ƒ", tooltip = … }
--   showFps      — if true, auto-appends a live "60 fps" pill driven by
--                  RunService.Heartbeat sampling.
-- =====================================================================

local Component = _G.IDARo.require("UI.Framework.Component")
local Element   = _G.IDARo.require("UI.Framework.Element")
local RunService = game:GetService("RunService")
local e         = Element.create

local StatusBar = Component.extend("StatusBar")

Component.setDefaultProps(StatusBar, {
    statusText = "",
    items      = {},
    showFps    = true,
    Size       = nil,
    Position   = nil,
})

function StatusBar:init()
    self.state = { fps = 60 }
    self._frames = 0
    self._timeAccum = 0
end

function StatusBar:didMount()
    if self.props.showFps then
        self._fpsConn = RunService.Heartbeat:Connect(function(dt)
            self._frames = self._frames + 1
            self._timeAccum = self._timeAccum + dt
            if self._timeAccum >= 0.5 then
                local fps = math.floor(self._frames / self._timeAccum + 0.5)
                self._frames = 0
                self._timeAccum = 0
                if self._mounted and fps ~= self.state.fps then
                    self:setState({ fps = fps })
                end
            end
        end)
    end
end

function StatusBar:willUnmount()
    if self._fpsConn then self._fpsConn:Disconnect() end
end

function StatusBar:_renderPill(item, index)
    local theme = self.theme
    local label = item.label or ""
    local icon  = item.icon
    local approxWidth = #label * 7 + (icon and 18 or 0) + theme:spacing("md") * 2
    if approxWidth < 60 then approxWidth = 60 end

    return e("Frame", {
        key              = "pill:" .. index,
        Size             = UDim2.fromOffset(approxWidth, theme:size("statusBar") - 6),
        BackgroundTransparency = 1,
        LayoutOrder      = index,
    }, {
        e("UIPadding", {
            PaddingLeft  = UDim.new(0, theme:spacing("sm")),
            PaddingRight = UDim.new(0, theme:spacing("sm")),
        }),
        e("UIListLayout", {
            FillDirection = Enum.FillDirection.Horizontal,
            VerticalAlignment = Enum.VerticalAlignment.Center,
            SortOrder = Enum.SortOrder.LayoutOrder,
            Padding   = UDim.new(0, 4),
        }),
        icon and e("TextLabel", {
            key            = "icon",
            Size           = UDim2.fromOffset(14, theme:size("statusBar") - 6),
            Text           = icon,
            Font           = Enum.Font.Gotham,
            TextSize       = theme:size("font.ui") - 1,
            TextColor3     = item.color and theme:color(item.color) or theme:color("textSubtle"),
            BackgroundTransparency = 1,
            LayoutOrder    = 1,
        }),
        e("TextLabel", {
            key            = "label",
            Size           = UDim2.fromOffset(approxWidth - (icon and 30 or 16), theme:size("statusBar") - 6),
            Text           = label,
            Font           = Enum.Font.RobotoMono,
            TextSize       = theme:size("font.ui") - 1,
            TextColor3     = theme:color("textMuted"),
            TextXAlignment = Enum.TextXAlignment.Left,
            BackgroundTransparency = 1,
            LayoutOrder    = 2,
        }),
    })
end

function StatusBar:render()
    local theme = self.theme
    local height = theme:size("statusBar")

    local items = table.clone(self.props.items or {})
    if self.props.showFps then
        items[#items + 1] = {
            label = string.format("%d fps", self.state.fps),
            icon  = "⌧",
        }
    end

    local pills = {}
    for i, it in items do
        pills[i] = self:_renderPill(it, i)
    end

    return e("Frame", {
        Size              = self.props.Size or UDim2.new(1, 0, 0, height),
        Position          = self.props.Position or UDim2.fromOffset(0, 0),
        BackgroundColor3  = theme:color("surfaceAlt"),
        BorderSizePixel   = 0,
        ZIndex            = 3,
    }, {
        -- Top border
        e("Frame", {
            key              = "topborder",
            Size             = UDim2.new(1, 0, 0, 1),
            Position         = UDim2.fromOffset(0, 0),
            BackgroundColor3 = theme:color("border"),
            BorderSizePixel  = 0,
            ZIndex           = 3,
        }),
        e("UIPadding", {
            PaddingLeft  = UDim.new(0, theme:spacing("md")),
            PaddingRight = UDim.new(0, theme:spacing("md")),
            PaddingTop   = UDim.new(0, 3),
            PaddingBottom = UDim.new(0, 2),
        }),
        -- LHS status text
        e("TextLabel", {
            key              = "status",
            AnchorPoint      = Vector2.new(0, 0.5),
            Position         = UDim2.new(0, 0, 0.5, 0),
            Size             = UDim2.new(0.5, 0, 1, 0),
            Text             = self.props.statusText or "",
            Font             = Enum.Font.Gotham,
            TextSize         = theme:size("font.ui") - 1,
            TextColor3       = theme:color("text"),
            TextXAlignment   = Enum.TextXAlignment.Left,
            TextTruncate     = Enum.TextTruncate.AtEnd,
            BackgroundTransparency = 1,
            ZIndex           = 4,
        }),
        -- RHS pills
        e("Frame", {
            key              = "pills",
            AnchorPoint      = Vector2.new(1, 0.5),
            Position         = UDim2.new(1, 0, 0.5, 0),
            Size             = UDim2.new(0.5, 0, 1, 0),
            BackgroundTransparency = 1,
            ZIndex           = 4,
        }, {
            e("UIListLayout", {
                FillDirection = Enum.FillDirection.Horizontal,
                HorizontalAlignment = Enum.HorizontalAlignment.Right,
                VerticalAlignment = Enum.VerticalAlignment.Center,
                SortOrder = Enum.SortOrder.LayoutOrder,
                Padding   = UDim.new(0, 8),
            }),
            Element.fragment(pills),
        }),
    })
end

return StatusBar
