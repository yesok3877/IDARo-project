--!nonstrict
-- =====================================================================
-- IDARoblox / UI / Framework / LayoutEngine
-- ---------------------------------------------------------------------
-- Three docking primitives, all built on the Component framework:
--
--   Splitter   — two children, draggable divider (horizontal/vertical)
--   TabGroup   — header strip + active body
--   Panel      — titled container with optional toolbar/footer slots
--
-- Layouts compose: a workspace is typically Splitter→{TabGroup, Splitter→
-- {TabGroup, TabGroup}}. The recursive nesting is the docking system.
-- =====================================================================

local Component = _G.IDARo.require("UI.Framework.Component")
local Element   = _G.IDARo.require("UI.Framework.Element")
local e         = Element.create
local Event     = Element.Event

local LayoutEngine = {}

local UserInputService = game:GetService("UserInputService")

-- =====================================================================
-- Splitter
-- =====================================================================

local Splitter = Component.extend("Splitter")
LayoutEngine.Splitter = Splitter

Component.setDefaultProps(Splitter, {
    orientation  = "horizontal",                                    -- "horizontal" | "vertical"
    ratio        = 0.5,
    minFirst     = 64,
    minSecond    = 64,
    splitterPx   = nil,                                             -- overrides theme size
    Size         = UDim2.fromScale(1, 1),
    Position     = UDim2.fromOffset(0, 0),
})

function Splitter:init(props)
    self.state = {
        ratio    = props.ratio,
        dragging = false,
        hover    = false,
        absSize  = Vector2.new(800, 600),
    }
    self._dragStartInput = nil
    self._dragStartRatio = 0
    self._inputConn = nil
    self._moveConn = nil
end

function Splitter:didMount()
    -- Track absolute size changes so min constraints honor pixel sizes.
    if self._node and self._node.instance then
        local container = self._node.instance
        self._sizeConn = container:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
            self:setState({ absSize = container.AbsoluteSize })
        end)
        self:setState({ absSize = container.AbsoluteSize })
    end
end

function Splitter:willUnmount()
    if self._sizeConn then self._sizeConn:Disconnect() end
    if self._inputConn then self._inputConn:Disconnect() end
    if self._moveConn then self._moveConn:Disconnect() end
end

function Splitter:_beginDrag(input)
    self._dragStartInput = input.Position
    self._dragStartRatio = self.state.ratio
    self:setState({ dragging = true })
    if self._moveConn then self._moveConn:Disconnect() end
    self._moveConn = UserInputService.InputChanged:Connect(function(moved)
        if moved.UserInputType == Enum.UserInputType.MouseMovement
            or moved.UserInputType == Enum.UserInputType.Touch then
            self:_dragTo(moved.Position)
        end
    end)
    if self._inputConn then self._inputConn:Disconnect() end
    self._inputConn = UserInputService.InputEnded:Connect(function(ended)
        if ended.UserInputType == Enum.UserInputType.MouseButton1
            or ended.UserInputType == Enum.UserInputType.Touch then
            self:_endDrag()
        end
    end)
end

function Splitter:_dragTo(pos)
    local startPos = self._dragStartInput
    if not startPos then return end
    local size = self.state.absSize
    local axis = if self.props.orientation == "horizontal" then "X" else "Y"
    local total = size[axis]
    if total <= 0 then return end
    local delta = pos[axis] - startPos[axis]
    local pixelOffset = self._dragStartRatio * total + delta
    local minFirst = self.props.minFirst
    local minSecond = self.props.minSecond
    local maxPx = total - minSecond
    if pixelOffset < minFirst then pixelOffset = minFirst end
    if pixelOffset > maxPx then pixelOffset = maxPx end
    local newRatio = pixelOffset / total
    if newRatio ~= self.state.ratio then
        self:setState({ ratio = newRatio })
        if self.props.onResize then pcall(self.props.onResize, newRatio) end
    end
end

function Splitter:_endDrag()
    if self._moveConn then self._moveConn:Disconnect() self._moveConn = nil end
    if self._inputConn then self._inputConn:Disconnect() self._inputConn = nil end
    self:setState({ dragging = false })
end

function Splitter:render()
    local ratio = self.state.ratio
    local isH = self.props.orientation == "horizontal"
    local splitPx = self.props.splitterPx or self.theme:size("splitter")
    local kids = self.props.children or {}
    local firstChild  = kids[1] or e("Frame", { BackgroundTransparency = 1 })
    local secondChild = kids[2] or e("Frame", { BackgroundTransparency = 1 })
    local color = self.theme:color(if self.state.dragging or self.state.hover then "primary" else "border")

    local firstSize, firstPos, secondSize, secondPos, divPos, divSize, cursor
    if isH then
        firstSize  = UDim2.new(ratio, -math.floor(splitPx / 2), 1, 0)
        firstPos   = UDim2.fromOffset(0, 0)
        secondSize = UDim2.new(1 - ratio, -math.ceil(splitPx / 2), 1, 0)
        secondPos  = UDim2.new(ratio, math.ceil(splitPx / 2), 0, 0)
        divPos     = UDim2.new(ratio, -math.floor(splitPx / 2), 0, 0)
        divSize    = UDim2.new(0, splitPx, 1, 0)
    else
        firstSize  = UDim2.new(1, 0, ratio, -math.floor(splitPx / 2))
        firstPos   = UDim2.fromOffset(0, 0)
        secondSize = UDim2.new(1, 0, 1 - ratio, -math.ceil(splitPx / 2))
        secondPos  = UDim2.new(0, 0, ratio, math.ceil(splitPx / 2))
        divPos     = UDim2.new(0, 0, ratio, -math.floor(splitPx / 2))
        divSize    = UDim2.new(1, 0, 0, splitPx)
    end

    return e("Frame", {
        Size                = self.props.Size,
        Position            = self.props.Position,
        BackgroundColor3    = self.theme:color("background"),
        BorderSizePixel     = 0,
    }, {
        e("Frame", {
            key              = "first",
            Size             = firstSize,
            Position         = firstPos,
            BackgroundTransparency = 1,
            BorderSizePixel  = 0,
            ClipsDescendants = true,
        }, { firstChild }),
        e("Frame", {
            key              = "second",
            Size             = secondSize,
            Position         = secondPos,
            BackgroundTransparency = 1,
            BorderSizePixel  = 0,
            ClipsDescendants = true,
        }, { secondChild }),
        e("Frame", {
            key              = "divider",
            Size             = divSize,
            Position         = divPos,
            BackgroundColor3 = color,
            BorderSizePixel  = 0,
            ZIndex           = 5,
            [Event.MouseEnter] = function()
                if self.state.hover then return end
                task.defer(function()
                    if self.state and not self.state.hover then
                        self:setState({ hover = true })
                    end
                end)
            end,
            [Event.MouseLeave] = function()
                if not self.state.hover then return end
                task.defer(function()
                    if self.state and self.state.hover then
                        self:setState({ hover = false })
                    end
                end)
            end,
            [Event.InputBegan] = function(_, input)
                if input.UserInputType == Enum.UserInputType.MouseButton1
                    or input.UserInputType == Enum.UserInputType.Touch then
                    self:_beginDrag(input)
                end
            end,
        }),
    })
end

-- =====================================================================
-- TabGroup
-- =====================================================================

local TabGroup = Component.extend("TabGroup")
LayoutEngine.TabGroup = TabGroup

Component.setDefaultProps(TabGroup, {
    tabs        = {},                                               -- { { id, label, content (element|fn) }, ... }
    activeId    = nil,
    onTabSelect = nil,
    Size        = UDim2.fromScale(1, 1),
    Position    = UDim2.fromOffset(0, 0),
})

function TabGroup:init(props)
    self.state = {
        activeId = props.activeId or (props.tabs[1] and props.tabs[1].id),
    }
end

function TabGroup:_onTab(id)
    if self.state.activeId == id then return end
    self:setState({ activeId = id })
    if self.props.onTabSelect then pcall(self.props.onTabSelect, id) end
end

function TabGroup:render()
    local tabBarHeight = self.theme:size("tabBar")
    local tabsRender = {}
    local x = 0
    local theme = self.theme
    for _, tab in self.props.tabs do
        local isActive = tab.id == self.state.activeId
        local labelText = tab.label or tab.id
        local approxWidth = math.max(80, #labelText * 7 + 28)
        tabsRender[#tabsRender + 1] = e("TextButton", {
            key                  = "tab:" .. tab.id,
            Size                 = UDim2.fromOffset(approxWidth, tabBarHeight),
            Position             = UDim2.fromOffset(x, 0),
            Text                 = labelText,
            Font                 = Enum.Font.GothamMedium,
            TextSize             = theme:size("font.ui"),
            TextColor3           = theme:color(if isActive then "text" else "textMuted"),
            BackgroundColor3     = theme:color(if isActive then "surface" else "surfaceAlt"),
            BorderSizePixel      = 0,
            AutoButtonColor      = false,
            ZIndex               = if isActive then 3 else 2,
            [Event.Activated] = function() self:_onTab(tab.id) end,
        }, {
            isActive and e("Frame", {
                key              = "underline",
                Size             = UDim2.new(1, 0, 0, 2),
                Position         = UDim2.new(0, 0, 1, -2),
                BackgroundColor3 = theme:color("primary"),
                BorderSizePixel  = 0,
            }),
        })
        x = x + approxWidth
    end

    -- Active body
    local activeBody
    for _, tab in self.props.tabs do
        if tab.id == self.state.activeId then
            activeBody = if type(tab.content) == "function" then tab.content() else tab.content
            break
        end
    end

    return e("Frame", {
        Size             = self.props.Size,
        Position         = self.props.Position,
        BackgroundColor3 = theme:color("surface"),
        BorderSizePixel  = 0,
    }, {
        e("Frame", {
            key              = "tabbar",
            Size             = UDim2.new(1, 0, 0, tabBarHeight),
            BackgroundColor3 = theme:color("surfaceAlt"),
            BorderSizePixel  = 0,
            ZIndex           = 2,
        }, tabsRender),
        e("Frame", {
            key              = "divider",
            Size             = UDim2.new(1, 0, 0, 1),
            Position         = UDim2.new(0, 0, 0, tabBarHeight),
            BackgroundColor3 = theme:color("border"),
            BorderSizePixel  = 0,
            ZIndex           = 3,
        }),
        e("Frame", {
            key              = "body",
            Size             = UDim2.new(1, 0, 1, -(tabBarHeight + 1)),
            Position         = UDim2.new(0, 0, 0, tabBarHeight + 1),
            BackgroundTransparency = 1,
            BorderSizePixel  = 0,
            ClipsDescendants = true,
        }, { activeBody }),
    })
end

-- =====================================================================
-- Panel
-- =====================================================================

local Panel = Component.extend("Panel")
LayoutEngine.Panel = Panel

Component.setDefaultProps(Panel, {
    title       = "",
    icon        = nil,
    toolbar     = nil,
    footer      = nil,
    Size        = UDim2.fromScale(1, 1),
    Position    = UDim2.fromOffset(0, 0),
})

function Panel:render()
    local theme = self.theme
    local titleHeight = if (self.props.title or "") ~= "" then 22 else 0
    local footerHeight = if self.props.footer then 22 else 0
    return e("Frame", {
        Size             = self.props.Size,
        Position         = self.props.Position,
        BackgroundColor3 = theme:color("surface"),
        BorderSizePixel  = 0,
    }, {
        titleHeight > 0 and e("Frame", {
            key              = "header",
            Size             = UDim2.new(1, 0, 0, titleHeight),
            BackgroundColor3 = theme:color("surfaceAlt"),
            BorderSizePixel  = 0,
        }, {
            e("UIPadding", {
                PaddingLeft = UDim.new(0, theme:spacing("md")),
                PaddingRight = UDim.new(0, theme:spacing("md")),
            }),
            e("TextLabel", {
                Text             = self.props.title,
                Font             = Enum.Font.GothamMedium,
                TextSize         = theme:size("font.ui"),
                TextColor3       = theme:color("textMuted"),
                TextXAlignment   = Enum.TextXAlignment.Left,
                BackgroundTransparency = 1,
                Size             = UDim2.fromScale(1, 1),
            }),
        }),
        e("Frame", {
            key              = "body",
            Size             = UDim2.new(1, 0, 1, -(titleHeight + footerHeight)),
            Position         = UDim2.new(0, 0, 0, titleHeight),
            BackgroundTransparency = 1,
            ClipsDescendants = true,
        }, self.props.children or {}),
        footerHeight > 0 and e("Frame", {
            key              = "footer",
            Size             = UDim2.new(1, 0, 0, footerHeight),
            Position         = UDim2.new(0, 0, 1, -footerHeight),
            BackgroundColor3 = theme:color("surfaceAlt"),
            BorderSizePixel  = 0,
        }, { self.props.footer }),
        e("Frame", {
            key              = "topBorder",
            Size             = UDim2.new(1, 0, 0, 1),
            Position         = UDim2.new(0, 0, 0, titleHeight),
            BackgroundColor3 = theme:color("border"),
            BorderSizePixel  = 0,
        }),
    })
end

return LayoutEngine
