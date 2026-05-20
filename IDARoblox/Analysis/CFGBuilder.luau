--!nonstrict
-- =====================================================================
-- IDARoblox / Analysis / CFGBuilder
-- ---------------------------------------------------------------------
-- Builds the control-flow graph for a single proto.
--
-- Pipeline:
--   1. Find block leaders     — entry PC, every branch target, and the
--                                instruction following every terminator
--   2. Slice instructions      — leader[i] .. leader[i+1]-1 = block body
--   3. Build edges             — read structured Disassembler refs:
--                                  branch refs → control-transfer edges
--                                  conditional branches also fall through
--                                  unconditional jumps don't fall through
--                                  returns reach the synthetic exit node
--   4. Reverse-postorder DFS   — used for the dominator iteration order
--   5. Immediate dominators    — Cooper-Harvey-Kennedy (CHK) iterative
--                                "engineered" algorithm: O(N · E · α(N))
--                                in practice, near-linear on CFGs.
--   6. Dominator tree          — children[idom[b]] = b
--   7. Natural loop detection  — every edge (u → v) where v dominates u
--                                is a back edge; the loop body is the
--                                reach-back closure of u in the reverse
--                                CFG, stopping at v.
--   8. Loop nesting depth      — derived from loop containment.
--
-- Output:
--   cfg = {
--       protoId        = ...,
--       entry          = 1,
--       exitId         = -1,                       -- synthetic exit node id
--       blocks         = {                          -- id → Block
--           [id] = {
--               id, startPc, endPc, instructions[],
--               successors[], predecessors[],
--               terminator       = "fall" | "jump" | "branch"
--                                  | "return" | "exit" | "indirect",
--               idom             = blockId | nil,
--               domTreeChildren  = { ... },
--               dominators       = { blockId set },
--               isLoopHeader     = bool,
--               loopId           = number?,
--               nestingDepth     = number,
--           },
--       },
--       edges          = { { from, to, kind = "fall"|"taken"|"jump"|"back"|"exit" } },
--       backEdges      = { … same shape },
--       loops          = { { id, header, body = {blockIds}, exits = {blockIds},
--                            backEdges = {…}, nestingDepth, parent = loopId? } },
--       reversePostOrder = { blockId, … },
--       postOrder        = { blockId, … },
--       stats          = { blockCount, edgeCount, loopCount, maxNestingDepth },
--   }
-- =====================================================================

local OpcodeTable = _G.IDARo.require("Analysis.OpcodeTable")

local CFGBuilder = {}
CFGBuilder.__index = CFGBuilder

local SYNTHETIC_EXIT = -1                                            -- sentinel block id

-- ---------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------

function CFGBuilder.new(disassembler, opts)
    if not disassembler then
        error("CFGBuilder.new: disassembler required", 2)
    end
    opts = opts or {}
    return setmetatable({
        _disasm   = disassembler,
        _cache    = {},                                              -- protoId → CFG
        _logger   = opts.logger,
    }, CFGBuilder)
end

function CFGBuilder:cfgForProto(protoId: number)
    local cached = self._cache[protoId]
    if cached then return cached end
    local stream = self._disasm:disassembleProto(protoId)
    local cfg = self:_build(stream, protoId)
    self._cache[protoId] = cfg
    return cfg
end

function CFGBuilder:invalidate(protoId: number?)
    if protoId then self._cache[protoId] = nil
    else self._cache = {} end
end

-- ---------------------------------------------------------------------
-- Internal: leader detection
-- ---------------------------------------------------------------------

local function pickLeaders(stream)
    local proto = stream.proto
    local leaders = { [1] = true }                                   -- entry
    local rowByPc = stream.rowByPc

    for _, row in stream.rows do
        if row.references then
            for _, ref in row.references do
                if ref.kind == "branch" and ref.target then
                    if ref.target >= 1 and ref.target <= proto.sizecode then
                        leaders[ref.target] = true
                    end
                end
            end
        end
        if row.isTerminator then
            -- Fall-through PC is the row's pc + its instruction width.
            local width = row.hasAux and 2 or 1
            local nextPc = row.pc + width
            if nextPc <= proto.sizecode then
                leaders[nextPc] = true
            end
        end
    end

    local sorted = {}
    for pc in leaders do sorted[#sorted + 1] = pc end
    table.sort(sorted)
    return sorted
end

-- ---------------------------------------------------------------------
-- Internal: block slicing
-- ---------------------------------------------------------------------

local function sliceBlocks(stream, leaderPcs)
    local proto    = stream.proto
    local rowByPc  = stream.rowByPc
    local blocks   = {}                                              -- id → block
    local pcToBlock = {}                                             -- pc → blockId

    for i = 1, #leaderPcs do
        local startPc = leaderPcs[i]
        local endPc   = (i < #leaderPcs and leaderPcs[i + 1] - 1) or proto.sizecode
        local instr   = {}
        -- Step through the [startPc .. endPc] range, picking the row for
        -- each PC. AUX-only slots have no row (stream.rowByPc[auxPc] is
        -- nil), which is fine — we collect only real instructions.
        local pc = startPc
        while pc <= endPc do
            local row = rowByPc[pc]
            if row then
                instr[#instr + 1] = row
                pcToBlock[pc] = i
                local width = row.hasAux and 2 or 1
                pc = pc + width
            else
                pc = pc + 1
            end
        end
        blocks[i] = {
            id              = i,
            startPc         = startPc,
            endPc           = endPc,
            instructions    = instr,
            successors      = {},
            predecessors    = {},
            terminator      = "fall",                                -- corrected below
            idom            = nil,
            domTreeChildren = {},
            dominators      = nil,                                   -- computed later
            isLoopHeader    = false,
            loopId          = nil,
            nestingDepth    = 0,
        }
    end
    return blocks, pcToBlock
end

-- ---------------------------------------------------------------------
-- Internal: edge construction
-- ---------------------------------------------------------------------

local function pushEdge(edgesList, from, to, kind)
    edgesList[#edgesList + 1] = { from = from, to = to, kind = kind }
end

local function buildEdges(blocks, pcToBlock, proto, edges)
    for _, block in blocks do
        local lastRow = block.instructions[#block.instructions]
        if not lastRow then
            -- Empty block (shouldn't happen but defensive)
            block.terminator = "fall"
            continue
        end

        -- Walk the structured references on the terminator row.
        local branchTargets = {}                                     -- PCs reached via branch refs
        local isReturn = false
        if lastRow.references then
            for _, ref in lastRow.references do
                if ref.kind == "branch" and ref.target then
                    branchTargets[#branchTargets + 1] = {
                        pc          = ref.target,
                        conditional = ref.conditional,
                        reason      = ref.reason,
                    }
                elseif ref.kind == "return" then
                    isReturn = true
                end
            end
        end

        local lastWidth = lastRow.hasAux and 2 or 1
        local fallPc    = lastRow.pc + lastWidth
        local fallBlock = pcToBlock[fallPc]

        if isReturn then
            block.terminator = "return"
            pushEdge(edges, block.id, SYNTHETIC_EXIT, "exit")
            block.successors[#block.successors + 1] = SYNTHETIC_EXIT
        elseif #branchTargets == 0 then
            -- No branches in refs → pure fall-through if there's a next
            -- block, otherwise this block exits.
            if fallBlock then
                block.terminator = "fall"
                pushEdge(edges, block.id, fallBlock, "fall")
                block.successors[#block.successors + 1] = fallBlock
            else
                block.terminator = "exit"
                pushEdge(edges, block.id, SYNTHETIC_EXIT, "exit")
                block.successors[#block.successors + 1] = SYNTHETIC_EXIT
            end
        else
            -- One or more branch refs. Classify by whether any is
            -- conditional: if at least one is conditional we also have
            -- a fall-through; if all are unconditional (the typical
            -- single-jump case), no fall-through.
            local anyConditional = false
            local seenTargets = {}
            for _, t in branchTargets do
                if t.conditional then anyConditional = true end
                local tBlock = pcToBlock[t.pc]
                if tBlock and not seenTargets[tBlock] then
                    seenTargets[tBlock] = true
                    pushEdge(edges, block.id, tBlock, "taken")
                    block.successors[#block.successors + 1] = tBlock
                end
            end
            if anyConditional and fallBlock and not seenTargets[fallBlock] then
                pushEdge(edges, block.id, fallBlock, "fall")
                block.successors[#block.successors + 1] = fallBlock
            end
            block.terminator = anyConditional and "branch"
                or (#branchTargets == 1 and "jump")
                or "indirect"
        end
    end

    -- Build predecessors by inverting the edges.
    for _, e in edges do
        if e.to ~= SYNTHETIC_EXIT then
            local target = blocks[e.to]
            if target then
                target.predecessors[#target.predecessors + 1] = e.from
            end
        end
    end
end

-- ---------------------------------------------------------------------
-- Internal: reverse-postorder DFS
-- ---------------------------------------------------------------------

local function reversePostOrder(blocks, entryId)
    local visited = {}
    local postOrder = {}
    local stack = { { id = entryId, idx = 1 } }
    visited[entryId] = true
    while #stack > 0 do
        local top = stack[#stack]
        local block = blocks[top.id]
        if not block then
            -- Synthetic exit or invalid: pop without adding successors
            postOrder[#postOrder + 1] = top.id
            stack[#stack] = nil
        elseif top.idx <= #block.successors then
            local succId = block.successors[top.idx]
            top.idx = top.idx + 1
            if succId == SYNTHETIC_EXIT then
                -- Skip; not part of the dominator world. The exit is
                -- recorded implicitly by the lack of a predecessor in
                -- the inverted edge.
            elseif not visited[succId] then
                visited[succId] = true
                stack[#stack + 1] = { id = succId, idx = 1 }
            end
        else
            postOrder[#postOrder + 1] = top.id
            stack[#stack] = nil
        end
    end
    local rpo = {}
    for i = #postOrder, 1, -1 do
        rpo[#rpo + 1] = postOrder[i]
    end
    return rpo, postOrder
end

-- ---------------------------------------------------------------------
-- Internal: Cooper-Harvey-Kennedy immediate dominators
-- ---------------------------------------------------------------------

local function computeIDoms(blocks, entryId, reversePostOrder, postOrder)
    local idom = {}
    idom[entryId] = entryId

    -- Build a postorder rank table: pc → its postorder index, used by
    -- the `intersect` finger-walk.
    local poRank = {}
    for i, blkId in postOrder do
        poRank[blkId] = i
    end

    local function intersect(b1, b2)
        local f1 = b1
        local f2 = b2
        local guard = 0
        while f1 ~= f2 do
            guard = guard + 1
            if guard > 10000 then break end                          -- safety net
            while (poRank[f1] or 0) < (poRank[f2] or 0) do
                local nxt = idom[f1]
                if not nxt or nxt == f1 then break end
                f1 = nxt
            end
            while (poRank[f2] or 0) < (poRank[f1] or 0) do
                local nxt = idom[f2]
                if not nxt or nxt == f2 then break end
                f2 = nxt
            end
            -- If neither finger could advance, neither is reachable from
            -- the other via idom; bail with the higher-postorder one
            -- (typically the entry side).
            if (poRank[f1] or 0) == (poRank[f2] or 0) and f1 ~= f2 then break end
        end
        return f1
    end

    local changed = true
    local iter = 0
    while changed do
        changed = false
        iter = iter + 1
        -- Iterate in reverse postorder, skipping entry (it's its own dom)
        for _, blkId in reversePostOrder do
            if blkId ~= entryId then
                local block = blocks[blkId]
                if block then
                    -- Pick the first processed predecessor.
                    local newIdom
                    for _, predId in block.predecessors do
                        if idom[predId] then
                            newIdom = predId
                            break
                        end
                    end
                    if newIdom then
                        for _, predId in block.predecessors do
                            if predId ~= newIdom and idom[predId] then
                                newIdom = intersect(predId, newIdom)
                            end
                        end
                        if idom[blkId] ~= newIdom then
                            idom[blkId] = newIdom
                            changed = true
                        end
                    end
                end
            end
        end
        if iter > 100 then
            -- Hard stop to prevent infinite spinning on pathological CFGs;
            -- in practice we converge in ≤ 5 iterations.
            break
        end
    end
    return idom, iter
end

-- ---------------------------------------------------------------------
-- Internal: compute full dominator set (used for loop detection)
-- ---------------------------------------------------------------------

local function dominatorSet(blocks, idom, entryId, blockId): { [number]: boolean }
    local set = { [blockId] = true }
    local cur = blockId
    while cur ~= entryId do
        cur = idom[cur]
        if not cur or set[cur] then break end
        set[cur] = true
    end
    return set
end

local function dominates(domSet, a: number, b: number): boolean
    return domSet[b] ~= nil and domSet[b][a] == true
end

-- ---------------------------------------------------------------------
-- Internal: natural loop detection
-- ---------------------------------------------------------------------

local function findNaturalLoops(blocks, edges, idom, entryId)
    -- 1. Materialize dominator sets for every block (needed for back-edge
    --    test). For very large CFGs this is O(N²) worst-case but fine in
    --    practice since CFG depth is shallow.
    local domSets = {}
    for blkId in blocks do
        domSets[blkId] = dominatorSet(blocks, idom, entryId, blkId)
    end

    -- 2. Identify back edges: (u → v) where v dominates u.
    local backEdges = {}
    for _, e in edges do
        if e.to ~= SYNTHETIC_EXIT and e.from ~= SYNTHETIC_EXIT then
            local domSetU = domSets[e.from]
            if domSetU and domSetU[e.to] then
                backEdges[#backEdges + 1] = { from = e.from, to = e.to, kind = "back" }
                e.kind = "back"
            end
        end
    end

    -- 3. For each back edge (u, v), the loop is { v } ∪ { all blocks that
    --    can reach u in the reverse CFG without passing through v }.
    local loops = {}
    for _, be in backEdges do
        local header = be.to
        local body = { [header] = true }
        local stack = { be.from }
        body[be.from] = true
        while #stack > 0 do
            local cur = table.remove(stack)
            local block = blocks[cur]
            if block then
                for _, predId in block.predecessors do
                    if predId ~= SYNTHETIC_EXIT and not body[predId] then
                        body[predId] = true
                        stack[#stack + 1] = predId
                    end
                end
            end
        end
        -- Collect loop exits: edges leaving any body block to a non-body
        -- (and non-exit) block.
        local exits = {}
        local seenExit = {}
        for bId in body do
            local block = blocks[bId]
            if block then
                for _, succ in block.successors do
                    if succ ~= SYNTHETIC_EXIT and not body[succ] and not seenExit[succ] then
                        seenExit[succ] = true
                        exits[#exits + 1] = succ
                    end
                end
            end
        end
        loops[#loops + 1] = {
            id           = #loops + 1,
            header       = header,
            body         = body,
            exits        = exits,
            backEdges    = { be },
            nestingDepth = 0,                                       -- computed below
            parent       = nil,
        }
        blocks[header].isLoopHeader = true
    end

    -- 4. Merge loops sharing a header (multiple back edges → single loop)
    local byHeader = {}
    local merged = {}
    for _, loop in loops do
        local existing = byHeader[loop.header]
        if existing then
            for b in loop.body do existing.body[b] = true end
            for _, be in loop.backEdges do existing.backEdges[#existing.backEdges + 1] = be end
        else
            byHeader[loop.header] = loop
            merged[#merged + 1] = loop
        end
    end

    -- Renumber loop ids after merge.
    for i, loop in merged do loop.id = i end

    -- 5. Compute loop nesting: a loop A is nested inside loop B iff
    --    A.header ∈ B.body and A ≠ B. The deepest enclosing loop is the
    --    `parent`.
    for _, inner in merged do
        local depth = 0
        local parent = nil
        for _, outer in merged do
            if outer ~= inner and outer.body[inner.header] then
                depth = depth + 1
                -- The smallest enclosing body is the most-immediate parent.
                local outerSize = 0
                for _ in outer.body do outerSize = outerSize + 1 end
                if not parent then
                    parent = outer
                else
                    local parentSize = 0
                    for _ in parent.body do parentSize = parentSize + 1 end
                    if outerSize < parentSize then parent = outer end
                end
            end
        end
        inner.nestingDepth = depth
        inner.parent       = parent and parent.id or nil
    end

    -- 6. Stamp blocks with their innermost loop id and nesting depth.
    for _, loop in merged do
        for blkId in loop.body do
            local block = blocks[blkId]
            if block and (block.loopId == nil
                or merged[block.loopId].nestingDepth < loop.nestingDepth) then
                block.loopId       = loop.id
                block.nestingDepth = loop.nestingDepth + 1
            end
        end
    end

    return merged, backEdges
end

-- ---------------------------------------------------------------------
-- Public build entry point
-- ---------------------------------------------------------------------

function CFGBuilder:_build(stream, protoId)
    local proto = stream.proto
    local leaderPcs = pickLeaders(stream)
    local blocks, pcToBlock = sliceBlocks(stream, leaderPcs)
    local edges = {}
    buildEdges(blocks, pcToBlock, proto, edges)

    local entryId = 1
    local rpo, po = reversePostOrder(blocks, entryId)
    local idom, _idomIters = computeIDoms(blocks, entryId, rpo, po)

    -- Populate idom field and dominator-tree children.
    for blkId, block in blocks do
        local d = idom[blkId]
        if d and d ~= blkId then
            block.idom = d
            local parent = blocks[d]
            if parent then
                parent.domTreeChildren[#parent.domTreeChildren + 1] = blkId
            end
        end
    end

    -- Cache the (small) dominator set per block — useful for later passes.
    for blkId in blocks do
        blocks[blkId].dominators = dominatorSet(blocks, idom, entryId, blkId)
    end

    local loops, backEdges = findNaturalLoops(blocks, edges, idom, entryId)

    local maxNest = 0
    for _, block in blocks do
        if block.nestingDepth > maxNest then maxNest = block.nestingDepth end
    end

    local cfg = {
        protoId           = protoId,
        entry             = entryId,
        exitId            = SYNTHETIC_EXIT,
        blocks            = blocks,
        edges             = edges,
        backEdges         = backEdges,
        loops             = loops,
        idom              = idom,
        reversePostOrder  = rpo,
        postOrder         = po,
        pcToBlock         = pcToBlock,
        stream            = stream,                                  -- back-reference
        stats = {
            blockCount       = #leaderPcs,
            edgeCount        = #edges,
            loopCount        = #loops,
            maxNestingDepth  = maxNest,
            backEdgeCount    = #backEdges,
        },
    }

    -- Attach handy query helpers.
    function cfg:dominators(blockId)
        local b = self.blocks[blockId]
        return b and b.dominators or {}
    end
    function cfg:dominates(a, b)
        local domSet = self.blocks[b] and self.blocks[b].dominators
        return domSet and domSet[a] == true or false
    end
    function cfg:loopOf(blockId)
        local b = self.blocks[blockId]
        if not b or not b.loopId then return nil end
        return self.loops[b.loopId]
    end
    function cfg:blockAtPc(pc)
        local id = self.pcToBlock[pc]
        return id and self.blocks[id] or nil
    end
    function cfg:successors(blockId)
        local b = self.blocks[blockId]
        return b and b.successors or {}
    end
    function cfg:predecessors(blockId)
        local b = self.blocks[blockId]
        return b and b.predecessors or {}
    end

    return cfg
end

-- ---------------------------------------------------------------------
-- Manifest
-- ---------------------------------------------------------------------

function CFGBuilder.manifest()
    return {
        id           = "Analysis.CFGBuilder",
        dependencies = { "Analysis.Disassembler" },
        weight       = 0.4,
        serviceName  = "CFGBuilder",
        stages = {
            { id = "register", weight = 1.0, fn = function(ctx)
                ctx:report(1, "CFGBuilder ready")
            end },
        },
    }
end

return CFGBuilder
