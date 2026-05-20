--!nonstrict
-- =====================================================================
-- IDARoblox / Analysis / Decompiler / Lifter
-- ---------------------------------------------------------------------
-- Translate a single proto's instructions into a linear IR statement
-- list. Branches/jumps stay as `branch` / `jump` / `label` markers; the
-- StructureRecovery pass folds them into structured `if` / `while` /
-- `for` constructs later.
--
-- Pipeline:
--   1. Initialize register name table from debug info (or default to
--      "var_N" generators).
--   2. Walk the instruction stream PC-by-PC.
--   3. For each row, look ahead for NAMECALL+CALL fusion (the only
--      multi-instruction idiom we handle in the lifter; the others —
--      table-constructor coalescing, GETIMPORT+GETTABLEKS chains —
--      stay in disassembly form and the Emitter prints them as the
--      flat sequence).
--   4. Dispatch to the opcode's lifter via F[op]; generic fallback
--      emits an IR.raw with the disassembly text.
--
-- Public API:
--   Lifter.liftProto(stream, parsedBytecode, opts) → {
--     stmts      = { stmt, … },           -- statement order = PC order
--     paramNames = { "arg1", "arg2", … },
--     upvalNames = { "upv0", "upv1", … },
--     regNames   = { [reg] = name },      -- written-to register names
--     hasVararg  = bool,
--     debugName  = string?,
--   }
--
-- opts.childIRs = { [protoId] = liftedResult } — supplied by the orchestrator
-- when decompiling bottom-up so that NEWCLOSURE/DUPCLOSURE can reference
-- the actual lifted body of the child proto.
-- =====================================================================

local OpcodeTable = _G.IDARo.require("Analysis.OpcodeTable")
local IR          = _G.IDARo.require("Analysis.Decompiler.IR")

local Lifter = {}

local Op = OpcodeTable.Op

-- ---------------------------------------------------------------------
-- Local helpers
-- ---------------------------------------------------------------------

local function literalFromK(k)
    if not k then return IR.unknown("missing-K") end
    if k.tag == "STRING"  then return IR.literal(k.value, "string")
    elseif k.tag == "NUMBER" then return IR.literal(k.value, "number")
    elseif k.tag == "BOOLEAN" then return IR.literal(k.value, "boolean")
    elseif k.tag == "NIL" then return IR.literal(nil, "nil")
    elseif k.tag == "VECTOR" then
        return IR.unknown(string.format("vector(%g,%g,%g,%g)",
            k.value.x, k.value.y, k.value.z, k.value.w or 0))
    elseif k.tag == "IMPORT" then return IR.importRef(k.chain)
    elseif k.tag == "TABLE" then return IR.unknown(string.format("k-table(%d keys)", #(k.keys or {})))
    elseif k.tag == "CLOSURE" then return IR.unknown(string.format("k-closure[%d]", k.protoId))
    end
    return IR.unknown("k-tag=" .. tostring(k.tag))
end

local function regName(state, r, pc)
    if state.regNames[r] then return state.regNames[r] end
    if state.proto.debug and state.proto.debug.locals then
        for _, loc in state.proto.debug.locals do
            if loc.reg == r and pc >= loc.startpc and pc < loc.endpc then
                state.regNames[r] = loc.name
                return loc.name
            end
        end
    end
    return nil                                                       -- caller falls back to "R%d"
end

local function regRef(state, r, pc)
    local name = regName(state, r, pc)
    if name then return IR.localRef(name, r) end
    return IR.reg(r)
end

local function upvalNameOf(state, idx)
    if state.proto.debug and state.proto.debug.upvalues then
        local u = state.proto.debug.upvalues[idx + 1]
        if u and u.name then return u.name end
    end
    return state.upvalNames[idx + 1] or string.format("upv%d", idx)
end

local function decodeJumpXEqKAux(aux)
    local notFlag = bit32.band(bit32.rshift(aux or 0, 31), 1) == 1
    local payload = bit32.band(aux or 0, 0x7FFFFFFF)
    return notFlag, payload
end

local function branchTargetPc(row)
    return OpcodeTable.jumpTarget(row.insn, row.pc)
end

local function pushStmt(state, stmt)
    state.stmts[#state.stmts + 1] = stmt
end

-- ---------------------------------------------------------------------
-- Per-opcode lifters (F[op] = function(state, row, pc) -> consumed)
-- where `consumed` is the number of instructions ingested
-- (default: row's natural width = 1 or 2).
-- ---------------------------------------------------------------------

local F = {}

-- Loads / moves -------------------------------------------------------

F[Op.NOP] = function(_, row) end
F[Op.BREAK] = function(state, row)
    pushStmt(state, IR.raw("debugger break", row.pc))
end

F[Op.LOADNIL] = function(state, row)
    pushStmt(state, IR.assign(regRef(state, row.a, row.pc), IR.literal(nil, "nil"), row.pc))
end

F[Op.LOADB] = function(state, row)
    pushStmt(state, IR.assign(
        regRef(state, row.a, row.pc),
        IR.literal(row.b ~= 0, "boolean"),
        row.pc))
    if row.c ~= 0 then
        -- The "+C" skip behaviour becomes a jump after the assign.
        pushStmt(state, IR.jumpStmt(row.pc + 1 + row.c, row.pc))
    end
end

F[Op.LOADN] = function(state, row)
    pushStmt(state, IR.assign(
        regRef(state, row.a, row.pc),
        IR.literal(row.d, "number"),
        row.pc))
end

F[Op.LOADK] = function(state, row)
    local k = state.proto.constants[row.d + 1]
    pushStmt(state, IR.assign(
        regRef(state, row.a, row.pc),
        literalFromK(k),
        row.pc))
end

F[Op.LOADKX] = function(state, row)
    local k = state.proto.constants[(row.aux or 0) + 1]
    pushStmt(state, IR.assign(
        regRef(state, row.a, row.pc),
        literalFromK(k),
        row.pc))
end

F[Op.MOVE] = function(state, row)
    pushStmt(state, IR.assign(
        regRef(state, row.a, row.pc),
        regRef(state, row.b, row.pc),
        row.pc))
end

-- Globals / upvalues --------------------------------------------------

F[Op.GETGLOBAL] = function(state, row)
    local k = state.proto.constants[(row.aux or 0) + 1]
    local name = k and k.tag == "STRING" and k.value or "?"
    pushStmt(state, IR.assign(
        regRef(state, row.a, row.pc),
        IR.globalRef(name),
        row.pc))
end

F[Op.SETGLOBAL] = function(state, row)
    local k = state.proto.constants[(row.aux or 0) + 1]
    local name = k and k.tag == "STRING" and k.value or "?"
    pushStmt(state, IR.assign(
        IR.globalRef(name),
        regRef(state, row.a, row.pc),
        row.pc))
end

F[Op.GETUPVAL] = function(state, row)
    pushStmt(state, IR.assign(
        regRef(state, row.a, row.pc),
        IR.upvalRef(row.b, upvalNameOf(state, row.b)),
        row.pc))
end

F[Op.SETUPVAL] = function(state, row)
    pushStmt(state, IR.assign(
        IR.upvalRef(row.b, upvalNameOf(state, row.b)),
        regRef(state, row.a, row.pc),
        row.pc))
end

F[Op.CLOSEUPVALS] = function(state, row)
    pushStmt(state, IR.raw(string.format("-- close upvals >= R%d", row.a), row.pc))
end

-- Imports -------------------------------------------------------------

F[Op.GETIMPORT] = function(state, row)
    local k = state.proto.constants[row.d + 1]
    local imp = k and k.tag == "IMPORT" and IR.importRef(k.chain)
        or IR.unknown("missing-import")
    pushStmt(state, IR.assign(regRef(state, row.a, row.pc), imp, row.pc))
end

-- Tables --------------------------------------------------------------

F[Op.GETTABLE] = function(state, row)
    pushStmt(state, IR.assign(
        regRef(state, row.a, row.pc),
        IR.index(regRef(state, row.b, row.pc), regRef(state, row.c, row.pc)),
        row.pc))
end

F[Op.SETTABLE] = function(state, row)
    pushStmt(state, IR.assign(
        IR.index(regRef(state, row.b, row.pc), regRef(state, row.c, row.pc)),
        regRef(state, row.a, row.pc),
        row.pc))
end

F[Op.GETTABLEKS] = function(state, row)
    local k = state.proto.constants[(row.aux or 0) + 1]
    local key = k and k.tag == "STRING" and k.value or "?"
    pushStmt(state, IR.assign(
        regRef(state, row.a, row.pc),
        IR.field(regRef(state, row.b, row.pc), key),
        row.pc))
end

F[Op.SETTABLEKS] = function(state, row)
    local k = state.proto.constants[(row.aux or 0) + 1]
    local key = k and k.tag == "STRING" and k.value or "?"
    pushStmt(state, IR.assign(
        IR.field(regRef(state, row.b, row.pc), key),
        regRef(state, row.a, row.pc),
        row.pc))
end

F[Op.GETTABLEN] = function(state, row)
    pushStmt(state, IR.assign(
        regRef(state, row.a, row.pc),
        IR.index(regRef(state, row.b, row.pc), IR.literal(row.c + 1, "number")),
        row.pc))
end

F[Op.SETTABLEN] = function(state, row)
    pushStmt(state, IR.assign(
        IR.index(regRef(state, row.b, row.pc), IR.literal(row.c + 1, "number")),
        regRef(state, row.a, row.pc),
        row.pc))
end

F[Op.NEWTABLE] = function(state, row)
    pushStmt(state, IR.assign(
        regRef(state, row.a, row.pc),
        IR.tableExpr({}, {}),
        row.pc))
end

F[Op.DUPTABLE] = function(state, row)
    -- Shape only — values get filled in by following SETTABLEKS/N instructions.
    local k = state.proto.constants[row.d + 1]
    local hash = {}
    if k and k.tag == "TABLE" and k.keys then
        for _, keyName in k.keys do
            hash[#hash + 1] = { key = IR.literal(keyName, "string"), value = IR.literal(nil, "nil") }
        end
    end
    pushStmt(state, IR.assign(
        regRef(state, row.a, row.pc),
        IR.tableExpr({}, hash),
        row.pc))
end

F[Op.SETLIST] = function(state, row)
    -- A=table, B=base, C=count (+1; 0=top), AUX=start index in table.
    local start = row.aux or 1
    if row.c > 0 then
        for i = 0, row.c - 2 do
            pushStmt(state, IR.assign(
                IR.index(regRef(state, row.a, row.pc), IR.literal(start + i, "number")),
                regRef(state, row.b + i, row.pc),
                row.pc))
        end
    else
        pushStmt(state, IR.raw(string.format(
            "-- SETLIST R%d top-of-stack from R%d, start=%d", row.a, row.b, start), row.pc))
    end
end

-- Closures ------------------------------------------------------------

local function liftClosure(state, row, childId)
    local childIR = state.childIRs and state.childIRs[childId]
    local childProto = state.bc.protos[childId]
    if childIR and childProto then
        pushStmt(state, IR.assign(
            regRef(state, row.a, row.pc),
            IR.funcExpr(
                childIR.paramNames,
                childIR.body or IR.block({}),
                childIR.hasVararg,
                childProto.debugName),
            row.pc))
    else
        pushStmt(state, IR.assign(
            regRef(state, row.a, row.pc),
            IR.unknown(string.format("function-proto[%d]", childId or -1)),
            row.pc))
    end
end

F[Op.NEWCLOSURE] = function(state, row)
    local children = state.proto.childProtoIds
    local childId = children and children[row.d + 1]
    liftClosure(state, row, childId)
end

F[Op.DUPCLOSURE] = function(state, row)
    local k = state.proto.constants[row.d + 1]
    local childId = k and k.tag == "CLOSURE" and k.protoId or nil
    liftClosure(state, row, childId)
end

-- CAPTURE annotates the closure being built — we emit a `-- capture` raw
-- comment as a hint; the orchestrator's child proto carries enough info
-- to reconstruct upvalue bindings via its own debug info.
F[Op.CAPTURE] = function(state, row)
    local typeName = OpcodeTable.CaptureName and OpcodeTable.CaptureName[row.a] or "?"
    pushStmt(state, IR.raw(string.format("-- capture %s %d", typeName, row.b), row.pc))
end

-- Calls / returns -----------------------------------------------------

F[Op.CALL] = function(state, row)
    local nargs = row.b
    local nret  = row.c
    local funcExpr = regRef(state, row.a, row.pc)
    local args = {}
    if nargs > 0 then
        for i = 1, nargs - 1 do args[i] = regRef(state, row.a + i, row.pc) end
    else
        args[#args + 1] = IR.varargs()
    end
    local callExpr = IR.call(funcExpr, args)
    if nret == 1 then
        -- 0 returns
        pushStmt(state, IR.callStmt(callExpr, row.pc))
    elseif nret == 2 then
        -- 1 return, written to R(A)
        pushStmt(state, IR.assign(regRef(state, row.a, row.pc), callExpr, row.pc))
    elseif nret > 2 then
        local dests = {}
        for i = 0, nret - 2 do dests[#dests + 1] = regRef(state, row.a + i, row.pc) end
        pushStmt(state, IR.multiAssign(dests, { callExpr }, row.pc))
    else
        -- top-of-stack returns (variadic)
        pushStmt(state, IR.multiAssign({ regRef(state, row.a, row.pc) }, { callExpr }, row.pc))
    end
end

F[Op.RETURN] = function(state, row)
    local count = row.b
    local values = {}
    if count > 0 then
        for i = 0, count - 2 do values[#values + 1] = regRef(state, row.a + i, row.pc) end
    else
        values[#values + 1] = IR.varargs()                            -- "return …"
    end
    pushStmt(state, IR.returnStmt(values, row.pc))
end

-- NAMECALL is special — it's nearly always immediately followed by CALL,
-- and the pair lifts to a single methodcall statement. The Lifter's main
-- loop performs that fusion (see liftRow); the bare NAMECALL fallback
-- below only fires if the following row isn't CALL (rare / corrupted).
F[Op.NAMECALL] = function(state, row)
    local k = state.proto.constants[(row.aux or 0) + 1]
    local method = k and k.tag == "STRING" and k.value or "?"
    pushStmt(state, IR.raw(string.format(
        "-- NAMECALL R%d=%s:%s (no following CALL?)",
        row.a, "R" .. row.b, method), row.pc))
end

-- Branches / jumps ----------------------------------------------------

local function emitJump(state, row)
    local target = branchTargetPc(row)
    if target then
        pushStmt(state, IR.jumpStmt(target, row.pc))
    end
end

F[Op.JUMP]     = function(state, row) emitJump(state, row) end
F[Op.JUMPBACK] = function(state, row) emitJump(state, row) end
F[Op.JUMPX]    = function(state, row) emitJump(state, row) end

local function emitBranchRA(state, row, reason, invert)
    local target = branchTargetPc(row)
    local cond = regRef(state, row.a, row.pc)
    if invert then cond = IR.unop("not ", cond) end
    pushStmt(state, IR.branchStmt(cond, target, row.pc, reason, invert))
end

F[Op.JUMPIF]    = function(state, row) emitBranchRA(state, row, "truthy", false) end
F[Op.JUMPIFNOT] = function(state, row) emitBranchRA(state, row, "falsy",  true)  end

local function emitBranchRARB(state, row, opSym, invert)
    local target = branchTargetPc(row)
    local lhs = regRef(state, row.a, row.pc)
    local rhs = regRef(state, row.aux or 0, row.pc)
    local cond = IR.binop(opSym, lhs, rhs)
    if invert then cond = IR.unop("not ", cond) end
    pushStmt(state, IR.branchStmt(cond, target, row.pc, opSym, invert))
end

F[Op.JUMPIFEQ]    = function(state, row) emitBranchRARB(state, row, "==", false) end
F[Op.JUMPIFLE]    = function(state, row) emitBranchRARB(state, row, "<=", false) end
F[Op.JUMPIFLT]    = function(state, row) emitBranchRARB(state, row, "<",  false) end
F[Op.JUMPIFNOTEQ] = function(state, row) emitBranchRARB(state, row, "==", true)  end
F[Op.JUMPIFNOTLE] = function(state, row) emitBranchRARB(state, row, "<=", true)  end
F[Op.JUMPIFNOTLT] = function(state, row) emitBranchRARB(state, row, "<",  true)  end

local function emitJumpXEqK(state, row, valueExpr)
    local target = branchTargetPc(row)
    local notFlag = decodeJumpXEqKAux(row.aux or 0)
    local cmp = notFlag and "~=" or "=="
    local cond = IR.binop(cmp, regRef(state, row.a, row.pc), valueExpr)
    pushStmt(state, IR.branchStmt(cond, target, row.pc, "fast-eq", notFlag))
end

F[Op.JUMPXEQKNIL] = function(state, row)
    emitJumpXEqK(state, row, IR.literal(nil, "nil"))
end
F[Op.JUMPXEQKB] = function(state, row)
    local _, payload = decodeJumpXEqKAux(row.aux or 0)
    emitJumpXEqK(state, row, IR.literal(bit32.band(payload, 1) == 1, "boolean"))
end
F[Op.JUMPXEQKN] = function(state, row)
    local _, payload = decodeJumpXEqKAux(row.aux or 0)
    local k = state.proto.constants[payload + 1]
    emitJumpXEqK(state, row, literalFromK(k))
end
F[Op.JUMPXEQKS] = function(state, row)
    local _, payload = decodeJumpXEqKAux(row.aux or 0)
    local k = state.proto.constants[payload + 1]
    emitJumpXEqK(state, row, literalFromK(k))
end

-- Arithmetic ----------------------------------------------------------

local function emitBinRR(state, row, op)
    pushStmt(state, IR.assign(
        regRef(state, row.a, row.pc),
        IR.binop(op,
            regRef(state, row.b, row.pc),
            regRef(state, row.c, row.pc)),
        row.pc))
end

local function emitBinRK(state, row, op)
    local k = state.proto.constants[row.c + 1]
    pushStmt(state, IR.assign(
        regRef(state, row.a, row.pc),
        IR.binop(op, regRef(state, row.b, row.pc), literalFromK(k)),
        row.pc))
end

local function emitBinKR(state, row, op)
    local k = state.proto.constants[row.b + 1]
    pushStmt(state, IR.assign(
        regRef(state, row.a, row.pc),
        IR.binop(op, literalFromK(k), regRef(state, row.c, row.pc)),
        row.pc))
end

F[Op.ADD]  = function(s, r) emitBinRR(s, r, "+") end
F[Op.SUB]  = function(s, r) emitBinRR(s, r, "-") end
F[Op.MUL]  = function(s, r) emitBinRR(s, r, "*") end
F[Op.DIV]  = function(s, r) emitBinRR(s, r, "/") end
F[Op.MOD]  = function(s, r) emitBinRR(s, r, "%") end
F[Op.POW]  = function(s, r) emitBinRR(s, r, "^") end
F[Op.IDIV] = function(s, r) emitBinRR(s, r, "//") end
F[Op.AND]  = function(s, r) emitBinRR(s, r, "and") end
F[Op.OR]   = function(s, r) emitBinRR(s, r, "or") end

F[Op.ADDK]  = function(s, r) emitBinRK(s, r, "+") end
F[Op.SUBK]  = function(s, r) emitBinRK(s, r, "-") end
F[Op.MULK]  = function(s, r) emitBinRK(s, r, "*") end
F[Op.DIVK]  = function(s, r) emitBinRK(s, r, "/") end
F[Op.MODK]  = function(s, r) emitBinRK(s, r, "%") end
F[Op.POWK]  = function(s, r) emitBinRK(s, r, "^") end
F[Op.IDIVK] = function(s, r) emitBinRK(s, r, "//") end
F[Op.ANDK]  = function(s, r) emitBinRK(s, r, "and") end
F[Op.ORK]   = function(s, r) emitBinRK(s, r, "or") end

F[Op.SUBRK] = function(s, r) emitBinKR(s, r, "-") end
F[Op.DIVRK] = function(s, r) emitBinKR(s, r, "/") end

F[Op.NOT]    = function(state, row)
    pushStmt(state, IR.assign(regRef(state, row.a, row.pc),
        IR.unop("not ", regRef(state, row.b, row.pc)), row.pc))
end
F[Op.MINUS]  = function(state, row)
    pushStmt(state, IR.assign(regRef(state, row.a, row.pc),
        IR.unop("-", regRef(state, row.b, row.pc)), row.pc))
end
F[Op.LENGTH] = function(state, row)
    pushStmt(state, IR.assign(regRef(state, row.a, row.pc),
        IR.lengthExpr(regRef(state, row.b, row.pc)), row.pc))
end

F[Op.CONCAT] = function(state, row)
    local parts = {}
    for r = row.b, row.c do parts[#parts + 1] = regRef(state, r, row.pc) end
    pushStmt(state, IR.assign(
        regRef(state, row.a, row.pc),
        IR.concat(parts),
        row.pc))
end

-- For loops -----------------------------------------------------------
-- The lifter emits these as raw branch markers; StructureRecovery
-- folds FORNPREP / FORNLOOP / FORGPREP* / FORGLOOP into structured
-- `fornum` / `forgen` statements.

local function emitForMarker(state, row, label)
    local target = branchTargetPc(row)
    pushStmt(state, IR.branchStmt(
        IR.unknown(label),
        target, row.pc, label, false))
end

F[Op.FORNPREP]       = function(s, r) emitForMarker(s, r, "FORNPREP") end
F[Op.FORNLOOP]       = function(s, r) emitForMarker(s, r, "FORNLOOP") end
F[Op.FORGPREP]       = function(s, r) emitForMarker(s, r, "FORGPREP") end
F[Op.FORGPREP_INEXT] = function(s, r) emitForMarker(s, r, "FORGPREP_INEXT") end
F[Op.FORGPREP_NEXT]  = function(s, r) emitForMarker(s, r, "FORGPREP_NEXT") end
F[Op.FORGLOOP]       = function(s, r) emitForMarker(s, r, "FORGLOOP") end

-- Varargs / misc ------------------------------------------------------

F[Op.GETVARARGS] = function(state, row)
    if row.b > 0 then
        local dests = {}
        for i = 0, row.b - 2 do dests[#dests + 1] = regRef(state, row.a + i, row.pc) end
        pushStmt(state, IR.multiAssign(dests, { IR.varargs() }, row.pc))
    else
        pushStmt(state, IR.assign(regRef(state, row.a, row.pc), IR.varargs(), row.pc))
    end
end

F[Op.PREPVARARGS] = function() end                                    -- frame setup, no statement

-- Fast-call hints don't produce statements on their own; the upcoming
-- CALL produces the actual call. We record them as `-- fastcall` so the
-- emitter can drop a hint, but they don't change semantics.
local function fastcallHint(state, row, args)
    local builtinName = OpcodeTable.Builtin
        and OpcodeTable.Builtin[row.a]
        or string.format("builtin#%d", row.a)
    pushStmt(state, IR.raw(string.format(
        "-- fastcall %s(%s) skip=%d", builtinName, args, row.c), row.pc))
end

F[Op.FASTCALL]   = function(s, r) fastcallHint(s, r, "…") end
F[Op.FASTCALL1]  = function(s, r) fastcallHint(s, r, string.format("R%d", r.b)) end
F[Op.FASTCALL2]  = function(s, r) fastcallHint(s, r, string.format("R%d,R%d", r.b, bit32.band(r.aux or 0, 0xFF))) end
F[Op.FASTCALL2K] = function(s, r) fastcallHint(s, r, string.format("R%d,K(%d)", r.b, r.aux or 0)) end
F[Op.FASTCALL3]  = function(s, r)
    local aux = r.aux or 0
    fastcallHint(s, r, string.format("R%d,R%d,R%d", r.b,
        bit32.band(aux, 0xFF), bit32.band(bit32.rshift(aux, 8), 0xFF)))
end

F[Op.COVERAGE]   = function() end
F[Op.NATIVECALL] = function() end

-- ---------------------------------------------------------------------
-- NAMECALL + CALL fusion (the only multi-instruction idiom)
-- ---------------------------------------------------------------------

local function tryFuseNamecallCall(state, ncRow, callRow)
    -- NAMECALL: A=dst, B=obj, AUX=K idx of method name
    -- CALL    : A=A_nc, B=#args+1 (0=top), C=#rets+1 (0=top)
    -- Args used by CALL start at R(A_nc + 1), which NAMECALL set to R(B).
    local k = state.proto.constants[(ncRow.aux or 0) + 1]
    local method = k and k.tag == "STRING" and k.value or "?"
    local obj = regRef(state, ncRow.b, ncRow.pc)
    -- additional args come after the implicit self at R(A_nc+1):
    --   R(A_nc+2), R(A_nc+3), … up to R(A_nc + B - 1)
    local args = {}
    local nargs = callRow.b
    if nargs > 0 then
        for i = 2, nargs - 1 do
            args[#args + 1] = regRef(state, callRow.a + i, callRow.pc)
        end
    else
        args[#args + 1] = IR.varargs()
    end
    local mcExpr = IR.methodcall(obj, method, args)
    local nret = callRow.c
    if nret == 1 then
        pushStmt(state, IR.callStmt(mcExpr, ncRow.pc))
    elseif nret == 2 then
        pushStmt(state, IR.assign(regRef(state, callRow.a, callRow.pc), mcExpr, ncRow.pc))
    elseif nret > 2 then
        local dests = {}
        for i = 0, nret - 2 do
            dests[#dests + 1] = regRef(state, callRow.a + i, callRow.pc)
        end
        pushStmt(state, IR.multiAssign(dests, { mcExpr }, ncRow.pc))
    else
        pushStmt(state, IR.multiAssign({ regRef(state, callRow.a, callRow.pc) }, { mcExpr }, ncRow.pc))
    end
    return true
end

-- ---------------------------------------------------------------------
-- Generic fallback
-- ---------------------------------------------------------------------

local function genericFallback(state, row)
    pushStmt(state, IR.raw(
        string.format("/* %-10s %s */",
            row.mnemonic or "?",
            row.operandText or ""),
        row.pc))
end

-- ---------------------------------------------------------------------
-- Main lifter loop
-- ---------------------------------------------------------------------

local function liftRow(state, row, pc)
    -- Look ahead for NAMECALL+CALL fusion.
    if row.op == Op.NAMECALL then
        local nextPc = pc + (row.hasAux and 2 or 1)
        local nextRow = state.stream.rowByPc[nextPc]
        if nextRow and nextRow.op == Op.CALL and nextRow.a == row.a then
            tryFuseNamecallCall(state, row, nextRow)
            -- Emit a label for the next-pc position so any branch targeting
            -- the post-CALL PC still lands cleanly (the linear stmts list
            -- continues at the natural next PC).
            return (nextRow.hasAux and 2 or 1) + (row.hasAux and 2 or 1)
        end
    end

    local fn = F[row.op]
    if fn then
        fn(state, row, pc)
    else
        genericFallback(state, row)
    end
    return row.hasAux and 2 or 1
end

-- ---------------------------------------------------------------------
-- Param/upval/regNames initialization
-- ---------------------------------------------------------------------

local function initNames(state)
    local proto = state.proto
    local params = {}
    if proto.numparams > 0 then
        for i = 0, proto.numparams - 1 do
            local nm
            if proto.debug and proto.debug.locals then
                for _, loc in proto.debug.locals do
                    if loc.reg == i and loc.startpc <= 1 then nm = loc.name; break end
                end
            end
            nm = nm or string.format("arg%d", i + 1)
            params[i + 1] = nm
            state.regNames[i] = nm
        end
    end
    state.paramNames = params

    local upvals = {}
    if proto.debug and proto.debug.upvalues then
        for i, u in proto.debug.upvalues do
            upvals[i] = u.name or string.format("upv%d", i - 1)
        end
    else
        for i = 1, proto.nups or 0 do
            upvals[i] = string.format("upv%d", i - 1)
        end
    end
    state.upvalNames = upvals
end

-- ---------------------------------------------------------------------
-- Public entry point
-- ---------------------------------------------------------------------

function Lifter.liftProto(stream, parsedBytecode, opts)
    opts = opts or {}
    local proto = stream.proto
    if not proto then error("Lifter.liftProto: stream has no proto", 2) end

    local state = {
        stream     = stream,
        proto      = proto,
        bc         = parsedBytecode,
        childIRs   = opts.childIRs or {},
        regNames   = {},
        paramNames = {},
        upvalNames = {},
        stmts      = {},
        labelsByPc = {},                                              -- pc → true (where labels are needed)
    }
    initNames(state)

    -- Walk the instruction stream. Inject labels for every branch target
    -- so structure recovery has anchors.
    for _, row in stream.rows do
        if row.references then
            for _, ref in row.references do
                if ref.kind == "branch" and ref.target then
                    state.labelsByPc[ref.target] = true
                end
            end
        end
    end

    local pc = 1
    while pc <= proto.sizecode do
        if state.labelsByPc[pc] then
            pushStmt(state, IR.labelStmt(pc))
        end
        local row = stream.rowByPc[pc]
        if not row then pc = pc + 1; continue end
        local consumed = liftRow(state, row, pc)
        pc = pc + consumed
    end

    return {
        stmts      = state.stmts,
        paramNames = state.paramNames,
        upvalNames = state.upvalNames,
        regNames   = state.regNames,
        hasVararg  = proto.isvararg,
        debugName  = proto.debugName,
        protoId    = proto.id,
    }
end

return Lifter
