--!nonstrict
-- =====================================================================
-- IDARoblox / UI / Views / GraphView
-- ---------------------------------------------------------------------
-- CFG visualization. Lays out the control-flow graph via Sugiyama, then
-- renders blocks as boxes and edges as rotated thin Frames.
--
-- Props:
--   cfg                  — a CFG result from CFGBuilder
--   stream               — the matching InstructionStream (for previewing
--                          block contents inside each box)
--   selectedBlockId      — optional, drives the active highlight
--   onSelectBlock        — fn(blockId, block) on click
--   onActivateBlock      — fn(blockId, block) on double-click (the
--                          workspace uses this to focus the PC in the
--                          DisassemblyView)
--   onMount / onUnmount  — component-instance capture (same pattern as
--                          DisassemblyView)
--
-- The Camera is owned by this component. Pan and zoom mutate the
-- camera's pan/zoom values, which through onChange directly update
-- WorldFrame.Position and UIScale.Scale — bypassing the render tree so
-- 60 fps panning doesn't trigger 60 component re-renders.
-- =====================================================================

local UserInputService = game:GetService("UserInputService")
local RunService       = game:GetService("RunService")

local Component       = _G.IDARo.require("UI.Framework.Component")
local Element         = _G.IDARo.require("UI.Framework.Element")
local Camera          = _G.IDARo.require("UI.Framework.Camera")
local SugiyamaLayout  = _G.IDARo.require("UI.Framework.SugiyamaLayout")

local e     = Element.create
local Event = Element.Event

local GraphView = Component.extend("GraphView")

Component.setDefaultProps(GraphView, {
    cfg               = nil,
    stream            = nil,
    selectedBlockId   = nil,
    onSelectBlock     = nil,
    onActivateBlock   = nil,
    Size              = UDim2.fromScale(1, 1),
    Position          = UDim2.fromOffset(0, 0),
    layerSpacingY     = 110,
    nodeSpacingX      = 40,
    blockWidth        = 220,
    minBlockHeight    = 72,
    rowHeight         = 14,
    maxRowsShown      = 5,
    edgeThickness     = 2,
    backEdgeThickness = 3,
})

-- ---------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------

local function blockPreviewHeight(block, maxRows, rowH)
    local headerH = 28
    local footerH = 18
    local rows    = math.min(maxRows, #block.instructions)
    local extra   = #block.instructions > maxRows and 14 or 0
    return headerH + rows * rowH + extra + footerH + 6
end

local function lineFrame(key, fromX, fromY, toX, toY, thickness, color, zIndex)
    local dx = toX - fromX
    local dy = toY - fromY
    local length = math.sqrt(dx * dx + dy * dy)
    if length < 0.5 then return nil end
    local angle = math.deg(math.atan2(dy, dx))
    local midX  = (fromX + toX) * 0.5
    local midY  = (fromY + toY) * 0.5
    return e("Frame", {
        key              = key,
        AnchorPoint      = Vector2.new(0.5, 0.5),
        Position         = UDim2.fromOffset(midX, midY),
        Size             = UDim2.fromOffset(length, thickness),
        Rotation         = angle,
        BackgroundColor3 = color,
        BorderSizePixel  = 0,
        ZIndex           = zIndex,
    })
end

local function edgeColor(theme, kind, isBack)
    if isBack then return theme:color("warning") end
    if kind == "taken" then return theme:color("success") end
    if kind == "jump"  then return theme:color("primary") end
    if kind == "back"  then return theme:color("warning") end
    if kind == "exit"  then return theme:color("danger") end
    return theme:color("textSubtle")                                 -- "fall" and default
end

local function blockStripeColor(theme, block)
    if block.id == 1 then return theme:color("primary") end
    if block.terminator == "return" then return theme:color("danger") end
    if block.isLoopHeader then return theme:color("accent") end
    return theme:color("textSubtle")
end

-- ---------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------

function GraphView:init(props)
    self.state = {
        hoverBlockId = nil,
        bgKey        = 0,                                            -- forces a re-render when layout changes
    }
    self._camera = Camera.new({
        minZoom = 0.18,
        maxZoom = 3.0,
    })
    self._dragging       = false
    self._dragStartScreen = nil
    self._inputConns     = {}
    self._layout         = nil
    self._viewportSize   = Vector2.new(0, 0)
    self:_recomputeLayout(props)
end

function GraphView:_recomputeLayout(props)
    local cfg = (props or self.props).cfg
    if not cfg then self._layout = nil; return end

    -- Build a SugiyamaLayout-friendly graph from the CFG. Skip the
    -- synthetic-exit virtual node: edges with target -1 are dropped so
    -- the exit doesn't pollute the layout, but they're still rendered
    -- as short "exit" stubs at the bottom of return blocks.
    local nodes = {}
    local edges = {}
    for id, block in cfg.blocks do
        nodes[id] = {
            width   = self.props.blockWidth,
            height  = math.max(self.props.minBlockHeight,
                blockPreviewHeight(block, self.props.maxRowsShown, self.props.rowHeight)),
            blockId = id,
        }
    end
    for _, edge in cfg.edges do
        if edge.to ~= cfg.exitId then
            edges[#edges + 1] = { from = edge.from, to = edge.to, kind = edge.kind }
        end
    end

    self._layout = SugiyamaLayout.compute({
        nodes     = nodes,
        edges     = edges,
        backEdges = cfg.backEdges,
        entry     = cfg.entry,
    }, {
        layerSpacingY    = self.props.layerSpacingY,
        nodeSpacingX     = self.props.nodeSpacingX,
        defaultWidth     = self.props.blockWidth,
        defaultHeight    = self.props.minBlockHeight,
        barycenterPasses = 6,
    })
end

function GraphView:willUpdate(nextProps)
    if nextProps.cfg ~= self.props.cfg then
        self:_recomputeLayout(nextProps)
        self.state.bgKey = self.state.bgKey + 1
    end
end

function GraphView:didMount()
    -- Apply initial camera transform to refs.
    self._camSub = self._camera:onChange(function(cam)
        if self._worldRef then
            self._worldRef.Position = UDim2.fromOffset(cam:pan_x(), cam:pan_y())
        end
        if self._scaleRef then
            self._scaleRef.Scale = cam:zoom()
        end
    end)

    -- Fit-to-screen once after the first paint so the user always sees
    -- the entire CFG on initial open.
    task.defer(function()
        if self._mounted then self:_fitToView() end
    end)

    -- Hook input on the viewport instance.
    self:_wireInput()

    if self.props.onMount then
        pcall(self.props.onMount, self)
    end
end

function GraphView:willUnmount()
    for _, c in self._inputConns do
        if c.Disconnect then c:Disconnect() end
    end
    self._inputConns = {}
    if self._camSub then self._camSub:disconnect() end
    if self.props.onUnmount then pcall(self.props.onUnmount, self) end
end

-- ---------------------------------------------------------------------
-- Camera input wiring
-- ---------------------------------------------------------------------

function GraphView:_wireInput()
    -- Mouse drag: started on the viewport InputBegan, tracked globally
    -- via UserInputService until released.
    local conns = self._inputConns

    conns[#conns + 1] = UserInputService.InputChanged:Connect(function(input)
        if not self._mounted then return end
        if input.UserInputType == Enum.UserInputType.MouseMovement then
            if self._dragging and self._dragStartScreen then
                local pos = Vector2.new(input.Position.X, input.Position.Y)
                local delta = pos - self._dragStartScreen
                self._dragStartScreen = pos
                self._camera:pan(delta.X, delta.Y)
            end
        end
    end)

    conns[#conns + 1] = UserInputService.InputEnded:Connect(function(input)
        if not self._mounted then return end
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.MouseButton3 then
            if self._dragging then
                self._dragging = false
                self._dragStartScreen = nil
                self._camera:endFlick()
            end
        end
    end)

    -- Inertia tick.
    conns[#conns + 1] = RunService.Heartbeat:Connect(function(dt)
        if not self._mounted then return end
        if not self._dragging then
            self._camera:applyInertia(dt)
        end
    end)
end

function GraphView:_fitToView()
    if not self._layout or not self._viewportRef then return end
    local viewSize = self._viewportRef.AbsoluteSize
    if viewSize.X < 4 or viewSize.Y < 4 then
        -- Not yet measured; retry next frame.
        task.defer(function()
            if self._mounted then self:_fitToView() end
        end)
        return
    end
    local b = self._layout.bounds
    self._camera:fitBounds(b.minX, b.minY, b.maxX, b.maxY, viewSize.X, viewSize.Y, 32)
end

-- ---------------------------------------------------------------------
-- Interaction
-- ---------------------------------------------------------------------

function GraphView:_onBlockClick(blockId)
    local now = os.clock()
    local isDouble = self._lastClickBlock == blockId and (now - (self._lastClickAt or 0)) < 0.4
    self._lastClickBlock = blockId
    self._lastClickAt = now
    if self.props.onSelectBlock then
        pcall(self.props.onSelectBlock, blockId, self.props.cfg.blocks[blockId])
    end
    if isDouble and self.props.onActivateBlock then
        pcall(self.props.onActivateBlock, blockId, self.props.cfg.blocks[blockId])
    end
end

-- ---------------------------------------------------------------------
-- Block rendering
-- ---------------------------------------------------------------------

function GraphView:_renderBlock(block, layoutNode)
    local theme    = self.theme
    local stripeC  = blockStripeColor(theme, block)
    local selected = self.props.selectedBlockId == block.id
    local hovered  = self.state.hoverBlockId == block.id

    local borderColor = selected and theme:color("primary")
        or hovered and theme:color("primaryHover")
        or theme:color("border")
    local borderThick = (selected or hovered) and 2 or 1

    local label = block.instructions[1] and block.instructions[1].label
        or string.format("loc_%04X", block.instructions[1] and block.instructions[1].address or 0)
    local headerText = string.format("B%d   %s", block.id, label)

    -- Mnemonic lines.
    local mnLines = {}
    local maxRows = self.props.maxRowsShown
    local rowH    = self.props.rowHeight
    for i = 1, math.min(maxRows, #block.instructions) do
        local row = block.instructions[i]
        mnLines[#mnLines + 1] = e("TextLabel", {
            key            = "row:" .. i,
            Position       = UDim2.fromOffset(8, 28 + (i - 1) * rowH),
            Size           = UDim2.new(1, -16, 0, rowH),
            Text           = string.format("%-10s %s",
                row.mnemonic or "?",
                (row.operandText or ""):sub(1, 32)),
            Font           = Enum.Font.RobotoMono,
            TextSize       = theme:size("font.mono") - 2,
            TextColor3     = theme:color("disassemblyOperand"),
            TextXAlignment = Enum.TextXAlignment.Left,
            BackgroundTransparency = 1,
        })
    end
    local extra = #block.instructions - maxRows
    if extra > 0 then
        mnLines[#mnLines + 1] = e("TextLabel", {
            key            = "more",
            Position       = UDim2.fromOffset(8, 28 + maxRows * rowH),
            Size           = UDim2.new(1, -16, 0, 14),
            Text           = string.format("… +%d more", extra),
            Font           = Enum.Font.Gotham,
            TextSize       = theme:size("font.ui") - 3,
            TextColor3     = theme:color("textSubtle"),
            TextXAlignment = Enum.TextXAlignment.Left,
            BackgroundTransparency = 1,
        })
    end

    -- Footer.
    local footerText = string.format("%d insn · %d→ · ←%d",
        #block.instructions, #block.successors, #block.predecessors)
    if block.isLoopHeader then
        footerText = "↻ " .. footerText
    end

    return e("TextButton", {
        key              = "block:" .. block.id,
        Position         = UDim2.fromOffset(layoutNode.x, layoutNode.y),
        Size             = UDim2.fromOffset(layoutNode.width, layoutNode.height),
        Text             = "",
        AutoButtonColor  = false,
        BackgroundColor3 = theme:color("surface"),
        BorderSizePixel  = 0,
        ZIndex           = 5,
        [Event.Activated] = function() self:_onBlockClick(block.id) end,
        [Event.MouseEnter] = function()
            if not self._mounted then return end
            if self.state.hoverBlockId == block.id then return end
            task.defer(function()
                if self._mounted and self.state.hoverBlockId ~= block.id then
                    self:setState({ hoverBlockId = block.id })
                end
            end)
        end,
        [Event.MouseLeave] = function()
            if not self._mounted then return end
            if self.state.hoverBlockId ~= block.id then return end
            task.defer(function()
                if self._mounted and self.state.hoverBlockId == block.id then
                    self:setState({ hoverBlockId = nil })
                end
            end)
        end,
        [Event.InputBegan] = function(_inst, input)
            if input.UserInputType == Enum.UserInputType.MouseButton2
                or input.UserInputType == Enum.UserInputType.MouseButton3 then
                self._dragging = true
                self._dragStartScreen = Vector2.new(input.Position.X, input.Position.Y)
                self._camera:beginFlick()
            end
        end,
    }, {
        e("UICorner", { CornerRadius = UDim.new(0, theme:radius("md")) }),
        e("UIStroke", { Color = borderColor, Thickness = borderThick }),
        -- Color stripe at the top edge
        e("Frame", {
            key              = "stripe",
            Position         = UDim2.fromOffset(0, 0),
            Size             = UDim2.new(1, 0, 0, 4),
            BackgroundColor3 = stripeC,
            BorderSizePixel  = 0,
            ZIndex           = 6,
        }, {
            e("UICorner", { CornerRadius = UDim.new(0, theme:radius("md")) }),
        }),
        -- Header text
        e("TextLabel", {
            key            = "header",
            Position       = UDim2.fromOffset(8, 6),
            Size           = UDim2.new(1, -16, 0, 20),
            Text           = headerText,
            Font           = Enum.Font.GothamMedium,
            TextSize       = theme:size("font.ui"),
            TextColor3     = theme:color("text"),
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate   = Enum.TextTruncate.AtEnd,
            BackgroundTransparency = 1,
            ZIndex         = 6,
        }),
        Element.fragment(mnLines),
        -- Footer
        e("TextLabel", {
            key            = "footer",
            AnchorPoint    = Vector2.new(0, 1),
            Position       = UDim2.new(0, 8, 1, -4),
            Size           = UDim2.new(1, -16, 0, 14),
            Text           = footerText,
            Font           = Enum.Font.Gotham,
            TextSize       = theme:size("font.ui") - 3,
            TextColor3     = theme:color("textSubtle"),
            TextXAlignment = Enum.TextXAlignment.Left,
            BackgroundTransparency = 1,
            ZIndex         = 6,
        }),
    })
end

-- ---------------------------------------------------------------------
-- Edge rendering
-- ---------------------------------------------------------------------

function GraphView:_renderEdges()
    local theme = self.theme
    if not self._layout then return {} end

    local out = {}
    for ei, edge in self._layout.edges do
        local color = edgeColor(theme, edge.kind, edge.isBack)
        local thick = edge.isBack and self.props.backEdgeThickness or self.props.edgeThickness
        local points = edge.points
        for i = 1, #points - 1 do
            local f = points[i]
            local t = points[i + 1]
            local seg = lineFrame(string.format("e%d:%d", ei, i),
                f.X, f.Y, t.X, t.Y, thick, color, 3)
            if seg then out[#out + 1] = seg end
        end
        -- Arrowhead at the final point.
        if #points >= 2 then
            local last  = points[#points]
            local before = points[#points - 1]
            local dx = last.X - before.X
            local dy = last.Y - before.Y
            local len = math.sqrt(dx * dx + dy * dy)
            if len >= 6 then
                local ux, uy = dx / len, dy / len
                -- Two perpendicular vectors
                local px, py = -uy, ux
                local backX = last.X - ux * 8
                local backY = last.Y - uy * 8
                local leftX  = backX + px * 4
                local leftY  = backY + py * 4
                local rightX = backX - px * 4
                local rightY = backY - py * 4
                out[#out + 1] = lineFrame(string.format("e%d:al", ei),
                    last.X, last.Y, leftX,  leftY,  thick, color, 4)
                out[#out + 1] = lineFrame(string.format("e%d:ar", ei),
                    last.X, last.Y, rightX, rightY, thick, color, 4)
            end
        end
    end
    return out
end

-- ---------------------------------------------------------------------
-- Render
-- ---------------------------------------------------------------------

function GraphView:render()
    local theme = self.theme
    if not self._layout or not self.props.cfg then
        return e("Frame", {
            Size             = self.props.Size,
            Position         = self.props.Position,
            BackgroundColor3 = theme:color("background"),
            BorderSizePixel  = 0,
        }, {
            e("TextLabel", {
                Size             = UDim2.fromScale(1, 1),
                Text             = "no CFG\n(select a proto)",
                Font             = Enum.Font.Gotham,
                TextSize         = theme:size("font.ui"),
                TextColor3       = theme:color("textMuted"),
                BackgroundTransparency = 1,
            }),
        })
    end

    local layout = self._layout
    local bounds = layout.bounds
    local worldW = math.max(1, bounds.maxX - bounds.minX + 64)
    local worldH = math.max(1, bounds.maxY - bounds.minY + 64)

    -- Render edges first (lower z) and then blocks.
    local edgeKids = self:_renderEdges()
    local blockKids = {}
    for id, node in layout.nodes do
        if not node.isDummy then
            local block = self.props.cfg.blocks[id]
            if block then
                blockKids[#blockKids + 1] = self:_renderBlock(block, node)
            end
        end
    end

    return e("Frame", {
        key              = "viewport",
        Size             = self.props.Size,
        Position         = self.props.Position,
        BackgroundColor3 = theme:color("background"),
        BorderSizePixel  = 0,
        ClipsDescendants = true,
        [Element.Ref]    = function(inst) self._viewportRef = inst end,
        [Event.InputBegan] = function(inst, input)
            if input.UserInputType == Enum.UserInputType.MouseButton1
                or input.UserInputType == Enum.UserInputType.MouseButton3 then
                self._dragging        = true
                self._dragStartScreen = Vector2.new(input.Position.X, input.Position.Y)
                self._camera:beginFlick()
            end
        end,
        [Event.InputChanged] = function(inst, input)
            if input.UserInputType == Enum.UserInputType.MouseWheel then
                local viewportPos = inst.AbsolutePosition
                local mx = input.Position.X - viewportPos.X
                local my = input.Position.Y - viewportPos.Y
                local factor = input.Position.Z > 0 and 1.1 or (1 / 1.1)
                self._camera:zoomAtScreen(factor, mx, my)
            end
        end,
    }, {
        -- Subtle grid backdrop so panning feels grounded
        e("Frame", {
            key              = "grid",
            Size             = UDim2.fromScale(1, 1),
            BackgroundColor3 = theme:color("backgroundAlt"),
            BorderSizePixel  = 0,
            ZIndex           = 1,
        }, {
            e("UIGradient", {
                Color = ColorSequence.new(theme:color("background"), theme:color("backgroundAlt")),
                Rotation = 90,
            }),
        }),
        -- World layer — pan/zoom mutate Position + UIScale.Scale directly
        e("Frame", {
            key              = "world",
            Size             = UDim2.fromOffset(worldW, worldH),
            Position         = UDim2.fromOffset(self._camera:pan_x(), self._camera:pan_y()),
            BackgroundTransparency = 1,
            ZIndex           = 2,
            [Element.Ref]    = function(inst) self._worldRef = inst end,
        }, {
            e("UIScale", {
                Scale = self._camera:zoom(),
                [Element.Ref] = function(inst) self._scaleRef = inst end,
            }),
            Element.fragment(edgeKids),
            Element.fragment(blockKids),
        }),
        -- Toolbar overlay (zoom / fit buttons, info pill)
        e("Frame", {
            key              = "overlay",
            AnchorPoint      = Vector2.new(1, 1),
            Position         = UDim2.new(1, -8, 1, -8),
            Size             = UDim2.fromOffset(208, 30),
            BackgroundColor3 = theme:color("surfaceAlt"),
            BorderSizePixel  = 0,
            ZIndex           = 20,
        }, {
            e("UICorner", { CornerRadius = UDim.new(0, theme:radius("md")) }),
            e("UIStroke", { Color = theme:color("border"), Thickness = 1 }),
            e("UIPadding", {
                PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6),
                PaddingTop  = UDim.new(0, 4), PaddingBottom = UDim.new(0, 4),
            }),
            e("UIListLayout", {
                FillDirection = Enum.FillDirection.Horizontal,
                VerticalAlignment = Enum.VerticalAlignment.Center,
                Padding = UDim.new(0, 4),
            }),
            e("TextButton", {
                Size             = UDim2.fromOffset(22, 22),
                Text             = "−",
                Font             = Enum.Font.GothamMedium,
                TextSize         = 14,
                TextColor3       = theme:color("text"),
                BackgroundColor3 = theme:color("surface"),
                AutoButtonColor  = false,
                BorderSizePixel  = 0,
                LayoutOrder      = 1,
                [Event.Activated] = function() self._camera:zoomBy(1 / 1.15) end,
            }, { e("UICorner", { CornerRadius = UDim.new(0, theme:radius("sm")) }) }),
            e("TextButton", {
                Size             = UDim2.fromOffset(22, 22),
                Text             = "+",
                Font             = Enum.Font.GothamMedium,
                TextSize         = 14,
                TextColor3       = theme:color("text"),
                BackgroundColor3 = theme:color("surface"),
                AutoButtonColor  = false,
                BorderSizePixel  = 0,
                LayoutOrder      = 2,
                [Event.Activated] = function() self._camera:zoomBy(1.15) end,
            }, { e("UICorner", { CornerRadius = UDim.new(0, theme:radius("sm")) }) }),
            e("TextButton", {
                Size             = UDim2.fromOffset(46, 22),
                Text             = "Fit",
                Font             = Enum.Font.Gotham,
                TextSize         = 11,
                TextColor3       = theme:color("text"),
                BackgroundColor3 = theme:color("surface"),
                AutoButtonColor  = false,
                BorderSizePixel  = 0,
                LayoutOrder      = 3,
                [Event.Activated] = function() self:_fitToView() end,
            }, { e("UICorner", { CornerRadius = UDim.new(0, theme:radius("sm")) }) }),
            e("TextLabel", {
                Size             = UDim2.fromOffset(110, 22),
                Text             = string.format("%d blk · %d edge · %d loop",
                    self.props.cfg.stats.blockCount,
                    self.props.cfg.stats.edgeCount,
                    self.props.cfg.stats.loopCount),
                Font             = Enum.Font.RobotoMono,
                TextSize         = 10,
                TextColor3       = theme:color("textMuted"),
                BackgroundTransparency = 1,
                TextXAlignment   = Enum.TextXAlignment.Left,
                LayoutOrder      = 4,
            }),
        }),
    })
end

-- ---------------------------------------------------------------------
-- Imperative API
-- ---------------------------------------------------------------------

function GraphView:fitToView() self:_fitToView() end

function GraphView:centerOnBlock(blockId)
    if not self._layout or not self._viewportRef then return end
    local node = self._layout.nodes[blockId]
    if not node then return end
    local size = self._viewportRef.AbsoluteSize
    local cx = node.x + node.width  / 2
    local cy = node.y + node.height / 2
    self._camera:centerOn(cx, cy, size.X, size.Y)
end

return GraphView
