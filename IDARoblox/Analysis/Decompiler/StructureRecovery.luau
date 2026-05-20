--!nonstrict
-- =====================================================================
-- IDARoblox / Analysis / Decompiler / StructureRecovery
-- ---------------------------------------------------------------------
-- Linear-IR → structured-IR converter. Walks the CFG using dominators
-- and loop information from CFGBuilder to fold jump/branch/label
-- markers into nested if/while/repeat/for/break/continue statements.
--
-- Algorithm:
--   1. Partition lifted statements into per-block sequences (block.stmts)
--      using each block's [startPc..endPc] range.
--   2. Identify natural loops (already done by CFGBuilder).
--      - For each loop, find its pre-header (predecessor outside body)
--        and exit set.
--      - Classify the loop:
--          * fornum: pre-header ends with FORNPREP, back-edge source
--                    ends with FORNLOOP
--          * forgen: pre-header ends with FORGPREP*, back-edge source
--                    ends with FORGLOOP
--          * otherwise → while (when the header has a conditional exit)
--                       or repeat-style (handled like while for v1).
--   3. Recursively emit blocks via emitFrom(blockId, ctx) where ctx
--      carries:
--          - loopStack[] : active loops, innermost last
--          - visited{}   : blocks already emitted in this scope
--          - stopAt      : sentinel block id; emission stops if reached
--                          (used to terminate "then" / "else" arms at
--                          the merge point).
--   4. Terminator handling:
--          - return                 → emit unchanged
--          - fall                   → recurse into the single successor
--          - unconditional jump     → continue / break / goto fallback
--          - conditional branch     → if/else with merge-point computation
--
-- The merge point of a conditional is found by parallel BFS over
-- successors from both branch targets until they collide.
--
-- Output:
--   recovered = {
--     body        = <IR.block>,             -- the entire structured body
--     gotoLabels  = { [pc] = true },        -- labels that survived (i.e.
--                                             couldn't be folded into a
--                                             structured construct)
--     stats       = { ifCount, whileCount,
--                     forNumCount, forGenCount,
--                     gotoCount, breakCount,
--                     continueCount, returnCount }
--   }
-- =====================================================================

local IR          = _G.IDARo.require("Analysis.Decompiler.IR")
local OpcodeTable = _G.IDARo.require("Analysis.OpcodeTable")
local Op          = OpcodeTable.Op

local StructureRecovery = {}

-- ---------------------------------------------------------------------
-- Block-level statement partitioning
-- ---------------------------------------------------------------------

local function partitionStmts(cfg, liftedStmts)
    local byBlock = {}                                              -- blockId → { stmts }
    for blockId in cfg.blocks do byBlock[blockId] = {} end

    for _, stmt in liftedStmts do
        local pc = stmt.pc
        if pc and cfg.pcToBlock then
            local b = cfg.pcToBlock[pc]
            if b and byBlock[b] then
                byBlock[b][#byBlock[b] + 1] = stmt
            end
        end
    end
    -- Labels were inserted with pc = the label's address; if there's no
    -- matching pcToBlock entry, place the label at the block whose
    -- startPc == pc.
    for _, stmt in liftedStmts do
        if stmt.kind == "label" and stmt.pc and not cfg.pcToBlock[stmt.pc] then
            for blockId, block in cfg.blocks do
                if block.startPc == stmt.pc then
                    table.insert(byBlock[blockId], 1, stmt); break
                end
            end
        end
    end
    return byBlock
end

-- ---------------------------------------------------------------------
-- Loop classification + pre-header / exit set
-- ---------------------------------------------------------------------

local function tagBlockOpAt(cfg, blockId)
    local block = cfg.blocks[blockId]
    if not block then return nil end
    local lastRow = block.instructions[#block.instructions]
    return lastRow and lastRow.op or nil
end

local function findPreHeader(cfg, loop)
    local header = cfg.blocks[loop.header]
    for _, predId in header.predecessors do
        if predId ~= cfg.exitId and not loop.body[predId] then
            return predId
        end
    end
    return nil
end

local function classifyLoop(cfg, loop)
    loop.preHeader = findPreHeader(cfg, loop)
    local preOp = loop.preHeader and tagBlockOpAt(cfg, loop.preHeader) or nil

    -- Find the back-edge source(s) for this loop.
    local backSources = {}
    for _, be in loop.backEdges do
        backSources[be.from] = true
    end

    -- Determine the dominant back-edge terminator opcode (used to
    -- recognise FORNLOOP / FORGLOOP).
    local backOp
    for bId in backSources do
        backOp = tagBlockOpAt(cfg, bId) or backOp
    end

    if preOp == Op.FORNPREP and backOp == Op.FORNLOOP then
        loop.kind = "fornum"
    elseif (preOp == Op.FORGPREP or preOp == Op.FORGPREP_INEXT or preOp == Op.FORGPREP_NEXT)
        and backOp == Op.FORGLOOP then
        loop.kind = "forgen"
    else
        -- Distinguish while vs repeat: while loops have the test at the
        -- header (so the header block ends in a conditional branch that
        -- exits when the condition is false); repeat loops have the
        -- test at the back-edge source.
        local headerOp = tagBlockOpAt(cfg, loop.header)
        if headerOp and OpcodeTable.Meta[headerOp]
            and OpcodeTable.Meta[headerOp].flow == "branch" then
            loop.kind = "while"
        else
            loop.kind = "repeat"
        end
    end

    -- Build a fast loop-exit lookup.
    loop.exitSet = {}
    for _, ex in loop.exits do loop.exitSet[ex] = true end
end

-- ---------------------------------------------------------------------
-- Merge-point finder for if/else recovery
-- ---------------------------------------------------------------------

local function findMergePoint(cfg, blockA, blockB)
    if blockA == blockB then return blockA end
    if not blockA or not blockB then return nil end
    local visitA = { [blockA] = true }
    local visitB = { [blockB] = true }
    local qA = { blockA }
    local qB = { blockB }
    local steps = 0
    while (#qA > 0 or #qB > 0) and steps < 1000 do
        steps = steps + 1
        if #qA > 0 then
            local cur = table.remove(qA, 1)
            if visitB[cur] then return cur end
            local block = cfg.blocks[cur]
            if block then
                for _, s in block.successors do
                    if s ~= cfg.exitId and not visitA[s] then
                        visitA[s] = true
                        qA[#qA + 1] = s
                    end
                end
            end
        end
        if #qB > 0 then
            local cur = table.remove(qB, 1)
            if visitA[cur] then return cur end
            local block = cfg.blocks[cur]
            if block then
                for _, s in block.successors do
                    if s ~= cfg.exitId and not visitB[s] then
                        visitB[s] = true
                        qB[#qB + 1] = s
                    end
                end
            end
        end
    end
    return nil
end

-- ---------------------------------------------------------------------
-- Successor classification
-- ---------------------------------------------------------------------

-- For a block ending in a conditional branch, find the "taken" successor
-- (the branch target) and the "fall" successor (the next sequential).
local function classifySuccessors(cfg, block)
    local taken, fall
    for _, s in block.successors do
        if s == cfg.exitId then continue end
        local sBlock = cfg.blocks[s]
        if not sBlock then continue end
        -- The taken successor's startPc equals the branch's target.
        -- The fall successor's startPc is the PC right after the branch.
        local lastRow = block.instructions[#block.instructions]
        local branchTarget = lastRow and OpcodeTable.jumpTarget(lastRow.insn, lastRow.pc)
        if branchTarget == sBlock.startPc then
            taken = s
        else
            fall = s
        end
    end
    return taken, fall
end

-- ---------------------------------------------------------------------
-- Statement-stream interpretation
-- ---------------------------------------------------------------------

-- Walk a block's statements (already partitioned). Strip trailing
-- branch/jump markers and report them via a returned `terminator`.
local function consumeBlockStmts(blockStmts)
    local body = {}
    local terminator = nil
    for i, stmt in blockStmts do
        if i == #blockStmts and (stmt.kind == "branch" or stmt.kind == "jump"
            or stmt.kind == "return") then
            terminator = stmt
        elseif stmt.kind == "label" then
            -- Pure marker; only emit if needed for goto fallback (handled later)
            -- For now we keep it; the emitter elides labels with no inbound goto.
            body[#body + 1] = stmt
        else
            body[#body + 1] = stmt
        end
    end
    return body, terminator
end

-- ---------------------------------------------------------------------
-- Main structuring algorithm
-- ---------------------------------------------------------------------

local function recoverProto(cfg, liftedStmts, opts)
    opts = opts or {}
    local blockStmts = partitionStmts(cfg, liftedStmts)

    -- Classify every loop up front.
    for _, loop in cfg.loops do classifyLoop(cfg, loop) end
    -- Index loops by header for fast lookup.
    local loopByHeader = {}
    for _, loop in cfg.loops do loopByHeader[loop.header] = loop end

    local stats = {
        ifCount       = 0,
        whileCount    = 0,
        repeatCount   = 0,
        forNumCount   = 0,
        forGenCount   = 0,
        gotoCount     = 0,
        breakCount    = 0,
        continueCount = 0,
        returnCount   = 0,
    }
    local gotoLabels = {}

    -- The visited set is scoped per emit-call so we don't re-emit the
    -- same block when it's reached from multiple paths inside a single
    -- structure. We also keep a global emitted set to detect when a
    -- merge target should NOT be recursed into (it'll be picked up by
    -- an outer caller).
    local emitFrom
    local emitLoop

    emitFrom = function(blockId, ctx)
        if blockId == nil or blockId == cfg.exitId then return {} end
        if ctx.stopAt and blockId == ctx.stopAt then return {} end
        if ctx.visited[blockId] then return {} end
        ctx.visited[blockId] = true

        -- If this block is a loop header AND it's not the one we're
        -- already in (handled by parent), emit as a loop and then
        -- continue with the loop's natural exit.
        local loopHere = loopByHeader[blockId]
        if loopHere and ctx.currentLoop ~= loopHere then
            local loopStmt = emitLoop(loopHere, ctx)
            local out = { loopStmt }
            -- Find the loop's natural exit: the header's non-body successor.
            local headerBlock = cfg.blocks[loopHere.header]
            local exitBlockId
            if headerBlock then
                for _, s in headerBlock.successors do
                    if s ~= cfg.exitId and not loopHere.body[s] then
                        exitBlockId = s; break
                    end
                end
            end
            -- Fall back to any block in exitSet if header successor scan failed.
            if not exitBlockId and loopHere.exitSet then
                for ex in loopHere.exitSet do
                    if ex ~= cfg.exitId then exitBlockId = ex; break end
                end
            end
            if exitBlockId then
                local cont = emitFrom(exitBlockId, ctx)
                for _, x in cont do out[#out + 1] = x end
            end
            return out
        end

        local block = cfg.blocks[blockId]
        local stmts = blockStmts[blockId] or {}
        local body, terminator = consumeBlockStmts(stmts)
        local out = body

        if not terminator then
            -- Fall through to the single successor, if any.
            local s = block and block.successors[1]
            if s and s ~= cfg.exitId then
                local cont = emitFrom(s, ctx)
                for _, x in cont do out[#out + 1] = x end
            end
            return out
        end

        if terminator.kind == "return" then
            out[#out + 1] = terminator
            stats.returnCount = stats.returnCount + 1
            return out
        end

        if terminator.kind == "jump" then
            local target = terminator.target
            local targetBlockId = target and cfg.pcToBlock and cfg.pcToBlock[target]
            -- Break / continue resolution against the current loop stack.
            for i = #ctx.loopStack, 1, -1 do
                local lp = ctx.loopStack[i]
                if targetBlockId == lp.header then
                    if i == #ctx.loopStack then
                        out[#out + 1] = IR.continueStmt(terminator.pc)
                        stats.continueCount = stats.continueCount + 1
                    else
                        gotoLabels[target] = true
                        out[#out + 1] = IR.raw(string.format("goto loc_%04X", (target - 1) * 4),
                            terminator.pc)
                        stats.gotoCount = stats.gotoCount + 1
                    end
                    return out
                elseif lp.exitSet and lp.exitSet[targetBlockId] then
                    if i == #ctx.loopStack then
                        out[#out + 1] = IR.breakStmt(terminator.pc)
                        stats.breakCount = stats.breakCount + 1
                    else
                        gotoLabels[target] = true
                        out[#out + 1] = IR.raw(string.format("goto loc_%04X", (target - 1) * 4),
                            terminator.pc)
                        stats.gotoCount = stats.gotoCount + 1
                    end
                    return out
                end
            end
            -- Plain forward jump: continue at target (linearly).
            if targetBlockId then
                local cont = emitFrom(targetBlockId, ctx)
                for _, x in cont do out[#out + 1] = x end
            else
                gotoLabels[target or 0] = true
                out[#out + 1] = IR.raw(string.format("goto loc_%04X",
                    ((target or 1) - 1) * 4), terminator.pc)
                stats.gotoCount = stats.gotoCount + 1
            end
            return out
        end

        if terminator.kind == "branch" then
            local taken, fall = classifySuccessors(cfg, block)
            local merge = findMergePoint(cfg, taken, fall)
            local takenCtx = { loopStack = ctx.loopStack, currentLoop = ctx.currentLoop,
                visited = { [blockId] = true }, stopAt = merge }
            local fallCtx  = { loopStack = ctx.loopStack, currentLoop = ctx.currentLoop,
                visited = { [blockId] = true }, stopAt = merge }
            for k in ctx.visited do takenCtx.visited[k] = true end
            for k in ctx.visited do fallCtx.visited[k]  = true end
            local takenBody = emitFrom(taken, takenCtx)
            local fallBody  = emitFrom(fall,  fallCtx)

            local thenBlock = #takenBody > 0 and IR.block(takenBody) or IR.block({})
            local elseBlock = #fallBody  > 0 and IR.block(fallBody)  or nil
            out[#out + 1] = IR.ifStmt(terminator.cond, thenBlock, elseBlock, terminator.pc)
            stats.ifCount = stats.ifCount + 1

            -- After the if/else, fall through into the merge point.
            if merge and merge ~= cfg.exitId then
                for k in takenCtx.visited do ctx.visited[k] = true end
                for k in fallCtx.visited  do ctx.visited[k] = true end
                local cont = emitFrom(merge, ctx)
                for _, x in cont do out[#out + 1] = x end
            end
            return out
        end

        return out
    end

    emitLoop = function(loop, ctx)
        local newCtx = {
            loopStack   = table.clone(ctx.loopStack),
            currentLoop = loop,
            visited     = {},
            stopAt      = nil,
        }
        table.insert(newCtx.loopStack, loop)

        if loop.kind == "fornum" or loop.kind == "forgen" then
            local function emitForBody()
                local bodyStmts = {}
                local header = cfg.blocks[loop.header]
                if header then
                    local first
                    for _, s in header.successors do
                        if loop.body[s] then first = s; break end
                    end
                    if first then
                        local res = emitFrom(first, newCtx)
                        for _, x in res do bodyStmts[#bodyStmts + 1] = x end
                    end
                end
                return IR.block(bodyStmts)
            end

            local preBlock = cfg.blocks[loop.preHeader]
            local prepRow = preBlock and preBlock.instructions[#preBlock.instructions]
            local A = prepRow and prepRow.a or 0

            if loop.kind == "fornum" then
                stats.forNumCount = stats.forNumCount + 1
                local body = emitForBody()
                table.remove(newCtx.loopStack)
                return IR.fornumStmt(
                    string.format("i_R%d", A + 3),
                    IR.unknown(string.format("R%d_start", A)),
                    IR.unknown(string.format("R%d_limit", A + 1)),
                    IR.unknown(string.format("R%d_step",  A + 2)),
                    body)
            else
                stats.forGenCount = stats.forGenCount + 1
                local body = emitForBody()
                table.remove(newCtx.loopStack)
                return IR.forgenStmt(
                    { string.format("k_R%d", A + 3), string.format("v_R%d", A + 4) },
                    { IR.unknown(string.format("R%d_iter", A)) },
                    body)
            end
        end

        if loop.kind == "while" then
            stats.whileCount = stats.whileCount + 1
            local headerBlock = cfg.blocks[loop.header]
            local headerStmts = blockStmts[loop.header] or {}
            local headerBody, headerTerm = consumeBlockStmts(headerStmts)
            local condExpr = (headerTerm and headerTerm.kind == "branch" and headerTerm.cond)
                or IR.literal(true, "boolean")
            local insideBlock
            if headerBlock then
                for _, s in headerBlock.successors do
                    if loop.body[s] then insideBlock = s; break end
                end
            end
            local bodyStmts = {}
            for _, s in headerBody do bodyStmts[#bodyStmts + 1] = s end
            if insideBlock then
                local res = emitFrom(insideBlock, newCtx)
                for _, x in res do bodyStmts[#bodyStmts + 1] = x end
            end
            table.remove(newCtx.loopStack)
            return IR.whileStmt(condExpr, IR.block(bodyStmts))
        end

        -- Repeat / generic loop: emit body in a while-true wrapper.
        stats.repeatCount = stats.repeatCount + 1
        local bodyStmts = {}
        local res = emitFrom(loop.header, newCtx)
        for _, x in res do bodyStmts[#bodyStmts + 1] = x end
        table.remove(newCtx.loopStack)
        return IR.whileStmt(IR.literal(true, "boolean"), IR.block(bodyStmts))
    end

    local rootCtx = {
        loopStack = {},
        currentLoop = nil,
        visited = {},
        stopAt  = nil,
    }
    local bodyStmts = emitFrom(cfg.entry, rootCtx)

    return {
        body       = IR.block(bodyStmts),
        gotoLabels = gotoLabels,
        stats      = stats,
    }
end

StructureRecovery.recoverProto = recoverProto

return StructureRecovery
