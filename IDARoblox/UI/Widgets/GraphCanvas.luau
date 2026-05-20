--!nonstrict
-- =====================================================================
-- IDARoblox / UI / Widgets / GraphCanvas
-- ---------------------------------------------------------------------
-- Pannable, zoomable canvas for control-flow and call-graph rendering.
-- The graph data model is supplied by callers (CFGBuilder for control
-- flow, the call-graph builder for the function-level view); this
-- widget cares only about *displaying* nodes and edges with smooth
-- pan/zoom, viewport culling, and click + context-menu hit testing.
--
-- Props
--   nodes        — { { id, x, y, w, h, header, color, render?(api) }, … }
--                  Coordinates are in *world* space. `render` is an
--                  optional callback returning Element children for the
--                  node body (so callers can put disassembly lines in).
--   edges        — { { from, to, kind?, label?, color? }, … }
--                  `kind` ∈ "straight" | "ortho" | "bezier"
--   viewport     — initial { zoom, panX, panY } (zoom = 1 means 1:1)
--   minZoom      — clamp lower bound (default 0.25)
--   maxZoom      — clamp upper bound (default 4.0)
--   showGrid     — bool, default true; draws a subtle dot grid
--   gridSpacing  — world-space units between grid dots, default 32
--   selectedNodeId — currently highlighted node id (drives outline)
--   onNodeClick  — fn(nodeId, mouseInfo)
--   onNodeRightClick — fn(nodeId, position) → typically open ContextMenu
--   onBackgroundClick — fn(worldX, worldY)
--   onViewportChange — fn({ zoom, panX, panY })
--
-- Imperative methods on the Component:
--   :setViewport({ zoom, panX, panY })
--   :centerOn(worldX, worldY)
--   :zoomToFit({ padding = 32 })
--   :focusNode(nodeId, { padding = 64, zoom = nil })
--   :worldToScreen(x, y) / :screenToWorld(x, y)
-- =====================================================================

local Component  = _G.IDARo.require("UI.Framework.Component")
local Element    = _G.IDARo.require("UI.Framework.Element")
local Animator   = _G.IDARo.require("UI.Framework.Animator")

local UserInputService = game:GetService("UserInputService")

local e     = Element.create
local Event = Element.Event
local Ref   = Element.Ref

local GraphCanvas = Component.extend("GraphCanvas")

Component.setDefaultProps(GraphCanvas, {
    nodes              = {},
    edges              = {},
    viewport           = nil,
    minZoom            = 0.25,
    maxZoom            = 4.0,
    showGrid           = true,
    gridSpacing        = 32,
    selectedNodeId     = nil,
    onNodeClick        = nil,
    onNodeRightClick   = nil,
    onBackgroundClick  = nil,
    onViewportChange   = nil,
    zoomStep           = 1.15,
    edgeRouting        = "ortho",                                    -- default routing for edges with no kind
    edgeColor          = nil,                                        -- nil → theme accent
    cullMargin         = 256,                                        -- world-space margin for culling
})

-- ---------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------

function GraphCanvas:init(props)
    local vp = props.viewport or {}
    self.state = {
        zoom = vp.zoom or 1.0,
        panX = vp.panX or 0,
        panY = vp.panY or 0,
        canvasSize = Vector2.new(800, 600),
        isPanning = false,
        panStartScreen = nil,
        panStartCamera = nil,
    }
    self._inputConns = {}
end

function GraphCanvas:didMount()
    -- Listen globally for mouse-up so panning ends even when the cursor
    -- leaves the widget bounds.
    self._inputConns[#self._inputConns + 1] = UserInputService.InputEnded:Connect(
        function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton3
                or input.UserInputType == Enum.UserInputType.Touch then
                if self.state.isPanning then
                    self:setState({
                        isPanning      = false,
                        panStartScreen = nil,
                        panStartCamera = nil,
                    })
                end
            end
        end)
    self._inputConns[#self._inputConns + 1] = UserInputService.InputChanged:Connect(
        function(input)
            if not self.state.isPanning then return end
            if input.UserInputType ~= Enum.UserInputType.MouseMovement
                and input.UserInputType ~= Enum.UserInputType.Touch then return end
            local pos = Vector2.new(input.Position.X, input.Position.Y)
            local sx, sy = self.state.panStartScreen.X, self.state.panStartScreen.Y
            local cx, cy = self.state.panStartCamera.X, self.state.panStartCamera.Y
            local dx, dy = pos.X - sx, pos.Y - sy
            self:_setViewport({
                zoom = self.state.zoom,
                panX = cx + dx,
                panY = cy + dy,
            })
        end)
end

function GraphCanvas:willUnmount()
    for _, conn in self._inputConns do
        if conn and conn.Disconnect then conn:Disconnect() end
    end
    self._inputConns = {}
end

-- ---------------------------------------------------------------------
-- Viewport math
-- ---------------------------------------------------------------------

function GraphCanvas:_clampZoom(z)
    if z < self.props.minZoom then return self.props.minZoom end
    if z > self.props.maxZoom then return self.props.maxZoom end
    return z
end

function GraphCanvas:_setViewport(v, opts)
    opts = opts or {}
    local z = self:_clampZoom(v.zoom or self.state.zoom)
    local update = { zoom = z, panX = v.panX or self.state.panX,
                     panY = v.panY or self.state.panY }
    if update.zoom == self.state.zoom
        and update.panX == self.state.panX
        and update.panY == self.state.panY then return end
    self:setState(update)
    if self.props.onViewportChange and not opts.silent then
        self.props.onViewportChange(update)
    end
end

function GraphCanvas:setViewport(vp)
    self:_setViewport(vp)
end

function GraphCanvas:worldToScreen(x, y)
    return x * self.state.zoom + self.state.panX,
           y * self.state.zoom + self.state.panY
end

function GraphCanvas:screenToWorld(sx, sy)
    if self.state.zoom == 0 then return 0, 0 end
    return (sx - self.state.panX) / self.state.zoom,
           (sy - self.state.panY) / self.state.zoom
end

function GraphCanvas:centerOn(wx, wy)
    local size = self.state.canvasSize
    self:_setViewport({
        zoom = self.state.zoom,
        panX = (size.X * 0.5) - wx * self.state.zoom,
        panY = (size.Y * 0.5) - wy * self.state.zoom,
    })
end

function GraphCanvas:zoomToFit(opts)
    opts = opts or {}
    local pad = opts.padding or 32
    local nodes = self.props.nodes
    if not nodes or #nodes == 0 then return end
    local minX, minY = math.huge, math.huge
    local maxX, maxY = -math.huge, -math.huge
    for _, n in nodes do
        if n.x < minX then minX = n.x end
        if n.y < minY then minY = n.y end
        if n.x + n.w > maxX then maxX = n.x + n.w end
        if n.y + n.h > maxY then maxY = n.y + n.h end
    end
    local boundsW = maxX - minX
    local boundsH = maxY - minY
    if boundsW <= 0 or boundsH <= 0 then return end
    local size = self.state.canvasSize
    local availW = size.X - pad * 2
    local availH = size.Y - pad * 2
    local fitZoom = math.min(availW / boundsW, availH / boundsH)
    fitZoom = self:_clampZoom(fitZoom)
    -- Pan so the bounds center sits at canvas center
    local cx = minX + boundsW * 0.5
    local cy = minY + boundsH * 0.5
    self:_setViewport({
        zoom = fitZoom,
        panX = size.X * 0.5 - cx * fitZoom,
        panY = size.Y * 0.5 - cy * fitZoom,
    })
end

function GraphCanvas:focusNode(nodeId, opts)
    opts = opts or {}
    for _, n in self.props.nodes do
        if n.id == nodeId then
            local zoom = opts.zoom or self.state.zoom
            self:_setViewport({ zoom = zoom })
            self:centerOn(n.x + n.w * 0.5, n.y + n.h * 0.5)
            return true
        end
    end
    return false
end

-- ---------------------------------------------------------------------
-- Input handlers
-- ---------------------------------------------------------------------

function GraphCanvas:_onCanvasMouseDown(rbx, input)
    local pos = Vector2.new(input.Position.X, input.Position.Y)
    if input.UserInputType == Enum.UserInputType.MouseButton3
        or (input.UserInputType == Enum.UserInputType.MouseButton1
            and UserInputService:IsKeyDown(Enum.KeyCode.LeftAlt)) then
        -- Begin pan
        self:setState({
            isPanning      = true,
            panStartScreen = pos,
            panStartCamera = Vector2.new(self.state.panX, self.state.panY),
        })
        return
    end
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        -- Background click — convert to world coords
        local absPos = rbx.AbsolutePosition
        local rel = pos - absPos
        local wx, wy = self:screenToWorld(rel.X, rel.Y)
        if self.props.onBackgroundClick then
            self.props.onBackgroundClick(wx, wy, input)
        end
    end
end

function GraphCanvas:_onCanvasScroll(rbx, input)
    if input.UserInputType ~= Enum.UserInputType.MouseWheel then return end
    -- Anchor zoom at the cursor: keep the world point under the cursor
    -- stationary while changing zoom.
    local mousePos = UserInputService:GetMouseLocation()
    local absPos = rbx.AbsolutePosition
    local relX, relY = mousePos.X - absPos.X, mousePos.Y - absPos.Y
    local wx, wy = self:screenToWorld(relX, relY)
    local dir = input.Position.Z                                     -- +1 / -1
    local nextZoom = self.state.zoom * (dir > 0 and self.props.zoomStep or (1 / self.props.zoomStep))
    nextZoom = self:_clampZoom(nextZoom)
    -- Recompute pan so (wx, wy) still lands at (relX, relY)
    self:_setViewport({
        zoom = nextZoom,
        panX = relX - wx * nextZoom,
        panY = relY - wy * nextZoom,
    })
end

function GraphCanvas:_onCanvasResize(rbx)
    -- Property-changed signals can fire synchronously during the
    -- reconcile that just created the host Frame.  Calling setState
    -- inside that reconcile produces an unbounded task.defer cascade
    -- (the new render produces a new Frame, whose AbsoluteSize fires
    -- again, etc.).  Defer the state update so it lands after the
    -- current reconcile commits, and re-check the size inside the
    -- deferred closure so a stable size doesn't cause a redundant
    -- update.
    local sNow = rbx.AbsoluteSize
    if sNow.X == self.state.canvasSize.X and sNow.Y == self.state.canvasSize.Y then return end
    if self._resizePending then return end                            -- coalesce repeat fires
    self._resizePending = true
    task.defer(function()
        self._resizePending = false
        if not self.state then return end                             -- unmounted between defer + run
        local sCur = rbx.AbsoluteSize
        if sCur.X == self.state.canvasSize.X and sCur.Y == self.state.canvasSize.Y then return end
        self:setState({ canvasSize = Vector2.new(sCur.X, sCur.Y) })
    end)
end

-- ---------------------------------------------------------------------
-- Culling: which nodes / edges intersect the visible world rect
-- ---------------------------------------------------------------------

function GraphCanvas:_visibleWorldRect()
    local s = self.state.canvasSize
    local x0, y0 = self:screenToWorld(0, 0)
    local x1, y1 = self:screenToWorld(s.X, s.Y)
    local m = self.props.cullMargin
    return x0 - m, y0 - m, x1 + m, y1 + m
end

local function nodeIntersectsRect(n, x0, y0, x1, y1)
    return not (n.x > x1 or n.x + n.w < x0 or n.y > y1 or n.y + n.h < y0)
end

-- ---------------------------------------------------------------------
-- Edge rendering helpers
-- ---------------------------------------------------------------------

-- Edges in the Roblox UI world are emulated using a sequence of thin
-- Frame rectangles. Straight edges produce one rotated frame; ortho
-- routes use horizontal + vertical segments; bezier samples points.

local EDGE_THICKNESS = 1.5

local function findNodeById(nodes, id)
    for _, n in nodes do if n.id == id then return n end end
    return nil
end

local function edgeAnchors(fromNode, toNode)
    -- Anchor on bottom-center of source, top-center of target (good for
    -- a top-down CFG). Callers can override by specifying explicit
    -- anchor offsets on the edge.
    local sx = fromNode.x + fromNode.w * 0.5
    local sy = fromNode.y + fromNode.h
    local tx = toNode.x + toNode.w * 0.5
    local ty = toNode.y
    return sx, sy, tx, ty
end

local function lineSegment(x1, y1, x2, y2, color, thickness)
    local dx, dy = x2 - x1, y2 - y1
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 0.5 then return nil end
    local angle = math.deg(math.atan2(dy, dx))
    return e("Frame", {
        Name             = "edge_seg",
        Size             = UDim2.fromOffset(len, thickness or EDGE_THICKNESS),
        Position         = UDim2.fromOffset(x1, y1),
        AnchorPoint      = Vector2.new(0, 0.5),
        Rotation         = angle,
        BackgroundColor3 = color,
        BorderSizePixel  = 0,
        BackgroundTransparency = 0,
        ZIndex           = 1,
    })
end

local function arrowHead(x, y, dirX, dirY, color, size)
    size = size or 6
    local angle = math.deg(math.atan2(dirY, dirX))
    return e("Frame", {
        Name             = "edge_head",
        Size             = UDim2.fromOffset(size, size),
        Position         = UDim2.fromOffset(x, y),
        AnchorPoint      = Vector2.new(0.5, 0.5),
        Rotation         = angle,
        BackgroundColor3 = color,
        BorderSizePixel  = 0,
        ZIndex           = 2,
    })
end

function GraphCanvas:_renderEdge(edge, fromNode, toNode, color)
    if not fromNode or not toNode then return nil end
    local kind = edge.kind or self.props.edgeRouting
    local sx, sy, tx, ty = edgeAnchors(fromNode, toNode)
    if edge.fromAnchor then sx, sy = edge.fromAnchor.x, edge.fromAnchor.y end
    if edge.toAnchor   then tx, ty = edge.toAnchor.x,   edge.toAnchor.y   end

    -- Transform to screen
    local s1x, s1y = self:worldToScreen(sx, sy)
    local s2x, s2y = self:worldToScreen(tx, ty)
    local edgeColor = edge.color or color

    if kind == "straight" then
        local children = {}
        local seg = lineSegment(s1x, s1y, s2x, s2y, edgeColor, EDGE_THICKNESS)
        if seg then children[#children + 1] = seg end
        local head = arrowHead(s2x, s2y, s2x - s1x, s2y - s1y, edgeColor)
        if head then children[#children + 1] = head end
        return e("Frame", {
            Name = "edge",
            Size = UDim2.fromScale(1, 1),
            BackgroundTransparency = 1,
            ZIndex = 1,
        }, children)
    elseif kind == "ortho" then
        -- Three-segment route: down, across, down. Mid-y splits the gap.
        local midY = (s1y + s2y) * 0.5
        local children = {}
        local a = lineSegment(s1x, s1y, s1x, midY, edgeColor)
        local b = lineSegment(s1x, midY, s2x, midY, edgeColor)
        local c = lineSegment(s2x, midY, s2x, s2y, edgeColor)
        if a then children[#children + 1] = a end
        if b then children[#children + 1] = b end
        if c then children[#children + 1] = c end
        local head = arrowHead(s2x, s2y, 0, s2y - midY, edgeColor)
        if head then children[#children + 1] = head end
        return e("Frame", {
            Name = "edge",
            Size = UDim2.fromScale(1, 1),
            BackgroundTransparency = 1,
            ZIndex = 1,
        }, children)
    else                                                              -- "bezier"
        -- Approximate a cubic bezier with N straight subsegments
        local N = 16
        local children = {}
        local cp1x, cp1y = s1x, (s1y + s2y) * 0.5
        local cp2x, cp2y = s2x, (s1y + s2y) * 0.5
        local prevX, prevY = s1x, s1y
        for i = 1, N do
            local t = i / N
            local omt = 1 - t
            local bx = omt^3 * s1x + 3 * omt^2 * t * cp1x
                + 3 * omt * t^2 * cp2x + t^3 * s2x
            local by = omt^3 * s1y + 3 * omt^2 * t * cp1y
                + 3 * omt * t^2 * cp2y + t^3 * s2y
            local seg = lineSegment(prevX, prevY, bx, by, edgeColor)
            if seg then children[#children + 1] = seg end
            prevX, prevY = bx, by
        end
        local head = arrowHead(s2x, s2y, s2x - cp2x, s2y - cp2y, edgeColor)
        if head then children[#children + 1] = head end
        return e("Frame", {
            Name = "edge",
            Size = UDim2.fromScale(1, 1),
            BackgroundTransparency = 1,
            ZIndex = 1,
        }, children)
    end
end

-- ---------------------------------------------------------------------
-- Background grid
-- ---------------------------------------------------------------------

function GraphCanvas:_renderGrid()
    if not self.props.showGrid then return nil end
    local spacing = self.props.gridSpacing
    if spacing < 4 then return nil end
    local s = self.state.canvasSize
    local x0, y0, x1, y1 = self:_visibleWorldRect()
    -- Don't draw a forest of dots at extreme zoom-out
    local screenSpacing = spacing * self.state.zoom
    if screenSpacing < 6 then return nil end
    local startX = math.floor(x0 / spacing) * spacing
    local startY = math.floor(y0 / spacing) * spacing
    local children = {}
    local gridColor = self.theme and self.theme:color("gridDot") or Color3.fromRGB(60, 60, 60)
    for wx = startX, x1, spacing do
        for wy = startY, y1, spacing do
            local sx, sy = self:worldToScreen(wx, wy)
            if sx >= -2 and sx <= s.X + 2 and sy >= -2 and sy <= s.Y + 2 then
                children[#children + 1] = e("Frame", {
                    Size = UDim2.fromOffset(2, 2),
                    Position = UDim2.fromOffset(sx, sy),
                    AnchorPoint = Vector2.new(0.5, 0.5),
                    BackgroundColor3 = gridColor,
                    BorderSizePixel = 0,
                    BackgroundTransparency = 0.3,
                    ZIndex = 0,
                })
            end
        end
    end
    return e("Frame", {
        Name = "grid",
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        ZIndex = 0,
    }, children)
end

-- ---------------------------------------------------------------------
-- Per-node render
-- ---------------------------------------------------------------------

function GraphCanvas:_renderNode(node)
    local sx, sy = self:worldToScreen(node.x, node.y)
    local sw = node.w * self.state.zoom
    local sh = node.h * self.state.zoom
    local theme = self.theme
    local bg = node.color or (theme and theme:color("nodeBg")) or Color3.fromRGB(40, 40, 48)
    local border = theme and theme:color("nodeBorder") or Color3.fromRGB(80, 80, 96)
    local selectedBorder = theme and theme:color("accent") or Color3.fromRGB(120, 180, 255)
    local isSelected = self.props.selectedNodeId == node.id
    local headerColor = node.headerColor or (theme and theme:color("surfaceActive"))
        or Color3.fromRGB(60, 60, 80)

    local headerH = math.min(22 * self.state.zoom, sh * 0.5)
    local children = {
        e("Frame", {
            Name = "header",
            Size = UDim2.fromOffset(sw, headerH),
            BackgroundColor3 = headerColor,
            BorderSizePixel = 0,
            ZIndex = 11,
        }, {
            e("TextLabel", {
                Size = UDim2.fromScale(1, 1),
                BackgroundTransparency = 1,
                Text = node.header or tostring(node.id),
                TextColor3 = theme and theme:color("nodeHeaderText")
                    or Color3.fromRGB(220, 220, 230),
                TextSize = math.max(10, math.floor(12 * self.state.zoom)),
                Font = Enum.Font.Code,
                TextXAlignment = Enum.TextXAlignment.Left,
                TextTruncate = Enum.TextTruncate.AtEnd,
                ClipsDescendants = true,
            }, {
                e("UIPadding", { PaddingLeft = UDim.new(0, 6) }),
            }),
        }),
    }
    -- Optional body via render callback
    if node.render then
        local body = node.render({
            zoom = self.state.zoom,
            nodeId = node.id,
            innerWidth = sw,
            innerHeight = sh - headerH,
        })
        if body then
            children[#children + 1] = e("Frame", {
                Name = "body",
                Size = UDim2.fromOffset(sw, sh - headerH),
                Position = UDim2.fromOffset(0, headerH),
                BackgroundTransparency = 1,
                ClipsDescendants = true,
                ZIndex = 11,
            }, { body })
        end
    end

    return e("Frame", {
        Name = "node_" .. tostring(node.id),
        Size = UDim2.fromOffset(sw, sh),
        Position = UDim2.fromOffset(sx, sy),
        BackgroundColor3 = bg,
        BorderColor3 = isSelected and selectedBorder or border,
        BorderSizePixel = isSelected and 2 or 1,
        ZIndex = 10,
        [Event.InputBegan] = function(_rbx, input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 then
                if self.props.onNodeClick then
                    self.props.onNodeClick(node.id, input)
                end
            elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
                if self.props.onNodeRightClick then
                    local pos = Vector2.new(input.Position.X, input.Position.Y)
                    self.props.onNodeRightClick(node.id, pos)
                end
            end
        end,
    }, children)
end

-- ---------------------------------------------------------------------
-- Render
-- ---------------------------------------------------------------------

function GraphCanvas:render()
    local theme = self.theme
    local bg = theme and theme:color("canvasBg") or Color3.fromRGB(24, 24, 30)
    local edgeColor = self.props.edgeColor
        or (theme and theme:color("edge"))
        or Color3.fromRGB(120, 130, 160)

    -- Compute visible-world rect for culling
    local x0, y0, x1, y1 = self:_visibleWorldRect()

    local children = {}

    -- Grid (z=0)
    local grid = self:_renderGrid()
    if grid then children[#children + 1] = grid end

    -- Edges (z=1)
    if self.props.edges then
        for _, edge in self.props.edges do
            local fromNode = findNodeById(self.props.nodes, edge.from)
            local toNode   = findNodeById(self.props.nodes, edge.to)
            if fromNode and toNode then
                -- Only render edges where at least one endpoint is in view.
                if nodeIntersectsRect(fromNode, x0, y0, x1, y1)
                    or nodeIntersectsRect(toNode, x0, y0, x1, y1) then
                    local edgeEl = self:_renderEdge(edge, fromNode, toNode, edgeColor)
                    if edgeEl then children[#children + 1] = edgeEl end
                end
            end
        end
    end

    -- Nodes (z=10+)
    if self.props.nodes then
        for _, node in self.props.nodes do
            if nodeIntersectsRect(node, x0, y0, x1, y1) then
                children[#children + 1] = self:_renderNode(node)
            end
        end
    end

    return e("Frame", {
        Name = "GraphCanvas",
        Size = UDim2.fromScale(1, 1),
        BackgroundColor3 = bg,
        BorderSizePixel = 0,
        ClipsDescendants = true,
        [Event.InputBegan] = function(rbx, input)
            self:_onCanvasMouseDown(rbx, input)
        end,
        [Event.InputChanged] = function(rbx, input)
            self:_onCanvasScroll(rbx, input)
        end,
        [Element.Changed.AbsoluteSize] = function(rbx)
            self:_onCanvasResize(rbx)
        end,
    }, children)
end

return GraphCanvas
