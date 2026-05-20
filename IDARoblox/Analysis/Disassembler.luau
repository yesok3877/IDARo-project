--!nonstrict
-- =====================================================================
-- IDARoblox / Analysis / Disassembler
-- ---------------------------------------------------------------------
-- Turns a parsed proto's instruction stream into an IDA-style listing:
-- per-instruction Row records with formatted operand text, resolved
-- comments (K values, import chains, jump labels, source lines), and
-- structured References for the XRef engine + CFG builder.
--
-- Each opcode has a dedicated formatter that:
--   1. Decodes operands per its `fmt` (ABC/AD/E) honoring AUX
--   2. Resolves K-table refs through the proto's constants
--   3. Resolves IMPORT chains via OpcodeTable.resolveImportChain
--   4. Computes branch targets, registers them with the label allocator
--   5. Builds a structured References list
--
-- Two-pass design:
--   Pass 1 — `_scanLabels()`: walk every branch/jump/loop instruction,
--            collect target PCs, assign labels (`loc_{addr_hex}`).
--   Pass 2 — `_buildRows()`: walk every instruction, run its formatter,
--            attach the label if this PC is a target.
--
-- Caching: one InstructionStream per proto. Re-disassembly is a hash
-- lookup. Disassembling all protos eagerly is fine for moderately-sized
-- scripts (the parser already walked them); for huge scripts the
-- caller can disassemble lazily on view.
--
-- Output rendering:
--   stream:formatAll()                  → multi-line text of the proto
--   stream:formatRange(fromPc, toPc)    → slice
--   disasm:formatLine(row)              → one row's text
--
-- The text format mirrors IDA Pro:
--     loc_0010:
--     0x0010   GETIMPORT    R0, K(2)            ; import game.Players  (line 12)
-- =====================================================================

local OpcodeTable = _G.IDARo.require("Analysis.OpcodeTable")

local Disassembler = {}
Disassembler.__index = Disassembler

local Op   = OpcodeTable.Op
local Meta = OpcodeTable.Meta
local band, rshift, lshift = bit32.band, bit32.rshift, bit32.lshift

-- ---------------------------------------------------------------------
-- Layout constants
-- ---------------------------------------------------------------------

local ADDR_WIDTH      = 8                                            -- "0xXXXX  " etc
local MNEMONIC_WIDTH  = 14
local OPERAND_WIDTH   = 36
local INDENT          = "  "

-- ---------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------

function Disassembler.new(parsedBytecode, opts)
    if not parsedBytecode or not parsedBytecode.protos then
        error("Disassembler.new: requires a parsed bytecode result", 2)
    end
    opts = opts or {}
    local self = setmetatable({
        _bc            = parsedBytecode,
        _streams       = {},                                        -- protoId → Stream
        _showLineInfo  = opts.showLineInfo ~= false,
        _showRawWords  = opts.showRawWords == true,
        _useDebugNames = opts.useDebugNames == true,
        _logger        = opts.logger,
    }, Disassembler)
    return self
end

function Disassembler:bytecode() return self._bc end

-- ---------------------------------------------------------------------
-- Helpers exposed on the instance
-- ---------------------------------------------------------------------

local function addrOf(pc: number): number return (pc - 1) * 4 end
local function fmtAddr(addr: number): string return string.format("0x%04X", addr) end
local function fmtLabel(targetPc: number): string return string.format("loc_%04X", addrOf(targetPc)) end

local function escString(s: string): string
    if s == nil then return "<nil>" end
    if type(s) ~= "string" then return tostring(s) end
    -- Truncate very long strings
    if #s > 48 then s = s:sub(1, 45) .. "..." end
    local b = {}
    for i = 1, #s do
        local c = string.byte(s, i)
        if c == 0x22 then b[i] = "\\\""
        elseif c == 0x5C then b[i] = "\\\\"
        elseif c == 0x0A then b[i] = "\\n"
        elseif c == 0x0D then b[i] = "\\r"
        elseif c == 0x09 then b[i] = "\\t"
        elseif c < 0x20 or c == 0x7F then b[i] = string.format("\\x%02X", c)
        else b[i] = string.char(c) end
    end
    return "\"" .. table.concat(b) .. "\""
end

local function fmtKConstant(constant): string
    if constant == nil then return "<bad K>" end
    if constant.tag == "NIL" then return "nil"
    elseif constant.tag == "BOOLEAN" then return tostring(constant.value)
    elseif constant.tag == "NUMBER" then
        local v = constant.value
        if v ~= v then return "nan"
        elseif v == math.huge then return "inf"
        elseif v == -math.huge then return "-inf"
        elseif v == math.floor(v) and math.abs(v) < 1e15 then
            return string.format("%d", v)
        end
        return string.format("%.14g", v)
    elseif constant.tag == "STRING" then return escString(constant.value)
    elseif constant.tag == "IMPORT" then
        if constant.chain then return "import " .. table.concat(constant.chain, ".") end
        return string.format("import #0x%08X", constant.encodedId or 0)
    elseif constant.tag == "TABLE" then
        if constant.keys and #constant.keys > 0 then
            return "{" .. table.concat(constant.keys, ", ") .. "}"
        end
        return "{}"
    elseif constant.tag == "CLOSURE" then
        return string.format("proto[%d]", constant.protoId)
    elseif constant.tag == "VECTOR" then
        local v = constant.value
        return string.format("vec(%g, %g, %g, %g)", v.x, v.y, v.z, v.w or 0)
    end
    return "<unknown K>"
end

-- ---------------------------------------------------------------------
-- Register name resolution
-- ---------------------------------------------------------------------

local function regAt(proto, reg: number, pc: number, useDebug: boolean): string
    if not useDebug or not proto.debug or not proto.debug.locals then
        return "R" .. reg
    end
    -- Pick the innermost local that owns this register at this PC.
    -- Luau's local startpc/endpc are inclusive of startpc, exclusive of endpc.
    local best = nil
    local bestRange = math.huge
    for _, loc in proto.debug.locals do
        if loc.reg == reg and pc >= loc.startpc and pc < loc.endpc then
            local range = loc.endpc - loc.startpc
            if range < bestRange then best = loc; bestRange = range end
        end
    end
    if best then return string.format("R%d{%s}", reg, best.name) end
    return "R" .. reg
end

local function upvalName(proto, idx: number): string?
    if not proto.debug or not proto.debug.upvalues then return nil end
    local u = proto.debug.upvalues[idx + 1]                          -- 0-based → 1-based
    return u and u.name
end

-- ---------------------------------------------------------------------
-- Reference builders
-- ---------------------------------------------------------------------

local function pushRef(row, ref)
    if not row.references then row.references = {} end
    row.references[#row.references + 1] = ref
end

local function pushComment(row, c)
    if c == nil or c == "" then return end
    if not row.comments then row.comments = {} end
    row.comments[#row.comments + 1] = c
end

-- ---------------------------------------------------------------------
-- Branch helpers
-- ---------------------------------------------------------------------

local function branchTarget(row, fmt: string, hasAux: boolean, insn, pc): number?
    -- Use OpcodeTable.jumpTarget for AUX-aware target calculation.
    return OpcodeTable.jumpTarget(insn, pc)
end

-- ---------------------------------------------------------------------
-- Decoders for special AUX layouts
-- ---------------------------------------------------------------------

-- JUMPXEQK*: bit 31 of AUX is the "not" flag; lower bits hold either a
-- K index (KN/KS) or a boolean value (KB) or nothing (KNIL).
local function decodeJumpXEqKAux(aux: number)
    local notFlag = band(rshift(aux, 31), 1) == 1
    local payload = band(aux, 0x7FFFFFFF)
    return notFlag, payload
end

-- FASTCALL3: AUX holds two extra register indices. Per Luau VM:
--   bits  0..7   → arg2 register
--   bits  8..15  → arg3 register
local function decodeFastcall3Aux(aux: number)
    return band(aux, 0xFF), band(rshift(aux, 8), 0xFF)
end

-- FORGLOOP: AUX is a packed descriptor.
--   bits 0..7   → number of iterator variables (typically 2 or 3)
--   bit  31     → fast-path flag (ipairs-style)
-- Higher bits may carry compiler hints in newer versions; we surface
-- the raw value for forward-compat.
local function decodeForgloopAux(aux: number)
    return {
        numVars   = band(aux, 0xFF),
        ipairs    = band(rshift(aux, 31), 1) == 1,
        raw       = aux,
    }
end

-- ---------------------------------------------------------------------
-- Per-opcode formatters
-- ---------------------------------------------------------------------
-- Each formatter receives:
--   row     — the row being built; mutate in place
--   ctx     — { proto, stream, disasm, useDebugNames, labels }
-- It MUST set row.operandText and MAY append comments + references.
-- ---------------------------------------------------------------------

local F = {}                                                         -- formatter table keyed by opcode id

local function reg(ctx, r, pc) return regAt(ctx.proto, r, pc, ctx.useDebugNames) end

-- ----------- Loads & moves -----------

F[Op.NOP] = function(row, ctx)
    row.operandText = ""
end

F[Op.BREAK] = function(row, ctx)
    row.operandText = ""
    pushComment(row, "debugger break")
end

F[Op.LOADNIL] = function(row, ctx)
    row.operandText = reg(ctx, row.a, row.pc)
end

F[Op.LOADB] = function(row, ctx)
    local parts = { reg(ctx, row.a, row.pc), tostring(row.b ~= 0) }
    if row.c ~= 0 then
        parts[#parts + 1] = string.format("+%d", row.c)
        pushComment(row, string.format("skip to %s", fmtLabel(row.pc + 1 + row.c)))
        pushRef(row, { kind = "branch", target = row.pc + 1 + row.c, conditional = false, reason = "loadb-skip" })
    end
    row.operandText = table.concat(parts, ", ")
end

F[Op.LOADN] = function(row, ctx)
    row.operandText = string.format("%s, %d", reg(ctx, row.a, row.pc), row.d)
end

F[Op.LOADK] = function(row, ctx)
    local k = ctx.proto.constants[row.d + 1]
    row.operandText = string.format("%s, K(%d)", reg(ctx, row.a, row.pc), row.d)
    pushComment(row, fmtKConstant(k))
    pushRef(row, { kind = "k", kidx = row.d, tag = k and k.tag })
end

F[Op.LOADKX] = function(row, ctx)
    local kidx = row.aux                                            -- AUX is the extended K index
    local k = ctx.proto.constants[kidx + 1]
    row.operandText = string.format("%s, K(%d)", reg(ctx, row.a, row.pc), kidx)
    pushComment(row, fmtKConstant(k) .. " (ext)")
    pushRef(row, { kind = "k", kidx = kidx, tag = k and k.tag, extended = true })
end

F[Op.MOVE] = function(row, ctx)
    row.operandText = string.format("%s, %s",
        reg(ctx, row.a, row.pc), reg(ctx, row.b, row.pc))
end

-- ----------- Globals & upvalues -----------

F[Op.GETGLOBAL] = function(row, ctx)
    local k = ctx.proto.constants[row.aux + 1]
    row.operandText = string.format("%s, K(%d)", reg(ctx, row.a, row.pc), row.aux)
    if k and k.tag == "STRING" then
        pushComment(row, "_G." .. k.value)
        pushRef(row, { kind = "global", name = k.value, mode = "read" })
    end
end

F[Op.SETGLOBAL] = function(row, ctx)
    local k = ctx.proto.constants[row.aux + 1]
    row.operandText = string.format("%s, K(%d)", reg(ctx, row.a, row.pc), row.aux)
    if k and k.tag == "STRING" then
        pushComment(row, "_G." .. k.value)
        pushRef(row, { kind = "global", name = k.value, mode = "write" })
    end
end

F[Op.GETUPVAL] = function(row, ctx)
    local rA = reg(ctx, row.a, row.pc)
    local name = upvalName(ctx.proto, row.b)
    if name then
        row.operandText = string.format("%s, U(%d){%s}", rA, row.b, name)
    else
        row.operandText = string.format("%s, U(%d)", rA, row.b)
    end
    pushRef(row, { kind = "upval", index = row.b, name = name, mode = "read" })
end

F[Op.SETUPVAL] = function(row, ctx)
    local rA = reg(ctx, row.a, row.pc)
    local name = upvalName(ctx.proto, row.b)
    if name then
        row.operandText = string.format("%s, U(%d){%s}", rA, row.b, name)
    else
        row.operandText = string.format("%s, U(%d)", rA, row.b)
    end
    pushRef(row, { kind = "upval", index = row.b, name = name, mode = "write" })
end

F[Op.CLOSEUPVALS] = function(row, ctx)
    row.operandText = reg(ctx, row.a, row.pc)
    pushComment(row, "close upvals at and above")
end

-- ----------- Imports -----------

F[Op.GETIMPORT] = function(row, ctx)
    -- Format: A=reg, D=K idx (IMPORT constant), AUX=encoded id (redundant)
    local k = ctx.proto.constants[row.d + 1]
    row.operandText = string.format("%s, K(%d)", reg(ctx, row.a, row.pc), row.d)
    if k and k.tag == "IMPORT" then
        local chain = k.chain or OpcodeTable.resolveImportChain(
            k.encodedId, ctx.proto.constants, ctx.bc.stringTable)
        pushComment(row, "import " .. table.concat(chain or {}, "."))
        pushRef(row, { kind = "import", chain = chain, encodedId = k.encodedId, kidx = row.d })
    elseif k then
        pushComment(row, "non-IMPORT k! tag=" .. tostring(k.tag))
    end
end

-- ----------- Tables -----------

F[Op.GETTABLE] = function(row, ctx)
    row.operandText = string.format("%s, %s, %s",
        reg(ctx, row.a, row.pc), reg(ctx, row.b, row.pc), reg(ctx, row.c, row.pc))
end

F[Op.SETTABLE] = function(row, ctx)
    row.operandText = string.format("%s, %s, %s",
        reg(ctx, row.a, row.pc), reg(ctx, row.b, row.pc), reg(ctx, row.c, row.pc))
end

F[Op.GETTABLEKS] = function(row, ctx)
    local k = ctx.proto.constants[row.aux + 1]
    row.operandText = string.format("%s, %s, K(%d)",
        reg(ctx, row.a, row.pc), reg(ctx, row.b, row.pc), row.aux)
    if k and k.tag == "STRING" then
        pushComment(row, "." .. k.value)
        pushRef(row, { kind = "field", name = k.value, mode = "read", kidx = row.aux })
    end
end

F[Op.SETTABLEKS] = function(row, ctx)
    local k = ctx.proto.constants[row.aux + 1]
    row.operandText = string.format("%s, %s, K(%d)",
        reg(ctx, row.a, row.pc), reg(ctx, row.b, row.pc), row.aux)
    if k and k.tag == "STRING" then
        pushComment(row, "." .. k.value)
        pushRef(row, { kind = "field", name = k.value, mode = "write", kidx = row.aux })
    end
end

F[Op.GETTABLEN] = function(row, ctx)
    row.operandText = string.format("%s, %s, %d",
        reg(ctx, row.a, row.pc), reg(ctx, row.b, row.pc), row.c + 1)
end

F[Op.SETTABLEN] = function(row, ctx)
    row.operandText = string.format("%s, %s, %d",
        reg(ctx, row.a, row.pc), reg(ctx, row.b, row.pc), row.c + 1)
end

F[Op.NEWTABLE] = function(row, ctx)
    -- B encodes log2(hash size); 0 means no hash. AUX is array size hint.
    local hashHint = if row.b == 0 then 0 else bit32.lshift(1, row.b - 1)
    local arrayHint = row.aux or 0
    row.operandText = string.format("%s, hash=%d, arr=%d",
        reg(ctx, row.a, row.pc), hashHint, arrayHint)
end

F[Op.DUPTABLE] = function(row, ctx)
    local k = ctx.proto.constants[row.d + 1]
    row.operandText = string.format("%s, K(%d)", reg(ctx, row.a, row.pc), row.d)
    if k and k.tag == "TABLE" then
        pushComment(row, "shape: " .. fmtKConstant(k))
        pushRef(row, { kind = "k", kidx = row.d, tag = "TABLE" })
    end
end

F[Op.SETLIST] = function(row, ctx)
    local count = row.c                                              -- count+1 packed; C=0 means top
    local start = row.aux or 1
    if count == 0 then
        row.operandText = string.format("%s, %s, top, start=%d",
            reg(ctx, row.a, row.pc), reg(ctx, row.b, row.pc), start)
    else
        row.operandText = string.format("%s, %s, %d, start=%d",
            reg(ctx, row.a, row.pc), reg(ctx, row.b, row.pc), count - 1, start)
        pushComment(row, string.format("[%d..%d]", start, start + count - 2))
    end
end

-- ----------- Closures -----------

F[Op.NEWCLOSURE] = function(row, ctx)
    local childArr = ctx.proto.childProtoIds
    local childId = childArr and childArr[row.d + 1]                -- D is index into proto.p
    row.operandText = string.format("%s, p[%d]", reg(ctx, row.a, row.pc), row.d)
    if childId ~= nil then
        pushComment(row, string.format("→ proto[%d]", childId))
        pushRef(row, { kind = "closure", protoId = childId, via = "p" })
    end
end

F[Op.DUPCLOSURE] = function(row, ctx)
    local k = ctx.proto.constants[row.d + 1]
    row.operandText = string.format("%s, K(%d)", reg(ctx, row.a, row.pc), row.d)
    if k and k.tag == "CLOSURE" then
        pushComment(row, string.format("→ proto[%d]", k.protoId))
        pushRef(row, { kind = "closure", protoId = k.protoId, via = "k" })
    end
end

-- ----------- Calls / returns -----------

F[Op.NAMECALL] = function(row, ctx)
    local k = ctx.proto.constants[row.aux + 1]
    row.operandText = string.format("%s, %s, K(%d)",
        reg(ctx, row.a, row.pc), reg(ctx, row.b, row.pc), row.aux)
    if k and k.tag == "STRING" then
        pushComment(row, ":" .. k.value)
        pushRef(row, { kind = "namecall", method = k.value, objectReg = row.b, kidx = row.aux })
    end
end

F[Op.CALL] = function(row, ctx)
    local nargs = if row.b == 0 then "top" else tostring(row.b - 1)
    local nret  = if row.c == 0 then "top" else tostring(row.c - 1)
    row.operandText = string.format("%s, %s args, %s rets",
        reg(ctx, row.a, row.pc), nargs, nret)
    pushRef(row, {
        kind         = "call",
        targetReg    = row.a,
        argCount     = if row.b == 0 then -1 else row.b - 1,
        returnCount  = if row.c == 0 then -1 else row.c - 1,
    })
end

F[Op.RETURN] = function(row, ctx)
    local count = if row.b == 0 then "top" else tostring(row.b - 1)
    row.operandText = string.format("%s, %s vals", reg(ctx, row.a, row.pc), count)
    pushRef(row, {
        kind        = "return",
        firstReg    = row.a,
        valueCount  = if row.b == 0 then -1 else row.b - 1,
    })
end

-- ----------- Unconditional jumps -----------

local function fmtJump(row, ctx, conditional, reason)
    local target = OpcodeTable.jumpTarget(row.insn, row.pc)
    if target then
        local lbl = ctx.labels[target] or fmtLabel(target)
        row.operandText = string.format("%s%+d", lbl, row.d or 0)
        pushComment(row, string.format("→ %s", lbl))
        pushRef(row, { kind = "branch", target = target, conditional = conditional, reason = reason })
    else
        row.operandText = tostring(row.d or 0)
    end
end

F[Op.JUMP] = function(row, ctx) fmtJump(row, ctx, false, "jump") end
F[Op.JUMPBACK] = function(row, ctx) fmtJump(row, ctx, false, "back") end
F[Op.JUMPX]    = function(row, ctx)
    local target = OpcodeTable.jumpTarget(row.insn, row.pc)
    if target then
        local lbl = ctx.labels[target] or fmtLabel(target)
        row.operandText = string.format("%s%+d", lbl, row.e or 0)
        pushComment(row, "→ " .. lbl)
        pushRef(row, { kind = "branch", target = target, conditional = false, reason = "jumpx" })
    else
        row.operandText = tostring(row.e or 0)
    end
end

-- ----------- Conditional jumps without AUX -----------

local function fmtJumpRA(row, ctx, reason)
    local target = OpcodeTable.jumpTarget(row.insn, row.pc)
    local rA = reg(ctx, row.a, row.pc)
    if target then
        local lbl = ctx.labels[target] or fmtLabel(target)
        row.operandText = string.format("%s, %s", rA, lbl)
        pushComment(row, "→ " .. lbl)
        pushRef(row, { kind = "branch", target = target, conditional = true, reason = reason })
    else
        row.operandText = string.format("%s, %+d", rA, row.d or 0)
    end
end

F[Op.JUMPIF]    = function(row, ctx) fmtJumpRA(row, ctx, "truthy") end
F[Op.JUMPIFNOT] = function(row, ctx) fmtJumpRA(row, ctx, "falsy") end

-- ----------- Conditional jumps with AUX (binary comparisons) -----------

local function fmtJumpRARB(row, ctx, opSym, reason)
    local target = OpcodeTable.jumpTarget(row.insn, row.pc)
    local rA = reg(ctx, row.a, row.pc)
    local rAux = reg(ctx, row.aux, row.pc)
    if target then
        local lbl = ctx.labels[target] or fmtLabel(target)
        row.operandText = string.format("%s %s %s, %s", rA, opSym, rAux, lbl)
        pushComment(row, "→ " .. lbl)
        pushRef(row, { kind = "branch", target = target, conditional = true, reason = reason, lhsReg = row.a, rhsReg = row.aux })
    else
        row.operandText = string.format("%s %s %s, %+d", rA, opSym, rAux, row.d or 0)
    end
end

F[Op.JUMPIFEQ]    = function(row, ctx) fmtJumpRARB(row, ctx, "==",  "eq") end
F[Op.JUMPIFLE]    = function(row, ctx) fmtJumpRARB(row, ctx, "<=",  "le") end
F[Op.JUMPIFLT]    = function(row, ctx) fmtJumpRARB(row, ctx, "<",   "lt") end
F[Op.JUMPIFNOTEQ] = function(row, ctx) fmtJumpRARB(row, ctx, "~=",  "ne") end
F[Op.JUMPIFNOTLE] = function(row, ctx) fmtJumpRARB(row, ctx, "!<=", "nle") end
F[Op.JUMPIFNOTLT] = function(row, ctx) fmtJumpRARB(row, ctx, "!<",  "nlt") end

-- ----------- JUMPXEQK* (fast equality-to-constant) -----------

local function fmtJumpXEqK(row, ctx, kindHint, valueRenderer)
    local target = OpcodeTable.jumpTarget(row.insn, row.pc)
    local notFlag, payload = decodeJumpXEqKAux(row.aux)
    local rA = reg(ctx, row.a, row.pc)
    local valueText = valueRenderer(payload, ctx)
    local cmp = if notFlag then "~=" else "=="
    local lbl = if target then (ctx.labels[target] or fmtLabel(target)) else tostring(row.d or 0)
    row.operandText = string.format("%s %s %s, %s", rA, cmp, valueText, lbl)
    if target then
        pushComment(row, "→ " .. lbl)
        pushRef(row, {
            kind         = "branch",
            target       = target,
            conditional  = true,
            reason       = "fast-eq",
            compareKind  = kindHint,
            inverted     = notFlag,
        })
    end
end

F[Op.JUMPXEQKNIL] = function(row, ctx)
    fmtJumpXEqK(row, ctx, "nil", function(_) return "nil" end)
end
F[Op.JUMPXEQKB] = function(row, ctx)
    fmtJumpXEqK(row, ctx, "bool", function(p)
        return tostring(band(p, 1) ~= 0)
    end)
end
F[Op.JUMPXEQKN] = function(row, ctx)
    fmtJumpXEqK(row, ctx, "number", function(kidx)
        local k = ctx.proto.constants[kidx + 1]
        return fmtKConstant(k)
    end)
end
F[Op.JUMPXEQKS] = function(row, ctx)
    fmtJumpXEqK(row, ctx, "string", function(kidx)
        local k = ctx.proto.constants[kidx + 1]
        return fmtKConstant(k)
    end)
end

-- ----------- Arithmetic / logic (binary, register-register) -----------

local function fmtBinRR(row, ctx, opSym)
    row.operandText = string.format("%s, %s %s %s",
        reg(ctx, row.a, row.pc),
        reg(ctx, row.b, row.pc), opSym, reg(ctx, row.c, row.pc))
end

F[Op.ADD]  = function(row, ctx) fmtBinRR(row, ctx, "+") end
F[Op.SUB]  = function(row, ctx) fmtBinRR(row, ctx, "-") end
F[Op.MUL]  = function(row, ctx) fmtBinRR(row, ctx, "*") end
F[Op.DIV]  = function(row, ctx) fmtBinRR(row, ctx, "/") end
F[Op.MOD]  = function(row, ctx) fmtBinRR(row, ctx, "%") end
F[Op.POW]  = function(row, ctx) fmtBinRR(row, ctx, "^") end
F[Op.IDIV] = function(row, ctx) fmtBinRR(row, ctx, "//") end
F[Op.AND]  = function(row, ctx) fmtBinRR(row, ctx, "and") end
F[Op.OR]   = function(row, ctx) fmtBinRR(row, ctx, "or") end

-- ----------- Arithmetic with K (R op K) -----------

local function fmtBinRK(row, ctx, opSym)
    local k = ctx.proto.constants[row.c + 1]
    row.operandText = string.format("%s, %s %s K(%d)",
        reg(ctx, row.a, row.pc), reg(ctx, row.b, row.pc), opSym, row.c)
    pushComment(row, fmtKConstant(k))
    pushRef(row, { kind = "k", kidx = row.c, tag = k and k.tag })
end

F[Op.ADDK]  = function(row, ctx) fmtBinRK(row, ctx, "+") end
F[Op.SUBK]  = function(row, ctx) fmtBinRK(row, ctx, "-") end
F[Op.MULK]  = function(row, ctx) fmtBinRK(row, ctx, "*") end
F[Op.DIVK]  = function(row, ctx) fmtBinRK(row, ctx, "/") end
F[Op.MODK]  = function(row, ctx) fmtBinRK(row, ctx, "%") end
F[Op.POWK]  = function(row, ctx) fmtBinRK(row, ctx, "^") end
F[Op.IDIVK] = function(row, ctx) fmtBinRK(row, ctx, "//") end
F[Op.ANDK]  = function(row, ctx) fmtBinRK(row, ctx, "and") end
F[Op.ORK]   = function(row, ctx) fmtBinRK(row, ctx, "or") end

-- ----------- Reversed K op R (SUBRK / DIVRK) -----------

local function fmtBinKR(row, ctx, opSym)
    -- A=dst, B=K idx, C=src reg
    local k = ctx.proto.constants[row.b + 1]
    row.operandText = string.format("%s, K(%d) %s %s",
        reg(ctx, row.a, row.pc), row.b, opSym, reg(ctx, row.c, row.pc))
    pushComment(row, fmtKConstant(k))
    pushRef(row, { kind = "k", kidx = row.b, tag = k and k.tag })
end

F[Op.SUBRK] = function(row, ctx) fmtBinKR(row, ctx, "-") end
F[Op.DIVRK] = function(row, ctx) fmtBinKR(row, ctx, "/") end

-- ----------- Unary ops -----------

local function fmtUnary(row, ctx, opSym)
    row.operandText = string.format("%s, %s %s",
        reg(ctx, row.a, row.pc), opSym, reg(ctx, row.b, row.pc))
end

F[Op.NOT]    = function(row, ctx) fmtUnary(row, ctx, "not") end
F[Op.MINUS]  = function(row, ctx) fmtUnary(row, ctx, "-") end
F[Op.LENGTH] = function(row, ctx) fmtUnary(row, ctx, "#") end

F[Op.CONCAT] = function(row, ctx)
    -- A=dst, B=base, C=end (concat R(B)..R(C))
    row.operandText = string.format("%s, %s..%s",
        reg(ctx, row.a, row.pc),
        reg(ctx, row.b, row.pc),
        reg(ctx, row.c, row.pc))
end

-- ----------- Numeric / generic for -----------

local function fmtForPrep(row, ctx, kind)
    local target = OpcodeTable.jumpTarget(row.insn, row.pc)
    local rA = reg(ctx, row.a, row.pc)
    if target then
        local lbl = ctx.labels[target] or fmtLabel(target)
        row.operandText = string.format("%s, %s", rA, lbl)
        pushComment(row, kind .. " exit → " .. lbl)
        pushRef(row, { kind = "branch", target = target, conditional = true, reason = kind .. "-prep" })
    else
        row.operandText = string.format("%s, %+d", rA, row.d or 0)
    end
end

F[Op.FORNPREP]       = function(row, ctx) fmtForPrep(row, ctx, "fornumeric") end
F[Op.FORGPREP]       = function(row, ctx) fmtForPrep(row, ctx, "forgeneric") end
F[Op.FORGPREP_INEXT] = function(row, ctx) fmtForPrep(row, ctx, "forgen-ipairs") end
F[Op.FORGPREP_NEXT]  = function(row, ctx) fmtForPrep(row, ctx, "forgen-next") end

F[Op.FORNLOOP] = function(row, ctx)
    local target = OpcodeTable.jumpTarget(row.insn, row.pc)
    local rA = reg(ctx, row.a, row.pc)
    if target then
        local lbl = ctx.labels[target] or fmtLabel(target)
        row.operandText = string.format("%s, %s", rA, lbl)
        pushComment(row, "fornumeric back → " .. lbl)
        pushRef(row, { kind = "branch", target = target, conditional = true, reason = "fornumeric-step" })
    else
        row.operandText = string.format("%s, %+d", rA, row.d or 0)
    end
end

F[Op.FORGLOOP] = function(row, ctx)
    local target = OpcodeTable.jumpTarget(row.insn, row.pc)
    local rA = reg(ctx, row.a, row.pc)
    local meta = decodeForgloopAux(row.aux or 0)
    local lbl = if target then (ctx.labels[target] or fmtLabel(target)) else tostring(row.d or 0)
    row.operandText = string.format("%s, %s, vars=%d%s",
        rA, lbl, meta.numVars, if meta.ipairs then ", ipairs" else "")
    if target then
        pushComment(row, "forgeneric back → " .. lbl)
        pushRef(row, { kind = "branch", target = target, conditional = true, reason = "forgeneric-step" })
    end
end

-- ----------- Varargs -----------

F[Op.GETVARARGS] = function(row, ctx)
    local count = if row.b == 0 then "top" else tostring(row.b - 1)
    row.operandText = string.format("%s, %s vals", reg(ctx, row.a, row.pc), count)
end

F[Op.PREPVARARGS] = function(row, ctx)
    row.operandText = string.format("numparams=%d", row.a)
end

-- ----------- Fast calls -----------

local function fmtFastcallHeader(row, ctx, argDescriptor)
    local builtinId = row.a
    local builtinName = OpcodeTable.Builtin[builtinId] or string.format("builtin#%d", builtinId)
    local skip = row.c
    row.operandText = string.format("%s(%s), skip=%d", builtinName, argDescriptor, skip)
    pushComment(row, "fast path: " .. builtinName)
    pushRef(row, { kind = "fastcall_builtin", id = builtinId, name = builtinName, skip = skip })
end

F[Op.FASTCALL] = function(row, ctx)
    fmtFastcallHeader(row, ctx, "…")
end

F[Op.FASTCALL1] = function(row, ctx)
    fmtFastcallHeader(row, ctx, reg(ctx, row.b, row.pc))
end

F[Op.FASTCALL2] = function(row, ctx)
    fmtFastcallHeader(row, ctx, string.format("%s, %s",
        reg(ctx, row.b, row.pc),
        reg(ctx, band(row.aux or 0, 0xFF), row.pc)))
end

F[Op.FASTCALL2K] = function(row, ctx)
    local kidx = row.aux or 0
    local k = ctx.proto.constants[kidx + 1]
    fmtFastcallHeader(row, ctx, string.format("%s, K(%d)",
        reg(ctx, row.b, row.pc), kidx))
    pushComment(row, fmtKConstant(k))
    pushRef(row, { kind = "k", kidx = kidx, tag = k and k.tag })
end

F[Op.FASTCALL3] = function(row, ctx)
    local r2, r3 = decodeFastcall3Aux(row.aux or 0)
    fmtFastcallHeader(row, ctx, string.format("%s, %s, %s",
        reg(ctx, row.b, row.pc),
        reg(ctx, r2, row.pc),
        reg(ctx, r3, row.pc)))
end

-- ----------- Capture (closure upval setup) -----------

F[Op.CAPTURE] = function(row, ctx)
    local typeName = OpcodeTable.CaptureName[row.a] or string.format("?%d", row.a)
    if row.a == OpcodeTable.Capture.UPVAL then
        local name = upvalName(ctx.proto, row.b)
        if name then
            row.operandText = string.format("%s, U(%d){%s}", typeName, row.b, name)
        else
            row.operandText = string.format("%s, U(%d)", typeName, row.b)
        end
        pushRef(row, { kind = "capture", kindCapture = "UPVAL", index = row.b, name = name })
    else
        row.operandText = string.format("%s, R%d", typeName, row.b)
        pushRef(row, { kind = "capture", kindCapture = typeName, reg = row.b })
    end
end

-- ----------- Coverage / native call -----------

F[Op.COVERAGE] = function(row, ctx)
    row.operandText = string.format("count=%d", row.e or 0)
    pushComment(row, "coverage instrumentation")
end

F[Op.NATIVECALL] = function(row, ctx)
    row.operandText = ""
    pushComment(row, "native code call hint")
end

-- ---------------------------------------------------------------------
-- Generic fallback for any opcode without a dedicated formatter
-- ---------------------------------------------------------------------

local function genericFormat(row, ctx)
    local m = Meta[row.op]
    if not m then
        row.operandText = string.format("0x%08X", row.insn)
        pushComment(row, "(unknown opcode)")
        return
    end
    if m.fmt == "ABC" then
        row.operandText = string.format("R%d, R%d, R%d", row.a, row.b, row.c)
    elseif m.fmt == "AD" then
        row.operandText = string.format("R%d, %d", row.a, row.d)
    elseif m.fmt == "E" then
        row.operandText = tostring(row.e)
    end
    if row.aux ~= nil then pushComment(row, string.format("aux=0x%08X", row.aux)) end
end

-- ---------------------------------------------------------------------
-- Build pipeline
-- ---------------------------------------------------------------------

function Disassembler:disassembleProto(protoId: number)
    if self._streams[protoId] then return self._streams[protoId] end
    local proto = self._bc.protos[protoId]
    if not proto then
        error(string.format("Disassembler: no proto with id %d", protoId), 2)
    end

    local stream = {
        protoId   = protoId,
        proto     = proto,
        rows      = {},
        rowByPc   = {},
        labels    = {},                                              -- pc → "loc_XXXX"
        branches  = {},
        calls     = {},
        returns   = {},
    }

    -- Pass 1: find every branch/jump/loop and register labels.
    self:_scanLabels(proto, stream)

    -- Pass 2: build rows.
    self:_buildRows(proto, stream)

    self._streams[protoId] = stream
    return stream
end

function Disassembler:disassembleAll(progressCb)
    local count = #self._bc.protos + 1
    local i = 0
    for id, _ in self._bc.protos do
        self:disassembleProto(id)
        i = i + 1
        if progressCb then pcall(progressCb, i, count) end
    end
    return self._streams
end

-- ---------------------------------------------------------------------
-- Pass 1 — label scan
-- ---------------------------------------------------------------------

function Disassembler:_scanLabels(proto, stream)
    for pc, insn, _aux, m in OpcodeTable.iterate(proto.instructions) do
        if m and (m.flow == "jump" or m.flow == "back" or m.flow == "branch" or m.flow == "loop") then
            local target = OpcodeTable.jumpTarget(insn, pc)
            if target and target >= 1 and target <= proto.sizecode then
                if not stream.labels[target] then
                    stream.labels[target] = fmtLabel(target)
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------
-- Pass 2 — row construction
-- ---------------------------------------------------------------------

function Disassembler:_buildRows(proto, stream)
    local ctx = {
        proto         = proto,
        stream        = stream,
        disasm        = self,
        bc            = self._bc,
        useDebugNames = self._useDebugNames,
        labels        = stream.labels,
    }

    local lineLookup = proto.lineInfo and proto.lineInfo.lookup or nil

    for pc, insn, aux, m in OpcodeTable.iterate(proto.instructions) do
        local row = {
            pc       = pc,
            address  = addrOf(pc),
            insn     = insn,
            op       = (m and m.id) or band(insn, 0xFF),
            mnemonic = (m and m.name) or string.format("OP_%d", band(insn, 0xFF)),
            fmt      = (m and m.fmt) or "ABC",
            hasAux   = aux ~= nil,
            auxWord  = aux,
        }
        if m then
            if m.fmt == "ABC" then
                local _, a, b, c = OpcodeTable.decodeABC(insn)
                row.a, row.b, row.c = a, b, c
                row.aux = aux
            elseif m.fmt == "AD" then
                local _, a, d = OpcodeTable.decodeAD(insn)
                row.a, row.d = a, d
                row.aux = aux
            elseif m.fmt == "E" then
                local _, e = OpcodeTable.decodeE(insn)
                row.e = e
                row.aux = aux
            end
            row.isTerminator = m.flow == "return" or m.flow == "jump"
                or m.flow == "back" or m.flow == "branch"
                or m.flow == "loop"
        end
        if stream.labels[pc] then
            row.label = stream.labels[pc]
        end
        if lineLookup then
            row.line = lineLookup(pc)
        end

        -- Run the per-opcode formatter (or fallback).
        local fn = F[row.op] or genericFormat
        local ok, err = pcall(fn, row, ctx)
        if not ok then
            row.operandText = string.format("<formatter error: %s>", tostring(err))
        end

        stream.rows[#stream.rows + 1] = row
        stream.rowByPc[pc] = row
        if m then
            if m.flow == "call" then stream.calls[#stream.calls + 1] = row
            elseif m.flow == "return" then stream.returns[#stream.returns + 1] = row
            elseif m.flow == "jump" or m.flow == "back" or m.flow == "branch" or m.flow == "loop" then
                stream.branches[#stream.branches + 1] = row
            end
        end
    end
end

-- ---------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------

local function pad(s: string, w: number): string
    if #s >= w then return s end
    return s .. string.rep(" ", w - #s)
end

function Disassembler:formatLine(row)
    local parts = {}
    local addr = fmtAddr(row.address)
    local mnem = pad(row.mnemonic, MNEMONIC_WIDTH)
    local ops  = pad(row.operandText or "", OPERAND_WIDTH)
    parts[#parts + 1] = addr
    parts[#parts + 1] = " "
    parts[#parts + 1] = mnem
    parts[#parts + 1] = " "
    parts[#parts + 1] = ops
    -- Trim trailing space if there's no comment
    local commentText = nil
    if row.comments and #row.comments > 0 then
        commentText = "; " .. table.concat(row.comments, " · ")
    end
    if self._showLineInfo and row.line and row.line > 0 then
        commentText = (commentText or "; ") .. string.format("  (line %d)", row.line)
    end
    if commentText then
        parts[#parts + 1] = commentText
    end
    if self._showRawWords then
        local raw = string.format("    [%08X", row.insn)
        if row.hasAux then raw = raw .. string.format(" %08X", row.auxWord) end
        parts[#parts + 1] = raw .. "]"
    end
    return table.concat(parts)
end

function Disassembler:formatProto(protoId: number, opts)
    opts = opts or {}
    local stream = self:disassembleProto(protoId)
    local proto = stream.proto
    local out = {}

    -- Header
    out[#out + 1] = string.format("; ===== proto[%d] %s =====",
        protoId, proto.debugName or "<anonymous>")
    out[#out + 1] = string.format(";   numparams=%d  nups=%d  maxstacksize=%d  isvararg=%s  flags=0x%02X",
        proto.numparams, proto.nups, proto.maxstacksize,
        tostring(proto.isvararg), proto.flags or 0)
    out[#out + 1] = string.format(";   lineDefined=%d  sizecode=%d  sizek=%d  sizep=%d",
        proto.lineDefined, proto.sizecode, #proto.constants, #proto.childProtoIds)

    -- Debug info (upvalues + locals) — useful for reading the disasm
    if proto.debug and proto.debug.upvalues and #proto.debug.upvalues > 0 then
        out[#out + 1] = "; upvalues:"
        for i, u in proto.debug.upvalues do
            out[#out + 1] = string.format(";   U(%d) = %s", i - 1, u.name)
        end
    end

    out[#out + 1] = ""

    -- Rows
    for _, row in stream.rows do
        if row.label then out[#out + 1] = row.label .. ":" end
        out[#out + 1] = INDENT .. self:formatLine(row)
    end
    return table.concat(out, "\n")
end

function Disassembler:formatAll(progressCb)
    local out = {}
    local total = #self._bc.protos + 1
    local i = 0
    for id, _ in self._bc.protos do
        out[#out + 1] = self:formatProto(id)
        out[#out + 1] = ""
        i = i + 1
        if progressCb then pcall(progressCb, i, total) end
    end
    return table.concat(out, "\n")
end

-- ---------------------------------------------------------------------
-- Stream rendering helpers (called via stream:formatAll() syntax)
-- ---------------------------------------------------------------------

function Disassembler:installStreamHelpers(stream)
    local disasm = self
    function stream:formatAll() return disasm:formatProto(self.protoId) end
    function stream:formatLine(row) return disasm:formatLine(row) end
    function stream:formatRange(fromPc, toPc)
        local out = {}
        for _, row in self.rows do
            if row.pc >= fromPc and row.pc <= toPc then
                if row.label then out[#out + 1] = row.label .. ":" end
                out[#out + 1] = INDENT .. disasm:formatLine(row)
            end
        end
        return table.concat(out, "\n")
    end
    return stream
end

-- Wrap disassembleProto so streams get the helpers attached on first creation
local _disassembleProto = Disassembler.disassembleProto
function Disassembler:disassembleProto(protoId: number)
    local s = _disassembleProto(self, protoId)
    if not s.formatAll then self:installStreamHelpers(s) end
    return s
end

-- ---------------------------------------------------------------------
-- Module manifest for the LoadingManager
-- ---------------------------------------------------------------------

function Disassembler.manifest()
    return {
        id           = "Analysis.Disassembler",
        dependencies = { "Analysis.BytecodeParser" },
        weight       = 0.6,
        serviceName  = "Disassembler",
        stages = {
            { id = "sanity", weight = 0.5, fn = function(ctx)
                -- Verify every opcode either has a formatter or will fall
                -- back to the generic one. This catches OpcodeTable
                -- regressions where an opcode is added without a handler.
                local missing = {}
                for id, m in OpcodeTable.Meta do
                    if not F[id] then missing[#missing + 1] = m.name end
                end
                if #missing > 0 then
                    ctx:report(1, string.format(
                        "%d opcodes use generic formatter (acceptable): %s",
                        #missing, table.concat(missing, ",", 1, math.min(5, #missing))))
                else
                    ctx:report(1, "every opcode has a dedicated formatter")
                end
            end },
            { id = "register", weight = 0.5, fn = function(ctx)
                ctx:report(1, "Disassembler ready")
            end },
        },
    }
end

return Disassembler
