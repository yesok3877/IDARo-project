--!nonstrict
-- =====================================================================
-- IDARo / UI / Views / HeapGraphView
-- ---------------------------------------------------------------------
-- Live reference-graph visualisation built on top of GCScanner's
-- reference data (fnUpvaluesOf / tableMembersOf / fnCalledBy). Layout
-- runs through SugiyamaLayout; rendering is delegated to GraphCanvas.
--
-- Heartbeat
--   The view polls the GCScanner on a configurable interval (off / 1s /
--   2s / 5s / 10s). On each heartbeat:
--     * Run a fresh scan (capped at maxNodes objects to keep layout
--       cheap)
--     * Diff against the previous snapshot:
--         - new nodes flash green for 1.5s
--         - removed nodes flash red for 1.5s before disappearing
--     * Re-layout incrementally — nodes that survived keep their last
--       position so the graph doesn't reshuffle wildly on every tick
--
-- Selection
--   Click a node → ScriptGenerator.fetchClosureFromGC /
--   fetchTableFromGC ready to copy.
--
-- Filtering
--   Type chips (Functions / Tables / Threads) and a "show edges"
--   toggle per edge kind (upvalues, table-members, call-edges).
-- =====================================================================

local Component = _G.IDARo.require("UI.Framework.Component")
local Element   = _G.IDARo.require("UI.Framework.Element")
local Sugiyama  = _G.IDARo.require("UI.Framework.SugiyamaLayout")

local GraphCanvas = _G.IDARo.require("UI.Widgets.GraphCanvas")
local ScriptGenerator = _G.IDARo.require("Core.ScriptGenerator")

local e     = Element.create
local Event = Element.Event

local HeapGraphView = Component.extend("HeapGraphView")

Component.setDefaultProps(HeapGraphView, {
    runtime      = nil,
    onCopyResult = nil,
    Size         = UDim2.fromScale(1, 1),
})

local TOP_BAR_H = 30
local FOOTER_H  = 20
local NODE_W    = 160
local NODE_H    = 44

local HEARTBEAT_OPTIONS = {
    { label = "Off",     seconds = nil },
    { label = "1s",      seconds = 1 },
    { label = "2s",      seconds = 2 },
    { label = "5s",      seconds = 5 },
    { label = "10s",     seconds = 10 },
}

local MAX_NODE_OPTIONS = { 50, 100, 200, 400, 800 }

-- ---------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------

function HeapGraphView:init(_props)
    self.state = {
        nodes          = {},                                         -- GraphCanvas nodes
        edges          = {},
        positions      = {},                                         -- objectId → {x, y}  preserved across heartbeats
        objectIndex    = {},                                         -- objectId → object
        flashes        = {},                                         -- objectId → { until = t, kind = "new"|"removed" }
        heartbeatIdx   = 3,                                          -- default 2s
        maxNodes       = 200,
        showFunctions  = true,
        showTables     = true,
        showThreads    = false,
        showUpvalEdges = true,
        showMemberEdges= true,
        showCallEdges  = false,
        scanning       = false,
        lastScanAt     = 0,
        selectedId     = nil,
        viewport       = { zoom = 0.7, panX = 0, panY = 0 },
    }
    self._heartbeatTask = nil
end

function HeapGraphView:didMount()
    self:_scan()
    self:_restartHeartbeat()
end

function HeapGraphView:willUnmount()
    self._heartbeatTask = nil                                        -- the loop checks this each iteration
end

function HeapGraphView:didUpdate(prev)
    if prev.runtime ~= self.props.runtime then self:_scan() end
end

-- ---------------------------------------------------------------------
-- Heartbeat scheduling
-- ---------------------------------------------------------------------

function HeapGraphView:_restartHeartbeat()
    self._heartbeatTask = nil
    local opt = HEARTBEAT_OPTIONS[self.state.heartbeatIdx]
    if not opt or not opt.seconds then return end
    local token = {}
    self._heartbeatTask = token
    task.spawn(function()
        while self._heartbeatTask == token do
            task.wait(opt.seconds)
            if self._heartbeatTask ~= token then return end
            self:_scan()
        end
    end)
end

-- ---------------------------------------------------------------------
-- Scan + diff
-- ---------------------------------------------------------------------

local function classifyObjectId(obj)
    -- Stable id: prefer GCScanner's `id`, fall back to ref tostring
    if obj.id then return tostring(obj.id) end
    if obj.ref then return tostring(obj.ref) end
    return tostring(obj)
end

local TYPE_COLOR_KEY = {
    func     = "accent",
    ["function"] = "accent",
    table    = "ok",
    thread   = "warnBg",
    userdata = "headerBg",
}

function HeapGraphView:_scan()
    local gc = self.props.runtime and self.props.runtime.gc
    if not gc then return end
    self:setState({ scanning = true })
    local ok, snap = pcall(function() return gc:scan({
        includeReferences = true,
        maxObjects        = self.state.maxNodes,
    }) end)
    self:setState({ scanning = false, lastScanAt = os.clock() })
    if not ok or not snap then
        if self.logger then self.logger:warn("HeapGraphView: scan failed: %s", tostring(snap)) end
        return
    end

    -- Build node index honoring type filters
    local newIndex = {}
    local nodesList = {}
    for _, obj in (snap.objects or {}) do
        local include = false
        if obj.type == "func" or obj.type == "function" then
            if self.state.showFunctions then include = true end
        elseif obj.type == "table" then
            if self.state.showTables then include = true end
        elseif obj.type == "thread" then
            if self.state.showThreads then include = true end
        end
        if include then
            local id = classifyObjectId(obj)
            newIndex[id] = obj
            nodesList[#nodesList + 1] = { id = id, obj = obj }
            if #nodesList >= self.state.maxNodes then break end
        end
    end

    -- Diff: detect new + removed
    local now = os.clock()
    local newFlashes = {}
    for id, _ in newIndex do
        if not self.state.objectIndex[id] then
            newFlashes[id] = { ["until"] = now + 1.5, kind = "new" }
        end
    end
    for id, _ in self.state.objectIndex do
        if not newIndex[id] then
            newFlashes[id] = { ["until"] = now + 1.5, kind = "removed" }
        end
    end
    -- Carry forward still-active flashes
    for id, f in self.state.flashes do
        if f["until"] > now and not newFlashes[id] then
            newFlashes[id] = f
        end
    end

    -- Build edges
    local edges = {}
    local function edgeKey(a, b, kind) return a .. "→" .. b .. "/" .. kind end
    local seenEdges = {}
    local function addEdge(a, b, kind, color)
        if not newIndex[a] or not newIndex[b] then return end
        local k = edgeKey(a, b, kind)
        if seenEdges[k] then return end
        seenEdges[k] = true
        edges[#edges + 1] = { from = a, to = b, kind = "ortho", color = color }
    end
    if snap.referenceGraph then
        if self.state.showUpvalEdges and snap.referenceGraph.fnUpvaluesOf then
            for fn, ups in snap.referenceGraph.fnUpvaluesOf do
                local fid = classifyObjectId({ ref = fn })
                for _, u in ups do
                    addEdge(fid, classifyObjectId({ ref = u }), "upval")
                end
            end
        end
        if self.state.showMemberEdges and snap.referenceGraph.tableMembersOf then
            for tbl, members in snap.referenceGraph.tableMembersOf do
                local tid = classifyObjectId({ ref = tbl })
                for _, m in members do
                    addEdge(tid, classifyObjectId({ ref = m }), "member")
                end
            end
        end
        if self.state.showCallEdges and snap.referenceGraph.fnCalledBy then
            for callee, callers in snap.referenceGraph.fnCalledBy do
                local cid = classifyObjectId({ ref = callee })
                for _, caller in callers do
                    addEdge(classifyObjectId({ ref = caller }), cid, "call")
                end
            end
        end
    end

    -- Layout via Sugiyama. Nodes that survived from the previous scan
    -- keep their position; new nodes get freshly laid-out positions.
    local sugiyamaNodes = {}
    for _, item in nodesList do
        sugiyamaNodes[#sugiyamaNodes + 1] = { id = item.id }
    end
    local sugiyamaEdges = {}
    for _, ed in edges do
        sugiyamaEdges[#sugiyamaEdges + 1] = { from = ed.from, to = ed.to }
    end
    local laidOut = {}
    local layoutOk = false
    if #sugiyamaNodes > 0 then
        local ok2, result = pcall(Sugiyama.layout, sugiyamaNodes, sugiyamaEdges, {
            layerSpacing  = NODE_H * 2.2,
            nodeSpacing   = NODE_W * 1.2,
            nodeWidth     = NODE_W,
            nodeHeight    = NODE_H,
        })
        if ok2 and result and result.positions then
            laidOut = result.positions
            layoutOk = true
        end
    end

    -- Compose final GraphCanvas nodes, preserving positions for known ids
    local theme = self.theme
    local canvasNodes = {}
    for i, item in nodesList do
        local id = item.id
        local pos = self.state.positions[id]
        if not pos and layoutOk and laidOut[id] then
            pos = { x = laidOut[id].x, y = laidOut[id].y }
        end
        if not pos then
            -- Fallback grid
            pos = { x = (i % 8) * (NODE_W + 16),
                    y = math.floor(i / 8) * (NODE_H + 12) }
        end
        local flash = newFlashes[id]
        local colorKey = TYPE_COLOR_KEY[item.obj.type] or "nodeHeader"
        local color = theme and theme:color(colorKey) or Color3.fromRGB(60, 60, 80)
        if flash and flash.kind == "new" then
            color = theme and theme:color("success") or Color3.fromRGB(80, 200, 80)
        elseif flash and flash.kind == "removed" then
            color = theme and theme:color("danger") or Color3.fromRGB(200, 80, 80)
        end
        local label = item.obj.label or item.obj.name or item.obj.type or "?"
        if #label > 22 then label = string.sub(label, 1, 19) .. "…" end
        canvasNodes[#canvasNodes + 1] = {
            id     = id,
            x      = pos.x, y = pos.y, w = NODE_W, h = NODE_H,
            header = label,
            color  = color,
            headerColor = color,
            render = function(api)
                return e("TextLabel", {
                    Size = UDim2.fromOffset(api.innerWidth, api.innerHeight),
                    BackgroundTransparency = 1,
                    Text = (item.obj.source or item.obj.type or "") ..
                           ((item.obj.numUpvalues and " · " .. item.obj.numUpvalues .. "u") or "") ..
                           ((item.obj.numConstants and " · " .. item.obj.numConstants .. "k") or ""),
                    TextColor3 = theme and theme:color("textMuted")
                        or Color3.fromRGB(170, 170, 180),
                    TextSize = math.max(9, math.floor(11 * api.zoom)),
                    Font = Enum.Font.Code,
                    TextXAlignment = Enum.TextXAlignment.Left,
                    TextTruncate = Enum.TextTruncate.AtEnd,
                    ClipsDescendants = true,
                }, {
                    e("UIPadding", { PaddingLeft = UDim.new(0, 6),
                                     PaddingTop = UDim.new(0, 2) }),
                })
            end,
        }
        -- Stash the position so the next scan reuses it
        self.state.positions[id] = pos
    end

    -- Drop positions for objects that no longer exist
    local stillThere = {}
    for id, _ in newIndex do stillThere[id] = true end
    for id, _ in self.state.positions do
        if not stillThere[id] and not newFlashes[id] then
            self.state.positions[id] = nil
        end
    end

    self:setState({
        nodes       = canvasNodes,
        edges       = edges,
        objectIndex = newIndex,
        flashes     = newFlashes,
    })
end

-- ---------------------------------------------------------------------
-- Node click → script generation
-- ---------------------------------------------------------------------

function HeapGraphView:_onNodeClick(nodeId)
    self:setState({ selectedId = nodeId })
end

function HeapGraphView:_copyForSelection(kind)
    local id = self.state.selectedId
    if not id then return end
    local obj = self.state.objectIndex[id]
    if not obj then return end
    local result
    if kind == "fetch" then
        if obj.type == "func" or obj.type == "function" then
            result = ScriptGenerator.fetchClosureFromGC(obj)
        elseif obj.type == "table" then
            result = ScriptGenerator.fetchTableFromGC(obj)
        else
            if self.props.onCopyResult then
                self.props.onCopyResult(false, {
                    "no generator for type: " .. tostring(obj.type) })
            end
            return
        end
    elseif kind == "hook" then
        if obj.type == "func" or obj.type == "function" then
            result = ScriptGenerator.hookClosure(obj, {})
        else
            if self.props.onCopyResult then
                self.props.onCopyResult(false, { "hook only valid for functions" })
            end
            return
        end
    end
    if not result then return end
    local ok, warnings = ScriptGenerator.copyToClipboard(result)
    if self.props.onCopyResult then
        self.props.onCopyResult(ok, warnings)
    end
end

-- ---------------------------------------------------------------------
-- Toolbar
-- ---------------------------------------------------------------------

function HeapGraphView:_renderToolbar()
    local theme = self.theme
    local function btn(label, x, w, color, onClick)
        return e("TextButton", {
            Size = UDim2.fromOffset(w, TOP_BAR_H - 6),
            Position = UDim2.fromOffset(x, 3),
            BackgroundColor3 = color,
            BorderColor3 = theme:color("border"),
            BorderSizePixel = 1,
            Text = label,
            TextColor3 = theme:color("text"),
            TextSize = 11,
            Font = Enum.Font.Code,
            [Event.Activated] = onClick,
        })
    end
    local hbLabel = "Beat: " .. HEARTBEAT_OPTIONS[self.state.heartbeatIdx].label
    local mnLabel = "Max: " .. tostring(self.state.maxNodes)

    local children = {
        btn("Scan", 4, 60,
            self.state.scanning and theme:color("surfaceAlt")
            or theme:color("surface"),
            function() self:_scan() end),
        btn(hbLabel, 68, 80, theme:color("surface"), function()
            local nextIdx = (self.state.heartbeatIdx % #HEARTBEAT_OPTIONS) + 1
            self:setState({ heartbeatIdx = nextIdx })
            self:_restartHeartbeat()
        end),
        btn(mnLabel, 152, 80, theme:color("surface"), function()
            local i = 1
            for k, v in MAX_NODE_OPTIONS do
                if v == self.state.maxNodes then i = k; break end
            end
            local ni = (i % #MAX_NODE_OPTIONS) + 1
            self:setState({ maxNodes = MAX_NODE_OPTIONS[ni] })
        end),
    }
    -- Type filter chips
    local x = 240
    local function chip(label, key, w)
        children[#children + 1] = e("TextButton", {
            Size = UDim2.fromOffset(w, TOP_BAR_H - 6),
            Position = UDim2.fromOffset(x, 3),
            BackgroundColor3 = self.state[key] and theme:color("accent")
                or theme:color("surfaceAlt"),
            BorderColor3 = theme:color("border"),
            BorderSizePixel = 1,
            Text = label,
            TextColor3 = theme:color("text"),
            TextSize = 11,
            Font = Enum.Font.Code,
            [Event.Activated] = function()
                local u = {}
                u[key] = not self.state[key]
                self:setState(u)
                self:_scan()
            end,
        })
        x = x + w + 4
    end
    chip("Functions", "showFunctions", 80)
    chip("Tables",    "showTables",    60)
    chip("Threads",   "showThreads",   64)
    chip("UpvalEdge", "showUpvalEdges", 80)
    chip("MembEdge",  "showMemberEdges", 80)
    chip("CallEdge",  "showCallEdges",  76)

    -- Selection actions
    if self.state.selectedId then
        children[#children + 1] = btn("📋 Fetch", x, 70,
            theme:color("surface"), function() self:_copyForSelection("fetch") end)
        x = x + 74
        children[#children + 1] = btn("📋 Hook", x, 70,
            theme:color("surface"), function() self:_copyForSelection("hook") end)
        x = x + 74
    end

    return e("Frame", {
        Name = "toolbar",
        Size = UDim2.new(1, 0, 0, TOP_BAR_H),
        BackgroundColor3 = theme:color("surfaceAlt"),
        BorderSizePixel = 0,
        ClipsDescendants = true,                                      -- keep chips from overflowing the bar
    }, children)
end

-- ---------------------------------------------------------------------
-- Render
-- ---------------------------------------------------------------------

function HeapGraphView:render()
    local theme = self.theme
    return e("Frame", {
        Name = "HeapGraphView",
        Size = self.props.Size,
        Position = self.props.Position or UDim2.fromOffset(0, 0),
        BackgroundColor3 = theme:color("surface"),
        BorderSizePixel = 0,
    }, {
        self:_renderToolbar(),
        e("Frame", {
            Size = UDim2.new(1, 0, 1, -(TOP_BAR_H + FOOTER_H)),
            Position = UDim2.fromOffset(0, TOP_BAR_H),
            BackgroundTransparency = 1,
        }, {
            e(GraphCanvas, {
                Size = UDim2.fromScale(1, 1),
                nodes = self.state.nodes,
                edges = self.state.edges,
                viewport = self.state.viewport,
                selectedNodeId = self.state.selectedId,
                onNodeClick = function(id) self:_onNodeClick(id) end,
                onViewportChange = function(vp) self.state.viewport = vp end,
                edgeRouting = "ortho",
                showGrid = true,
                minZoom = 0.15, maxZoom = 3.0,
            }),
        }),
        e("Frame", {
            Name = "footer",
            Size = UDim2.new(1, 0, 0, FOOTER_H),
            Position = UDim2.new(0, 0, 1, -FOOTER_H),
            BackgroundColor3 = theme:color("backgroundAlt"),
            BorderSizePixel = 0,
        }, {
            e("TextLabel", {
                Size = UDim2.fromScale(1, 1),
                BackgroundTransparency = 1,
                Text = string.format(
                    "%d nodes · %d edges · last scan %.1fs ago · selected: %s",
                    #self.state.nodes, #self.state.edges,
                    os.clock() - self.state.lastScanAt,
                    self.state.selectedId or "—"),
                TextColor3 = theme:color("textMuted"),
                TextSize = 11,
                Font = Enum.Font.Code,
                TextXAlignment = Enum.TextXAlignment.Left,
            }, {
                e("UIPadding", { PaddingLeft = UDim.new(0, 8) }),
            }),
        }),
    })
end

return HeapGraphView
