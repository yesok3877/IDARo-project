--!nonstrict
-- =====================================================================
-- IDARoblox / Analysis / DataFlowAnalyzer
-- ---------------------------------------------------------------------
-- Register-level data-flow analysis on a control-flow graph.
--
-- Pipeline:
--   1. Per-instruction def/use     — classified from the Luau opcode
--                                    semantics (see opDefUse() below).
--   2. Block-level def/use aggregate
--                                  — Use[B] is the set of registers
--                                    used **before** being defined
--                                    within B. Def[B] is every register
--                                    written by any instruction in B.
--   3. Liveness (backward DFA)     — iterate until fixed point:
--                                       LiveOut[B] = ⋃ LiveIn[succ]
--                                       LiveIn[B]  = Use[B] ∪ (LiveOut[B] − Def[B])
--                                    in reverse-postorder for fastest
--                                    convergence on most CFGs.
--   4. Per-PC live sets            — generated lazily by walking a block
--                                    backwards from LiveOut, applying
--                                    each instruction's defs/uses in
--                                    reverse.
--
-- Output (cached per proto):
--   dfa = {
--       protoId      = ...,
--       cfg          = <CFG ref>,
--       defUseByPc   = { [pc] = { defs = {reg, …}, uses = {reg, …} } },
--       defByBlock   = { [blockId] = { regSet } },
--       useByBlock   = { [blockId] = { regSet } },
--       liveIn       = { [blockId] = { regSet } },
--       liveOut      = { [blockId] = { regSet } },
--       iterations   = iterationsToConverge,
--   }
--
--   dfa:liveAtPc(pc)            — set of registers live at the *start* of `pc`
--   dfa:defsAt(pc)              — registers defined by instruction at `pc`
--   dfa:usesAt(pc)              — registers used by instruction at `pc`
--   dfa:isLiveAtPc(reg, pc)
--   dfa:registerInterval(reg)   — first/last PC where `reg` participates
-- =====================================================================

local OpcodeTable = _G.IDARo.require("Analysis.OpcodeTable")

local DataFlowAnalyzer = {}
DataFlowAnalyzer.__index = DataFlowAnalyzer

local Op = OpcodeTable.Op

-- ---------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------

function DataFlowAnalyzer.new(cfgBuilder, opts)
    if not cfgBuilder then
        error("DataFlowAnalyzer.new: cfgBuilder required", 2)
    end
    return setmetatable({
        _cfg    = cfgBuilder,
        _cache  = {},                                                -- protoId → DFA result
        _logger = opts and opts.logger,
    }, DataFlowAnalyzer)
end

function DataFlowAnalyzer:analyze(protoId: number)
    local cached = self._cache[protoId]
    if cached then return cached end
    local cfg = self._cfg:cfgForProto(protoId)
    local result = self:_compute(cfg, protoId)
    self._cache[protoId] = result
    return result
end

function DataFlowAnalyzer:invalidate(protoId: number?)
    if protoId then self._cache[protoId] = nil
    else self._cache = {} end
end

-- ---------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------

local function setUnion(a, b)
    local out = {}
    for k in a do out[k] = true end
    for k in b do out[k] = true end
    return out
end

local function setDifference(a, b)                                  -- a - b
    local out = {}
    for k in a do
        if not b[k] then out[k] = true end
    end
    return out
end

local function setEquals(a, b)
    for k in a do if not b[k] then return false end end
    for k in b do if not a[k] then return false end end
    return true
end

local function rangeSet(first: number, count: number): { [number]: boolean }
    local s = {}
    if count <= 0 then return s end
    for r = first, first + count - 1 do s[r] = true end
    return s
end

-- ---------------------------------------------------------------------
-- Per-opcode def/use computation
-- ---------------------------------------------------------------------
-- Returns two register sets: `defs` (registers WRITTEN by this insn)
-- and `uses` (registers READ before being written within the insn).
-- Callers are expected to provide the Disassembler row (which already
-- has decoded a/b/c/d/aux) to avoid re-decoding.
-- ---------------------------------------------------------------------

local function defUseFor(row): ({ [number]: boolean }, { [number]: boolean })
    local op = row.op
    local defs = {}
    local uses = {}

    -- Loads / moves / load-immediates ----------------------------------
    if op == Op.LOADNIL or op == Op.LOADB or op == Op.LOADN
        or op == Op.LOADK or op == Op.LOADKX then
        defs[row.a] = true

    elseif op == Op.MOVE then
        defs[row.a] = true
        uses[row.b] = true

    -- Globals & upvalues -----------------------------------------------
    elseif op == Op.GETGLOBAL or op == Op.GETIMPORT or op == Op.GETUPVAL then
        defs[row.a] = true

    elseif op == Op.SETGLOBAL or op == Op.SETUPVAL then
        uses[row.a] = true

    elseif op == Op.CLOSEUPVALS then
        -- Closes upvalues at and above R(A). Doesn't define/use registers
        -- in the normal sense; conservatively use R(A) to keep it alive.
        uses[row.a] = true

    -- Tables ------------------------------------------------------------
    elseif op == Op.GETTABLE then
        defs[row.a] = true; uses[row.b] = true; uses[row.c] = true
    elseif op == Op.SETTABLE then
        uses[row.a] = true; uses[row.b] = true; uses[row.c] = true
    elseif op == Op.GETTABLEKS then
        defs[row.a] = true; uses[row.b] = true
    elseif op == Op.SETTABLEKS then
        uses[row.a] = true; uses[row.b] = true
    elseif op == Op.GETTABLEN then
        defs[row.a] = true; uses[row.b] = true
    elseif op == Op.SETTABLEN then
        uses[row.a] = true; uses[row.b] = true
    elseif op == Op.NEWTABLE or op == Op.DUPTABLE then
        defs[row.a] = true
    elseif op == Op.SETLIST then
        -- A=table, B=base, C=count(+1; 0=top). Reads R(B)..R(B+C-2).
        uses[row.a] = true
        if row.c > 0 then
            for r = row.b, row.b + row.c - 2 do uses[r] = true end
        else
            -- "top" — leave underspecified; conservatively mark R(B).
            uses[row.b] = true
        end

    -- Closures ----------------------------------------------------------
    elseif op == Op.NEWCLOSURE or op == Op.DUPCLOSURE then
        defs[row.a] = true

    -- Calls & returns ---------------------------------------------------
    elseif op == Op.NAMECALL then
        -- Reads object from R(B), stores method into R(A) and object
        -- into R(A+1) for the upcoming CALL.
        defs[row.a]     = true
        defs[row.a + 1] = true
        uses[row.b]     = true

    elseif op == Op.CALL then
        local nargs = row.b
        local nret  = row.c
        uses[row.a] = true                                          -- the function itself
        if nargs > 0 then
            for r = row.a + 1, row.a + nargs - 1 do uses[r] = true end
        else
            -- "top" — covers everything above; mark R(A+1) as a hint
            uses[row.a + 1] = true
        end
        if nret > 0 then
            for r = row.a, row.a + nret - 2 do defs[r] = true end
        else
            defs[row.a] = true
        end

    elseif op == Op.RETURN then
        local count = row.b
        if count > 0 then
            for r = row.a, row.a + count - 2 do uses[r] = true end
        else
            uses[row.a] = true
        end

    -- Unconditional jumps (no register effects) ------------------------
    elseif op == Op.JUMP or op == Op.JUMPBACK or op == Op.JUMPX then
        -- nothing

    -- Conditional jumps single-reg -------------------------------------
    elseif op == Op.JUMPIF or op == Op.JUMPIFNOT then
        uses[row.a] = true

    -- Conditional jumps with AUX register (binary compares) ------------
    elseif op == Op.JUMPIFEQ or op == Op.JUMPIFLE or op == Op.JUMPIFLT
        or op == Op.JUMPIFNOTEQ or op == Op.JUMPIFNOTLE or op == Op.JUMPIFNOTLT then
        uses[row.a] = true
        uses[row.aux] = true

    -- Fast equality-to-constant jumps ----------------------------------
    elseif op == Op.JUMPXEQKNIL or op == Op.JUMPXEQKB
        or op == Op.JUMPXEQKN or op == Op.JUMPXEQKS then
        uses[row.a] = true

    -- Arithmetic & logic ------------------------------------------------
    elseif op == Op.ADD or op == Op.SUB or op == Op.MUL or op == Op.DIV
        or op == Op.MOD or op == Op.POW or op == Op.IDIV
        or op == Op.AND or op == Op.OR then
        defs[row.a] = true; uses[row.b] = true; uses[row.c] = true

    elseif op == Op.ADDK or op == Op.SUBK or op == Op.MULK or op == Op.DIVK
        or op == Op.MODK or op == Op.POWK or op == Op.IDIVK
        or op == Op.ANDK or op == Op.ORK then
        defs[row.a] = true; uses[row.b] = true

    elseif op == Op.SUBRK or op == Op.DIVRK then
        defs[row.a] = true; uses[row.c] = true

    elseif op == Op.NOT or op == Op.MINUS or op == Op.LENGTH then
        defs[row.a] = true; uses[row.b] = true

    elseif op == Op.CONCAT then
        defs[row.a] = true
        for r = row.b, row.c do uses[r] = true end

    -- For-loops --------------------------------------------------------
    elseif op == Op.FORNPREP then
        -- Initializes loop state in R(A..A+2). The state is also USED
        -- because the compiler emits the bounds into these regs.
        for r = row.a, row.a + 2 do defs[r] = true; uses[r] = true end
    elseif op == Op.FORNLOOP then
        uses[row.a] = true; uses[row.a + 1] = true; uses[row.a + 2] = true
        defs[row.a]     = true                                       -- counter advance
        defs[row.a + 3] = true                                       -- loop variable
    elseif op == Op.FORGPREP or op == Op.FORGPREP_INEXT or op == Op.FORGPREP_NEXT then
        for r = row.a, row.a + 2 do defs[r] = true; uses[r] = true end
    elseif op == Op.FORGLOOP then
        uses[row.a]     = true
        uses[row.a + 1] = true
        uses[row.a + 2] = true
        local numVars   = row.aux and bit32.band(row.aux, 0xFF) or 2
        if numVars < 1 then numVars = 1 end
        for r = row.a + 3, row.a + 2 + numVars do defs[r] = true end
        defs[row.a] = true                                          -- iter state

    -- Varargs ----------------------------------------------------------
    elseif op == Op.GETVARARGS then
        local count = row.b
        if count > 0 then
            for r = row.a, row.a + count - 2 do defs[r] = true end
        else
            defs[row.a] = true
        end
    elseif op == Op.PREPVARARGS then
        -- frame setup; no register effect at the Luau-level model

    -- Fast-call hints (the upcoming CALL handles the real def/use) -----
    elseif op == Op.FASTCALL then
        -- no register effects
    elseif op == Op.FASTCALL1 then
        uses[row.b] = true
    elseif op == Op.FASTCALL2 then
        uses[row.b] = true
        if row.aux then uses[bit32.band(row.aux, 0xFF)] = true end
    elseif op == Op.FASTCALL2K then
        uses[row.b] = true
    elseif op == Op.FASTCALL3 then
        uses[row.b] = true
        if row.aux then
            uses[bit32.band(row.aux, 0xFF)] = true
            uses[bit32.band(bit32.rshift(row.aux, 8), 0xFF)] = true
        end

    -- Captures (closure upval setup) -----------------------------------
    elseif op == Op.CAPTURE then
        -- A=captureKind, B=reg|upvalIdx. Only VAL/REF read a register.
        local kindName = OpcodeTable.CaptureName and OpcodeTable.CaptureName[row.a]
        if kindName == "VAL" or kindName == "REF" then
            uses[row.b] = true
        end

    -- Misc -------------------------------------------------------------
    elseif op == Op.COVERAGE or op == Op.NATIVECALL
        or op == Op.BREAK or op == Op.NOP then
        -- nothing

    end

    return defs, uses
end

-- ---------------------------------------------------------------------
-- Block-level def/use aggregation
-- ---------------------------------------------------------------------

local function aggregateBlock(block, defUseByPc)
    local blockDef = {}                                              -- everything defined in B
    local blockUse = {}                                              -- used BEFORE being defined in B
    for _, row in block.instructions do
        local du = defUseByPc[row.pc]
        if du then
            for r in du.uses do
                if not blockDef[r] then blockUse[r] = true end
            end
            for r in du.defs do blockDef[r] = true end
        end
    end
    return blockDef, blockUse
end

-- ---------------------------------------------------------------------
-- Backward dataflow (live-variable analysis)
-- ---------------------------------------------------------------------

local function runLiveness(cfg, defByBlock, useByBlock)
    local liveIn  = {}
    local liveOut = {}
    for blkId in cfg.blocks do
        liveIn[blkId]  = {}
        liveOut[blkId] = {}
    end

    -- Iterate in REVERSE of reverse-postorder (i.e. postorder) so
    -- successors converge first. This matches the recommended order for
    -- backward dataflow problems.
    local order = {}
    for i = #cfg.reversePostOrder, 1, -1 do
        order[#order + 1] = cfg.reversePostOrder[i]
    end

    local iter = 0
    local changed = true
    while changed do
        changed = false
        iter = iter + 1
        for _, blkId in order do
            local block = cfg.blocks[blkId]
            if block then
                -- LiveOut[B] = ⋃ LiveIn[S]
                local newOut = {}
                for _, succId in block.successors do
                    local liveSucc = liveIn[succId]
                    if liveSucc then
                        for r in liveSucc do newOut[r] = true end
                    end
                end
                -- LiveIn[B] = Use[B] ∪ (LiveOut[B] − Def[B])
                local diff = setDifference(newOut, defByBlock[blkId])
                local newIn = setUnion(useByBlock[blkId], diff)
                if not setEquals(newIn, liveIn[blkId]) then
                    liveIn[blkId] = newIn
                    changed = true
                end
                if not setEquals(newOut, liveOut[blkId]) then
                    liveOut[blkId] = newOut
                    changed = true
                end
            end
        end
        if iter > 1000 then break end                                -- safety net
    end

    return liveIn, liveOut, iter
end

-- ---------------------------------------------------------------------
-- Main compute
-- ---------------------------------------------------------------------

function DataFlowAnalyzer:_compute(cfg, protoId)
    local stream = cfg.stream

    -- 1. Per-PC def/use
    local defUseByPc = {}
    for _, row in stream.rows do
        local d, u = defUseFor(row)
        defUseByPc[row.pc] = { defs = d, uses = u }
    end

    -- 2. Block-level def / use
    local defByBlock = {}
    local useByBlock = {}
    for blkId, block in cfg.blocks do
        local bDef, bUse = aggregateBlock(block, defUseByPc)
        defByBlock[blkId] = bDef
        useByBlock[blkId] = bUse
    end

    -- 3. Live-variable analysis
    local liveIn, liveOut, iterations = runLiveness(cfg, defByBlock, useByBlock)

    -- 4. Build a register-interval table — first/last PC where a
    -- register is read or written. Cheap to compute, useful for view
    -- highlighting and for the decompiler's local-name inference.
    local intervals = {}                                             -- reg → { first, last, defs, uses }
    for pc, du in defUseByPc do
        for r in du.defs do
            local v = intervals[r]
            if not v then v = { first = pc, last = pc, defs = 0, uses = 0 }; intervals[r] = v end
            v.defs = v.defs + 1
            if pc < v.first then v.first = pc end
            if pc > v.last  then v.last  = pc end
        end
        for r in du.uses do
            local v = intervals[r]
            if not v then v = { first = pc, last = pc, defs = 0, uses = 0 }; intervals[r] = v end
            v.uses = v.uses + 1
            if pc < v.first then v.first = pc end
            if pc > v.last  then v.last  = pc end
        end
    end

    local result = {
        protoId         = protoId,
        cfg             = cfg,
        defUseByPc      = defUseByPc,
        defByBlock      = defByBlock,
        useByBlock      = useByBlock,
        liveIn          = liveIn,
        liveOut         = liveOut,
        intervals       = intervals,
        iterations      = iterations,
        _livePerPcCache = {},                                        -- pc → set
    }

    -- ---- Convenience methods on the result table ---------------------

    function result:defsAt(pc)
        local du = self.defUseByPc[pc]
        return du and du.defs or {}
    end
    function result:usesAt(pc)
        local du = self.defUseByPc[pc]
        return du and du.uses or {}
    end

    function result:liveAtPc(pc)
        local cached = self._livePerPcCache[pc]
        if cached then return cached end
        -- Find which block contains pc, then walk backwards from
        -- LiveOut[B] to pc applying each instruction's defs/uses.
        local blockId = self.cfg:blockAtPc(pc)
        if not blockId then return {} end
        local block = self.cfg.blocks[blockId.id]
        local live = {}
        for r in self.liveOut[block.id] do live[r] = true end
        -- Walk block instructions in reverse, stop AFTER processing pc.
        for i = #block.instructions, 1, -1 do
            local row = block.instructions[i]
            if row.pc < pc then break end
            local du = self.defUseByPc[row.pc]
            if du then
                for r in du.defs do live[r] = nil end
                for r in du.uses do live[r] = true end
            end
            self._livePerPcCache[row.pc] = (function()
                local snap = {}; for k in live do snap[k] = true end; return snap
            end)()
            if row.pc == pc then break end
        end
        return self._livePerPcCache[pc] or live
    end

    function result:isLiveAtPc(reg, pc)
        local s = self:liveAtPc(pc)
        return s[reg] == true
    end

    function result:registerInterval(reg)
        return self.intervals[reg]
    end

    return result
end

-- ---------------------------------------------------------------------
-- Manifest
-- ---------------------------------------------------------------------

function DataFlowAnalyzer.manifest()
    return {
        id           = "Analysis.DataFlowAnalyzer",
        dependencies = { "Analysis.CFGBuilder" },
        weight       = 0.4,
        serviceName  = "DataFlowAnalyzer",
        stages = {
            { id = "register", weight = 1.0, fn = function(ctx)
                ctx:report(1, "DataFlowAnalyzer ready")
            end },
        },
    }
end

return DataFlowAnalyzer
