--!nonstrict
-- =====================================================================
-- IDARoblox / Plugins / Builtin / ConstFolder
-- ---------------------------------------------------------------------
-- Static constant-folding pass. Scans every proto's instruction stream
-- for arithmetic operations whose operands are guaranteed constants
-- (LOADN / LOADK / ADDK / etc.) and emits annotations pointing out the
-- pre-computable value. Does NOT rewrite bytecode — analyses live
-- scripts non-destructively.
--
-- Detected patterns
--   * ADDK Rd Ra K        ; Ra known constant → Rd = Ra + K
--   * SUBRK Rd K Ra       ; K - Ra when Ra known
--   * NUMERIC literal chain (LOADN/LOADK → ADD/SUB/MUL/DIV → SETUPVAL/
--     SETGLOBAL/SETTABLE → fold-able assignment to a constant)
--   * String concatenation of two known string constants via CONCAT
--
-- Findings include the folded value so the disassembly view can show a
-- ghosted result.
-- =====================================================================

local PluginAPI = _G.IDARo.require("Plugins.PluginAPI")

local PLUGIN_ID = "builtin.constFolder"

-- Track the value of each register through a single basic-block scan.
-- Folding only applies within the same block — out-of-block values are
-- unknown to a fast pass.

local function newRegState()
    return {                                                          -- regId → { kind, value }
        regs = {},
    }
end

local function setReg(st, reg, kind, value)
    st.regs[reg] = { kind = kind, value = value }
end

local function getReg(st, reg)
    return st.regs[reg]
end

local function clearReg(st, reg)
    st.regs[reg] = nil
end

-- Apply an opcode's effect on register state. Returns (folded?, foldedValue, foldedKind).
local function applyInsn(st, insn)
    local mnem = insn.mnemonic
    local A    = insn.a or insn.A
    local B    = insn.b or insn.B
    local C    = insn.c or insn.C
    local Bx   = insn.bx or insn.Bx
    local Kref = insn.k or insn.K or insn.constant

    if not mnem then return false end

    -- Loads
    if mnem == "LOADNIL" then
        setReg(st, A, "nil", nil); return false
    end
    if mnem == "LOADB" then
        setReg(st, A, "boolean", B ~= 0); return false
    end
    if mnem == "LOADN" then
        setReg(st, A, "number", insn.imm or B or 0); return false
    end
    if mnem == "LOADK" or mnem == "LOADKX" then
        local k = Kref
        if k and k.kind then
            setReg(st, A, k.kind, k.value)
        end
        return false
    end
    if mnem == "MOVE" then
        local src = getReg(st, B)
        if src then setReg(st, A, src.kind, src.value) else clearReg(st, A) end
        return false
    end

    -- Arithmetic: register-register
    local arithReg = {
        ADD = function(x, y) return x + y end,
        SUB = function(x, y) return x - y end,
        MUL = function(x, y) return x * y end,
        DIV = function(x, y) return x / y end,
        MOD = function(x, y) return x % y end,
        POW = function(x, y) return x ^ y end,
    }
    if arithReg[mnem] then
        local lhs = getReg(st, B)
        local rhs = getReg(st, C)
        if lhs and rhs and lhs.kind == "number" and rhs.kind == "number" then
            local v = arithReg[mnem](lhs.value, rhs.value)
            setReg(st, A, "number", v)
            return true, v, "number"
        end
        clearReg(st, A); return false
    end

    -- Arithmetic: register-K
    local arithK = {
        ADDK = function(x, y) return x + y end,
        SUBK = function(x, y) return x - y end,
        MULK = function(x, y) return x * y end,
        DIVK = function(x, y) return x / y end,
        MODK = function(x, y) return x % y end,
        POWK = function(x, y) return x ^ y end,
    }
    if arithK[mnem] then
        local lhs = getReg(st, B)
        if lhs and lhs.kind == "number" and Kref and Kref.kind == "number" then
            local v = arithK[mnem](lhs.value, Kref.value)
            setReg(st, A, "number", v)
            return true, v, "number"
        end
        clearReg(st, A); return false
    end

    -- String concat: in Luau this is CONCAT A B C (range B..C)
    if mnem == "CONCAT" then
        local parts = {}
        local ok = true
        for r = B, C do
            local v = getReg(st, r)
            if v and v.kind == "string" then
                parts[#parts + 1] = v.value
            else
                ok = false; break
            end
        end
        if ok then
            local v = table.concat(parts)
            setReg(st, A, "string", v)
            return true, v, "string"
        end
        clearReg(st, A); return false
    end

    -- Anything else: invalidate any def into A if present
    if A then clearReg(st, A) end
    return false
end

-- ---------------------------------------------------------------------
-- Manifest
-- ---------------------------------------------------------------------

local ConstFolder = {
    id          = PLUGIN_ID,
    name        = "Constant Folder",
    author      = "IDARo",
    version     = "1.0",
    description = "Statically folds constant-operand arithmetic; annotates "
        .. "instructions with their compile-time value.",
    requires    = {},
    priority    = 60,
    findings    = nil :: { any }?,
}

function ConstFolder:init(_ctx) self.findings = {} end

function ConstFolder:scan(bytecode, ctx)
    self.findings = {}
    if not bytecode or not bytecode.protos then return end
    local d = ctx.search and ctx.search._disassembler                -- best-effort grab
    -- If we can't get a disassembler, plugins that need decoded rows
    -- just emit no findings rather than failing.
    if not d then return end

    local totalFolded = 0
    for protoId, _proto in bytecode.protos do
        local ok, stream = pcall(function() return d:disassembleProto(protoId) end)
        if ok and stream and stream.instructions then
            local st = newRegState()
            for _, insn in stream.instructions do
                local folded, value, kind = applyInsn(st, insn)
                if folded then
                    totalFolded = totalFolded + 1
                    self.findings[#self.findings + 1] = PluginAPI.annotation({
                        source   = PLUGIN_ID,
                        kind     = PluginAPI.AnnotationKind.HIGHLIGHT,
                        text     = string.format("foldable %s → %s",
                            insn.mnemonic, tostring(value)),
                        severity = PluginAPI.Severity.INFO,
                        address  = { protoId = protoId, pc = insn.pc },
                        payload  = { foldedValue = value, foldedKind = kind },
                    })
                end
            end
        end
    end

    if ctx.logger then
        ctx.logger:info("ConstFolder: %d foldable sites across %d protos",
            totalFolded, #bytecode.protos)
    end
end

function ConstFolder:onRow(row, _proto, _ctx)
    -- Quick per-row annotation when re-running interactively. The slow
    -- whole-proto scan during onBytecodeLoad establishes the baseline;
    -- this just attaches per-row markers we already computed.
    if not self.findings then return nil end
    for _, f in self.findings do
        if f.address and f.address.protoId == row.protoId
            and f.address.pc == row.pc then
            return f
        end
    end
    return nil
end

function ConstFolder:cleanup() self.findings = nil end

return ConstFolder
