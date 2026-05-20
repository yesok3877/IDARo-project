--!nonstrict
-- =====================================================================
-- IDARoblox / Analysis / ConstantPropagation
-- ---------------------------------------------------------------------
-- SSA-flavoured constant propagation over the basic-block CFG. For each
-- proto, walks blocks in reverse-postorder, tracks the constant value
-- of every register at every PC, and joins block-entry states at merge
-- points using the meet operator:
--
--     Top  ∩ X     = X
--     Cv   ∩ Cv    = Cv
--     Cv   ∩ Cw    = Bottom   (v ≠ w)
--     Bottom ∩ X   = Bottom
--
-- The pass iterates to a fixed point — joining never *increases* a
-- register's information so monotone convergence is guaranteed.
--
-- Output structure (per proto)
--   result.byProto[pid] = {
--       atPc[pc]      = { regId → { kind, value, source = "loadk"|"propagated"|... } }
--       blockExits[blockId] = { regId → cell }     -- per-block exit state
--       stats         = { knownDefs, foldedReads, blocksVisited, iterations }
--   }
--
-- This information is consumed by:
--   * ExpressionFolder        — fuses const-loaded registers into folded ops
--   * Decompiler.NameResolver — picks intelligent constant-derived names
--   * Plugins/ConstFolder     — reports foldable sites in the UI
-- =====================================================================

local ConstantPropagation = {}
ConstantPropagation.__index = ConstantPropagation

-- Lattice value sentinels
local TOP    = { _lattice = "top" }                                  -- unanalysed / no def yet
local BOTTOM = { _lattice = "bottom" }                               -- unknown / merge-conflict

ConstantPropagation.TOP    = TOP
ConstantPropagation.BOTTOM = BOTTOM

local function isConst(v) return v ~= nil and v ~= TOP and v ~= BOTTOM end

-- Meet of two cells
local function meet(a, b)
    if a == TOP then return b end
    if b == TOP then return a end
    if a == BOTTOM or b == BOTTOM then return BOTTOM end
    -- Both are concrete cells {kind, value}
    if a.kind == b.kind then
        if a.kind == "number" then
            -- Handle NaN: NaN ≠ NaN by IEEE, so we use a special compare
            if a.value ~= a.value and b.value ~= b.value then return a end
            if a.value == b.value then return a end
        elseif a.value == b.value then
            return a
        end
    end
    return BOTTOM
end

-- Shallow-copy a register-state table (regs are typically sparse, so
-- copying a few keys is cheap)
local function copyState(s)
    local out = {}
    for k, v in s do out[k] = v end
    return out
end

local function statesEqual(a, b)
    if a == nil and b == nil then return true end
    if a == nil or b == nil then return false end
    local seenKeys = {}
    for k, va in a do
        seenKeys[k] = true
        local vb = b[k]
        if va ~= vb then
            if va == TOP or va == BOTTOM or vb == TOP or vb == BOTTOM then
                return false
            end
            if type(va) ~= "table" or type(vb) ~= "table" then return false end
            if va.kind ~= vb.kind or va.value ~= vb.value then return false end
        end
    end
    for k in b do
        if not seenKeys[k] then return false end
    end
    return true
end

-- ---------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------

function ConstantPropagation.new(opts)
    opts = opts or {}
    return setmetatable({
        _disassembler = opts.disassembler,
        _cfgBuilder   = opts.cfgBuilder,
        _bytecode     = opts.bytecode,
        _logger       = opts.logger,
        _cache        = {},                                          -- protoId → result
        _stats = {
            protosAnalyzed = 0,
            totalIterations = 0,
            totalKnownDefs  = 0,
        },
    }, ConstantPropagation)
end

-- ---------------------------------------------------------------------
-- Per-instruction transfer function
-- ---------------------------------------------------------------------

-- Updates state in-place to reflect the effect of `insn` on registers.
-- Returns `true` if any register write happened (informational).
local function transfer(state, insn)
    local mnem = insn.mnemonic
    local A    = insn.a or insn.A
    local B    = insn.b or insn.B
    local C    = insn.c or insn.C
    local Kref = insn.k or insn.K or insn.constant

    if not mnem then return false end

    if mnem == "LOADNIL" then
        state[A] = { kind = "nil", value = nil, source = "loadnil" }; return true
    end
    if mnem == "LOADB" then
        state[A] = { kind = "boolean", value = B ~= 0, source = "loadb" }; return true
    end
    if mnem == "LOADN" then
        state[A] = { kind = "number", value = insn.imm or B or 0, source = "loadn" }; return true
    end
    if mnem == "LOADK" or mnem == "LOADKX" then
        if Kref and Kref.kind and Kref.value ~= nil then
            state[A] = { kind = Kref.kind, value = Kref.value, source = "loadk" }
            return true
        end
        state[A] = BOTTOM; return true
    end
    if mnem == "MOVE" then
        local src = state[B]
        if src and src ~= TOP and src ~= BOTTOM then
            state[A] = { kind = src.kind, value = src.value, source = "move" }
        else
            state[A] = BOTTOM
        end
        return true
    end

    -- Binary ops over registers
    local rrOps = {
        ADD = function(x, y) return x + y end,
        SUB = function(x, y) return x - y end,
        MUL = function(x, y) return x * y end,
        DIV = function(x, y) return x / y end,
        MOD = function(x, y) return x % y end,
        POW = function(x, y) return x ^ y end,
        IDIV = function(x, y) return math.floor(x / y) end,
    }
    if rrOps[mnem] then
        local lhs, rhs = state[B], state[C]
        if lhs and rhs and lhs.kind == "number" and rhs.kind == "number"
            and lhs.value ~= nil and rhs.value ~= nil then
            local v = rrOps[mnem](lhs.value, rhs.value)
            state[A] = { kind = "number", value = v, source = "fold-" .. mnem }
            return true
        end
        state[A] = BOTTOM; return true
    end

    -- Binary ops over register + K
    local rkOps = {
        ADDK = function(x, y) return x + y end,
        SUBK = function(x, y) return x - y end,
        MULK = function(x, y) return x * y end,
        DIVK = function(x, y) return x / y end,
        MODK = function(x, y) return x % y end,
        POWK = function(x, y) return x ^ y end,
        IDIVK = function(x, y) return math.floor(x / y) end,
    }
    if rkOps[mnem] then
        local lhs = state[B]
        if lhs and lhs.kind == "number" and lhs.value ~= nil
            and Kref and Kref.kind == "number" and Kref.value ~= nil then
            local v = rkOps[mnem](lhs.value, Kref.value)
            state[A] = { kind = "number", value = v, source = "foldK-" .. mnem }
            return true
        end
        state[A] = BOTTOM; return true
    end

    -- SUBRK / DIVRK: K op Register
    if mnem == "SUBRK" or mnem == "DIVRK" then
        local rhs = state[C]
        if Kref and Kref.kind == "number" and Kref.value ~= nil
            and rhs and rhs.kind == "number" and rhs.value ~= nil then
            local v
            if mnem == "SUBRK" then v = Kref.value - rhs.value
            else                    v = Kref.value / rhs.value end
            state[A] = { kind = "number", value = v, source = "fold-" .. mnem }
            return true
        end
        state[A] = BOTTOM; return true
    end

    -- Unary
    if mnem == "MINUS" then
        local r = state[B]
        if r and r.kind == "number" and r.value ~= nil then
            state[A] = { kind = "number", value = -r.value, source = "fold-MINUS" }
        else state[A] = BOTTOM end
        return true
    end
    if mnem == "NOT" then
        local r = state[B]
        if r == nil or r == TOP or r == BOTTOM then state[A] = BOTTOM
        else
            local truthy = r.kind ~= "nil" and not (r.kind == "boolean" and r.value == false)
            state[A] = { kind = "boolean", value = not truthy, source = "fold-NOT" }
        end
        return true
    end
    if mnem == "LENGTH" then
        local r = state[B]
        if r and r.kind == "string" and type(r.value) == "string" then
            state[A] = { kind = "number", value = #r.value, source = "fold-LENGTH" }
        else state[A] = BOTTOM end
        return true
    end

    if mnem == "CONCAT" then
        local parts = {}
        local ok = true
        for r = B, C do
            local v = state[r]
            if v and v.kind == "string" and v.value ~= nil then
                parts[#parts + 1] = v.value
            else ok = false; break end
        end
        if ok then
            state[A] = { kind = "string", value = table.concat(parts),
                source = "fold-CONCAT" }
        else
            state[A] = BOTTOM
        end
        return true
    end

    -- For unknown/side-effect ops, invalidate A if known to write.
    -- We're conservative: any other op that has an A and isn't read-only
    -- kills the known value at A.
    if A and (mnem == "CALL" or mnem == "NAMECALL" or mnem == "GETIMPORT"
        or mnem == "GETGLOBAL" or mnem == "GETUPVAL" or mnem == "GETTABLE"
        or mnem == "GETTABLEKS" or mnem == "GETTABLEN"
        or mnem == "NEWTABLE" or mnem == "DUPTABLE"
        or mnem == "NEWCLOSURE" or mnem == "DUPCLOSURE"
        or mnem == "FASTCALL" or mnem == "FASTCALL1" or mnem == "FASTCALL2"
        or mnem == "FASTCALL2K") then
        state[A] = BOTTOM
        return true
    end
    return false
end

-- ---------------------------------------------------------------------
-- Block-level join
-- ---------------------------------------------------------------------

local function joinStates(states)
    if #states == 0 then return {} end
    if #states == 1 then return copyState(states[1]) end
    local out = copyState(states[1])
    for i = 2, #states do
        local s = states[i]
        local seen = {}
        for reg, cell in s do
            seen[reg] = true
            out[reg] = meet(out[reg], cell)
        end
        for reg in out do
            if not seen[reg] then
                out[reg] = meet(out[reg], TOP)                       -- = unchanged
            end
        end
    end
    return out
end

-- ---------------------------------------------------------------------
-- Analyse a single proto
-- ---------------------------------------------------------------------

function ConstantPropagation:_analyseProto(protoId)
    if self._cache[protoId] then return self._cache[protoId] end

    local stream = self._disassembler and self._disassembler:disassembleProto(protoId)
    if not stream or not stream.instructions then
        local empty = {
            atPc = {}, blockExits = {},
            stats = { knownDefs = 0, foldedReads = 0, blocksVisited = 0, iterations = 0 },
        }
        self._cache[protoId] = empty
        return empty
    end
    local cfg = self._cfgBuilder and self._cfgBuilder:cfgForProto(protoId)

    -- Per-PC atPc[pc] = { reg → cell } and per-block exit states.
    local atPc       = {}
    local blockEntry = {}
    local blockExit  = {}
    local iterations = 0
    local maxIter    = 20

    -- If no CFG, fall back to a linear single pass through the proto.
    if not cfg or not cfg.blocks or #cfg.blocks == 0 then
        local state = {}
        for _, insn in stream.instructions do
            local atPcSnap = {}
            for k, v in state do atPcSnap[k] = v end
            atPc[insn.pc or 0] = atPcSnap
            transfer(state, insn)
        end
        local result = {
            atPc = atPc,
            blockExits = {},
            stats = { knownDefs = self:_countKnown(atPc), foldedReads = 0,
                      blocksVisited = 1, iterations = 1 },
        }
        self._cache[protoId] = result
        return result
    end

    -- Fixed-point iteration over the CFG. RPO order to converge fast.
    local order = cfg.rpo or cfg.blockOrder
    if not order then
        order = {}
        for bid in cfg.blocks do order[#order + 1] = bid end
    end

    local blocksVisited = 0
    repeat
        iterations = iterations + 1
        local changed = false
        for _, bid in order do
            local blk = cfg.blocks[bid]
            -- Build entry state from joined predecessor exits.
            local incoming = {}
            if blk.preds then
                for _, pid in blk.preds do
                    if blockExit[pid] then
                        incoming[#incoming + 1] = blockExit[pid]
                    end
                end
            end
            local entry = joinStates(incoming)
            blockEntry[bid] = entry

            local state = copyState(entry)
            local pcStart = blk.start or blk.startPc or 1
            local pcEnd   = blk.finish or blk.endPc or pcStart
            for pc = pcStart, pcEnd do
                local insn = stream.instructions[pc]
                if insn then
                    local snap = {}
                    for k, v in state do snap[k] = v end
                    atPc[insn.pc or pc] = snap
                    transfer(state, insn)
                end
            end

            if not statesEqual(state, blockExit[bid]) then
                blockExit[bid] = state
                changed = true
            end
            blocksVisited = blocksVisited + 1
        end
        if not changed then break end
    until iterations >= maxIter

    local result = {
        atPc       = atPc,
        blockEntry = blockEntry,
        blockExits = blockExit,
        stats = {
            knownDefs    = self:_countKnown(atPc),
            foldedReads  = 0,
            blocksVisited = blocksVisited,
            iterations   = iterations,
        },
    }
    self._cache[protoId] = result
    self._stats.protosAnalyzed = self._stats.protosAnalyzed + 1
    self._stats.totalIterations = self._stats.totalIterations + iterations
    self._stats.totalKnownDefs  = self._stats.totalKnownDefs + result.stats.knownDefs
    return result
end

function ConstantPropagation:_countKnown(atPc)
    local n = 0
    for _, regs in atPc do
        for _, cell in regs do
            if isConst(cell) and cell ~= TOP and cell ~= BOTTOM then
                n = n + 1
            end
        end
    end
    return n
end

-- ---------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------

function ConstantPropagation:analyse(protoId)
    return self:_analyseProto(protoId)
end

function ConstantPropagation:analyseAll()
    if not self._bytecode or not self._bytecode.protos then return end
    for protoId in self._bytecode.protos do
        self:_analyseProto(protoId)
    end
end

function ConstantPropagation:getCell(protoId, pc, reg)
    local p = self._cache[protoId]
    if not p then return nil end
    local regs = p.atPc[pc]
    if not regs then return nil end
    local cell = regs[reg]
    if not cell or cell == TOP or cell == BOTTOM then return nil end
    return cell
end

function ConstantPropagation:invalidate(protoId)
    if protoId then self._cache[protoId] = nil
    else self._cache = {} end
end

function ConstantPropagation:setBytecode(bc)     self._bytecode = bc; self:invalidate() end
function ConstantPropagation:setDisassembler(d)  self._disassembler = d; self:invalidate() end
function ConstantPropagation:setCFGBuilder(c)    self._cfgBuilder = c; self:invalidate() end

function ConstantPropagation:stats()
    return {
        protosAnalyzed  = self._stats.protosAnalyzed,
        totalIterations = self._stats.totalIterations,
        totalKnownDefs  = self._stats.totalKnownDefs,
        cacheSize       = (function()
            local n = 0
            for _ in self._cache do n = n + 1 end
            return n
        end)(),
    }
end

return ConstantPropagation
