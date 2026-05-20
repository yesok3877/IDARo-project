--!nonstrict
-- =====================================================================
-- IDARoblox / Analysis / OpcodeTable
-- ---------------------------------------------------------------------
-- Canonical metadata for every Luau opcode (LOP_*) covering bytecode
-- versions 3 through 6 — every opcode the current Roblox VM can emit.
--
-- The disassembler and decompiler consume this table to:
--   * decode instruction words into operand tuples
--   * resolve K-table references (via K mode)
--   * follow control flow (via flow type)
--   * format instructions for display
--   * reason about side effects when lifting
--
-- Encoding reference (Luau is a 32-bit register VM):
--
--   ABC format:   [opcode:8] [A:8] [B:8] [C:8]
--   AD  format:   [opcode:8] [A:8] [D:16 signed]
--   E   format:   [opcode:8] [E:24 signed]
--
-- Some instructions consume a following 32-bit AUX word. The `aux` field
-- declares this; `kmode` declares how a constant index is encoded (in C,
-- D, or AUX), if at all.
-- =====================================================================

local OpcodeTable = {}

-- ---------------------------------------------------------------------
-- Bytecode version envelope
-- ---------------------------------------------------------------------

OpcodeTable.LBC_VERSION_MIN      = 3
OpcodeTable.LBC_VERSION_MAX      = 6
OpcodeTable.LBC_TYPE_VERSION_MIN = 1
OpcodeTable.LBC_TYPE_VERSION_MAX = 3

-- ---------------------------------------------------------------------
-- Constant tags (LBC_CONSTANT_*)
-- ---------------------------------------------------------------------

OpcodeTable.Constant = {
    NIL     = 0,
    BOOLEAN = 1,
    NUMBER  = 2,
    STRING  = 3,
    IMPORT  = 4,
    TABLE   = 5,
    CLOSURE = 6,
    VECTOR  = 7,
}
OpcodeTable.ConstantName = {
    [0] = "NIL", [1] = "BOOLEAN", [2] = "NUMBER", [3] = "STRING",
    [4] = "IMPORT", [5] = "TABLE", [6] = "CLOSURE", [7] = "VECTOR",
}

-- ---------------------------------------------------------------------
-- Capture types (used by LOP_CAPTURE)
-- ---------------------------------------------------------------------

OpcodeTable.Capture = {
    VAL   = 0,                                                      -- by-value capture (immutable)
    REF   = 1,                                                      -- by-reference (mutable)
    UPVAL = 2,                                                      -- from outer upvalue
}
OpcodeTable.CaptureName = { [0] = "VAL", [1] = "REF", [2] = "UPVAL" }

-- ---------------------------------------------------------------------
-- Proto flags (Luau's LPF_*)
-- ---------------------------------------------------------------------

OpcodeTable.ProtoFlag = {
    NATIVE_MODULE   = 0x01,                                         -- @native module
    NATIVE_COLD     = 0x02,                                         -- skip native compilation
    NATIVE_FUNCTION = 0x04,                                         -- @native function
}

-- ---------------------------------------------------------------------
-- Builtin IDs (the FASTCALL targets). This is the canonical list as of
-- current Luau. The disassembler uses this to render FASTCALL hints.
-- ---------------------------------------------------------------------

OpcodeTable.Builtin = {
    [1]  = "assert",
    [2]  = "math.abs",   [3]  = "math.acos",  [4]  = "math.asin", [5]  = "math.atan2",
    [6]  = "math.atan",  [7]  = "math.ceil",  [8]  = "math.cosh", [9]  = "math.cos",
    [10] = "math.deg",   [11] = "math.exp",   [12] = "math.floor",[13] = "math.fmod",
    [14] = "math.frexp", [15] = "math.ldexp", [16] = "math.log10",[17] = "math.log",
    [18] = "math.max",   [19] = "math.min",   [20] = "math.modf", [21] = "math.pow",
    [22] = "math.rad",   [23] = "math.sinh",  [24] = "math.sin",  [25] = "math.sqrt",
    [26] = "math.tanh",  [27] = "math.tan",
    [28] = "bit32.arshift", [29] = "bit32.band", [30] = "bit32.bnot", [31] = "bit32.bor",
    [32] = "bit32.bxor", [33] = "bit32.btest", [34] = "bit32.extract", [35] = "bit32.lrotate",
    [36] = "bit32.lshift", [37] = "bit32.replace", [38] = "bit32.rrotate", [39] = "bit32.rshift",
    [40] = "type",
    [41] = "string.byte", [42] = "string.char", [43] = "string.len",
    [44] = "typeof",
    [45] = "string.sub",
    [46] = "math.clamp", [47] = "math.sign", [48] = "math.round",
    [49] = "rawset", [50] = "rawget", [51] = "rawequal",
    [52] = "table.insert", [53] = "table.unpack",
    [54] = "Vector3.new", [55] = "Vector2.new", [56] = "CFrame.new",
    [57] = "bit32.countlz", [58] = "bit32.countrz",
    [59] = "select",
    [60] = "rawlen",
    [61] = "bit32.extractk",                                        -- alias
    [62] = "getmetatable",
    [63] = "setmetatable",
    [64] = "tonumber", [65] = "tostring",
    [66] = "bit32.byteswap",
    [67] = "buffer.readi8", [68] = "buffer.readu8", [69] = "buffer.writeu8",
    [70] = "buffer.readi16", [71] = "buffer.readu16", [72] = "buffer.writeu16",
    [73] = "buffer.readi32", [74] = "buffer.readu32", [75] = "buffer.writeu32",
    [76] = "buffer.readf32", [77] = "buffer.writef32",
    [78] = "buffer.readf64", [79] = "buffer.writef64",
    [80] = "vector.create", [81] = "vector.magnitude", [82] = "vector.normalize",
    [83] = "vector.cross", [84] = "vector.dot",
    [85] = "vector.floor", [86] = "vector.ceil", [87] = "vector.abs",
    [88] = "vector.sign", [89] = "vector.clamp",
    [90] = "vector.max", [91] = "vector.min",
}

-- ---------------------------------------------------------------------
-- Opcode IDs (LOP_*). Numbering matches the Luau VM, do not reorder.
-- ---------------------------------------------------------------------

local Op = {
    NOP            = 0,
    BREAK          = 1,
    LOADNIL        = 2,
    LOADB          = 3,
    LOADN          = 4,
    LOADK          = 5,
    MOVE           = 6,
    GETGLOBAL      = 7,
    SETGLOBAL      = 8,
    GETUPVAL       = 9,
    SETUPVAL       = 10,
    CLOSEUPVALS    = 11,
    GETIMPORT      = 12,
    GETTABLE       = 13,
    SETTABLE       = 14,
    GETTABLEKS     = 15,
    SETTABLEKS     = 16,
    GETTABLEN      = 17,
    SETTABLEN      = 18,
    NEWCLOSURE     = 19,
    NAMECALL       = 20,
    CALL           = 21,
    RETURN         = 22,
    JUMP           = 23,
    JUMPBACK       = 24,
    JUMPIF         = 25,
    JUMPIFNOT      = 26,
    JUMPIFEQ       = 27,
    JUMPIFLE       = 28,
    JUMPIFLT       = 29,
    JUMPIFNOTEQ    = 30,
    JUMPIFNOTLE    = 31,
    JUMPIFNOTLT    = 32,
    ADD            = 33,
    SUB            = 34,
    MUL            = 35,
    DIV            = 36,
    MOD            = 37,
    POW            = 38,
    ADDK           = 39,
    SUBK           = 40,
    MULK           = 41,
    DIVK           = 42,
    MODK           = 43,
    POWK           = 44,
    AND            = 45,
    OR             = 46,
    ANDK           = 47,
    ORK            = 48,
    CONCAT         = 49,
    NOT            = 50,
    MINUS          = 51,
    LENGTH         = 52,
    NEWTABLE       = 53,
    DUPTABLE       = 54,
    SETLIST        = 55,
    FORNPREP       = 56,
    FORNLOOP       = 57,
    FORGLOOP       = 58,
    FORGPREP_INEXT = 59,
    FASTCALL3      = 60,                                            -- (older slot held by deprecated opcode)
    FORGPREP_NEXT  = 61,
    NATIVECALL     = 62,                                            -- (older slot held by deprecated opcode)
    GETVARARGS     = 63,
    DUPCLOSURE     = 64,
    PREPVARARGS    = 65,
    LOADKX         = 66,
    JUMPX          = 67,
    FASTCALL       = 68,
    COVERAGE       = 69,
    CAPTURE        = 70,
    SUBRK          = 71,
    DIVRK          = 72,
    FASTCALL1      = 73,
    FASTCALL2      = 74,
    FASTCALL2K     = 75,
    FORGPREP       = 76,
    JUMPXEQKNIL    = 77,
    JUMPXEQKB      = 78,
    JUMPXEQKN      = 79,
    JUMPXEQKS      = 80,
    IDIV           = 81,
    IDIVK          = 82,
}
OpcodeTable.Op = Op

-- Reverse lookup id → name
local Name = {}
for k, v in Op do Name[v] = k end
OpcodeTable.Name = Name

-- ---------------------------------------------------------------------
-- Per-opcode metadata
-- ---------------------------------------------------------------------
-- Fields:
--   name   : mnemonic
--   fmt    : "ABC" | "AD" | "E"
--   aux    : true if a 32-bit AUX word follows
--   kmode  : "none" | "aux" | "c" | "d" | "import"
--   flow   : "fall" | "jump" | "branch" | "back" | "return" | "loop" | "call"
--   side   : set of effect tags
--   desc   : short description
-- ---------------------------------------------------------------------

local M = {}
OpcodeTable.Meta = M

local function meta(id, name, fmt, aux, kmode, flow, sideArr, desc)
    local side = {}
    for _, s in sideArr do side[s] = true end
    M[id] = {
        id     = id,
        name   = name,
        fmt    = fmt,
        aux    = aux,
        kmode  = kmode,
        flow   = flow,
        side   = side,
        desc   = desc,
    }
end

meta(Op.NOP,            "NOP",            "ABC", false, "none",   "fall",   {},                              "no operation")
meta(Op.BREAK,          "BREAK",          "ABC", false, "none",   "fall",   { "break" },                     "debugger breakpoint trap")
meta(Op.LOADNIL,        "LOADNIL",        "ABC", false, "none",   "fall",   { "wr" },                        "R(A) := nil")
meta(Op.LOADB,          "LOADB",          "ABC", false, "none",   "fall",   { "wr" },                        "R(A) := bool(B); if C ~= 0 then PC += C")
meta(Op.LOADN,          "LOADN",          "AD",  false, "none",   "fall",   { "wr" },                        "R(A) := int16(D)")
meta(Op.LOADK,          "LOADK",          "AD",  false, "d",      "fall",   { "wr", "rk" },                  "R(A) := K(D)")
meta(Op.MOVE,           "MOVE",           "ABC", false, "none",   "fall",   { "wr", "rr" },                  "R(A) := R(B)")
meta(Op.GETGLOBAL,      "GETGLOBAL",      "ABC", true,  "aux",    "fall",   { "wr", "rg", "rk" },            "R(A) := _G[K(AUX)]")
meta(Op.SETGLOBAL,      "SETGLOBAL",      "ABC", true,  "aux",    "fall",   { "rr", "wg", "rk" },            "_G[K(AUX)] := R(A)")
meta(Op.GETUPVAL,       "GETUPVAL",       "ABC", false, "none",   "fall",   { "wr", "ru" },                  "R(A) := upval(B)")
meta(Op.SETUPVAL,       "SETUPVAL",       "ABC", false, "none",   "fall",   { "rr", "wu" },                  "upval(B) := R(A)")
meta(Op.CLOSEUPVALS,    "CLOSEUPVALS",    "ABC", false, "none",   "fall",   { "cu" },                        "close all upvals at R(A) and above")
meta(Op.GETIMPORT,      "GETIMPORT",      "AD",  true,  "import", "fall",   { "wr", "ri", "rk" },            "R(A) := resolve_import(AUX)")
meta(Op.GETTABLE,       "GETTABLE",       "ABC", false, "none",   "fall",   { "wr", "rt", "rr" },            "R(A) := R(B)[R(C)]")
meta(Op.SETTABLE,       "SETTABLE",       "ABC", false, "none",   "fall",   { "wt", "rr" },                  "R(B)[R(C)] := R(A)")
meta(Op.GETTABLEKS,     "GETTABLEKS",     "ABC", true,  "aux",    "fall",   { "wr", "rt", "rk" },            "R(A) := R(B)[K(AUX)]")
meta(Op.SETTABLEKS,     "SETTABLEKS",     "ABC", true,  "aux",    "fall",   { "wt", "rr", "rk" },            "R(B)[K(AUX)] := R(A)")
meta(Op.GETTABLEN,      "GETTABLEN",      "ABC", false, "none",   "fall",   { "wr", "rt" },                  "R(A) := R(B)[C+1]")
meta(Op.SETTABLEN,      "SETTABLEN",      "ABC", false, "none",   "fall",   { "wt", "rr" },                  "R(B)[C+1] := R(A)")
meta(Op.NEWCLOSURE,     "NEWCLOSURE",     "AD",  false, "none",   "fall",   { "wr", "alloc" },               "R(A) := closure(p[D])")
meta(Op.NAMECALL,       "NAMECALL",       "ABC", true,  "aux",    "fall",   { "wr", "rr", "rk" },            "R(A+1) := R(B); R(A) := R(B)[K(AUX)]")
meta(Op.CALL,           "CALL",           "ABC", false, "none",   "call",   { "call" },                      "R(A..A+C-2) := R(A)(R(A+1..A+B-1))")
meta(Op.RETURN,         "RETURN",         "ABC", false, "none",   "return", { "ret" },                       "return R(A..A+B-2)")
meta(Op.JUMP,           "JUMP",           "AD",  false, "none",   "jump",   { "cf" },                        "PC += D")
meta(Op.JUMPBACK,       "JUMPBACK",       "AD",  false, "none",   "back",   { "cf", "intr" },                "PC += D (with interrupt poll)")
meta(Op.JUMPIF,         "JUMPIF",         "AD",  false, "none",   "branch", { "rr", "cf" },                  "if R(A) then PC += D")
meta(Op.JUMPIFNOT,      "JUMPIFNOT",      "AD",  false, "none",   "branch", { "rr", "cf" },                  "if not R(A) then PC += D")
meta(Op.JUMPIFEQ,       "JUMPIFEQ",       "AD",  true,  "none",   "branch", { "rr", "cf" },                  "if R(A) == R(AUX) then PC += D")
meta(Op.JUMPIFLE,       "JUMPIFLE",       "AD",  true,  "none",   "branch", { "rr", "cf" },                  "if R(A) <= R(AUX) then PC += D")
meta(Op.JUMPIFLT,       "JUMPIFLT",       "AD",  true,  "none",   "branch", { "rr", "cf" },                  "if R(A) < R(AUX) then PC += D")
meta(Op.JUMPIFNOTEQ,    "JUMPIFNOTEQ",    "AD",  true,  "none",   "branch", { "rr", "cf" },                  "if R(A) ~= R(AUX) then PC += D")
meta(Op.JUMPIFNOTLE,    "JUMPIFNOTLE",    "AD",  true,  "none",   "branch", { "rr", "cf" },                  "if not (R(A) <= R(AUX)) then PC += D")
meta(Op.JUMPIFNOTLT,    "JUMPIFNOTLT",    "AD",  true,  "none",   "branch", { "rr", "cf" },                  "if not (R(A) < R(AUX)) then PC += D")
meta(Op.ADD,            "ADD",            "ABC", false, "none",   "fall",   { "wr", "rr", "arith" },         "R(A) := R(B) + R(C)")
meta(Op.SUB,            "SUB",            "ABC", false, "none",   "fall",   { "wr", "rr", "arith" },         "R(A) := R(B) - R(C)")
meta(Op.MUL,            "MUL",            "ABC", false, "none",   "fall",   { "wr", "rr", "arith" },         "R(A) := R(B) * R(C)")
meta(Op.DIV,            "DIV",            "ABC", false, "none",   "fall",   { "wr", "rr", "arith" },         "R(A) := R(B) / R(C)")
meta(Op.MOD,            "MOD",            "ABC", false, "none",   "fall",   { "wr", "rr", "arith" },         "R(A) := R(B) % R(C)")
meta(Op.POW,            "POW",            "ABC", false, "none",   "fall",   { "wr", "rr", "arith" },         "R(A) := R(B) ^ R(C)")
meta(Op.ADDK,           "ADDK",           "ABC", false, "c",      "fall",   { "wr", "rr", "rk", "arith" },   "R(A) := R(B) + K(C)")
meta(Op.SUBK,           "SUBK",           "ABC", false, "c",      "fall",   { "wr", "rr", "rk", "arith" },   "R(A) := R(B) - K(C)")
meta(Op.MULK,           "MULK",           "ABC", false, "c",      "fall",   { "wr", "rr", "rk", "arith" },   "R(A) := R(B) * K(C)")
meta(Op.DIVK,           "DIVK",           "ABC", false, "c",      "fall",   { "wr", "rr", "rk", "arith" },   "R(A) := R(B) / K(C)")
meta(Op.MODK,           "MODK",           "ABC", false, "c",      "fall",   { "wr", "rr", "rk", "arith" },   "R(A) := R(B) % K(C)")
meta(Op.POWK,           "POWK",           "ABC", false, "c",      "fall",   { "wr", "rr", "rk", "arith" },   "R(A) := R(B) ^ K(C)")
meta(Op.AND,            "AND",            "ABC", false, "none",   "fall",   { "wr", "rr", "logic" },         "R(A) := R(B) and R(C)")
meta(Op.OR,             "OR",             "ABC", false, "none",   "fall",   { "wr", "rr", "logic" },         "R(A) := R(B) or R(C)")
meta(Op.ANDK,           "ANDK",           "ABC", false, "c",      "fall",   { "wr", "rr", "rk", "logic" },   "R(A) := R(B) and K(C)")
meta(Op.ORK,            "ORK",            "ABC", false, "c",      "fall",   { "wr", "rr", "rk", "logic" },   "R(A) := R(B) or K(C)")
meta(Op.CONCAT,         "CONCAT",         "ABC", false, "none",   "fall",   { "wr", "rr", "concat" },        "R(A) := R(B) .. ... .. R(C)")
meta(Op.NOT,            "NOT",            "ABC", false, "none",   "fall",   { "wr", "rr", "logic" },         "R(A) := not R(B)")
meta(Op.MINUS,          "MINUS",          "ABC", false, "none",   "fall",   { "wr", "rr", "arith" },         "R(A) := -R(B)")
meta(Op.LENGTH,         "LENGTH",         "ABC", false, "none",   "fall",   { "wr", "rr", "len" },           "R(A) := #R(B)")
meta(Op.NEWTABLE,       "NEWTABLE",       "ABC", true,  "none",   "fall",   { "wr", "alloc" },               "R(A) := { } (with hash size hint=B, array size hint=AUX)")
meta(Op.DUPTABLE,       "DUPTABLE",       "AD",  false, "d",      "fall",   { "wr", "rk", "alloc" },         "R(A) := dup(K(D))")
meta(Op.SETLIST,        "SETLIST",        "ABC", true,  "none",   "fall",   { "wt", "rr" },                  "R(A)[AUX+i-1] := R(B+i-1) for i in 1..C-1")
meta(Op.FORNPREP,       "FORNPREP",       "AD",  false, "none",   "branch", { "rr", "cf" },                  "numeric for prep; if non-iterable jump PC+=D")
meta(Op.FORNLOOP,       "FORNLOOP",       "AD",  false, "none",   "loop",   { "rr", "cf", "intr" },          "numeric for step; if continuing PC+=D")
meta(Op.FORGLOOP,       "FORGLOOP",       "AD",  true,  "none",   "loop",   { "rr", "wr", "cf", "intr" },    "generic for step; AUX has count|flags")
meta(Op.FORGPREP_INEXT, "FORGPREP_INEXT", "AD",  false, "none",   "branch", { "rr", "cf" },                  "generic for prep (ipairs-style)")
meta(Op.FASTCALL3,      "FASTCALL3",      "ABC", true,  "none",   "fall",   { "fastcall" },                  "fast-path 3-arg builtin")
meta(Op.FORGPREP_NEXT,  "FORGPREP_NEXT",  "AD",  false, "none",   "branch", { "rr", "cf" },                  "generic for prep (pairs-style)")
meta(Op.NATIVECALL,     "NATIVECALL",     "ABC", false, "none",   "fall",   { "native" },                    "native code call hint")
meta(Op.GETVARARGS,     "GETVARARGS",     "ABC", false, "none",   "fall",   { "wr", "varargs" },             "R(A..A+B-2) := vararg")
meta(Op.DUPCLOSURE,     "DUPCLOSURE",     "AD",  false, "d",      "fall",   { "wr", "rk", "alloc" },         "R(A) := closure-dup(K(D))")
meta(Op.PREPVARARGS,    "PREPVARARGS",    "ABC", false, "none",   "fall",   { "varargs" },                   "store varargs (A=numparams)")
meta(Op.LOADKX,         "LOADKX",         "ABC", true,  "aux",    "fall",   { "wr", "rk" },                  "R(A) := K(AUX)  (extended k-index)")
meta(Op.JUMPX,          "JUMPX",          "E",   false, "none",   "jump",   { "cf" },                        "PC += E (24-bit offset)")
meta(Op.FASTCALL,       "FASTCALL",       "ABC", false, "none",   "fall",   { "fastcall" },                  "fast-path builtin call (A=builtin, C=skip)")
meta(Op.COVERAGE,       "COVERAGE",       "E",   false, "none",   "fall",   { "cov" },                       "coverage hit counter")
meta(Op.CAPTURE,        "CAPTURE",        "ABC", false, "none",   "fall",   { "capture" },                   "closure capture: A=type, B=reg/upval")
meta(Op.SUBRK,          "SUBRK",          "ABC", false, "b",      "fall",   { "wr", "rr", "rk", "arith" },   "R(A) := K(B) - R(C)  (reversed)")
meta(Op.DIVRK,          "DIVRK",          "ABC", false, "b",      "fall",   { "wr", "rr", "rk", "arith" },   "R(A) := K(B) / R(C)  (reversed)")
meta(Op.FASTCALL1,      "FASTCALL1",      "ABC", false, "none",   "fall",   { "fastcall" },                  "1-arg fast builtin (B=arg)")
meta(Op.FASTCALL2,      "FASTCALL2",      "ABC", true,  "none",   "fall",   { "fastcall" },                  "2-arg fast builtin (B=arg1, AUX=arg2)")
meta(Op.FASTCALL2K,     "FASTCALL2K",     "ABC", true,  "aux",    "fall",   { "fastcall", "rk" },            "2-arg fast builtin (B=arg1, AUX=K idx)")
meta(Op.FORGPREP,       "FORGPREP",       "AD",  false, "none",   "branch", { "rr", "cf" },                  "generic for prep (general iterator)")
meta(Op.JUMPXEQKNIL,    "JUMPXEQKNIL",    "AD",  true,  "aux",    "branch", { "rr", "cf" },                  "fast eq-nil branch (AUX flag bit)")
meta(Op.JUMPXEQKB,      "JUMPXEQKB",      "AD",  true,  "aux",    "branch", { "rr", "cf", "rk" },            "fast eq-bool branch (AUX flag+value)")
meta(Op.JUMPXEQKN,      "JUMPXEQKN",      "AD",  true,  "aux",    "branch", { "rr", "cf", "rk" },            "fast eq-number branch (AUX flag|K idx)")
meta(Op.JUMPXEQKS,      "JUMPXEQKS",      "AD",  true,  "aux",    "branch", { "rr", "cf", "rk" },            "fast eq-string branch (AUX flag|K idx)")
meta(Op.IDIV,           "IDIV",           "ABC", false, "none",   "fall",   { "wr", "rr", "arith" },         "R(A) := R(B) // R(C)")
meta(Op.IDIVK,          "IDIVK",          "ABC", false, "c",      "fall",   { "wr", "rr", "rk", "arith" },   "R(A) := R(B) // K(C)")

-- ---------------------------------------------------------------------
-- Instruction-decoding helpers
-- ---------------------------------------------------------------------
-- These work on any 32-bit instruction word and the format hint.
-- ---------------------------------------------------------------------

local band, rshift = bit32.band, bit32.rshift

function OpcodeTable.decodeOp(insn: number): number
    return band(insn, 0xFF)
end

function OpcodeTable.decodeA(insn: number): number
    return band(rshift(insn, 8), 0xFF)
end

function OpcodeTable.decodeABC(insn: number): (number, number, number, number)
    local op = band(insn, 0xFF)
    local a  = band(rshift(insn, 8),  0xFF)
    local b  = band(rshift(insn, 16), 0xFF)
    local c  = band(rshift(insn, 24), 0xFF)
    return op, a, b, c
end

function OpcodeTable.decodeAD(insn: number): (number, number, number)
    local op = band(insn, 0xFF)
    local a  = band(rshift(insn, 8), 0xFF)
    local d  = band(rshift(insn, 16), 0xFFFF)
    if d >= 0x8000 then d = d - 0x10000 end                         -- sign-extend 16-bit
    return op, a, d
end

function OpcodeTable.decodeE(insn: number): (number, number)
    local op = band(insn, 0xFF)
    local e  = band(rshift(insn, 8), 0xFFFFFF)
    if e >= 0x800000 then e = e - 0x1000000 end                     -- sign-extend 24-bit
    return op, e
end

-- Decode a complete instruction along with the (optional) AUX word that
-- may follow it. Returns a structured row whose shape depends on `fmt`:
--   ABC: { op, name, fmt, a, b, c, aux? }
--   AD:  { op, name, fmt, a, d, aux? }
--   E:   { op, name, fmt, e, aux? }
-- For unknown opcodes the metadata is filled in best-effort and a
-- `.unknown = true` flag is set.

function OpcodeTable.decodeInstruction(insn: number, auxWord: number?): { [string]: any }
    local op = band(insn, 0xFF)
    local m = M[op]
    if not m then
        return { op = op, name = ("OP_%d"):format(op), fmt = "ABC", unknown = true,
                 a = band(rshift(insn, 8), 0xFF),
                 b = band(rshift(insn, 16), 0xFF),
                 c = band(rshift(insn, 24), 0xFF),
                 aux = auxWord }
    end
    if m.fmt == "ABC" then
        local _, a, b, c = OpcodeTable.decodeABC(insn)
        return { op = op, name = m.name, fmt = "ABC", a = a, b = b, c = c, aux = if m.aux then auxWord else nil }
    elseif m.fmt == "AD" then
        local _, a, d = OpcodeTable.decodeAD(insn)
        return { op = op, name = m.name, fmt = "AD", a = a, d = d, aux = if m.aux then auxWord else nil }
    else -- E
        local _, e = OpcodeTable.decodeE(insn)
        return { op = op, name = m.name, fmt = "E", e = e, aux = if m.aux then auxWord else nil }
    end
end

-- Whether this opcode consumes the next 32-bit word as AUX.
function OpcodeTable.hasAux(op: number): boolean
    local m = M[op]
    return m and m.aux == true or false
end

-- Width in 32-bit words (instruction itself + optional AUX).
function OpcodeTable.width(op: number): number
    return OpcodeTable.hasAux(op) and 2 or 1
end

-- Walk an instruction array, yielding (pc, insn, aux, meta) for each
-- logical instruction. Honors AUX consumption — the next iteration
-- skips the AUX word.
function OpcodeTable.iterate(instructions: { number })
    local i = 1
    local n = #instructions
    return function()
        if i > n then return nil end
        local insn = instructions[i]
        local op = band(insn, 0xFF)
        local m = M[op]
        local aux: number? = nil
        if m and m.aux and i + 1 <= n then
            aux = instructions[i + 1]
            local pc = i
            i = i + 2
            return pc, insn, aux, m
        else
            local pc = i
            i = i + 1
            return pc, insn, aux, m
        end
    end
end

-- ---------------------------------------------------------------------
-- Import-id decoding
-- ---------------------------------------------------------------------
-- Encoded form (32-bit):
--   [count:2][id0:10][id1:10][id2:10]
-- Each id is an index into the proto's k-table; the constant there is a
-- STRING and gives the segment name (e.g. "game", "Players").

function OpcodeTable.decodeImportId(id: number): (number, number, number, number)
    local count = band(rshift(id, 30), 0x3)
    local id0   = band(rshift(id, 20), 0x3FF)
    local id1   = band(rshift(id, 10), 0x3FF)
    local id2   = band(id, 0x3FF)
    return count, id0, id1, id2
end

-- Resolve an encoded import id against a proto's constants + the string
-- table. Returns an array of 1..3 strings (the dotted path segments),
-- empty array if resolution fails.
function OpcodeTable.resolveImportChain(encodedId, protoConstants, stringTable): { string }
    local count, i0, i1, i2 = OpcodeTable.decodeImportId(encodedId)
    local chain = {}
    local function resolveSegment(kIdx)
        local k = protoConstants[kIdx + 1]                          -- 1-based proto k table
        if not k or k.tag ~= "STRING" then return nil end
        local s = stringTable[k.stringId]
        return s
    end
    if count >= 1 then chain[1] = resolveSegment(i0) end
    if count >= 2 then chain[2] = resolveSegment(i1) end
    if count >= 3 then chain[3] = resolveSegment(i2) end
    return chain
end

-- ---------------------------------------------------------------------
-- Convenience predicates used by the CFG builder (Step 6) and the
-- decompiler structural-recovery pass (Step 8).
-- ---------------------------------------------------------------------

function OpcodeTable.isJump(op: number): boolean
    local m = M[op]
    return m and (m.flow == "jump" or m.flow == "back" or m.flow == "branch" or m.flow == "loop") or false
end

function OpcodeTable.isConditionalJump(op: number): boolean
    local m = M[op]
    return m and (m.flow == "branch" or m.flow == "loop") or false
end

function OpcodeTable.isUnconditionalJump(op: number): boolean
    local m = M[op]
    return m and (m.flow == "jump" or m.flow == "back") or false
end

function OpcodeTable.isReturn(op: number): boolean
    local m = M[op]
    return m and m.flow == "return" or false
end

function OpcodeTable.isCall(op: number): boolean
    local m = M[op]
    return m and m.flow == "call" or false
end

function OpcodeTable.isTerminator(op: number): boolean
    -- A terminator ends a basic block.
    return OpcodeTable.isJump(op) or OpcodeTable.isReturn(op) or OpcodeTable.isCall(op)
end

-- Jump-offset extractor — returns the absolute target PC, or nil if the
-- instruction isn't a jump. Argument `pc` is the PC of the jump itself
-- (1-based, instruction-word index, NOT byte offset).
function OpcodeTable.jumpTarget(insn: number, pc: number): number?
    local m = M[band(insn, 0xFF)]
    if not m then return nil end
    if m.fmt == "AD" and (m.flow == "jump" or m.flow == "back" or m.flow == "branch" or m.flow == "loop") then
        local _, _, d = OpcodeTable.decodeAD(insn)
        -- A jump's target is PC+1+D (the +1 accounts for advancing past the
        -- jump). When an AUX word is present, the next-PC is +2, and Luau's
        -- D is measured from that point. We honor `aux` here.
        local stride = m.aux and 2 or 1
        return pc + stride + d
    elseif m.fmt == "E" and m.flow == "jump" then
        local _, e = OpcodeTable.decodeE(insn)
        return pc + 1 + e
    end
    return nil
end

return OpcodeTable
