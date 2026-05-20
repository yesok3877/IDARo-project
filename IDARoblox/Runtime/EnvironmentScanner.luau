--!nonstrict
-- =====================================================================
-- IDARoblox / Runtime / EnvironmentScanner
-- ---------------------------------------------------------------------
-- A defensive wrapper around the Lua executor's introspection APIs.
-- Every callable is detected once and cached; every invocation is
-- pcall-wrapped and degrades gracefully when an API is missing or
-- restricted.
--
-- Why this exists separately from FunctionRegistry / ScriptRegistry /
-- HookManager: those modules need a uniform "can I do X?" decision
-- point. Centralising the capability-detection logic here means the
-- rest of Runtime never has to write
--     if type(getgc) == "function" then …
-- defensively at every call site — they call
--     scanner:capabilities().getgc
-- and trust the answer.
--
-- Public API:
--   EnvironmentScanner.new(opts)
--     opts.logger?       — used for non-fatal warnings
--     opts.includeTables — default false, passed to getgc
--
--   scanner:capabilities()        → {getgc=true, hookfunction=true, …}
--   scanner:scanGc(includeTables) → { functions={}, tables={}, threads={} }
--   scanner:scanScripts()         → { … } (combined loadedModules+running)
--   scanner:scanRegistry()        → registry table (or nil)
--   scanner:scanEnvironment()     → genv-like table (or nil)
--   scanner:getBytecode(script)   → bytecode string or nil
--   scanner:protectedCall(name, … params)
--                                 → pcall wrapper with capability check
-- =====================================================================

local EnvironmentScanner = {}
EnvironmentScanner.__index = EnvironmentScanner

-- ---------------------------------------------------------------------
-- Capability detection
-- ---------------------------------------------------------------------

local function safeGlobal(name)
    -- getfenv(0) is reliable in Luau; some executors override _G.
    local ok, env = pcall(function() return getfenv(0) end)
    if ok and env then
        local val = env[name]
        if val ~= nil then return val end
    end
    return rawget(_G, name)
end

-- Detect every capability we care about in one sweep. Each entry is
-- a function reference (or nil) — never raw booleans, since storing
-- the function lets callers invoke it directly via the registry.
local function detectCapabilities()
    local caps = {
        getgc                 = safeGlobal("getgc"),
        getloadedmodules      = safeGlobal("getloadedmodules"),
        getrunningscripts     = safeGlobal("getrunningscripts"),
        getscriptbytecode     = safeGlobal("getscriptbytecode")
                              or safeGlobal("dumpstring"),                -- some executors alias
        getscriptclosure      = safeGlobal("getscriptclosure")
                              or safeGlobal("getscriptfunction"),
        hookfunction          = safeGlobal("hookfunction")
                              or safeGlobal("replaceclosure")
                              or safeGlobal("hookfunc"),
        hookmetamethod        = safeGlobal("hookmetamethod"),
        getrawmetatable       = safeGlobal("getrawmetatable"),
        setrawmetatable       = safeGlobal("setrawmetatable"),
        setreadonly           = safeGlobal("setreadonly"),
        isreadonly            = safeGlobal("isreadonly"),
        getconnections        = safeGlobal("getconnections"),
        getnamecallmethod     = safeGlobal("getnamecallmethod"),
        setnamecallmethod     = safeGlobal("setnamecallmethod"),
        getreg                = safeGlobal("getreg")
                              or safeGlobal("getregistry"),
        getrenv               = safeGlobal("getrenv"),
        getgenv               = safeGlobal("getgenv"),
        getsenv               = safeGlobal("getsenv"),
        islclosure            = safeGlobal("islclosure"),
        iscclosure            = safeGlobal("iscclosure"),
        clonefunction         = safeGlobal("clonefunction"),
        newcclosure           = safeGlobal("newcclosure"),
        checkcaller           = safeGlobal("checkcaller"),
        identifyexecutor      = safeGlobal("identifyexecutor")
                              or safeGlobal("getexecutorname"),
    }

    -- Debug-library functions (Luau extends Lua's debug with Roblox-specific entries).
    local debug_t = safeGlobal("debug")
    if type(debug_t) == "table" then
        caps.debug_getconstants = type(debug_t.getconstants) == "function" and debug_t.getconstants or nil
        caps.debug_setconstant  = type(debug_t.setconstant)  == "function" and debug_t.setconstant  or nil
        caps.debug_getprotos    = type(debug_t.getprotos)    == "function" and debug_t.getprotos    or nil
        caps.debug_getproto     = type(debug_t.getproto)     == "function" and debug_t.getproto     or nil
        caps.debug_getupvalues  = type(debug_t.getupvalues)  == "function" and debug_t.getupvalues  or nil
        caps.debug_getupvalue   = type(debug_t.getupvalue)   == "function" and debug_t.getupvalue   or nil
        caps.debug_setupvalue   = type(debug_t.setupvalue)   == "function" and debug_t.setupvalue   or nil
        caps.debug_info         = type(debug_t.info)         == "function" and debug_t.info         or nil
        caps.debug_traceback    = type(debug_t.traceback)    == "function" and debug_t.traceback    or nil
        caps.debug_getregistry  = type(debug_t.getregistry)  == "function" and debug_t.getregistry  or nil
    end

    return caps
end

-- ---------------------------------------------------------------------
-- Constructor
-- ---------------------------------------------------------------------

function EnvironmentScanner.new(opts)
    opts = opts or {}
    local self = setmetatable({
        _logger        = opts.logger,
        _includeTables = opts.includeTables ~= false,                -- default true
        _caps          = nil,
        _executorName  = nil,
    }, EnvironmentScanner)
    self:capabilities()                                              -- eager detect
    return self
end

function EnvironmentScanner:capabilities()
    if not self._caps then
        self._caps = detectCapabilities()
        -- Identify executor once, for logging context.
        if self._caps.identifyexecutor then
            local ok, name = pcall(self._caps.identifyexecutor)
            if ok then self._executorName = type(name) == "table" and name[1] or name end
        end
        if self._logger then
            local present = 0
            for _, v in self._caps do if v then present = present + 1 end end
            self._logger:info(
                "EnvironmentScanner: executor=%s, %d/40 capabilities detected",
                tostring(self._executorName or "unknown"), present)
        end
    end
    return self._caps
end

function EnvironmentScanner:executorName()
    return self._executorName
end

-- ---------------------------------------------------------------------
-- Defensive call wrapper
-- ---------------------------------------------------------------------

-- Call a capability by name, threading additional args. Returns
-- (true, results…) on success or (false, errMsg) on failure / missing.
function EnvironmentScanner:protectedCall(name, ...)
    local caps = self:capabilities()
    local fn = caps[name]
    if not fn then return false, "capability unavailable: " .. tostring(name) end
    return pcall(fn, ...)
end

-- ---------------------------------------------------------------------
-- GC scan
-- ---------------------------------------------------------------------

function EnvironmentScanner:scanGc(includeTables)
    local caps = self:capabilities()
    local out = { functions = {}, tables = {}, threads = {}, totalSeen = 0 }
    if not caps.getgc then return out end
    local include = includeTables
    if include == nil then include = self._includeTables end
    local ok, all = pcall(caps.getgc, include)
    if not ok or type(all) ~= "table" then
        if self._logger then self._logger:warn("scanGc: getgc failed (%s)", tostring(all)) end
        return out
    end
    local fnArr, tblArr, thrArr = out.functions, out.tables, out.threads
    for _, obj in all do
        local t = type(obj)
        if t == "function" then
            fnArr[#fnArr + 1] = obj
        elseif t == "table" then
            tblArr[#tblArr + 1] = obj
        elseif t == "thread" then
            thrArr[#thrArr + 1] = obj
        end
    end
    out.totalSeen = #all
    return out
end

-- ---------------------------------------------------------------------
-- Script enumeration
-- ---------------------------------------------------------------------

function EnvironmentScanner:scanScripts()
    local caps = self:capabilities()
    local scripts = {}
    local seen    = {}
    local origin  = {}                                               -- script → "modules"|"running"|"both"

    if caps.getloadedmodules then
        local ok, mods = pcall(caps.getloadedmodules)
        if ok and type(mods) == "table" then
            for _, m in mods do
                if not seen[m] then
                    seen[m] = true
                    scripts[#scripts + 1] = m
                    origin[m] = "modules"
                end
            end
        end
    end

    if caps.getrunningscripts then
        local ok, running = pcall(caps.getrunningscripts)
        if ok and type(running) == "table" then
            for _, s in running do
                if seen[s] then
                    origin[s] = "both"
                else
                    seen[s] = true
                    scripts[#scripts + 1] = s
                    origin[s] = "running"
                end
            end
        end
    end

    return scripts, origin
end

-- ---------------------------------------------------------------------
-- Bytecode retrieval (cached per script)
-- ---------------------------------------------------------------------

function EnvironmentScanner:getBytecode(script)
    local caps = self:capabilities()
    if not caps.getscriptbytecode or not script then return nil end
    local ok, bc = pcall(caps.getscriptbytecode, script)
    if not ok then
        if self._logger then
            self._logger:warn("getBytecode: failed (%s)", tostring(bc))
        end
        return nil
    end
    if type(bc) ~= "string" or #bc == 0 then return nil end
    return bc
end

-- ---------------------------------------------------------------------
-- Registry / environment access
-- ---------------------------------------------------------------------

function EnvironmentScanner:scanRegistry()
    local caps = self:capabilities()
    local fn = caps.getreg or caps.debug_getregistry
    if not fn then return nil end
    local ok, reg = pcall(fn)
    if not ok then return nil end
    return reg
end

function EnvironmentScanner:scanEnvironment(which)
    -- which ∈ "renv" | "genv" | "senv"
    local caps = self:capabilities()
    local fn = which == "renv" and caps.getrenv
        or  which == "senv" and caps.getsenv
        or  caps.getgenv
    if not fn then return nil end
    local ok, env = pcall(fn)
    if not ok then return nil end
    return env
end

-- ---------------------------------------------------------------------
-- Lua-closure detection
-- ---------------------------------------------------------------------

function EnvironmentScanner:isLuaClosure(fn)
    if type(fn) ~= "function" then return false end
    local caps = self:capabilities()
    if caps.islclosure then
        local ok, result = pcall(caps.islclosure, fn)
        if ok then return result end
    end
    -- Fallback: try to read constants — only Lua closures have them.
    if caps.debug_getconstants then
        local ok, _ = pcall(caps.debug_getconstants, fn)
        return ok
    end
    return false
end

function EnvironmentScanner:isCClosure(fn)
    if type(fn) ~= "function" then return false end
    local caps = self:capabilities()
    if caps.iscclosure then
        local ok, result = pcall(caps.iscclosure, fn)
        if ok then return result end
    end
    return not self:isLuaClosure(fn)
end

-- ---------------------------------------------------------------------
-- Function introspection helpers
-- ---------------------------------------------------------------------

function EnvironmentScanner:fnInfo(fn)
    if type(fn) ~= "function" then return nil end
    local caps = self:capabilities()
    local info = {
        source    = nil,
        line      = nil,
        what      = nil,
        name      = nil,
        numparams = nil,
        isvararg  = nil,
    }
    if caps.debug_info then
        pcall(function() info.source    = caps.debug_info(fn, "s") end)
        pcall(function() info.line      = caps.debug_info(fn, "l") end)
        pcall(function() info.what      = caps.debug_info(fn, "w") end)
        pcall(function() info.name      = caps.debug_info(fn, "n") end)
        pcall(function() info.numparams = caps.debug_info(fn, "a") end)
    else
        local ok, basic = pcall(debug.info, fn, "sl")
        if ok then info.source, info.line = basic, basic end
    end
    return info
end

function EnvironmentScanner:fnConstants(fn)
    local caps = self:capabilities()
    if not caps.debug_getconstants then return nil end
    local ok, c = pcall(caps.debug_getconstants, fn)
    if not ok then return nil end
    return c
end

function EnvironmentScanner:fnProtos(fn)
    local caps = self:capabilities()
    if not caps.debug_getprotos then return nil end
    local ok, p = pcall(caps.debug_getprotos, fn)
    if not ok then return nil end
    return p
end

function EnvironmentScanner:fnUpvalues(fn)
    local caps = self:capabilities()
    if not caps.debug_getupvalues then return nil end
    local ok, u = pcall(caps.debug_getupvalues, fn)
    if not ok then return nil end
    return u
end

return EnvironmentScanner
