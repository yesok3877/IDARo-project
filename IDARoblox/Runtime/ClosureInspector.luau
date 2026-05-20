--!nonstrict
-- =====================================================================
-- IDARoblox / Runtime / ClosureInspector
-- ---------------------------------------------------------------------
-- Read + safe-write access to a closure's introspectable internals:
--
--   * upvalues  (debug.getupvalues / debug.setupvalue)
--   * constants (debug.getconstants / debug.setconstant)
--   * sub-protos (debug.getprotos / debug.getproto)
--   * debug.info  (source, what, name, currentline, …)
--
-- Patches go through a per-function PatchLog so users can revert
-- individual writes. The log is in-memory only (the runtime owns it).
--
-- Safety
--   * Writes are refused on builtin (`what == "C"`) functions because
--     setupvalue / setconstant don't apply meaningfully there.
--   * Constant kind narrowing: setConstant refuses to install a value
--     whose type differs from the original kind (e.g. you can't replace
--     a number constant with a function reference).
--   * All writes pcall-wrapped; failures are surfaced via PatchLog.
--
-- Construction
--   ClosureInspector.new {
--     scanner   = EnvironmentScanner,
--     logger    = Logger,
--     eventBus  = EventBus,
--   }
-- =====================================================================

local ClosureInspector = {}
ClosureInspector.__index = ClosureInspector

-- ---------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------

function ClosureInspector.new(opts)
    opts = opts or {}
    return setmetatable({
        _scanner   = opts.scanner,
        _logger    = opts.logger,
        _eventBus  = opts.eventBus,
        _patchLog  = {},                                             -- fn → { patches = [...], byKey = {…} }
        _cache     = {},                                             -- fn → last inspect snapshot
        _stats = {
            inspected     = 0,
            upvalueWrites = 0,
            constantWrites = 0,
            writesRefused = 0,
            writesFailed  = 0,
            cacheHits     = 0,
        },
    }, ClosureInspector)
end

function ClosureInspector:setScanner(s) self._scanner = s; self._cache = {} end

local function emit(self, evt, payload)
    if self._eventBus and type(self._eventBus.emit) == "function" then
        pcall(self._eventBus.emit, self._eventBus, evt, payload)
    end
end

-- ---------------------------------------------------------------------
-- Resolver shims (graceful when capability missing)
-- ---------------------------------------------------------------------

local function fetch(scanner, name)
    if scanner and type(scanner.getRaw) == "function" then
        return scanner:getRaw(name)
    end
    -- Bare globals as fallback (executor exposes them directly sometimes)
    local g = getfenv(0)
    return g[name]
end

local function debugFns(scanner)
    local dbg = fetch(scanner, "debug") or debug
    if type(dbg) ~= "table" then return nil end
    return {
        getupvalues  = dbg.getupvalues,
        setupvalue   = dbg.setupvalue,
        getupvalue   = dbg.getupvalue,
        getconstants = dbg.getconstants,
        setconstant  = dbg.setconstant,
        getconstant  = dbg.getconstant,
        getprotos    = dbg.getprotos,
        getproto     = dbg.getproto,
        info         = dbg.info or dbg.getinfo,
        getinfo      = dbg.getinfo or dbg.info,
    }
end

-- Polyfill: getupvalues from per-index getupvalue
local function readUpvaluesByIndex(getup, fn)
    local out = {}
    local i = 1
    while true do
        local ok, name, value = pcall(getup, fn, i)
        if not ok or name == nil then break end
        out[i] = { name = name, value = value, idx = i }
        i = i + 1
        if i > 1000 then break end                                   -- sanity
    end
    return out
end

local function readUpvalues(d, fn)
    if d.getupvalues then
        local ok, ups = pcall(d.getupvalues, fn)
        if ok and type(ups) == "table" then
            -- Some implementations return [{name,value}]; some return
            -- {[idx] = value}. Normalize.
            local out = {}
            local hasIdx = false
            for k, v in pairs(ups) do
                if type(k) == "number" then hasIdx = true; break end
            end
            if hasIdx then
                for i, v in ups do
                    if type(v) == "table" and v.name then
                        out[i] = { name = v.name, value = v.value, idx = i }
                    else
                        out[i] = { name = nil, value = v, idx = i }
                    end
                end
            else
                local i = 0
                for name, value in pairs(ups) do
                    i = i + 1
                    out[i] = { name = name, value = value, idx = i }
                end
            end
            return out
        end
    end
    if d.getupvalue then return readUpvaluesByIndex(d.getupvalue, fn) end
    return {}
end

local function readConstants(d, fn)
    if d.getconstants then
        local ok, ks = pcall(d.getconstants, fn)
        if ok and type(ks) == "table" then
            local out = {}
            for i, v in ks do
                out[i] = { value = v, kind = type(v), idx = i }
            end
            return out
        end
    end
    if d.getconstant then
        local out = {}
        local i = 1
        while true do
            local ok, v = pcall(d.getconstant, fn, i)
            if not ok or v == nil then break end
            out[i] = { value = v, kind = type(v), idx = i }
            i = i + 1
            if i > 4096 then break end
        end
        return out
    end
    return {}
end

local function readProtos(d, fn)
    if d.getprotos then
        local ok, ps = pcall(d.getprotos, fn)
        if ok and type(ps) == "table" then
            local out = {}
            for i, p in ps do out[i] = { fn = p, idx = i } end
            return out
        end
    end
    if d.getproto then
        local out = {}
        local i = 1
        while true do
            local ok, p = pcall(d.getproto, fn, i)
            if not ok or p == nil then break end
            out[i] = { fn = p, idx = i }
            i = i + 1
            if i > 4096 then break end
        end
        return out
    end
    return {}
end

local function readInfo(d, fn)
    if d.info then
        local ok, info = pcall(d.info, fn, "slna")
        if ok and type(info) == "table" then return info end
    end
    if d.getinfo then
        local ok, info = pcall(d.getinfo, fn, "Sln")
        if ok and type(info) == "table" then return info end
    end
    return nil
end

-- ---------------------------------------------------------------------
-- inspect
-- ---------------------------------------------------------------------

function ClosureInspector:inspect(fn, opts)
    opts = opts or {}
    if type(fn) ~= "function" then return nil, "not a function" end
    if self._cache[fn] and not opts.refresh then
        self._stats.cacheHits = self._stats.cacheHits + 1
        return self._cache[fn]
    end
    local d = debugFns(self._scanner)
    if not d then return nil, "debug introspection unavailable" end

    local info = readInfo(d, fn)
    local snap = {
        ref        = fn,
        info       = info,
        upvalues   = readUpvalues(d, fn),
        constants  = readConstants(d, fn),
        protos     = readProtos(d, fn),
        isC        = info and info.what == "C",
        source     = info and info.source,
        what       = info and info.what,
        lineDefined = info and (info.linedefined or info.currentline),
        name       = info and info.name,
        nUpvalues  = 0,
        nConstants = 0,
        nProtos    = 0,
    }
    snap.nUpvalues  = #snap.upvalues
    snap.nConstants = #snap.constants
    snap.nProtos    = #snap.protos
    self._cache[fn] = snap
    self._stats.inspected = self._stats.inspected + 1
    return snap
end

function ClosureInspector:refresh(fn) return self:inspect(fn, { refresh = true }) end

-- ---------------------------------------------------------------------
-- Patch log
-- ---------------------------------------------------------------------

local function patchLogFor(self, fn)
    local log = self._patchLog[fn]
    if not log then log = { patches = {}, byKey = {} }; self._patchLog[fn] = log end
    return log
end

local function recordPatch(self, fn, kind, idx, oldValue, newValue)
    local log = patchLogFor(self, fn)
    local key = kind .. ":" .. tostring(idx)
    local patch = log.byKey[key]
    if patch then
        -- Update newValue but keep the *first* oldValue we ever saw so
        -- revert restores the pristine state.
        patch.newValue = newValue
        patch.lastAt = os.time()
        patch.appliedCount = (patch.appliedCount or 1) + 1
    else
        patch = {
            kind = kind, idx = idx,
            oldValue = oldValue, newValue = newValue,
            firstAt = os.time(), lastAt = os.time(), appliedCount = 1,
        }
        log.byKey[key] = patch
        log.patches[#log.patches + 1] = patch
    end
    return patch
end

-- ---------------------------------------------------------------------
-- setUpvalue
-- ---------------------------------------------------------------------

function ClosureInspector:setUpvalue(fn, idx, newValue)
    if type(fn) ~= "function" then return false, "not a function" end
    local snap = self:inspect(fn)
    if not snap then return false, "inspect failed" end
    if snap.isC then
        self._stats.writesRefused = self._stats.writesRefused + 1
        return false, "refusing write to C function"
    end
    local up = snap.upvalues[idx]
    if not up then return false, "no upvalue at index " .. tostring(idx) end
    local d = debugFns(self._scanner)
    if not d or not d.setupvalue then return false, "setupvalue unavailable" end
    local oldValue = up.value
    local ok, err = pcall(d.setupvalue, fn, idx, newValue)
    if not ok then
        self._stats.writesFailed = self._stats.writesFailed + 1
        return false, "setupvalue failed: " .. tostring(err)
    end
    self._stats.upvalueWrites = self._stats.upvalueWrites + 1
    local patch = recordPatch(self, fn, "upvalue", idx, oldValue, newValue)
    -- Invalidate cache so next inspect re-reads
    self._cache[fn] = nil
    emit(self, "closure.upvalueChanged",
        { fn = fn, idx = idx, oldValue = oldValue, newValue = newValue })
    return true, patch
end

-- ---------------------------------------------------------------------
-- setConstant
-- ---------------------------------------------------------------------

function ClosureInspector:setConstant(fn, idx, newValue, opts)
    opts = opts or {}
    if type(fn) ~= "function" then return false, "not a function" end
    local snap = self:inspect(fn)
    if not snap then return false, "inspect failed" end
    if snap.isC then
        self._stats.writesRefused = self._stats.writesRefused + 1
        return false, "refusing write to C function"
    end
    local k = snap.constants[idx]
    if not k then return false, "no constant at index " .. tostring(idx) end
    if not opts.allowTypeChange and type(newValue) ~= k.kind then
        self._stats.writesRefused = self._stats.writesRefused + 1
        return false, string.format(
            "type narrowing: original is %s, new is %s — pass allowTypeChange=true to override",
            k.kind, type(newValue))
    end
    local d = debugFns(self._scanner)
    if not d or not d.setconstant then return false, "setconstant unavailable" end
    local oldValue = k.value
    local ok, err = pcall(d.setconstant, fn, idx, newValue)
    if not ok then
        self._stats.writesFailed = self._stats.writesFailed + 1
        return false, "setconstant failed: " .. tostring(err)
    end
    self._stats.constantWrites = self._stats.constantWrites + 1
    local patch = recordPatch(self, fn, "constant", idx, oldValue, newValue)
    self._cache[fn] = nil
    emit(self, "closure.constantChanged",
        { fn = fn, idx = idx, oldValue = oldValue, newValue = newValue })
    return true, patch
end

-- ---------------------------------------------------------------------
-- Revert single patch
-- ---------------------------------------------------------------------

function ClosureInspector:revertPatch(fn, kind, idx)
    local log = self._patchLog[fn]
    if not log then return false, "no patches recorded" end
    local key = kind .. ":" .. tostring(idx)
    local patch = log.byKey[key]
    if not patch then return false, "no such patch" end
    local d = debugFns(self._scanner)
    if not d then return false, "debug unavailable" end
    local writer = (kind == "upvalue") and d.setupvalue or d.setconstant
    if not writer then return false, kind .. " writer unavailable" end
    local ok, err = pcall(writer, fn, idx, patch.oldValue)
    if not ok then return false, "revert failed: " .. tostring(err) end
    log.byKey[key] = nil
    for i, p in log.patches do
        if p == patch then table.remove(log.patches, i); break end
    end
    self._cache[fn] = nil
    emit(self, "closure.patchReverted",
        { fn = fn, kind = kind, idx = idx, restoredValue = patch.oldValue })
    return true
end

function ClosureInspector:revertAll(fn)
    local log = self._patchLog[fn]
    if not log then return 0 end
    local d = debugFns(self._scanner)
    if not d then return 0 end
    local reverted = 0
    -- Apply reverts in reverse order
    for i = #log.patches, 1, -1 do
        local p = log.patches[i]
        local writer = (p.kind == "upvalue") and d.setupvalue or d.setconstant
        if writer then
            local ok = pcall(writer, fn, p.idx, p.oldValue)
            if ok then reverted = reverted + 1 end
        end
    end
    self._patchLog[fn] = nil
    self._cache[fn] = nil
    emit(self, "closure.patchesReverted", { fn = fn, count = reverted })
    return reverted
end

-- ---------------------------------------------------------------------
-- Bulk operations
-- ---------------------------------------------------------------------

function ClosureInspector:replaceUpvaluesMatching(fn, predicate, newValue)
    local snap = self:inspect(fn)
    if not snap then return 0 end
    local n = 0
    for _, up in snap.upvalues do
        if predicate(up.name, up.value, up.idx) then
            local ok = self:setUpvalue(fn, up.idx, newValue)
            if ok then n = n + 1 end
        end
    end
    return n
end

function ClosureInspector:replaceConstantsMatching(fn, predicate, newValue, opts)
    local snap = self:inspect(fn)
    if not snap then return 0 end
    local n = 0
    for _, k in snap.constants do
        if predicate(k.value, k.kind, k.idx) then
            local ok = self:setConstant(fn, k.idx, newValue, opts)
            if ok then n = n + 1 end
        end
    end
    return n
end

-- ---------------------------------------------------------------------
-- Queries
-- ---------------------------------------------------------------------

function ClosureInspector:patches(fn)
    local log = self._patchLog[fn]
    if not log then return {} end
    local out = table.create(#log.patches)
    for i, p in log.patches do out[i] = p end
    return out
end

function ClosureInspector:hasPatches(fn)
    local log = self._patchLog[fn]
    return log ~= nil and #log.patches > 0
end

function ClosureInspector:allPatchedFunctions()
    local out = {}
    for fn in self._patchLog do out[#out + 1] = fn end
    return out
end

function ClosureInspector:stats()
    local patchedCount = 0
    local totalPatches = 0
    for _, log in self._patchLog do
        patchedCount = patchedCount + 1
        totalPatches = totalPatches + #log.patches
    end
    return {
        inspected      = self._stats.inspected,
        upvalueWrites  = self._stats.upvalueWrites,
        constantWrites = self._stats.constantWrites,
        writesRefused  = self._stats.writesRefused,
        writesFailed   = self._stats.writesFailed,
        cacheHits      = self._stats.cacheHits,
        patchedFunctions = patchedCount,
        totalPatches   = totalPatches,
        cacheSize      = (function()
            local n = 0; for _ in self._cache do n = n + 1 end; return n
        end)(),
    }
end

return ClosureInspector
