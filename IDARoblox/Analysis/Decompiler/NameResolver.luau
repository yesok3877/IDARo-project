--!nonstrict
-- =====================================================================
-- IDARoblox / Analysis / Decompiler / NameResolver
-- ---------------------------------------------------------------------
-- Picks readable local names for the lifted IR's registers. Naming
-- policy (descending priority):
--
--   1. Debug info       — proto.debug.locals[i] has a name and an
--                          active range [startpc, endpc]; use it when
--                          the read PC falls inside the range.
--   2. NAMECALL target  — the last NAMECALL that wrote to this reg gave
--                          us a method name → "<method>Result".
--   3. Constant binding — if the only def is `LOADK "foo"`, name the
--                          register after the constant text (sanitized).
--   4. Field-from-table — if the only def is `GETTABLEKS B C` where C
--                          is a string K, name after the field.
--   5. Builtin return   — if produced by FASTCALL of a known builtin,
--                          use a name derived from the builtin id
--                          ("math.floor" → "floored").
--   6. Type defaults    — fall back to type-prefixed counters: Number
--                          → n1, n2, …; String → s1, s2, …; etc.
--
-- The resolver builds a per-(protoId, regId) name map; the
-- Decompiler.Emitter substitutes through this map at print time.
-- =====================================================================

local NameResolver = {}
NameResolver.__index = NameResolver

local DEFAULT_TYPE_PREFIX = {
    Number   = "n",
    String   = "s",
    Boolean  = "b",
    Table    = "t",
    Function = "fn",
    Vector   = "v",
    Userdata = "ud",
    Buffer   = "buf",
    Thread   = "co",
    Nil      = "z",
    Any      = "v",
    Top      = "v",
}

local BUILTIN_RESULT_NAMES = {
    ["math.floor"]   = "floored",
    ["math.ceil"]    = "ceiled",
    ["math.round"]   = "rounded",
    ["math.abs"]     = "absVal",
    ["math.sqrt"]    = "sqrtVal",
    ["math.sin"]     = "sinVal",
    ["math.cos"]     = "cosVal",
    ["math.tan"]     = "tanVal",
    ["math.min"]     = "minVal",
    ["math.max"]     = "maxVal",
    ["math.clamp"]   = "clamped",
    ["math.random"] = "randomVal",
    ["math.sign"]    = "signVal",
    ["string.byte"]  = "byteVal",
    ["string.char"]  = "charStr",
    ["string.sub"]   = "subStr",
    ["string.len"]   = "lenVal",
    ["tonumber"]     = "num",
    ["tostring"]     = "str",
    ["type"]         = "typeStr",
    ["typeof"]       = "typeStr",
    ["rawget"]       = "rawValue",
    ["rawlen"]       = "rawLen",
    ["Vector3.new"]  = "vec",
    ["table.unpack"] = "unpacked",
}

local LUA_RESERVED = {
    ["and"] = true, ["break"] = true, ["do"] = true, ["else"] = true,
    ["elseif"] = true, ["end"] = true, ["false"] = true, ["for"] = true,
    ["function"] = true, ["if"] = true, ["in"] = true, ["local"] = true,
    ["nil"] = true, ["not"] = true, ["or"] = true, ["repeat"] = true,
    ["return"] = true, ["then"] = true, ["true"] = true, ["until"] = true,
    ["while"] = true, ["continue"] = true,                            -- Luau
    ["type"] = true,
}

-- ---------------------------------------------------------------------
-- Name sanitization
-- ---------------------------------------------------------------------

local function sanitizeName(s)
    if type(s) ~= "string" or s == "" then return nil end
    -- Strip non-identifier chars
    local out = string.gsub(s, "[^%w_]", "_")
    -- Collapse repeated underscores
    out = string.gsub(out, "_+", "_")
    out = string.gsub(out, "^_+", "")
    out = string.gsub(out, "_+$", "")
    -- Must start with letter or underscore
    if string.match(out, "^%d") then out = "_" .. out end
    if out == "" or LUA_RESERVED[out] then return nil end
    if #out > 32 then out = string.sub(out, 1, 32) end
    return out
end

-- ---------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------

function NameResolver.new(opts)
    opts = opts or {}
    return setmetatable({
        _bytecode      = opts.bytecode,
        _disassembler  = opts.disassembler,
        _typeInferencer = opts.typeInferencer,
        _constProp     = opts.constProp,
        _projectDB     = opts.projectDB,
        _logger        = opts.logger,
        _cache         = {},                                         -- protoId → name map
        _stats = {
            protosResolved = 0,
            namesAssigned  = 0,
            fromDebug      = 0,
            fromConst      = 0,
            fromField      = 0,
            fromNamecall   = 0,
            fromBuiltin    = 0,
            fromTypeDefault = 0,
        },
    }, NameResolver)
end

function NameResolver:setBytecode(bc)         self._bytecode = bc; self._cache = {} end
function NameResolver:setDisassembler(d)      self._disassembler = d; self._cache = {} end
function NameResolver:setTypeInferencer(ti)   self._typeInferencer = ti; self._cache = {} end
function NameResolver:setConstantPropagation(cp) self._constProp = cp end

-- ---------------------------------------------------------------------
-- Debug-info lookup: name whose active range covers (reg, pc)
-- ---------------------------------------------------------------------

local function debugNameAtPc(proto, reg, pc)
    if not proto.debug or not proto.debug.locals then return nil end
    for _, loc in proto.debug.locals do
        if loc.reg == reg and loc.startpc <= pc and loc.endpc >= pc then
            return loc.name
        end
    end
    return nil
end

-- ---------------------------------------------------------------------
-- Per-instruction name hint extractor
--
-- Walks every instruction; for each register *write*, records the best
-- hint we can derive without ambiguous merging.
-- ---------------------------------------------------------------------

local function extractHint(insn, stream)
    local mnem = insn.mnemonic
    if not mnem then return nil end
    local A = insn.a or insn.A
    local Kref = insn.k or insn.K or insn.constant

    if mnem == "LOADK" or mnem == "LOADKX" then
        if Kref and Kref.kind == "string" then
            return { source = "const", text = Kref.value }
        end
        if Kref and Kref.kind == "number" then
            return { source = "const", text = string.format("num%d",
                math.floor(Kref.value)) }
        end
        return nil
    end
    if mnem == "GETTABLEKS" then
        if Kref and Kref.kind == "string" then
            return { source = "field", text = Kref.value }
        end
        return nil
    end
    if mnem == "GETIMPORT" then
        if insn.imports then
            local last = insn.imports[#insn.imports]
            if last then return { source = "field", text = last } end
        end
        return nil
    end
    if mnem == "NAMECALL" then
        if Kref and Kref.kind == "string" then
            return { source = "namecall", text = Kref.value }
        end
        return nil
    end
    if mnem == "FASTCALL" or mnem == "FASTCALL1" or mnem == "FASTCALL2"
        or mnem == "FASTCALL2K" then
        local sig = insn.builtinName
        if sig and BUILTIN_RESULT_NAMES[sig] then
            return { source = "builtin", text = BUILTIN_RESULT_NAMES[sig] }
        end
        return nil
    end
    if mnem == "GETGLOBAL" then
        if Kref and Kref.kind == "string" then
            return { source = "global", text = Kref.value }
        end
        return nil
    end
    if mnem == "NEWTABLE" or mnem == "DUPTABLE" then
        return { source = "newtable", text = "tbl" }
    end
    if mnem == "NEWCLOSURE" or mnem == "DUPCLOSURE" then
        return { source = "newclosure", text = "fn" }
    end
    return nil
end

-- ---------------------------------------------------------------------
-- Resolve for a single proto
-- ---------------------------------------------------------------------

function NameResolver:_resolveProto(protoId)
    if self._cache[protoId] then return self._cache[protoId] end
    local proto = self._bytecode and self._bytecode.protos and self._bytecode.protos[protoId]
    if not proto then return {} end

    local stream = self._disassembler and self._disassembler:disassembleProto(protoId)
    local typeR  = self._typeInferencer and self._typeInferencer:analyse(protoId)

    -- Per-register chosen name. Priority is locked first time we pick.
    local names = {}                                                  -- regId → name
    local sources = {}                                                -- regId → source label

    local used = {}                                                   -- name → count (for uniquification)
    local typeCounters = {}                                           -- prefix → counter

    local function pick(reg, candidate, sourceLabel)
        if not candidate then return end
        local sane = sanitizeName(candidate)
        if not sane then return end
        if names[reg] then return end                                  -- first wins (highest priority)
        local final = sane
        if used[final] then
            used[final] = used[final] + 1
            final = sane .. "_" .. used[final]
        else
            used[final] = 1
        end
        names[reg] = final
        sources[reg] = sourceLabel
        self._stats.namesAssigned = self._stats.namesAssigned + 1
        if sourceLabel == "debug"     then self._stats.fromDebug    = self._stats.fromDebug + 1 end
        if sourceLabel == "const"     then self._stats.fromConst    = self._stats.fromConst + 1 end
        if sourceLabel == "field"     then self._stats.fromField    = self._stats.fromField + 1 end
        if sourceLabel == "namecall"  then self._stats.fromNamecall = self._stats.fromNamecall + 1 end
        if sourceLabel == "builtin"   then self._stats.fromBuiltin  = self._stats.fromBuiltin + 1 end
    end

    -- 1. Parameters: use debug names if present
    if proto.numparams then
        for r = 0, proto.numparams - 1 do
            local dn = debugNameAtPc(proto, r, 0)
            if dn then pick(r, dn, "debug") end
        end
    end

    -- 2. Walk instructions, accumulate hints. We prefer "namecall"
    -- result names over generic "const" names → register pick priority
    -- by ordering: first-pass for namecalls/builtins, second for fields,
    -- third for raw consts.
    local hintsPerReg = {}                                            -- reg → array of {pc, hint}
    if stream and stream.instructions then
        for _, insn in stream.instructions do
            local A = insn.a or insn.A
            if A then
                local hint = extractHint(insn, stream)
                if hint then
                    local arr = hintsPerReg[A]
                    if not arr then arr = {}; hintsPerReg[A] = arr end
                    arr[#arr + 1] = { pc = insn.pc, hint = hint }
                end
                -- Debug-info lookup: register's first def may be inside a
                -- live range whose name is preferred over anything else.
                if not names[A] then
                    local dn = debugNameAtPc(proto, A, insn.pc or 0)
                    if dn then pick(A, dn, "debug") end
                end
            end
        end
    end

    -- 2a. Namecall results first
    for reg, arr in hintsPerReg do
        for _, e in arr do
            if e.hint.source == "namecall" then
                pick(reg, e.hint.text .. "Result", "namecall")
                break
            end
        end
    end
    -- 2b. Builtins
    for reg, arr in hintsPerReg do
        if not names[reg] then
            for _, e in arr do
                if e.hint.source == "builtin" then
                    pick(reg, e.hint.text, "builtin"); break
                end
            end
        end
    end
    -- 2c. Fields (GETTABLEKS / GETIMPORT)
    for reg, arr in hintsPerReg do
        if not names[reg] then
            for _, e in arr do
                if e.hint.source == "field" or e.hint.source == "global" then
                    pick(reg, e.hint.text, "field"); break
                end
            end
        end
    end
    -- 2d. Constant binding
    for reg, arr in hintsPerReg do
        if not names[reg] then
            for _, e in arr do
                if e.hint.source == "const" then
                    pick(reg, e.hint.text, "const"); break
                end
            end
        end
    end
    -- 2e. New table / new closure
    for reg, arr in hintsPerReg do
        if not names[reg] then
            for _, e in arr do
                if e.hint.source == "newtable" then
                    pick(reg, "tbl", "newtable"); break
                elseif e.hint.source == "newclosure" then
                    pick(reg, "callback", "newclosure"); break
                end
            end
        end
    end

    -- 3. Type-driven defaults for everything still unnamed.
    if stream and stream.instructions then
        for _, insn in stream.instructions do
            local A = insn.a or insn.A
            if A and not names[A] then
                local typeKind = K_default_for_reg(typeR, A, insn.pc)
                local prefix   = DEFAULT_TYPE_PREFIX[typeKind] or DEFAULT_TYPE_PREFIX.Any
                typeCounters[prefix] = (typeCounters[prefix] or 0) + 1
                pick(A, prefix .. tostring(typeCounters[prefix]), "typeDefault")
                self._stats.fromTypeDefault = self._stats.fromTypeDefault + 1
            end
        end
    end

    local result = {
        names      = names,
        sources    = sources,
        typeCounters = typeCounters,
    }
    self._cache[protoId] = result
    self._stats.protosResolved = self._stats.protosResolved + 1
    return result
end

function K_default_for_reg(typeR, reg, pc)
    if not typeR then return "Any" end
    local snap = typeR.atPc and typeR.atPc[pc]
    local cell = snap and snap[reg]
    if cell and cell.kind then return cell.kind end
    -- Walk pc backwards a bit to find any known cell
    if typeR.atPc then
        for tryPc = (pc or 1) - 1, math.max(0, (pc or 1) - 8), -1 do
            local s = typeR.atPc[tryPc]
            if s and s[reg] and s[reg].kind then return s[reg].kind end
        end
    end
    return "Any"
end

-- ---------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------

function NameResolver:resolve(protoId)
    return self:_resolveProto(protoId)
end

function NameResolver:resolveAll()
    if not self._bytecode or not self._bytecode.protos then return end
    for protoId in self._bytecode.protos do self:_resolveProto(protoId) end
end

function NameResolver:nameFor(protoId, regId)
    local r = self._cache[protoId]
    if not r then r = self:_resolveProto(protoId) end
    return r.names and r.names[regId]
end

function NameResolver:applyToIR(protoId, ir)
    -- Rewrite IR var nodes with scope="register" by substituting the
    -- resolved name into the `name` field (Emitter prefers `name`).
    local r = self:resolve(protoId)
    if not r or not r.names then return ir end

    local function walk(node)
        if type(node) ~= "table" then return end
        if node.kind == "var" and node.scope == "register" and node.regId
            and r.names[node.regId] then
            node.name = r.names[node.regId]
        end
        for _, k in {"lhs","rhs","operand","value","target","index","fn","self"} do
            if node[k] then walk(node[k]) end
        end
        for _, listKey in {"args","parts","elements","statements","fields","values","targets"} do
            local list = node[listKey]
            if list then
                for _, child in list do walk(child) end
            end
        end
        if node.body then walk(node.body) end
        if node.thenBranch then walk(node.thenBranch) end
        if node.elseBranch then walk(node.elseBranch) end
    end
    walk(ir)
    return ir
end

function NameResolver:invalidate(protoId)
    if protoId then self._cache[protoId] = nil
    else self._cache = {} end
end

function NameResolver:stats()
    return {
        protosResolved   = self._stats.protosResolved,
        namesAssigned    = self._stats.namesAssigned,
        fromDebug        = self._stats.fromDebug,
        fromConst        = self._stats.fromConst,
        fromField        = self._stats.fromField,
        fromNamecall     = self._stats.fromNamecall,
        fromBuiltin      = self._stats.fromBuiltin,
        fromTypeDefault  = self._stats.fromTypeDefault,
        cacheSize        = (function()
            local n = 0
            for _ in self._cache do n = n + 1 end
            return n
        end)(),
    }
end

return NameResolver
