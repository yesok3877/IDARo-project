--!nonstrict
-- =====================================================================
-- IDARoblox / UI / Framework / SugiyamaLayout
-- ---------------------------------------------------------------------
-- Pure layered-graph layout (the "Sugiyama" algorithm).
--
-- Pipeline:
--   1. Cycle removal             — caller supplies the back-edge set;
--                                   layout treats them as logically
--                                   reversed for layering, but renders
--                                   them in their original direction.
--   2. Longest-path layering      — every node sits at one more than the
--                                   max layer of its forward predecessors.
--   3. Dummy-node insertion       — every forward edge that spans
--                                   multiple layers gets sliced into a
--                                   chain of single-layer edges, with
--                                   anonymous "dummy" nodes at each
--                                   intermediate layer.
--   4. Crossing reduction         — barycenter heuristic, alternating
--                                   down-sweeps and up-sweeps over the
--                                   layer stack. We run a configurable
--                                   number of passes (default 6).
--   5. X-coordinate assignment    — simple uniform spacing: within each
--                                   layer, nodes occupy slot 0..N-1
--                                   at constant horizontal pitch.
--   6. Centering                  — every layer is centred on the same
--                                   x-axis as the widest one so the
--                                   final graph reads symmetrically.
--
-- Input:
--   graph = {
--     nodes      = { [id] = { width = px, height = px, … (user data) } },
--     edges      = { { from = id, to = id, kind = "..." }, … },
--     backEdges  = OPTIONAL set { [edgeIndex] = true } | { from=, to= }
--     entry      = id,                         -- where to start RPO
--   }
--   opts = {
--     layerSpacingY = 80,
--     nodeSpacingX  = 32,
--     defaultWidth  = 220,
--     defaultHeight = 80,
--     barycenterPasses = 6,
--   }
--
-- Output:
--   layout = {
--     nodes      = { [id] = { x, y, width, height, layer, indexInLayer } },
--     edges      = { { source, target, kind, points = { Vector2, … } }, … },
--     bounds     = { minX, minY, maxX, maxY },
--     layers     = { [layerIdx] = { nodeId, … } },
--     dummyNodes = { [dummyId] = { layer, indexInLayer, x, y } },
--   }
-- =====================================================================

local SugiyamaLayout = {}

local DEFAULTS = {
    layerSpacingY     = 90,
    nodeSpacingX      = 36,
    defaultWidth      = 220,
    defaultHeight     = 80,
    barycenterPasses  = 6,
}

-- ---------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------

local function setOfBackEdges(backEdges)
    local set = {}
    if not backEdges then return set end
    for _, be in backEdges do
        if be.from and be.to then
            set[be.from .. ">" .. be.to] = true
        end
    end
    return set
end

local function edgeIsBack(edge, backSet)
    return backSet[edge.from .. ">" .. edge.to] == true
end

-- ---------------------------------------------------------------------
-- Step 1: forward graph (back edges removed for layering)
-- ---------------------------------------------------------------------

local function buildForward(graph, backSet)
    local outAdj = {}                                                -- node → { succ … }
    local inAdj  = {}                                                -- node → { pred … }
    for id in graph.nodes do
        outAdj[id] = {}
        inAdj[id]  = {}
    end
    for _, e in graph.edges do
        if not edgeIsBack(e, backSet) and graph.nodes[e.from] and graph.nodes[e.to] then
            table.insert(outAdj[e.from], e.to)
            table.insert(inAdj[e.to],  e.from)
        end
    end
    return outAdj, inAdj
end

-- ---------------------------------------------------------------------
-- Step 2: longest-path layer assignment
-- ---------------------------------------------------------------------

-- Topological order via iterative DFS on the forward graph, starting
-- from entry. Returns nodes in postorder; the reverse is a valid
-- topo sort.
local function topoOrder(graph, outAdj, entry)
    local visited = {}
    local post    = {}
    local function visitAll(roots)
        local stack = {}
        for _, r in roots do
            if not visited[r] then
                stack[#stack + 1] = { id = r, idx = 1 }
                visited[r] = true
            end
            while #stack > 0 do
                local top = stack[#stack]
                local succs = outAdj[top.id]
                if top.idx <= #succs then
                    local s = succs[top.idx]
                    top.idx = top.idx + 1
                    if not visited[s] then
                        visited[s] = true
                        stack[#stack + 1] = { id = s, idx = 1 }
                    end
                else
                    post[#post + 1] = top.id
                    stack[#stack] = nil
                end
            end
        end
    end
    visitAll({ entry })
    -- Catch orphans (defensive)
    for id in graph.nodes do
        if not visited[id] then
            visitAll({ id })
        end
    end
    local topo = {}
    for i = #post, 1, -1 do topo[#topo + 1] = post[i] end
    return topo
end

local function assignLayers(graph, outAdj, inAdj, topo)
    local layer = {}
    for _, n in topo do
        local preds = inAdj[n]
        if #preds == 0 then
            layer[n] = 0
        else
            local best = 0
            for _, p in preds do
                local pl = layer[p] or 0
                if pl + 1 > best then best = pl + 1 end
            end
            layer[n] = best
        end
    end
    return layer
end

-- ---------------------------------------------------------------------
-- Step 3: dummy node insertion
-- ---------------------------------------------------------------------
-- For every forward edge (u → v) with `layer[v] - layer[u] > 1`,
-- create dummy nodes at intermediate layers and replace the edge by a
-- chain. The original edge id is preserved on each segment so render
-- can join them back into a polyline.

local function insertDummies(graph, outAdj, inAdj, layer, backSet)
    local dummyNodes = {}
    local segments   = {}                                            -- per original-edge segment chains
    local nextDummyId = -1                                           -- negative ids → never collide with block ids

    local function newDummy(atLayer)
        local id = nextDummyId
        nextDummyId = nextDummyId - 1
        dummyNodes[id] = { layer = atLayer, indexInLayer = 0 }
        outAdj[id] = {}
        inAdj[id]  = {}
        layer[id]  = atLayer
        return id
    end

    for edgeIdx, e in graph.edges do
        if edgeIsBack(e, backSet) then
            -- Back edges aren't sliced — we render them in original
            -- direction with a single segment chain (source → target).
            segments[edgeIdx] = { e.from, e.to }
        elseif not graph.nodes[e.from] or not graph.nodes[e.to] then
            -- Stale edge; skip
        else
            local fromLayer = layer[e.from]
            local toLayer   = layer[e.to]
            if not fromLayer or not toLayer then
                segments[edgeIdx] = { e.from, e.to }
            elseif toLayer - fromLayer <= 1 then
                segments[edgeIdx] = { e.from, e.to }
            else
                local chain = { e.from }
                local prev  = e.from
                for L = fromLayer + 1, toLayer - 1 do
                    local d = newDummy(L)
                    chain[#chain + 1] = d
                    table.insert(outAdj[prev], d)
                    table.insert(inAdj[d], prev)
                    prev = d
                end
                chain[#chain + 1] = e.to
                table.insert(outAdj[prev], e.to)
                table.insert(inAdj[e.to], prev)
                -- Remove the original direct edge from outAdj[from]/inAdj[to].
                local fromSuccs = outAdj[e.from]
                for i, s in fromSuccs do
                    if s == e.to then table.remove(fromSuccs, i); break end
                end
                local toPreds = inAdj[e.to]
                for i, p in toPreds do
                    if p == e.from then table.remove(toPreds, i); break end
                end
                segments[edgeIdx] = chain
            end
        end
    end

    return dummyNodes, segments
end

-- ---------------------------------------------------------------------
-- Step 4: barycenter crossing reduction
-- ---------------------------------------------------------------------

-- Build layers[L] = { nodeId, … } in initial order (current outAdj/inAdj
-- iteration order). This gives a deterministic starting permutation,
-- not optimal but reasonable.
local function buildInitialLayers(graph, dummyNodes, layer)
    local layers = {}
    for id in graph.nodes do
        local L = layer[id]
        if L then
            layers[L] = layers[L] or {}
            table.insert(layers[L], id)
        end
    end
    for id in dummyNodes do
        local L = layer[id]
        layers[L] = layers[L] or {}
        table.insert(layers[L], id)
    end
    return layers
end

local function indexLayer(layerArr)
    local idx = {}
    for i, n in layerArr do idx[n] = i end
    return idx
end

local function barycenterOf(neighbors, neighborIndex)
    local n = #neighbors
    if n == 0 then return math.huge end                              -- floats to end if no neighbors
    local s = 0
    for _, x in neighbors do
        s = s + (neighborIndex[x] or 0)
    end
    return s / n
end

local function sortStable(arr, keyFn)
    -- Stable sort: decorate, sort, undecorate.
    local decorated = {}
    for i, v in arr do decorated[i] = { v = v, k = keyFn(v), origIdx = i } end
    table.sort(decorated, function(a, b)
        if a.k == b.k then return a.origIdx < b.origIdx end
        return a.k < b.k
    end)
    for i, d in decorated do arr[i] = d.v end
end

local function reduceCrossings(layers, outAdj, inAdj, passes)
    local maxLayer = 0
    for L in layers do if L > maxLayer then maxLayer = L end end
    for pass = 1, passes do
        -- Down sweep (use predecessors' indices in the previous layer).
        for L = 1, maxLayer do
            local prev = layers[L - 1]
            local cur  = layers[L]
            if prev and cur then
                local prevIdx = indexLayer(prev)
                sortStable(cur, function(n)
                    return barycenterOf(inAdj[n] or {}, prevIdx)
                end)
            end
        end
        -- Up sweep (use successors' indices in the next layer).
        for L = maxLayer - 1, 0, -1 do
            local next = layers[L + 1]
            local cur  = layers[L]
            if next and cur then
                local nextIdx = indexLayer(next)
                sortStable(cur, function(n)
                    return barycenterOf(outAdj[n] or {}, nextIdx)
                end)
            end
        end
    end
    return layers
end

-- ---------------------------------------------------------------------
-- Step 5: coordinate assignment
-- ---------------------------------------------------------------------

-- Per-layer uniform spacing, centred around the widest layer's centre.
local function assignCoords(layers, graph, dummyNodes, opts)
    local layerSpacingY = opts.layerSpacingY
    local nodeSpacingX  = opts.nodeSpacingX
    local defaultWidth  = opts.defaultWidth
    local defaultHeight = opts.defaultHeight

    -- Compute each layer's total width, then the global midpoint.
    local layerWidth  = {}
    local globalCenter = 0
    local maxLayer = 0
    for L in layers do if L > maxLayer then maxLayer = L end end
    local widest = 0
    for L = 0, maxLayer do
        local arr = layers[L] or {}
        local w = 0
        for i, id in arr do
            local node = graph.nodes[id]
            local nw   = node and (node.width or defaultWidth) or 8   -- dummy width
            w = w + nw
            if i < #arr then w = w + nodeSpacingX end
        end
        layerWidth[L] = w
        if w > widest then widest = w end
    end
    globalCenter = widest / 2

    local nodes = {}
    for L = 0, maxLayer do
        local arr = layers[L] or {}
        local y   = L * layerSpacingY
        local lineW = layerWidth[L] or 0
        local lineStart = globalCenter - lineW / 2
        local cursor = lineStart
        for i, id in arr do
            local source = graph.nodes[id] or dummyNodes[id]
            local nw, nh
            if graph.nodes[id] then
                nw = source.width  or defaultWidth
                nh = source.height or defaultHeight
            else
                nw, nh = 8, 8
            end
            nodes[id] = {
                x            = cursor,
                y            = y,
                width        = nw,
                height       = nh,
                layer        = L,
                indexInLayer = i,
                isDummy      = dummyNodes[id] ~= nil,
            }
            cursor = cursor + nw + nodeSpacingX
        end
    end

    return nodes
end

-- ---------------------------------------------------------------------
-- Step 6: build poly-line points for edges
-- ---------------------------------------------------------------------

local function buildEdgePoints(edges, segments, nodes, backSet)
    local out = {}
    for edgeIdx, e in edges do
        local segChain = segments[edgeIdx]
        if not segChain then continue end
        local points = {}
        for i, nid in segChain do
            local n = nodes[nid]
            if not n then continue end
            local cx = n.x + n.width / 2
            local cy
            if i == 1 then
                cy = n.y + n.height                                  -- bottom of source
            elseif i == #segChain then
                cy = n.y                                              -- top of target
            else
                cy = n.y + n.height / 2                              -- through dummy centre
            end
            points[#points + 1] = Vector2.new(cx, cy)
        end
        out[#out + 1] = {
            source = e.from,
            target = e.to,
            kind   = e.kind,
            isBack = edgeIsBack(e, backSet),
            points = points,
        }
    end
    return out
end

-- ---------------------------------------------------------------------
-- Bounds
-- ---------------------------------------------------------------------

local function computeBounds(nodes)
    local minX, minY = math.huge, math.huge
    local maxX, maxY = -math.huge, -math.huge
    local has = false
    for _, n in nodes do
        has = true
        if n.x < minX then minX = n.x end
        if n.y < minY then minY = n.y end
        if n.x + n.width  > maxX then maxX = n.x + n.width  end
        if n.y + n.height > maxY then maxY = n.y + n.height end
    end
    if not has then
        return { minX = 0, minY = 0, maxX = 0, maxY = 0 }
    end
    return { minX = minX, minY = minY, maxX = maxX, maxY = maxY }
end

-- ---------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------

function SugiyamaLayout.compute(graph, opts)
    opts = opts or {}
    for k, v in DEFAULTS do
        if opts[k] == nil then opts[k] = v end
    end
    local backSet = setOfBackEdges(graph.backEdges)

    -- 1. Forward adjacency
    local outAdj, inAdj = buildForward(graph, backSet)

    -- 2. Topo sort + longest-path layers
    local entry = graph.entry
    if not entry then
        for id in graph.nodes do entry = id; break end
    end
    local topo  = topoOrder(graph, outAdj, entry)
    local layer = assignLayers(graph, outAdj, inAdj, topo)
    -- Default any unreached node to layer 0
    for id in graph.nodes do
        if layer[id] == nil then layer[id] = 0 end
    end

    -- 3. Dummy insertion
    local dummyNodes, segments = insertDummies(graph, outAdj, inAdj, layer, backSet)

    -- 4. Initial layers + barycenter sweeps
    local layers = buildInitialLayers(graph, dummyNodes, layer)
    reduceCrossings(layers, outAdj, inAdj, opts.barycenterPasses)

    -- 5. Coordinates
    local nodes = assignCoords(layers, graph, dummyNodes, opts)

    -- 6. Edges
    local laidOutEdges = buildEdgePoints(graph.edges, segments, nodes, backSet)

    return {
        nodes      = nodes,
        edges      = laidOutEdges,
        layers     = layers,
        dummyNodes = dummyNodes,
        bounds     = computeBounds(nodes),
    }
end

return SugiyamaLayout
