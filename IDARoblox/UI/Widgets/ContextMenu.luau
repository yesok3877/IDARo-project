--!nonstrict
-- =====================================================================
-- IDARoblox / UI / Widgets / ContextMenu
-- ---------------------------------------------------------------------
-- Right-click style popup menu. Renders into an overlay layer so it
-- sits above everything else. Each item is one of:
--
--   { label, icon?, accelerator?, action, submenu?, disabled?, checked? }
--   { separator = true }
--
-- Submenus are arrays of items. Hovering an item with a submenu opens
-- the child menu to the right, auto-flipped to the left if it would
-- run off the viewport edge.
--
-- Props
--   items          array of items
--   position       Vector2 (screen coords) where to open
--   onClose        fn() — fired when the menu closes for any reason
--   parentMenu     reference for submenu nesting (internal)
--
-- Imperative
--   ContextMenu.open(workspace, items, position)
--       Mounts a transient instance and returns a handle with :close()
-- =====================================================================

local Component        = _G.IDARo.require("UI.Framework.Component")
local Element          = _G.IDARo.require("UI.Framework.Element")
local UserInputService = game:GetService("UserInputService")
local e = Element.create
local Event = Element.Event

local ROW_HEIGHT       = 22
local SEPARATOR_HEIGHT = 6
local MIN_WIDTH        = 160
local MENU_PADDING     = 4

local ContextMenu = Component.extend("ContextMenu")

Component.setDefaultProps(ContextMenu, {
    items      = {},
    position   = Vector2.new(0, 0),
    onClose    = nil,
    parentMenu = nil,
})

function ContextMenu:init()
    self.state = {
        hoveredIdx     = nil,
        openSubmenuIdx = nil,
        submenuPos     = nil,
    }
    self._keyConn   = nil
    self._inputConn = nil
end

function ContextMenu:didMount()
    -- Esc closes
    self._keyConn = UserInputService.InputBegan:Connect(function(input, processed)
        if processed then return end
        if input.KeyCode == Enum.KeyCode.Escape then self:_close() end
    end)
    -- Click outside closes
    self._inputConn = UserInputService.InputBegan:Connect(function(input, processed)
        if input.UserInputType ~= Enum.UserInputType.MouseButton1
            and input.UserInputType ~= Enum.UserInputType.MouseButton2 then return end
        if not self._rootRef then return end
        local pos = input.Position
        local abs = self._rootRef.AbsolutePosition
        local sz  = self._rootRef.AbsoluteSize
        if pos.X < abs.X or pos.X > abs.X + sz.X
            or pos.Y < abs.Y or pos.Y > abs.Y + sz.Y then
            -- check submenu hit
            if not (self._submenuRef and self._inSubmenu(self, pos)) then
                self:_close()
            end
        end
    end)
end

function ContextMenu._inSubmenu(self, pos)
    if not self._submenuRef then return false end
    local abs = self._submenuRef.AbsolutePosition
    local sz  = self._submenuRef.AbsoluteSize
    return pos.X >= abs.X and pos.X <= abs.X + sz.X
        and pos.Y >= abs.Y and pos.Y <= abs.Y + sz.Y
end

function ContextMenu:willUnmount()
    if self._keyConn then self._keyConn:Disconnect() end
    if self._inputConn then self._inputConn:Disconnect() end
end

function ContextMenu:_close()
    if self.props.onClose then self.props.onClose() end
end

function ContextMenu:_invoke(item)
    if item.disabled then return end
    if not item.submenu and item.action then
        local ok, err = pcall(item.action)
        if not ok and self.logger then
            self.logger:warn("ContextMenu action failed: %s", tostring(err))
        end
        self:_close()
    end
end

-- ---------------------------------------------------------------------
-- Measure menu size from items
-- ---------------------------------------------------------------------

local function measureMenu(items)
    local maxLabel, maxAccel = 0, 0
    local h = MENU_PADDING * 2
    for _, item in items do
        if item.separator then
            h = h + SEPARATOR_HEIGHT
        else
            h = h + ROW_HEIGHT
            if item.label   then maxLabel = math.max(maxLabel, #item.label) end
            if item.accelerator then maxAccel = math.max(maxAccel, #item.accelerator) end
        end
    end
    local w = math.max(MIN_WIDTH, maxLabel * 7 + maxAccel * 7 + 56)
    return w, h
end

-- Flip-to-fit at the screen edges
local function fitOnScreen(pos, w, h)
    local cam = workspace.CurrentCamera
    local sz = cam and cam.ViewportSize or Vector2.new(1920, 1080)
    local x, y = pos.X, pos.Y
    if x + w > sz.X then x = math.max(0, sz.X - w) end
    if y + h > sz.Y then y = math.max(0, sz.Y - h) end
    return Vector2.new(x, y)
end

-- ---------------------------------------------------------------------
-- Render
-- ---------------------------------------------------------------------

function ContextMenu:_renderRow(item, idx)
    local theme = self.theme
    if item.separator then
        return e("Frame", {
            Size = UDim2.new(1, -8, 0, SEPARATOR_HEIGHT),
            Position = UDim2.new(0, 4, 0, 0),
            LayoutOrder = idx,
            BackgroundTransparency = 1,
        }, {
            e("Frame", {
                Size = UDim2.new(1, 0, 0, 1),
                Position = UDim2.new(0, 0, 0.5, 0),
                BackgroundColor3 = theme:color("menuSeparator"),
                BorderSizePixel = 0,
            })
        })
    end
    local hovered = self.state.hoveredIdx == idx
    local fg = item.disabled and theme:color("menuDisabledFg") or theme:color("menuFg")
    return e("TextButton", {
        Size = UDim2.new(1, -4, 0, ROW_HEIGHT),
        Position = UDim2.new(0, 2, 0, 0),
        LayoutOrder = idx,
        BackgroundColor3 = hovered and theme:color("menuHoverBg") or theme:color("transparent"),
        BackgroundTransparency = hovered and 0 or 1,
        BorderSizePixel = 0,
        Text = "",
        AutoButtonColor = false,
        [Event "MouseEnter"] = function()
            self:setState({ hoveredIdx = idx })
            if item.submenu then
                -- Compute submenu position to the right of this row
                if self._rootRef then
                    local abs = self._rootRef.AbsolutePosition
                    local sz  = self._rootRef.AbsoluteSize
                    self:setState({
                        openSubmenuIdx = idx,
                        submenuPos = Vector2.new(abs.X + sz.X, abs.Y + (idx - 1) * ROW_HEIGHT),
                    })
                end
            else
                if self.state.openSubmenuIdx ~= nil then
                    self:setState({ openSubmenuIdx = nil, submenuPos = nil })
                end
            end
        end,
        [Event "Activated"] = function() self:_invoke(item) end,
    }, {
        -- Check mark / icon
        e("TextLabel", {
            Size = UDim2.new(0, 16, 1, 0),
            Position = UDim2.new(0, 4, 0, 0),
            Text = item.checked and "✓" or (item.icon or ""),
            Font = Enum.Font.Code,
            TextSize = 12,
            TextColor3 = fg,
            TextXAlignment = Enum.TextXAlignment.Center,
            BackgroundTransparency = 1,
        }),
        -- Label
        e("TextLabel", {
            Size = UDim2.new(1, -100, 1, 0),
            Position = UDim2.new(0, 24, 0, 0),
            Text = item.label or "",
            Font = Enum.Font.SourceSans,
            TextSize = 13,
            TextColor3 = fg,
            TextXAlignment = Enum.TextXAlignment.Left,
            BackgroundTransparency = 1,
        }),
        -- Accelerator
        e("TextLabel", {
            Size = UDim2.new(0, 70, 1, 0),
            Position = UDim2.new(1, -88, 0, 0),
            Text = item.accelerator or "",
            Font = Enum.Font.SourceSans,
            TextSize = 11,
            TextColor3 = theme:color("menuAcceleratorFg"),
            TextXAlignment = Enum.TextXAlignment.Right,
            BackgroundTransparency = 1,
        }),
        -- Submenu arrow
        item.submenu and e("TextLabel", {
            Size = UDim2.new(0, 12, 1, 0),
            Position = UDim2.new(1, -14, 0, 0),
            Text = "▸",
            Font = Enum.Font.SourceSans,
            TextSize = 11,
            TextColor3 = fg,
            BackgroundTransparency = 1,
        }) or nil,
    })
end

function ContextMenu:render()
    local items = self.props.items
    local w, h  = measureMenu(items)
    local pos   = fitOnScreen(self.props.position, w, h)
    local theme = self.theme

    local rows = {
        e("UIListLayout", {
            FillDirection = Enum.FillDirection.Vertical,
            SortOrder     = Enum.SortOrder.LayoutOrder,
            Padding       = UDim.new(0, 0),
        }),
        e("UIPadding", {
            PaddingTop = UDim.new(0, MENU_PADDING),
            PaddingBottom = UDim.new(0, MENU_PADDING),
        }),
    }
    for i, item in items do
        rows[#rows + 1] = self:_renderRow(item, i)
    end

    local root = e("Frame", {
        Size = UDim2.new(0, w, 0, h),
        Position = UDim2.new(0, pos.X, 0, pos.Y),
        BackgroundColor3 = theme:color("menuBg"),
        BorderSizePixel = 0,
        ZIndex = 1000,
        [Element.Ref] = function(rbx) self._rootRef = rbx end,
    }, rows)

    -- Submenu (rendered as sibling overlay)
    local children = { root }
    if self.state.openSubmenuIdx then
        local item = items[self.state.openSubmenuIdx]
        if item and item.submenu then
            children[#children + 1] = e(ContextMenu, {
                items    = item.submenu,
                position = self.state.submenuPos or Vector2.new(0, 0),
                onClose  = function()
                    self:setState({ openSubmenuIdx = nil, submenuPos = nil })
                    self:_close()
                end,
                parentMenu = self,
                [Element.Ref] = function(rbx) self._submenuRef = rbx end,
            })
        end
    end

    return e("Frame", {
        Size = UDim2.new(1, 0, 1, 0),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ZIndex = 1000,
    }, children)
end

return ContextMenu
