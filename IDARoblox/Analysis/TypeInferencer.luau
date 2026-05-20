--!nonstrict
-- =====================================================================
-- IDARoblox / Analysis / TypeInferencer
-- ---------------------------------------------------------------------
-- Per-register type inference at every PC. Builds on:
--
--   1. Luau v5+ embedded type info (proto.typeinfo, when present) —
--      authoritative for parameter and local types.
--   2. ConstantPropagation results — concrete values imply concrete
--      types (LOADK k="string" → register holds string).
--   3. Operand-shape inference — opcodes carry type information:
--        GETTABLEKS A B C   → B is table
--        NAMECALL   A B C   → B is table, A is a method bound to B
--        FASTCALL2K + builtin id → resolves through BUILTIN_SIGS
--        GETIMPORT  A K aux → resolves the dotted import path
--        ARITH (ADD/SUB/...) → number
--        LENGTH         → number, operand is string|table
--        CONCAT         → string, operands are string|number
--
-- Lattice of TypeCells
--
--   {
--     kind   = "Any" | "Nil" | "Boolean" | "Number" | "String" |
--              "Table" | "Function" | "Userdata" | "Vector" | "Buffer" |
--              "Thread" | "Top" | "Bottom",
--     source = "typeinfo" | "constprop" | "operand-shape" | "builtin-sig"
--              | "propagated" | "default",
--     details = {                                                    -- type-specific
--       table  = { shape = { field → kind }, isArray = bool }
--       function = { params = [kind], returns = [kind], builtinId = ? }
--       string = { length = ?, klass = StringAnalyzer.Class }
--     },
--   }
--
-- The meet operator takes two cells and produces the more-general one
-- (Number ∩ String = Top). Bottom only arises when typeinfo says one
-- type but constprop says another (a bug — surfaced as a warning).
-- =====================================================================

local TypeInferencer = {}
TypeInferencer.__index = TypeInferencer

-- ---------------------------------------------------------------------
-- Type kinds
-- ---------------------------------------------------------------------

TypeInferencer.Kind = table.freeze({
    ANY      = "Any",
    NIL      = "Nil",
    BOOLEAN  = "Boolean",
    NUMBER   = "Number",
    STRING   = "String",
    TABLE    = "Table",
    FUNCTION = "Function",
    USERDATA = "Userdata",
    VECTOR   = "Vector",
    BUFFER   = "Buffer",
    THREAD   = "Thread",
    TOP      = "Top",
    BOTTOM   = "Bottom",
})

local K = TypeInferencer.Kind

local function cellTop()    return { kind = K.TOP, source = "default" } end
local function cellAny()    return { kind = K.ANY, source = "default" } end
local function cellBottom() return { kind = K.BOTTOM, source = "conflict" } end

local function isConcrete(k)
    return k ~= K.TOP and k ~= K.BOTTOM and k ~= K.ANY
end

-- Subtype/compatibility for the meet operator
local function meet(a, b)
    if a == nil then return b end
    if b == nil then return a end
    if a.kind == K.TOP    then return b end
    if b.kind == K.TOP    then return a end
    if a.kind == K.BOTTOM then return a end
    if b.kind == K.BOTTOM then return b end
    if a.kind == K.ANY or b.kind == K.ANY then
        -- Any narrows to the other if the other is concrete
        if a.kind == K.ANY and isConcrete(b.kind) then return b end
        if b.kind == K.ANY and isConcrete(a.kind) then return a end
        return cellAny()
    end
    if a.kind == b.kind then return a end
    return cellBottom()
end

-- ---------------------------------------------------------------------
-- Built-in signatures (Luau fast-call builtin id → return + arg types)
--
-- Builtin ids correspond to the LBF_* enum in luau-lang/luau. The table
-- below covers the most common builtins; unrecognized ids return Any.
-- ---------------------------------------------------------------------

local BUILTIN_SIGS = {
    -- ids from Luau source (subject to version)
    [1]  = { name = "assert",       args = { K.ANY, K.ANY },         returns = { K.ANY } },
    [2]  = { name = "math.abs",     args = { K.NUMBER },             returns = { K.NUMBER } },
    [3]  = { name = "math.acos",    args = { K.NUMBER },             returns = { K.NUMBER } },
    [4]  = { name = "math.asin",    args = { K.NUMBER },             returns = { K.NUMBER } },
    [5]  = { name = "math.atan2",   args = { K.NUMBER, K.NUMBER },   returns = { K.NUMBER } },
    [6]  = { name = "math.atan",    args = { K.NUMBER },             returns = { K.NUMBER } },
    [7]  = { name = "math.ceil",    args = { K.NUMBER },             returns = { K.NUMBER } },
    [8]  = { name = "math.cosh",    args = { K.NUMBER },             returns = { K.NUMBER } },
    [9]  = { name = "math.cos",     args = { K.NUMBER },             returns = { K.NUMBER } },
    [10] = { name = "math.deg",     args = { K.NUMBER },             returns = { K.NUMBER } },
    [11] = { name = "math.exp",     args = { K.NUMBER },             returns = { K.NUMBER } },
    [12] = { name = "math.floor",   args = { K.NUMBER },             returns = { K.NUMBER } },
    [13] = { name = "math.fmod",    args = { K.NUMBER, K.NUMBER },   returns = { K.NUMBER } },
    [14] = { name = "math.frexp",   args = { K.NUMBER },             returns = { K.NUMBER, K.NUMBER } },
    [15] = { name = "math.ldexp",   args = { K.NUMBER, K.NUMBER },   returns = { K.NUMBER } },
    [16] = { name = "math.log10",   args = { K.NUMBER },             returns = { K.NUMBER } },
    [17] = { name = "math.log",     args = { K.NUMBER, K.NUMBER },   returns = { K.NUMBER } },
    [18] = { name = "math.max",     args = { K.NUMBER },             returns = { K.NUMBER } },
    [19] = { name = "math.min",     args = { K.NUMBER },             returns = { K.NUMBER } },
    [20] = { name = "math.modf",    args = { K.NUMBER },             returns = { K.NUMBER, K.NUMBER } },
    [21] = { name = "math.pow",     args = { K.NUMBER, K.NUMBER },   returns = { K.NUMBER } },
    [22] = { name = "math.rad",     args = { K.NUMBER },             returns = { K.NUMBER } },
    [23] = { name = "math.random",  args = { K.NUMBER, K.NUMBER },   returns = { K.NUMBER } },
    [24] = { name = "math.randomseed", args = { K.NUMBER },          returns = {} },
    [25] = { name = "math.sinh",    args = { K.NUMBER },             returns = { K.NUMBER } },
    [26] = { name = "math.sin",     args = { K.NUMBER },             returns = { K.NUMBER } },
    [27] = { name = "math.sqrt",    args = { K.NUMBER },             returns = { K.NUMBER } },
    [28] = { name = "math.tanh",    args = { K.NUMBER },             returns = { K.NUMBER } },
    [29] = { name = "math.tan",     args = { K.NUMBER },             returns = { K.NUMBER } },
    [30] = { name = "bit32.arshift", args = { K.NUMBER, K.NUMBER },  returns = { K.NUMBER } },
    [31] = { name = "bit32.band",   args = { K.NUMBER },             returns = { K.NUMBER } },
    [32] = { name = "bit32.bnot",   args = { K.NUMBER },             returns = { K.NUMBER } },
    [33] = { name = "bit32.bor",    args = { K.NUMBER },             returns = { K.NUMBER } },
    [34] = { name = "bit32.bxor",   args = { K.NUMBER },             returns = { K.NUMBER } },
    [35] = { name = "bit32.btest",  args = { K.NUMBER },             returns = { K.BOOLEAN } },
    [36] = { name = "bit32.extract", args = { K.NUMBER, K.NUMBER },  returns = { K.NUMBER } },
    [37] = { name = "bit32.lrotate", args = { K.NUMBER, K.NUMBER },  returns = { K.NUMBER } },
    [38] = { name = "bit32.lshift", args = { K.NUMBER, K.NUMBER },   returns = { K.NUMBER } },
    [39] = { name = "bit32.replace", args = { K.NUMBER },            returns = { K.NUMBER } },
    [40] = { name = "bit32.rrotate", args = { K.NUMBER, K.NUMBER },  returns = { K.NUMBER } },
    [41] = { name = "bit32.rshift", args = { K.NUMBER, K.NUMBER },   returns = { K.NUMBER } },
    [42] = { name = "type",         args = { K.ANY },                returns = { K.STRING } },
    [43] = { name = "string.byte",  args = { K.STRING, K.NUMBER },   returns = { K.NUMBER } },
    [44] = { name = "string.char",  args = { K.NUMBER },             returns = { K.STRING } },
    [45] = { name = "string.len",   args = { K.STRING },             returns = { K.NUMBER } },
    [46] = { name = "typeof",       args = { K.ANY },                returns = { K.STRING } },
    [47] = { name = "string.sub",   args = { K.STRING, K.NUMBER, K.NUMBER }, returns = { K.STRING } },
    [48] = { name = "math.clamp",   args = { K.NUMBER, K.NUMBER, K.NUMBER }, returns = { K.NUMBER } },
    [49] = { name = "math.sign",    args = { K.NUMBER },             returns = { K.NUMBER } },
    [50] = { name = "math.round",   args = { K.NUMBER },             returns = { K.NUMBER } },
    [54] = { name = "rawset",       args = { K.TABLE, K.ANY, K.ANY }, returns = { K.TABLE } },
    [55] = { name = "rawget",       args = { K.TABLE, K.ANY },       returns = { K.ANY } },
    [56] = { name = "rawequal",     args = { K.ANY, K.ANY },         returns = { K.BOOLEAN } },
    [57] = { name = "rawlen",       args = { K.ANY },                returns = { K.NUMBER } },
    [58] = { name = "table.insert", args = { K.TABLE, K.ANY },       returns = {} },
    [59] = { name = "table.unpack", args = { K.TABLE },              returns = { K.ANY } },
    [60] = { name = "Vector3.new",  args = { K.NUMBER, K.NUMBER, K.NUMBER }, returns = { K.VECTOR } },
    [61] = { name = "tonumber",     args = { K.ANY },                returns = { K.NUMBER } },
    [62] = { name = "tostring",     args = { K.ANY },                returns = { K.STRING } },
}

TypeInferencer.BUILTIN_SIGS = BUILTIN_SIGS

-- ---------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------

function TypeInferencer.new(opts)
    opts = opts or {}
    return setmetatable({
        _disassembler = opts.disassembler,
        _cfgBuilder   = opts.cfgBuilder,
        _bytecode     = opts.bytecode,
        _constProp    = opts.constProp,                              -- ConstantPropagation
        _logger       = opts.logger,
        _cache        = {},
        _stats = {
            protosAnalyzed     = 0,
            cellsProduced      = 0,
            conflictsDetected  = 0,
            typeinfoUsed       = 0,
            constPropAdoptions = 0,
            builtinResolutions = 0,
        },
    }, TypeInferencer)
end

function TypeInferencer:setBytecode(bc)        self._bytecode = bc; self._cache = {} end
function TypeInferencer:setDisassembler(d)     self._disassembler = d; self._cache = {} end
function TypeInferencer:setCFGBuilder(c)       self._cfgBuilder = c; self._cache = {} end
function TypeInferencer:setConstantPropagation(cp) self._constProp = cp end

-- ---------------------------------------------------------------------
-- Seed state from Luau embedded type info
--
-- proto.typeinfo (when v5+ available) carries per-argument and per-local
-- type tags. We seed the entry-state registers with those.
-- ---------------------------------------------------------------------

local TYPEINFO_TAG_TO_KIND = {
    -- These tags come from the Luau encoding (LUAU_BCTAG_TYPEINFO_*)
    [0]  = K.NIL,
    [1]  = K.BOOLEAN,
    [2]  = K.NUMBER,
    [3]  = K.STRING,
    [4]  = K.TABLE,
    [5]  = K.FUNCTION,
    [6]  = K.USERDATA,
    [7]  = K.VECTOR,
    [8]  = K.BUFFER,
    [9]  = K.THREAD,
    [255] = K.ANY,
}

local function seedFromTypeinfo(self, proto)
    local seeded = {}
    if not proto.typeinfo then return seeded end
    local info = proto.typeinfo
    -- typeinfo[1..numParams] = per-param tag
    for r = 0, (info.numParams or 0) - 1 do
        local tag = info.params and info.params[r + 1]
        local kind = TYPEINFO_TAG_TO_KIND[tag or 255] or K.ANY
        seeded[r] = { kind = kind, source = "typeinfo" }
        self._stats.typeinfoUsed = self._stats.typeinfoUsed + 1
    end
    return seeded
end

-- ---------------------------------------------------------------------
-- Per-instruction transfer
-- ---------------------------------------------------------------------

local function transfer(self, state, insn, atPcCp)
    local mnem = insn.mnemonic
    if not mnem then return end
    local A = insn.a or insn.A
    local B = insn.b or insn.B
    local C = insn.c or insn.C
    local Kref = insn.k or insn.K or insn.constant

    -- Loads
    if mnem == "LOADNIL"  then state[A] = { kind = K.NIL,     source = "operand-shape" }; return end
    if mnem == "LOADB"    then state[A] = { kind = K.BOOLEAN, source = "operand-shape" }; return end
    if mnem == "LOADN"    then state[A] = { kind = K.NUMBER,  source = "operand-shape" }; return end
    if mnem == "LOADK" or mnem == "LOADKX" then
        if Kref and Kref.kind then
            local kindMap = {
                string  = K.STRING,
                number  = K.NUMBER,
                boolean = K.BOOLEAN,
                ["nil"] = K.NIL,
                closure = K.FUNCTION,
                vector  = K.VECTOR,
            }
            state[A] = { kind = kindMap[Kref.kind] or K.ANY,
                source = "operand-shape",
                details = (Kref.kind == "string") and { length = #(Kref.value or "") } or nil }
        else state[A] = cellAny() end
        return
    end
    if mnem == "MOVE" then
        state[A] = state[B] and { kind = state[B].kind, source = "propagated",
            details = state[B].details } or cellAny()
        return
    end
    if mnem == "NEWTABLE" or mnem == "DUPTABLE" then
        state[A] = { kind = K.TABLE, source = "operand-shape", details = { shape = {}, isArray = false } }
        return
    end
    if mnem == "NEWCLOSURE" or mnem == "DUPCLOSURE" then
        state[A] = { kind = K.FUNCTION, source = "operand-shape" }
        return
    end
    if mnem == "GETUPVAL" then
        -- Without inter-proto analysis upvalues are Any. Could be refined later.
        state[A] = cellAny(); return
    end
    if mnem == "GETGLOBAL" then
        -- Constant string K is the name of the global; type unknown.
        state[A] = cellAny(); return
    end
    if mnem == "GETIMPORT" then
        -- Imports resolve to Roblox API roots; type unknown (mostly Userdata)
        state[A] = { kind = K.USERDATA, source = "operand-shape" }; return
    end
    if mnem == "GETTABLE" or mnem == "GETTABLEKS" or mnem == "GETTABLEN" then
        -- B is the table register; refine its type retroactively
        if state[B] and state[B].kind ~= K.TABLE then
            -- Don't downgrade; just note via meet
            state[B] = meet(state[B], { kind = K.TABLE, source = "operand-shape" })
        else
            state[B] = state[B] or { kind = K.TABLE, source = "operand-shape" }
        end
        state[A] = cellAny()
        return
    end
    if mnem == "SETTABLE" or mnem == "SETTABLEKS" or mnem == "SETTABLEN" then
        if state[A] and state[A].kind ~= K.TABLE then
            state[A] = meet(state[A], { kind = K.TABLE, source = "operand-shape" })
        else
            state[A] = state[A] or { kind = K.TABLE, source = "operand-shape" }
        end
        return
    end
    if mnem == "NAMECALL" then
        -- B is table, A receives method bound + self in A+1
        state[B] = state[B] or { kind = K.TABLE, source = "operand-shape" }
        state[A] = { kind = K.FUNCTION, source = "operand-shape" }
        return
    end
    if mnem == "CALL" then
        -- Return values land in A..A+C-2; we don't know counts here, mark
        -- A as Any.
        state[A] = cellAny()
        return
    end
    if mnem == "FASTCALL" or mnem == "FASTCALL1" or mnem == "FASTCALL2" or mnem == "FASTCALL2K" then
        local builtinId = insn.builtinId or A
        local sig = BUILTIN_SIGS[builtinId]
        if sig and sig.returns and sig.returns[1] then
            state[insn.targetReg or B] = { kind = sig.returns[1], source = "builtin-sig",
                details = { builtinName = sig.name } }
            self._stats.builtinResolutions = self._stats.builtinResolutions + 1
            return
        end
        if insn.targetReg then state[insn.targetReg] = cellAny() end
        return
    end

    -- Arithmetic always produces number
    local arithOps = { ADD=1,SUB=1,MUL=1,DIV=1,MOD=1,POW=1,IDIV=1,
                       ADDK=1,SUBK=1,MULK=1,DIVK=1,MODK=1,POWK=1,IDIVK=1,
                       SUBRK=1,DIVRK=1,MINUS=1 }
    if arithOps[mnem] then
        state[A] = { kind = K.NUMBER, source = "operand-shape" }
        return
    end
    if mnem == "LENGTH" then
        state[A] = { kind = K.NUMBER, source = "operand-shape" }
        return
    end
    if mnem == "NOT" then
        state[A] = { kind = K.BOOLEAN, source = "operand-shape" }
        return
    end
    if mnem == "CONCAT" then
        state[A] = { kind = K.STRING, source = "operand-shape" }
        return
    end

    -- Comparisons produce booleans where they write back (rare in Luau —
    -- comparisons are usually jump-based, no register write)

    -- ConstantPropagation hint: if CP has a concrete cell at this PC for
    -- register A, we can sharpen the type to match.
    if A and atPcCp then
        local cp = atPcCp[A]
        if cp and cp ~= nil then
            local kindMap = { number = K.NUMBER, string = K.STRING,
                              boolean = K.BOOLEAN, ["nil"] = K.NIL }
            local k = kindMap[cp.kind]
            if k then
                state[A] = { kind = k, source = "constprop" }
                self._stats.constPropAdoptions = self._stats.constPropAdoptions + 1
            end
        end
    end
end

-- ---------------------------------------------------------------------
-- Analyse a single proto
-- ---------------------------------------------------------------------

function TypeInferencer:_analyseProto(protoId)
    if self._cache[protoId] then return self._cache[protoId] end
    if not self._bytecode or not self._bytecode.protos then return {} end
    local proto = self._bytecode.protos[protoId]
    if not proto then return {} end

    local stream = self._disassembler and self._disassembler:disassembleProto(protoId)
    if not stream or not stream.instructions then
        local empty = { atPc = {}, stats = { conflicts = 0, cells = 0 } }
        self._cache[protoId] = empty
        return empty
    end
    local cpResult = self._constProp and self._constProp:analyse(protoId)

    -- Initial state from typeinfo (params)
    local initial = seedFromTypeinfo(self, proto)
    local atPc    = {}
    local state   = {}
    for k, v in initial do state[k] = v end

    local conflicts = 0
    for _, insn in stream.instructions do
        local snap = {}
        for r, cell in state do snap[r] = cell end
        atPc[insn.pc or 0] = snap
        local atPcCp = cpResult and cpResult.atPc[insn.pc or 0]
        transfer(self, state, insn, atPcCp)
        -- Conflict detection: if a write produces a cell whose kind
        -- contradicts an explicit typeinfo on a local at the same reg,
        -- emit a conflict marker.
        local writtenReg = insn.a or insn.A
        if writtenReg and proto.typeinfo and proto.typeinfo.locals then
            local localTag = proto.typeinfo.locals[writtenReg + 1]
            if localTag then
                local expected = TYPEINFO_TAG_TO_KIND[localTag]
                local got = state[writtenReg]
                if expected and got and isConcrete(got.kind)
                    and expected ~= K.ANY and got.kind ~= expected then
                    conflicts = conflicts + 1
                end
            end
        end
        self._stats.cellsProduced = self._stats.cellsProduced + 1
    end

    local result = {
        atPc  = atPc,
        finalState = state,
        stats = {
            conflicts = conflicts,
            cells     = self._stats.cellsProduced,
        },
    }
    if conflicts > 0 then
        self._stats.conflictsDetected = self._stats.conflictsDetected + conflicts
    end
    self._cache[protoId] = result
    self._stats.protosAnalyzed = self._stats.protosAnalyzed + 1
    return result
end

-- ---------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------

function TypeInferencer:analyse(protoId)    return self:_analyseProto(protoId) end
function TypeInferencer:analyseAll()
    if not self._bytecode or not self._bytecode.protos then return end
    for protoId in self._bytecode.protos do self:_analyseProto(protoId) end
end

function TypeInferencer:getCell(protoId, pc, reg)
    local p = self._cache[protoId]
    if not p then return nil end
    local snap = p.atPc[pc]
    if not snap then return nil end
    return snap[reg]
end

function TypeInferencer:invalidate(protoId)
    if protoId then self._cache[protoId] = nil
    else self._cache = {} end
end

function TypeInferencer:stats()
    return {
        protosAnalyzed     = self._stats.protosAnalyzed,
        cellsProduced      = self._stats.cellsProduced,
        conflictsDetected  = self._stats.conflictsDetected,
        typeinfoUsed       = self._stats.typeinfoUsed,
        constPropAdoptions = self._stats.constPropAdoptions,
        builtinResolutions = self._stats.builtinResolutions,
        cacheSize          = (function()
            local n = 0
            for _ in self._cache do n = n + 1 end
            return n
        end)(),
    }
end

return TypeInferencer
