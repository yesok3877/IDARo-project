--!nonstrict
-- =====================================================================
-- IDARoblox / UI / Widgets / Splitter
-- ---------------------------------------------------------------------
-- Draggable splitter that divides a container into two resizable panes.
-- Orientations: horizontal (left | right) or vertical (top / bottom).
-- The split is described as a ratio in (0,1); the actual pixel position
-- is computed at render time from props.Size.
--
-- Props
--   orientation     "horizontal" | "vertical"
--   ratio           initial split (0..1); defaults to 0.5
--   minRatio        minimum allowed ratio (default 0.05)
--   maxRatio        maximum allowed ratio (default 0.95)
--   gutterSize      px width of the draggable gutter (default 6)
--   snapThreshold   if drag releases below this, snap to 0 (collapse first
--                   pane); above (1 - threshold) → snap to 1
--   first           render-fn for the first pane (receives subFrame)
--   second          render-fn for the second pane
--   onRatioChange   fn(newRatio) — emitted on commit (mouse up)
--   onResize        fn(newRatio) — emitted continuously during drag
--
-- Imperative API
--   :setRatio(r)             — sets the current ratio + re-renders
--   :collapse(which)         — "first" | "second" → instant collapse
--   :uncollapse()            — restore the prior ratio
-- =====================================================================

local Component   = _G.IDARo.require("UI.Framework.Component")
local Element     = _G.IDARo.require("UI.Framework.Element")
local e           = Element.create
local Event       = Element.Event

local UserInputService = game:GetService("UserInputService")

local Splitter = Component.extend("Splitter")

Component.setDefaultProps(Splitter, {
    orientation   = "horizontal",
    ratio         = 0.5,
    minRatio      = 0.05,
    maxRatio      = 0.95,
    gutterSize    = 6,
    snapThreshold = 0.03,
    first         = nil,
    second        = nil,
    onRatioChange = nil,
    onResize      = nil,
})

function Splitter:init(props)
    self.state = {
        ratio         = props.ratio,
        dragging      = false,
        hovering      = false,
        savedRatio    = props.ratio,                                 -- for uncollapse()
    }
    self._inputConn      = nil
    self._inputChangeConn = nil
end

function Splitter:didMount()
    -- We connect on demand in :_beginDrag; nothing to do at mount.
end

function Splitter:willUnmount()
    self:_endDrag()
end

function Splitter:setRatio(r)
    r = math.max(self.props.minRatio, math.min(self.props.maxRatio, r))
    if self.state.ratio ~= r then
        self:setState({ ratio = r })
        if self.props.onRatioChange then self.props.onRatioChange(r) end
    end
end

function Splitter:collapse(which)
    self.state.savedRatio = self.state.ratio
    self:setState({ ratio = (which == "first") and 0 or 1 })
end

function Splitter:uncollapse()
    self:setRatio(self.state.savedRatio or 0.5)
end

function Splitter:_beginDrag()
    if self.state.dragging then return end
    self:setState({ dragging = true })
    local axis = self.props.orientation == "horizontal" and "X" or "Y"
    self._inputChangeConn = UserInputService.InputChanged:Connect(function(input)
        if input.UserInputType ~= Enum.UserInputType.MouseMovement then return end
        if not self._rootRef then return end
        local rootAbsPos  = self._rootRef.AbsolutePosition
        local rootAbsSize = self._rootRef.AbsoluteSize
        local cursor = input.Position
        local rel = (axis == "X")
            and ((cursor.X - rootAbsPos.X) / math.max(1, rootAbsSize.X))
            or  ((cursor.Y - rootAbsPos.Y) / math.max(1, rootAbsSize.Y))
        rel = math.max(self.props.minRatio, math.min(self.props.maxRatio, rel))
        if self.state.ratio ~= rel then
            self:setState({ ratio = rel })
            if self.props.onResize then self.props.onResize(rel) end
        end
    end)
    self._inputConn = UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
        local r = self.state.ratio
        -- Snap behavior
        if r < self.props.snapThreshold then r = 0
        elseif r > (1 - self.props.snapThreshold) then r = 1 end
        self:setState({ dragging = false, ratio = r })
        if self.props.onRatioChange then self.props.onRatioChange(r) end
        self:_endDrag()
    end)
end

function Splitter:_endDrag()
    if self._inputConn then self._inputConn:Disconnect(); self._inputConn = nil end
    if self._inputChangeConn then self._inputChangeConn:Disconnect(); self._inputChangeConn = nil end
end

-- ---------------------------------------------------------------------
-- Render
-- ---------------------------------------------------------------------

function Splitter:render()
    local theme   = self.theme
    local hor     = self.props.orientation == "horizontal"
    local gutter  = self.props.gutterSize
    local r       = self.state.ratio
    local color
    if self.state.dragging       then color = theme:color("splitterActive")
    elseif self.state.hovering   then color = theme:color("splitterHover")
    else                              color = theme:color("splitterIdle") end
    -- Build subframes
    local firstFrame  = hor
        and { Size = UDim2.new(r, -gutter/2, 1, 0),
              Position = UDim2.new(0, 0, 0, 0) }
        or  { Size = UDim2.new(1, 0, r, -gutter/2),
              Position = UDim2.new(0, 0, 0, 0) }
    local gutterFrame = hor
        and { Size = UDim2.new(0, gutter, 1, 0),
              Position = UDim2.new(r, -gutter/2, 0, 0) }
        or  { Size = UDim2.new(1, 0, 0, gutter),
              Position = UDim2.new(0, 0, r, -gutter/2) }
    local secondFrame = hor
        and { Size = UDim2.new(1-r, -gutter/2, 1, 0),
              Position = UDim2.new(r, gutter/2, 0, 0) }
        or  { Size = UDim2.new(1, 0, 1-r, -gutter/2),
              Position = UDim2.new(0, 0, r, gutter/2) }

    local children = {}
    if self.props.first then
        children[#children + 1] = e("Frame", {
            Size              = firstFrame.Size,
            Position          = firstFrame.Position,
            BackgroundTransparency = 1,
            ClipsDescendants  = true,
        }, { self.props.first(firstFrame) })
    end
    children[#children + 1] = e("Frame", {
        Size                   = gutterFrame.Size,
        Position               = gutterFrame.Position,
        BackgroundColor3       = color,
        BorderSizePixel        = 0,
        ZIndex                 = 50,
        [Event "InputBegan"] = function(_, input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 then
                self:_beginDrag()
            elseif input.UserInputType == Enum.UserInputType.MouseMovement then
                if not self.state.hovering then self:setState({ hovering = true }) end
            end
        end,
        [Event "InputEnded"] = function(_, input)
            if input.UserInputType == Enum.UserInputType.MouseMovement then
                if self.state.hovering then self:setState({ hovering = false }) end
            end
        end,
    })
    if self.props.second then
        children[#children + 1] = e("Frame", {
            Size              = secondFrame.Size,
            Position          = secondFrame.Position,
            BackgroundTransparency = 1,
            ClipsDescendants  = true,
        }, { self.props.second(secondFrame) })
    end

    return e("Frame", {
        Size                  = self.props.Size or UDim2.new(1, 0, 1, 0),
        Position              = self.props.Position or UDim2.new(0, 0, 0, 0),
        BackgroundTransparency = 1,
        BorderSizePixel       = 0,
        [Element.Ref] = function(rbx) self._rootRef = rbx end,
    }, children)
end

return Splitter
