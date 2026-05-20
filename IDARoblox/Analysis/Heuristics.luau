--!nonstrict
-- =====================================================================
-- IDARoblox / Analysis / Heuristics
-- ---------------------------------------------------------------------
-- Built-in pattern library. Each Heuristics.<group>.* entry is a
-- pattern as defined by PatternMatcher, ready to be registered.
--
-- Patterns are organised by category:
--   Heuristics.calls      — NAMECALL+CALL fused method invocations
--   Heuristics.roblox     — Roblox-specific idioms (WaitForChild, Connect, etc.)
--   Heuristics.loops      — FORNPREP/FORGPREP recognition for visible markup
--   Heuristics.math       — fastcall builtin recognition
--   Heuristics.arithmetic — common arithmetic idioms (x = x + 1, x = -x, etc.)
--   Heuristics.tables     — table-construction patterns
--
-- Registering with the matcher:
--   Heuristics.registerAll(matcher)            -- register every pattern
--   Heuristics.registerGroups(matcher, {…})    -- only these categories
-- =====================================================================

local Heuristics = {}

-- ---------------------------------------------------------------------
-- Constraint helper builders
-- ---------------------------------------------------------------------

-- Build a constraint that checks the named-call method (resolved K)
-- equals a target string.
local function methodIs(captureName, target)
    return function(captures)
        local entry = captures[captureName]
        if not entry or not entry.row then return false end
        local refs = entry.row.references
        if not refs then return false end
        for _, ref in refs do
            if ref.kind == "namecall" and ref.method == target then return true end
        end
        return false
    end
end

-- Build a constraint that checks `R(call.A) == R(nc.A)` — the CALL
-- and NAMECALL share their A register (essential for the fusion).
local function callMatchesNamecall(ncName, callName)
    return function(captures)
        local nc, call = captures[ncName], captures[callName]
        if not nc or not call then return false end
        return nc.row.a == call.row.a
    end
end

-- Build a constraint that checks a GETIMPORT chain matches a path.
local function importMatches(captureName, expected)
    return function(captures)
        local entry = captures[captureName]
        if not entry or not entry.row then return false end
        for _, ref in entry.row.references or {} do
            if ref.kind == "import" and ref.chain then
                local chain = table.concat(ref.chain, ".")
                if chain == expected then return true end
            end
        end
        return false
    end
end

-- Build a constraint that checks a GETGLOBAL name equals expected.
local function globalIs(captureName, expected)
    return function(captures)
        local entry = captures[captureName]
        if not entry or not entry.row then return false end
        for _, ref in entry.row.references or {} do
            if ref.kind == "global" and ref.name == expected then return true end
        end
        return false
    end
end

-- ---------------------------------------------------------------------
-- Calls category
-- ---------------------------------------------------------------------

Heuristics.calls = {
    {
        id = "calls.method-call",
        description = "Method call (NAMECALL fused with CALL)",
        category = "calls",
        atoms = {
            { op = "NAMECALL", capture = "nc" },
            { op = "CALL",     capture = "call",
              constraint = callMatchesNamecall("nc", "call") },
        },
    },
}

-- ---------------------------------------------------------------------
-- Roblox idioms
-- ---------------------------------------------------------------------

Heuristics.roblox = {
    {
        id = "roblox.WaitForChild",
        description = "Instance:WaitForChild call",
        category = "roblox",
        severity = "info",
        atoms = {
            { op = "NAMECALL", capture = "nc",
              constraint = methodIs("nc", "WaitForChild") },
            { op = "CALL", capture = "call",
              constraint = callMatchesNamecall("nc", "call") },
        },
    },
    {
        id = "roblox.FindFirstChild",
        description = "Instance:FindFirstChild call",
        category = "roblox",
        atoms = {
            { op = "NAMECALL", capture = "nc",
              constraint = methodIs("nc", "FindFirstChild") },
            { op = "CALL", capture = "call",
              constraint = callMatchesNamecall("nc", "call") },
        },
    },
    {
        id = "roblox.signal.Connect",
        description = "RBXScriptSignal:Connect call",
        category = "roblox",
        severity = "important",
        atoms = {
            { op = "NAMECALL", capture = "nc",
              constraint = methodIs("nc", "Connect") },
            { op = "CALL", capture = "call",
              constraint = callMatchesNamecall("nc", "call") },
        },
    },
    {
        id = "roblox.signal.Once",
        description = "RBXScriptSignal:Once call",
        category = "roblox",
        atoms = {
            { op = "NAMECALL", capture = "nc",
              constraint = methodIs("nc", "Once") },
            { op = "CALL", capture = "call",
              constraint = callMatchesNamecall("nc", "call") },
        },
    },
    {
        id = "roblox.signal.Wait",
        description = "RBXScriptSignal:Wait call",
        category = "roblox",
        atoms = {
            { op = "NAMECALL", capture = "nc",
              constraint = methodIs("nc", "Wait") },
            { op = "CALL", capture = "call",
              constraint = callMatchesNamecall("nc", "call") },
        },
    },
    {
        id = "roblox.connection.Disconnect",
        description = "RBXScriptConnection:Disconnect call",
        category = "roblox",
        atoms = {
            { op = "NAMECALL", capture = "nc",
              constraint = methodIs("nc", "Disconnect") },
            { op = "CALL", capture = "call",
              constraint = callMatchesNamecall("nc", "call") },
        },
    },
    {
        id = "roblox.GetService",
        description = "game:GetService call",
        category = "roblox",
        severity = "important",
        atoms = {
            { op = "NAMECALL", capture = "nc",
              constraint = methodIs("nc", "GetService") },
            { op = "CALL", capture = "call",
              constraint = callMatchesNamecall("nc", "call") },
        },
    },
    {
        id = "roblox.Destroy",
        description = "Instance:Destroy call",
        category = "roblox",
        atoms = {
            { op = "NAMECALL", capture = "nc",
              constraint = methodIs("nc", "Destroy") },
            { op = "CALL", capture = "call",
              constraint = callMatchesNamecall("nc", "call") },
        },
    },
    {
        id = "roblox.Clone",
        description = "Instance:Clone call",
        category = "roblox",
        atoms = {
            { op = "NAMECALL", capture = "nc",
              constraint = methodIs("nc", "Clone") },
            { op = "CALL", capture = "call",
              constraint = callMatchesNamecall("nc", "call") },
        },
    },
    {
        id = "roblox.fire-server",
        description = "RemoteEvent:FireServer call",
        category = "roblox",
        severity = "important",
        atoms = {
            { op = "NAMECALL", capture = "nc",
              constraint = methodIs("nc", "FireServer") },
            { op = "CALL", capture = "call",
              constraint = callMatchesNamecall("nc", "call") },
        },
    },
    {
        id = "roblox.invoke-server",
        description = "RemoteFunction:InvokeServer call",
        category = "roblox",
        severity = "important",
        atoms = {
            { op = "NAMECALL", capture = "nc",
              constraint = methodIs("nc", "InvokeServer") },
            { op = "CALL", capture = "call",
              constraint = callMatchesNamecall("nc", "call") },
        },
    },
}

-- ---------------------------------------------------------------------
-- Loops
-- ---------------------------------------------------------------------

Heuristics.loops = {
    {
        id = "loops.fornum-prep",
        description = "Numeric for-loop preparation (FORNPREP)",
        category = "loops",
        atoms = {
            { op = "FORNPREP", capture = "prep" },
        },
    },
    {
        id = "loops.forgen-prep",
        description = "Generic for-loop preparation (FORGPREP*)",
        category = "loops",
        atoms = {
            { op = "FORGPREP*", capture = "prep" },
        },
    },
    {
        id = "loops.back-jump",
        description = "Back-edge (JUMPBACK)",
        category = "loops",
        atoms = {
            { op = "JUMPBACK", capture = "back" },
        },
    },
}

-- ---------------------------------------------------------------------
-- Math / fastcall builtins
-- ---------------------------------------------------------------------

Heuristics.math = {
    {
        id = "math.fastcall",
        description = "FASTCALL — builtin (math/table/string/…) invocation",
        category = "math",
        atoms = {
            { op = "FASTCALL*", capture = "fc" },
        },
    },
}

-- ---------------------------------------------------------------------
-- Arithmetic idioms
-- ---------------------------------------------------------------------

Heuristics.arithmetic = {
    {
        id = "arith.increment",
        description = "Self-increment: x = x + N (ADD/SUB with self-source)",
        category = "arithmetic",
        atoms = {
            { op = { "ADD", "ADDK", "SUB", "SUBK" }, capture = "add",
              -- A == B means the register is its own source (self-mutating)
              constraint = function(captures)
                  local r = captures.add.row
                  return r.a == r.b
              end },
        },
    },
    {
        id = "arith.length",
        description = "Length operator (#)",
        category = "arithmetic",
        atoms = {
            { op = "LENGTH", capture = "len" },
        },
    },
    {
        id = "arith.concat",
        description = "String concatenation (.. operator across CONCAT)",
        category = "arithmetic",
        atoms = {
            { op = "CONCAT", capture = "concat" },
        },
    },
}

-- ---------------------------------------------------------------------
-- Table construction patterns
-- ---------------------------------------------------------------------

Heuristics.tables = {
    {
        id = "tables.new-empty",
        description = "Empty table construction",
        category = "tables",
        atoms = {
            { op = "NEWTABLE", capture = "newt",
              constraint = function(captures)
                  -- Empty table: B and C both zero (array+hash capacity zero)
                  local r = captures.newt.row
                  return (r.b or 0) == 0 and (r.c or 0) == 0
              end },
        },
    },
    {
        id = "tables.new",
        description = "Table construction (NEWTABLE)",
        category = "tables",
        atoms = {
            { op = "NEWTABLE", capture = "newt" },
        },
    },
    {
        id = "tables.dup",
        description = "Table construction from constant template (DUPTABLE)",
        category = "tables",
        atoms = {
            { op = "DUPTABLE", capture = "dup" },
        },
    },
    {
        id = "tables.setlist",
        description = "Array-section table fill (SETLIST)",
        category = "tables",
        atoms = {
            { op = "SETLIST", capture = "set" },
        },
    },
}

-- ---------------------------------------------------------------------
-- Group registry
-- ---------------------------------------------------------------------

Heuristics.groups = {
    calls      = Heuristics.calls,
    roblox     = Heuristics.roblox,
    loops      = Heuristics.loops,
    math       = Heuristics.math,
    arithmetic = Heuristics.arithmetic,
    tables     = Heuristics.tables,
}

function Heuristics.registerAll(matcher)
    for _, group in Heuristics.groups do
        for _, pattern in group do matcher:register(pattern) end
    end
end

function Heuristics.registerGroups(matcher, groupNames)
    for _, name in groupNames do
        local g = Heuristics.groups[name]
        if g then
            for _, pattern in g do matcher:register(pattern) end
        end
    end
end

function Heuristics.allPatterns()
    local out = {}
    for _, group in Heuristics.groups do
        for _, p in group do out[#out + 1] = p end
    end
    return out
end

return Heuristics
