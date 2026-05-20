--!nonstrict
-- =====================================================================
-- IDARoblox / Analysis / Decompiler / Emitter
-- ---------------------------------------------------------------------
-- Pretty-printer for structured IR. Produces idiomatic-ish Luau source.
--
-- Algorithm:
--   * StringBuilder of lines, with current indent depth.
--   * emitStmt(stmt) appends one or more lines.
--   * emitExpr(expr, parentPrec) returns a string fragment, inserting
--     parentheses where the child's precedence is lower than the
--     parent's (and respecting right-vs-left associativity for ^, ..,
--     and equality chains).
--
-- Precedence table (Luau, low → high):
--   1  or
--   2  and
--   3  < > <= >= ~= ==
--   4  ..  (right-assoc)
--   5  + -
--   6  * / // %
--   7  unary: not  #  -
--   8  ^   (right-assoc)
--   9  primary: literals, identifiers, parens, calls, indexing
--
-- Identifiers that collide with Luau reserved words get printed with
-- bracket notation: `t["end"]` instead of `t.end`.
-- =====================================================================

local Emitter = {}

local RESERVED = {
    ["and"]=true, ["break"]=true, ["do"]=true, ["else"]=true, ["elseif"]=true,
    ["end"]=true, ["false"]=true, ["for"]=true, ["function"]=true, ["if"]=true,
    ["in"]=true, ["local"]=true, ["nil"]=true, ["not"]=true, ["or"]=true,
    ["repeat"]=true, ["return"]=true, ["then"]=true, ["true"]=true, ["until"]=true,
    ["while"]=true, ["continue"]=true,
}

local function isValidIdent(s)
    if type(s) ~= "string" then return false end
    if RESERVED[s] then return false end
    if not string.match(s, "^[%a_][%w_]*$") then return false end
    return true
end

local function escapeString(s)
    if type(s) ~= "string" then return tostring(s) end
    -- Luau %q produces a fully-escaped, syntactically valid string.
    return string.format("%q", s)
end

local function escapeNumber(n)
    if n ~= n then return "0/0"          -- nan
    elseif n == math.huge then return "math.huge"
    elseif n == -math.huge then return "-math.huge"
    end
    if type(n) == "number" and n == math.floor(n) and math.abs(n) < 1e15 then
        return string.format("%d", n)
    end
    return string.format("%.14g", n)
end

-- ---------------------------------------------------------------------
-- Precedence
-- ---------------------------------------------------------------------

local BINOP_PREC = {
    ["or"]  = { prec = 1, assoc = "left" },
    ["and"] = { prec = 2, assoc = "left" },
    ["<"]   = { prec = 3, assoc = "left" },
    [">"]   = { prec = 3, assoc = "left" },
    ["<="]  = { prec = 3, assoc = "left" },
    [">="]  = { prec = 3, assoc = "left" },
    ["~="]  = { prec = 3, assoc = "left" },
    ["=="]  = { prec = 3, assoc = "left" },
    [".."]  = { prec = 4, assoc = "right" },
    ["+"]   = { prec = 5, assoc = "left" },
    ["-"]   = { prec = 5, assoc = "left" },
    ["*"]   = { prec = 6, assoc = "left" },
    ["/"]   = { prec = 6, assoc = "left" },
    ["//"]  = { prec = 6, assoc = "left" },
    ["%"]   = { prec = 6, assoc = "left" },
    ["^"]   = { prec = 8, assoc = "right" },
}

local UNARY_PREC  = 7
local PRIMARY     = 9

-- ---------------------------------------------------------------------
-- Builder
-- ---------------------------------------------------------------------

local function newBuilder(opts)
    return {
        lines      = {},
        indent     = 0,
        indentStr  = opts and opts.indentStr or "    ",
        emitLabels = opts and opts.emitLabels or false,
    }
end

local function pushLine(b, text)
    if text == "" then
        b.lines[#b.lines + 1] = ""
        return
    end
    b.lines[#b.lines + 1] = string.rep(b.indentStr, b.indent) .. text
end

-- ---------------------------------------------------------------------
-- Expression emission
-- ---------------------------------------------------------------------

local emitExpr                                                       -- forward decl

local function emitArgs(args)
    local parts = {}
    for i, a in args or {} do parts[i] = emitExpr(a, 0) end
    return table.concat(parts, ", ")
end

local function emitFieldOrIndexKey(obj)
    -- Field access uses dot notation when name is a valid ident,
    -- otherwise bracket notation.
    return obj
end

local function emitTable(node)
    -- Combine array and hash sections.
    local parts = {}
    if node.array and #node.array > 0 then
        for _, v in node.array do parts[#parts + 1] = emitExpr(v, 0) end
    end
    if node.hash and #node.hash > 0 then
        for _, entry in node.hash do
            local key = entry.key
            local valTxt = emitExpr(entry.value, 0)
            if key.kind == "literal" and key.literalKind == "string"
                and isValidIdent(key.value) then
                parts[#parts + 1] = string.format("%s = %s", key.value, valTxt)
            else
                parts[#parts + 1] = string.format("[%s] = %s",
                    emitExpr(key, 0), valTxt)
            end
        end
    end
    if #parts == 0 then return "{}" end
    return "{ " .. table.concat(parts, ", ") .. " }"
end

local function emitFunctionExpr(node, builder)
    -- Inline function-expression. For short bodies we could one-line
    -- this, but the easier and more readable behaviour is multi-line.
    local params = {}
    for i, p in node.params or {} do params[i] = p end
    if node.isVararg then params[#params + 1] = "..." end
    local header = "function(" .. table.concat(params, ", ") .. ")"
    if not node.body or (node.body.kind == "block" and #node.body.stmts == 0) then
        return header .. " end"
    end
    -- Multi-line: emit body into a sub-builder and join with the header
    local sub = newBuilder({ indentStr = builder.indentStr })
    sub.indent = builder.indent + 1
    Emitter._emitBlockBody(sub, node.body)
    local bodyText = table.concat(sub.lines, "\n")
    return header .. "\n" .. bodyText .. "\n"
        .. string.rep(builder.indentStr, builder.indent) .. "end"
end

emitExpr = function(node, parentPrec, builder)
    parentPrec = parentPrec or 0
    if type(node) ~= "table" or not node.kind then return tostring(node) end
    local k = node.kind

    if k == "literal" then
        if node.literalKind == "nil" then return "nil"
        elseif node.literalKind == "string" then return escapeString(node.value)
        elseif node.literalKind == "boolean" then return tostring(node.value)
        elseif node.literalKind == "number" then return escapeNumber(node.value)
        end
        return tostring(node.value)
    elseif k == "reg" then
        return string.format("R%d", node.num)
    elseif k == "local" then
        return node.name
    elseif k == "global" then
        return node.name
    elseif k == "upval" then
        return node.name or string.format("upv%d", node.index)
    elseif k == "import" then
        -- An import chain reads as `game.Players.LocalPlayer` etc.
        local parts = {}
        for i, segment in node.chain do
            if i == 1 then parts[i] = segment
            elseif isValidIdent(segment) then parts[i] = segment
            else parts[i] = string.format("[%s]", escapeString(segment))
            end
        end
        -- Join: first separator is `.`, but if part needs brackets we glue without dot.
        local s = parts[1] or ""
        for i = 2, #parts do
            if string.sub(parts[i], 1, 1) == "[" then s = s .. parts[i]
            else s = s .. "." .. parts[i] end
        end
        return s
    elseif k == "binop" then
        local info = BINOP_PREC[node.op] or { prec = 0, assoc = "left" }
        local myPrec = info.prec
        local left  = emitExpr(node.lhs, info.assoc == "left"  and myPrec or myPrec + 1, builder)
        local right = emitExpr(node.rhs, info.assoc == "right" and myPrec or myPrec + 1, builder)
        local out = string.format("%s %s %s", left, node.op, right)
        if myPrec < parentPrec then return "(" .. out .. ")" end
        return out
    elseif k == "unop" then
        local inner = emitExpr(node.expr, UNARY_PREC, builder)
        local out = string.format("%s%s", node.op, inner)
        if UNARY_PREC < parentPrec then return "(" .. out .. ")" end
        return out
    elseif k == "length" then
        return "#" .. emitExpr(node.expr, UNARY_PREC, builder)
    elseif k == "field" then
        local obj = emitExpr(node.obj, PRIMARY, builder)
        if isValidIdent(node.name) then
            return obj .. "." .. node.name
        else
            return obj .. "[" .. escapeString(node.name) .. "]"
        end
    elseif k == "index" then
        local obj = emitExpr(node.obj, PRIMARY, builder)
        return obj .. "[" .. emitExpr(node.index, 0, builder) .. "]"
    elseif k == "call" then
        local func = emitExpr(node.func, PRIMARY, builder)
        local parts = {}
        for i, a in node.args do parts[i] = emitExpr(a, 0, builder) end
        return func .. "(" .. table.concat(parts, ", ") .. ")"
    elseif k == "methodcall" then
        local obj = emitExpr(node.obj, PRIMARY, builder)
        local parts = {}
        for i, a in node.args do parts[i] = emitExpr(a, 0, builder) end
        return string.format("%s:%s(%s)", obj, node.method, table.concat(parts, ", "))
    elseif k == "builtin" then
        local parts = {}
        for i, a in node.args do parts[i] = emitExpr(a, 0, builder) end
        return string.format("%s(%s)", node.name, table.concat(parts, ", "))
    elseif k == "varargs" then
        return "..."
    elseif k == "concat" then
        local info = BINOP_PREC[".."]
        local prec = info.prec
        local parts = {}
        for i, a in node.exprs do
            parts[i] = emitExpr(a, prec + 1, builder)
        end
        local out = table.concat(parts, " .. ")
        if prec < parentPrec then return "(" .. out .. ")" end
        return out
    elseif k == "table" then
        return emitTable(node)
    elseif k == "function" then
        return emitFunctionExpr(node, builder or newBuilder())
    elseif k == "unknown" then
        return "--[[ " .. (node.text or "?") .. " ]]"
    end
    return "<" .. k .. ">"
end

-- ---------------------------------------------------------------------
-- Statement emission
-- ---------------------------------------------------------------------

local emitStmt
local function emitBlockBody(builder, blockOrNil)
    if not blockOrNil then return end
    if blockOrNil.kind ~= "block" then
        emitStmt(builder, blockOrNil)
        return
    end
    for _, s in blockOrNil.stmts do emitStmt(builder, s) end
end
Emitter._emitBlockBody = emitBlockBody

local function emitDest(node, builder)
    -- Destinations can be: local/reg/global/field/index/upval.
    return emitExpr(node, 0, builder)
end

emitStmt = function(builder, stmt)
    if not stmt then return end
    local k = stmt.kind

    if k == "assign" then
        pushLine(builder, string.format("%s = %s",
            emitDest(stmt.dest, builder),
            emitExpr(stmt.value, 0, builder)))
    elseif k == "multiAssign" then
        local dests = {}
        for i, d in stmt.dests do dests[i] = emitDest(d, builder) end
        local values = {}
        for i, v in stmt.values do values[i] = emitExpr(v, 0, builder) end
        pushLine(builder, string.format("%s = %s",
            table.concat(dests, ", "), table.concat(values, ", ")))
    elseif k == "localDecl" then
        local names = stmt.names or {}
        local values = stmt.values or {}
        local valuesTxt = ""
        if #values > 0 then
            local parts = {}
            for i, v in values do parts[i] = emitExpr(v, 0, builder) end
            valuesTxt = " = " .. table.concat(parts, ", ")
        end
        pushLine(builder, "local " .. table.concat(names, ", ") .. valuesTxt)
    elseif k == "callStmt" then
        pushLine(builder, emitExpr(stmt.call, 0, builder))
    elseif k == "return" then
        if not stmt.values or #stmt.values == 0 then
            pushLine(builder, "return")
        else
            local parts = {}
            for i, v in stmt.values do parts[i] = emitExpr(v, 0, builder) end
            pushLine(builder, "return " .. table.concat(parts, ", "))
        end
    elseif k == "break" then
        pushLine(builder, "break")
    elseif k == "continue" then
        pushLine(builder, "continue")
    elseif k == "if" then
        pushLine(builder, "if " .. emitExpr(stmt.cond, 0, builder) .. " then")
        builder.indent = builder.indent + 1
        emitBlockBody(builder, stmt.thenBody)
        builder.indent = builder.indent - 1
        if stmt.elseBody and (stmt.elseBody.kind == "block" and #stmt.elseBody.stmts > 0
            or stmt.elseBody.kind ~= "block") then
            -- elseif folding: if the elseBody is a single if-stmt, emit
            -- as `elseif` to reduce indent depth.
            local eb = stmt.elseBody
            if eb.kind == "block" and #eb.stmts == 1 and eb.stmts[1].kind == "if" then
                local inner = eb.stmts[1]
                pushLine(builder, "elseif " .. emitExpr(inner.cond, 0, builder) .. " then")
                builder.indent = builder.indent + 1
                emitBlockBody(builder, inner.thenBody)
                builder.indent = builder.indent - 1
                -- recursively unfold inner.elseBody via tail call style
                local tail = inner.elseBody
                while tail and tail.kind == "block" and #tail.stmts == 1 and tail.stmts[1].kind == "if" do
                    local nested = tail.stmts[1]
                    pushLine(builder, "elseif " .. emitExpr(nested.cond, 0, builder) .. " then")
                    builder.indent = builder.indent + 1
                    emitBlockBody(builder, nested.thenBody)
                    builder.indent = builder.indent - 1
                    tail = nested.elseBody
                end
                if tail and ((tail.kind == "block" and #tail.stmts > 0) or tail.kind ~= "block") then
                    pushLine(builder, "else")
                    builder.indent = builder.indent + 1
                    emitBlockBody(builder, tail)
                    builder.indent = builder.indent - 1
                end
            else
                pushLine(builder, "else")
                builder.indent = builder.indent + 1
                emitBlockBody(builder, eb)
                builder.indent = builder.indent - 1
            end
        end
        pushLine(builder, "end")
    elseif k == "while" then
        pushLine(builder, "while " .. emitExpr(stmt.cond, 0, builder) .. " do")
        builder.indent = builder.indent + 1
        emitBlockBody(builder, stmt.body)
        builder.indent = builder.indent - 1
        pushLine(builder, "end")
    elseif k == "repeat" then
        pushLine(builder, "repeat")
        builder.indent = builder.indent + 1
        emitBlockBody(builder, stmt.body)
        builder.indent = builder.indent - 1
        pushLine(builder, "until " .. emitExpr(stmt.cond, 0, builder))
    elseif k == "fornum" then
        local startE = emitExpr(stmt.startE, 0, builder)
        local stopE  = emitExpr(stmt.stopE,  0, builder)
        local stepE  = stmt.stepE and emitExpr(stmt.stepE, 0, builder) or nil
        local header
        if stepE then
            header = string.format("for %s = %s, %s, %s do", stmt.var, startE, stopE, stepE)
        else
            header = string.format("for %s = %s, %s do", stmt.var, startE, stopE)
        end
        pushLine(builder, header)
        builder.indent = builder.indent + 1
        emitBlockBody(builder, stmt.body)
        builder.indent = builder.indent - 1
        pushLine(builder, "end")
    elseif k == "forgen" then
        local iters = {}
        for i, e in stmt.iters or {} do iters[i] = emitExpr(e, 0, builder) end
        pushLine(builder, string.format("for %s in %s do",
            table.concat(stmt.vars or { "_" }, ", "),
            table.concat(iters, ", ")))
        builder.indent = builder.indent + 1
        emitBlockBody(builder, stmt.body)
        builder.indent = builder.indent - 1
        pushLine(builder, "end")
    elseif k == "do" then
        pushLine(builder, "do")
        builder.indent = builder.indent + 1
        emitBlockBody(builder, stmt.body)
        builder.indent = builder.indent - 1
        pushLine(builder, "end")
    elseif k == "block" then
        emitBlockBody(builder, stmt)
    elseif k == "raw" then
        pushLine(builder, stmt.text or "")
    elseif k == "jump" then
        pushLine(builder, string.format("-- goto loc_%04X",
            stmt.target and ((stmt.target - 1) * 4) or 0))
    elseif k == "branch" then
        pushLine(builder, string.format("if %s then goto loc_%04X end",
            emitExpr(stmt.cond, 0, builder),
            stmt.target and ((stmt.target - 1) * 4) or 0))
    elseif k == "label" then
        -- Labels are pre-inserted at every branch target by the Lifter to
        -- give StructureRecovery anchors. After recovery folds the
        -- linear-flow markers into structured constructs, surviving label
        -- declarations are mostly dead syntax. They become required only
        -- when a goto fallback survives (those are rare and emit a
        -- separate `raw` statement). The Emitter skips them by default;
        -- pass `opts.emitLabels = true` to re-enable.
        if builder.emitLabels then
            pushLine(builder, string.format("::loc_%04X::",
                stmt.pc and ((stmt.pc - 1) * 4) or 0))
        end
    else
        pushLine(builder, string.format("-- unhandled stmt kind=%s", k))
    end
end

-- ---------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------

-- emit a single proto. `lifted` is the Lifter's result (paramNames, hasVararg,
-- debugName); `structured` is the StructureRecovery result (body).
function Emitter.emitFunction(lifted, structured, opts)
    opts = opts or {}
    local b = newBuilder({ indentStr = opts.indent or "    " })
    local name = opts.functionName or lifted.debugName or "anonymous"
    local params = {}
    for i, p in lifted.paramNames do params[i] = p end
    if lifted.hasVararg then params[#params + 1] = "..." end
    local header
    if opts.declarationStyle == "named" then
        header = string.format("function %s(%s)", name, table.concat(params, ", "))
    elseif opts.declarationStyle == "local-named" then
        header = string.format("local function %s(%s)", name, table.concat(params, ", "))
    else
        header = string.format("-- %s\nfunction (%s)", name, table.concat(params, ", "))
    end
    pushLine(b, header)
    b.indent = b.indent + 1
    emitBlockBody(b, structured.body)
    b.indent = b.indent - 1
    pushLine(b, "end")
    return table.concat(b.lines, "\n")
end

-- Emit raw IR (no surrounding function) — used for testing or
-- decompiling fragments.
function Emitter.emit(ir, opts)
    opts = opts or {}
    local b = newBuilder({ indentStr = opts.indent or "    " })
    if ir.kind == "block" then emitBlockBody(b, ir)
    else emitStmt(b, ir) end
    return table.concat(b.lines, "\n")
end

return Emitter
