--!nonstrict
-- =====================================================================
-- IDARoblox / Analysis / Decompiler / IR
-- ---------------------------------------------------------------------
-- Intermediate-representation node definitions for the decompiler.
--
-- All node "constructors" are tiny factory functions that return a
-- table tagged with a `kind` string. Nothing more interesting happens
-- here — IR is a passive data model. Consumers pattern-match on `kind`
-- using simple `if`/`elseif` chains.
--
-- Two flavours of nodes:
--   Expressions  produce a value           (literal, reg, binop, call, …)
--   Statements   advance program state     (assign, return, if, while, …)
--
-- The Lifter emits a flat sequence of statements (with raw `jump` /
-- `branch` / `label` markers); the StructureRecovery pass folds those
-- linear markers into nested `if` / `while` / `repeat` / `fornum`
-- /`forgen` constructs using the CFG and dominator information.
--
-- During emission the raw `reg` nodes can be substituted for `local`
-- nodes via a name map; the Emitter is agnostic — it prints whichever
-- shape it gets handed.
-- =====================================================================

local IR = {}

-- ---------------------------------------------------------------------
-- Expression constructors
-- ---------------------------------------------------------------------

function IR.literal(value, literalKind)
    return { kind = "literal", value = value, literalKind = literalKind or "any" }
end
function IR.reg(num)                return { kind = "reg",       num = num } end
function IR.localRef(name, reg)     return { kind = "local",     name = name, reg = reg } end
function IR.globalRef(name)         return { kind = "global",    name = name } end
function IR.upvalRef(index, name)   return { kind = "upval",     index = index, name = name } end
function IR.importRef(chain)        return { kind = "import",    chain = chain or {} } end

function IR.binop(op, lhs, rhs)     return { kind = "binop",     op = op, lhs = lhs, rhs = rhs } end
function IR.unop(op, expr)          return { kind = "unop",      op = op, expr = expr } end
function IR.field(obj, name)        return { kind = "field",     obj = obj, name = name } end
function IR.index(obj, key)         return { kind = "index",     obj = obj, index = key } end

function IR.call(func, args)        return { kind = "call",      func = func, args = args or {} } end
function IR.methodcall(obj, m, args)return { kind = "methodcall",obj = obj, method = m, args = args or {} } end
function IR.builtin(name, args)     return { kind = "builtin",   name = name, args = args or {} } end

function IR.tableExpr(arr, hash)
    return { kind = "table", array = arr or {}, hash = hash or {} }
end
function IR.funcExpr(params, body, isVararg, debugName)
    return { kind = "function", params = params or {}, body = body, isVararg = isVararg, debugName = debugName }
end
function IR.varargs()               return { kind = "varargs" } end
function IR.concat(exprs)           return { kind = "concat",    exprs = exprs or {} } end
function IR.lengthExpr(expr)        return { kind = "length",    expr = expr } end
function IR.unknown(text, ref)      return { kind = "unknown",   text = text or "<?>", ref = ref } end

-- ---------------------------------------------------------------------
-- Statement constructors
-- ---------------------------------------------------------------------

function IR.assign(dest, value, pc)
    return { kind = "assign", dest = dest, value = value, pc = pc }
end
function IR.multiAssign(dests, values, pc)
    return { kind = "multiAssign", dests = dests, values = values, pc = pc }
end
function IR.localDecl(names, values, pc)
    return { kind = "localDecl", names = names or {}, values = values or {}, pc = pc }
end
function IR.callStmt(call, pc)
    return { kind = "callStmt", call = call, pc = pc }
end
function IR.returnStmt(values, pc)
    return { kind = "return", values = values or {}, pc = pc }
end
function IR.breakStmt(pc)           return { kind = "break", pc = pc } end
function IR.continueStmt(pc)        return { kind = "continue", pc = pc } end

function IR.ifStmt(cond, thenBody, elseBody, pc)
    return { kind = "if", cond = cond, thenBody = thenBody, elseBody = elseBody, pc = pc }
end
function IR.whileStmt(cond, body, pc)
    return { kind = "while", cond = cond, body = body, pc = pc }
end
function IR.repeatStmt(body, cond, pc)
    return { kind = "repeat", body = body, cond = cond, pc = pc }
end
function IR.fornumStmt(var, startE, stopE, stepE, body, pc)
    return { kind = "fornum", var = var, startE = startE, stopE = stopE, stepE = stepE, body = body, pc = pc }
end
function IR.forgenStmt(vars, iters, body, pc)
    return { kind = "forgen", vars = vars or {}, iters = iters or {}, body = body, pc = pc }
end
function IR.doStmt(body, pc)
    return { kind = "do", body = body, pc = pc }
end
function IR.block(stmts)
    return { kind = "block", stmts = stmts or {} }
end
function IR.raw(text, pc)           return { kind = "raw", text = text, pc = pc } end

-- Pre-structure-recovery linear-control-flow markers
function IR.jumpStmt(target, pc)    return { kind = "jump",   target = target, pc = pc } end
function IR.branchStmt(cond, target, pc, reason, inverted)
    return { kind = "branch", cond = cond, target = target, pc = pc, reason = reason, inverted = inverted }
end
function IR.labelStmt(pc)           return { kind = "label",  pc = pc } end

-- ---------------------------------------------------------------------
-- Visitor / walker
-- ---------------------------------------------------------------------
-- IR.walk(node, fn) calls fn(node) and then recursively descends every
-- nested IR node (expressions inside statements, child statements
-- inside blocks). The return value of fn is ignored.

local walk
local function walkAll(t, fn)
    if type(t) ~= "table" then return end
    for _, v in t do walk(v, fn) end
end

walk = function(node, fn)
    if type(node) ~= "table" or not node.kind then return end
    fn(node)
    local k = node.kind
    if k == "binop" then walk(node.lhs, fn); walk(node.rhs, fn)
    elseif k == "unop" or k == "length" then walk(node.expr, fn)
    elseif k == "field" or k == "index" then
        walk(node.obj, fn)
        if k == "index" then walk(node.index, fn) end
    elseif k == "call" then walk(node.func, fn); walkAll(node.args, fn)
    elseif k == "methodcall" then walk(node.obj, fn); walkAll(node.args, fn)
    elseif k == "builtin" then walkAll(node.args, fn)
    elseif k == "table" then
        walkAll(node.array, fn)
        for _, e in node.hash do walk(e.key, fn); walk(e.value, fn) end
    elseif k == "function" then walk(node.body, fn)
    elseif k == "concat" then walkAll(node.exprs, fn)
    elseif k == "assign" then walk(node.dest, fn); walk(node.value, fn)
    elseif k == "multiAssign" then walkAll(node.dests, fn); walkAll(node.values, fn)
    elseif k == "localDecl" then walkAll(node.values, fn)
    elseif k == "callStmt" then walk(node.call, fn)
    elseif k == "return"   then walkAll(node.values, fn)
    elseif k == "if" then
        walk(node.cond, fn); walk(node.thenBody, fn); walk(node.elseBody, fn)
    elseif k == "while" then walk(node.cond, fn); walk(node.body, fn)
    elseif k == "repeat" then walk(node.body, fn); walk(node.cond, fn)
    elseif k == "fornum" then
        walk(node.startE, fn); walk(node.stopE, fn); walk(node.stepE, fn); walk(node.body, fn)
    elseif k == "forgen" then walkAll(node.iters, fn); walk(node.body, fn)
    elseif k == "do" then walk(node.body, fn)
    elseif k == "block" then walkAll(node.stmts, fn)
    elseif k == "branch" then walk(node.cond, fn)
    end
end

IR.walk = walk

-- ---------------------------------------------------------------------
-- Debug pretty-printer (used by self-tests + Emitter dev mode)
-- ---------------------------------------------------------------------

local function asString(node, depth)
    depth = depth or 0
    if type(node) ~= "table" or not node.kind then return tostring(node) end
    local pad = string.rep("  ", depth)
    local k = node.kind
    if k == "literal" then
        if node.literalKind == "string" then return string.format('%q', node.value)
        elseif node.literalKind == "nil" then return "nil"
        else return tostring(node.value) end
    elseif k == "reg"     then return "R" .. tostring(node.num)
    elseif k == "local"   then return node.name
    elseif k == "global"  then return node.name
    elseif k == "upval"   then return node.name or ("U" .. node.index)
    elseif k == "import"  then return table.concat(node.chain, ".")
    elseif k == "binop"   then return "(" .. asString(node.lhs) .. " " .. node.op .. " " .. asString(node.rhs) .. ")"
    elseif k == "unop"    then return node.op .. asString(node.expr)
    elseif k == "field"   then return asString(node.obj) .. "." .. node.name
    elseif k == "index"   then return asString(node.obj) .. "[" .. asString(node.index) .. "]"
    elseif k == "call" then
        local parts = {}
        for _, a in node.args do parts[#parts + 1] = asString(a) end
        return asString(node.func) .. "(" .. table.concat(parts, ", ") .. ")"
    elseif k == "methodcall" then
        local parts = {}
        for _, a in node.args do parts[#parts + 1] = asString(a) end
        return asString(node.obj) .. ":" .. node.method .. "(" .. table.concat(parts, ", ") .. ")"
    elseif k == "builtin" then
        local parts = {}
        for _, a in node.args do parts[#parts + 1] = asString(a) end
        return node.name .. "(" .. table.concat(parts, ", ") .. ")"
    elseif k == "varargs"  then return "..."
    elseif k == "concat"   then
        local parts = {}
        for _, a in node.exprs do parts[#parts + 1] = asString(a) end
        return table.concat(parts, " .. ")
    elseif k == "length"   then return "#" .. asString(node.expr)
    elseif k == "table"    then
        local n = #node.array + #node.hash
        return string.format("{...%d entries...}", n)
    elseif k == "function" then return "function(…)…end"
    elseif k == "unknown"  then return string.format("/*UNK %s*/", node.text)
    else return "<" .. k .. ">"
    end
end
IR.asString = asString

return IR
