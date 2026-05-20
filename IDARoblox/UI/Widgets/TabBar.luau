--!nonstrict
-- =====================================================================
-- IDARoblox / UI / Widgets / TabBar
-- ---------------------------------------------------------------------
-- Horizontal tab strip. Each tab carries an id, label, optional icon,
-- dirty indicator, badge (numeric notification), and a close button.
--
-- Props
--   tabs         array of { id, label, icon?, dirty?, badge?, closable?, tooltip? }
--   activeId     id of the currently selected tab
--   onSelect     fn(id)
--   onClose      fn(id)
--   onAdd        fn() — clicking the "+" button at the end
--   onContextMenu fn(id, position) — right-click handler
--   addButton    boolean — whether to show "+" at the end
--   showCloseButtons boolean — default true
-- =====================================================================

local Component = _G.IDARo.require("UI.Framework.Component")
local Element   = _G.IDARo.require("UI.Framework.Element")
local e = Element.create
local Event = Element.Event

local TabBar = Component.extend("TabBar")

Component.setDefaultProps(TabBar, {
    tabs              = {},
    activeId          = nil,
    onSelect          = nil,
    onClose           = nil,
    onAdd             = nil,
    onContextMenu     = nil,
    addButton         = false,
    showCloseButtons  = true,
    height            = 28,
})

function TabBar:init()
    self.state = {
        hoveredId    = nil,
        scrollOffset = 0,
    }
end

local function clampToVisible(self, scrollOffset, contentSize, viewSize)
    if contentSize <= viewSize then return 0 end
    return math.max(0, math.min(scrollOffset, contentSize - viewSize))
end

function TabBar:_renderTab(tab, isActive, theme)
    local h = self.props.height
    local label = tab.label or tostring(tab.id)
    if tab.dirty then label = label .. " •" end
    local textW = (#label) * 7 + 36
    if tab.icon  then textW = textW + 18 end
    if tab.badge then textW = textW + 22 end
    if self.props.showCloseButtons and tab.closable ~= false then textW = textW + 20 end

    local bg, fg
    if isActive then
        bg = theme:color("tabActiveBg")
        fg = theme:color("tabActiveFg")
    elseif self.state.hoveredId == tab.id then
        bg = theme:color("tabHoverBg")
        fg = theme:color("tabFg")
    else
        bg = theme:color("tabBg")
        fg = theme:color("tabFg")
    end

    local content = {}

    -- Icon
    if tab.icon then
        content[#content + 1] = e("TextLabel", {
            Size = UDim2.new(0, 16, 1, 0),
            Position = UDim2.new(0, 4, 0, 0),
            Text = tab.icon,
            Font = Enum.Font.Code,
            TextSize = 14,
            TextColor3 = fg,
            BackgroundTransparency = 1,
        })
    end

    -- Label
    content[#content + 1] = e("TextLabel", {
        Size = UDim2.new(1, -(tab.icon and 20 or 0)
            - (tab.badge and 24 or 0)
            - ((self.props.showCloseButtons and tab.closable ~= false) and 22 or 0)
            - 8, 1, 0),
        Position = UDim2.new(0, tab.icon and 24 or 8, 0, 0),
        Text = label,
        Font = isActive and Enum.Font.SourceSansBold or Enum.Font.SourceSans,
        TextSize = 14,
        TextColor3 = fg,
        TextXAlignment = Enum.TextXAlignment.Left,
        BackgroundTransparency = 1,
    })

    -- Badge
    if tab.badge and tab.badge > 0 then
        content[#content + 1] = e("Frame", {
            Size = UDim2.new(0, 20, 0, 14),
            Position = UDim2.new(1, -(self.props.showCloseButtons and 44 or 24), 0.5, -7),
            BackgroundColor3 = theme:color("badge"),
            BorderSizePixel = 0,
        }, {
            e("TextLabel", {
                Size = UDim2.new(1, 0, 1, 0),
                Text = tostring(tab.badge),
                Font = Enum.Font.SourceSansBold,
                TextSize = 11,
                TextColor3 = theme:color("badgeFg"),
                BackgroundTransparency = 1,
            }),
            e("UICorner", { CornerRadius = UDim.new(0, 4) }),
        })
    end

    -- Close button
    if self.props.showCloseButtons and tab.closable ~= false then
        content[#content + 1] = e("TextButton", {
            Size = UDim2.new(0, 16, 0, 16),
            Position = UDim2.new(1, -20, 0.5, -8),
            Text = "×",
            Font = Enum.Font.SourceSans,
            TextSize = 16,
            TextColor3 = fg,
            BackgroundColor3 = (self.state.hoveredCloseId == tab.id)
                and theme:color("tabCloseHover") or theme:color("transparent"),
            BackgroundTransparency = (self.state.hoveredCloseId == tab.id) and 0 or 1,
            BorderSizePixel = 0,
            [Event "Activated"] = function()
                if self.props.onClose then self.props.onClose(tab.id) end
            end,
            [Event "MouseEnter"] = function()
                self:setState({ hoveredCloseId = tab.id })
            end,
            [Event "MouseLeave"] = function()
                if self.state.hoveredCloseId == tab.id then
                    self:setState({ hoveredCloseId = nil })
                end
            end,
        })
    end

    -- Wrap in a TextButton so the whole tab is clickable
    return e("TextButton", {
        Size = UDim2.new(0, textW, 0, h),
        Text = "",
        BackgroundColor3 = bg,
        BorderSizePixel = 0,
        AutoButtonColor = false,
        [Event "Activated"] = function(_, input)
            if input and input.UserInputType == Enum.UserInputType.MouseButton2 then
                if self.props.onContextMenu then
                    self.props.onContextMenu(tab.id, input.Position)
                end
            elseif input and input.UserInputType == Enum.UserInputType.MouseButton3 then
                -- Middle-click closes
                if self.props.onClose then self.props.onClose(tab.id) end
            else
                if self.props.onSelect then self.props.onSelect(tab.id) end
            end
        end,
        [Event "MouseEnter"] = function() self:setState({ hoveredId = tab.id }) end,
        [Event "MouseLeave"] = function()
            if self.state.hoveredId == tab.id then self:setState({ hoveredId = nil }) end
        end,
        [Event "InputBegan"] = function(_, input)
            if input.UserInputType == Enum.UserInputType.MouseButton2 then
                if self.props.onContextMenu then
                    self.props.onContextMenu(tab.id, input.Position)
                end
            elseif input.UserInputType == Enum.UserInputType.MouseButton3 then
                if self.props.onClose then self.props.onClose(tab.id) end
            end
        end,
    }, content)
end

function TabBar:render()
    local theme = self.theme
    local h = self.props.height
    local children = {}

    -- A horizontal scrolling frame containing each tab
    local tabElements = {}
    local listPad = 1
    tabElements[#tabElements + 1] = e("UIListLayout", {
        FillDirection = Enum.FillDirection.Horizontal,
        SortOrder     = Enum.SortOrder.LayoutOrder,
        Padding       = UDim.new(0, listPad),
    })
    for i, tab in self.props.tabs do
        tabElements[#tabElements + 1] = Element.withKey(tostring(tab.id),
            self:_renderTab(tab, tab.id == self.props.activeId, theme))
        tabElements[#tabElements].LayoutOrder = i
    end
    -- "+" button
    if self.props.addButton then
        tabElements[#tabElements + 1] = e("TextButton", {
            LayoutOrder = #self.props.tabs + 1,
            Size = UDim2.new(0, 28, 0, h),
            Text = "+",
            Font = Enum.Font.SourceSansBold,
            TextSize = 18,
            TextColor3 = theme:color("tabFg"),
            BackgroundColor3 = theme:color("tabBg"),
            BorderSizePixel = 0,
            [Event "Activated"] = function()
                if self.props.onAdd then self.props.onAdd() end
            end,
        })
    end

    children[#children + 1] = e("ScrollingFrame", {
        Size = UDim2.new(1, 0, 1, 0),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ScrollBarThickness = 4,
        CanvasSize = UDim2.new(0, 0, 0, 0),
        AutomaticCanvasSize = Enum.AutomaticSize.X,
        ScrollingDirection = Enum.ScrollingDirection.X,
        VerticalScrollBarInset = Enum.ScrollBarInset.None,
        HorizontalScrollBarInset = Enum.ScrollBarInset.ScrollBar,
    }, tabElements)

    return e("Frame", {
        Size = self.props.Size or UDim2.new(1, 0, 0, h),
        Position = self.props.Position or UDim2.new(0, 0, 0, 0),
        BackgroundColor3 = theme:color("tabBarBg"),
        BorderSizePixel = 0,
    }, children)
end

return TabBar
