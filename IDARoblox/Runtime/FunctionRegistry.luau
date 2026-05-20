--!nonstrict
-- =====================================================================
-- IDARoblox / Runtime / FunctionRegistry
-- ---------------------------------------------------------------------
-- An index of live Lua/C functions discovered via getgc. For each
-- discovered function we capture:
--
--   {
--     id            = N,
--     fn            = <function ref>,
--     kind          = "lua" | "c" | "builtin" | "unknown",
--     source        = string?,   -- debug.info "s"  (script path or "[C]" etc.)
--     line          = number?,   -- debug.info "l"
--     what          = string?,   -- debug.info "w"  ("Lua" / "C" / "main")
--     name          = string?,   -- debug.info "n"  (best-effort)
--     numparams     = number?,
--     nupvalues     = number?,
--     constantCount = number?,
--     protoCount    = number?,
--     fingerprint   = string?,   -- stable content hash for re-identification
--     scriptEntry   = ScriptRegistry entry?  (when source maps to a known script)
--     firstSeenAt   = os.clock(),
--   }
--
-- The fingerprint combines structural facts (numparams, nupvalues,
-- nconstants, nprotos) with the first few constants (truncated). It's
-- not a cryptographic hash — collisions are possible but rare for
-- non-trivial functions — but it gives a stable "this looks like the
-- same function across two GC scans" signal that's good enough for the
-- HooksView's "rediscover after rescan" behaviour.
--
-- Indexes:
--   _byFn         : fn → entry
--   _byFingerprint: fingerprint → { entry, … }
--   _bySource     : source-string → { entry, … }
--   _byName       : name → { entry, … }
--   _byScript     : ScriptRegistry-entry → { entry, … }
-- =====================================================================

local FunctionRegistry = {}
FunctionRegistry.__index = FunctionRegistry

-- ---------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------

function FunctionRegistry.new(opts)
    if not opts or not opts.scanner then
        error("FunctionRegistry.new: opts.scanner required", 2)
    end
    return setmetatable({
        _scanner       = opts.scanner,
        _scriptRegistry = opts.scriptRegistry,                       -- optional cross-link
        _logger        = opts.logger,
        _entries       = {},
        _byFn          = {},
        _byFingerprint = {},
        _bySource      = {},
        _byName        = {},
        _byScript      = {},                                         -- script-entry → { fnEntry, … }
        _nextId        = 1,
        _scanCount     = 0,
        _lastScanAt    = nil,
    }, FunctionRegistry)
end

-- ---------------------------------------------------------------------
-- Fingerprint
-- ---------------------------------------------------------------------

local MAX_FP_CONSTANTS = 8

local function fingerprintFn(scanner, fn)
    local nparams, nups, nconst, nprotos = 0, 0, 0, 0
    local consts, protos
    local info
    pcall(function() info = scanner:fnInfo(fn) end)
    if info then
        nparams = tonumber(info.numparams) or 0
    end
    pcall(function()
        consts = scanner:fnConstants(fn)
        if consts then nconst = #consts end
    end)
    pcall(function()
        protos = scanner:fnProtos(fn)
        if protos then nprotos = #protos end
    end)
    pcall(function()
        local ups = scanner:fnUpvalues(fn)
        if ups then nups = #ups end
    end)

    local parts = {
        tostring(nparams),
        tostring(nups),
        tostring(nconst),
        tostring(nprotos),
    }
    if consts then
        for i = 1, math.min(MAX_FP_CONSTANTS, nconst) do
            local c = consts[i]
            local t = type(c)
            local repr
            if t == "string" then
                repr = "s:" .. string.sub(c, 1, 24)
            elseif t == "number" then
                repr = "n:" .. tostring(c)
            elseif t == "boolean" then
                repr = "b:" .. tostring(c)
            elseif t == "nil" then
                repr = "0"
            else
                repr = t                                             -- coarse: just the type
            end
            parts[#parts + 1] = repr
        end
    end
    return table.concat(parts, "|"), {
        nparams = nparams,
        nupvalues = nups,
        constantCount = nconst,
        protoCount = nprotos,
    }
end

-- ---------------------------------------------------------------------
-- Inspect a single function
-- ---------------------------------------------------------------------

local function inspectFn(self, fn)
    local info  = self._scanner:fnInfo(fn) or {}
    local isLua = self._scanner:isLuaClosure(fn)
    local kind  = isLua and "lua" or (self._scanner:isCClosure(fn) and "c" or "unknown")
    local fp, stats = fingerprintFn(self._scanner, fn)
    return {
        id            = nil,                                         -- assigned by caller
        fn            = fn,
        kind          = kind,
        source        = info.source,
        line          = info.line,
        what          = info.what,
        name          = info.name,
        numparams     = info.numparams,
        nupvalues     = stats.nupvalues,
        constantCount = stats.constantCount,
        protoCount    = stats.protoCount,
        fingerprint   = fp,
        scriptEntry   = nil,
        firstSeenAt   = os.clock(),
    }
end

-- Try to map a function's `source` field to a registered script.
-- Source strings look like `=Players.Player.PlayerScripts.MyScript`
-- or just `=[C]` for C closures. We normalise and search.
local function tryLinkScript(self, entry)
    if not self._scriptRegistry or not entry.source then return end
    local s = entry.source
    if string.sub(s, 1, 1) == "=" then s = string.sub(s, 2) end
    if s == "[C]" or s == "" then return end
    -- Try exact path match first.
    for _, scriptEntry in self._scriptRegistry:entries() do
        if scriptEntry.path == s or string.find(scriptEntry.path, s, 1, true) then
            entry.scriptEntry = scriptEntry
            local bucket = self._byScript[scriptEntry]
            if not bucket then bucket = {}; self._byScript[scriptEntry] = bucket end
            bucket[#bucket + 1] = entry
            return
        end
    end
end

-- ---------------------------------------------------------------------
-- Scan
-- ---------------------------------------------------------------------

local function pushIndex(tbl, key, entry)
    if not key then return end
    local b = tbl[key]
    if not b then b = {}; tbl[key] = b end
    b[#b + 1] = entry
end

function FunctionRegistry:scan(opts)
    opts = opts or {}
    local includeC = opts.includeCClosures ~= false                   -- default true
    self._scanCount = self._scanCount + 1
    self._lastScanAt = os.clock()

    local gc = self._scanner:scanGc(false)
    local fns = gc.functions

    -- Reset indexes if requested; otherwise extend (incremental scan).
    if opts.reset ~= false then
        self._entries = {}
        self._byFn, self._byFingerprint = {}, {}
        self._bySource, self._byName, self._byScript = {}, {}, {}
        self._nextId = 1
    end

    local added = 0
    for _, fn in fns do
        if self._byFn[fn] then continue end
        local entry = inspectFn(self, fn)
        if entry.kind == "c" and not includeC then continue end
        entry.id = self._nextId
        self._nextId = self._nextId + 1
        self._byFn[fn] = entry
        self._entries[#self._entries + 1] = entry
        pushIndex(self._byFingerprint, entry.fingerprint, entry)
        pushIndex(self._bySource,      entry.source,      entry)
        pushIndex(self._byName,        entry.name,        entry)
        tryLinkScript(self, entry)
        added = added + 1
    end

    if self._logger then
        self._logger:info(
            "FunctionRegistry: scan #%d → %d entries (+%d new) across %d gc-functions",
            self._scanCount, #self._entries, added, #fns)
    end
    return { added = added, total = #self._entries }
end

-- ---------------------------------------------------------------------
-- Lookup
-- ---------------------------------------------------------------------

function FunctionRegistry:entries() return self._entries end
function FunctionRegistry:entryFor(fn) return self._byFn[fn] end

function FunctionRegistry:findByFingerprint(fp) return self._byFingerprint[fp] or {} end
function FunctionRegistry:findBySource(src) return self._bySource[src] or {} end
function FunctionRegistry:findByName(name) return self._byName[name] or {} end
function FunctionRegistry:findByScript(scriptEntry) return self._byScript[scriptEntry] or {} end

function FunctionRegistry:filter(predicate)
    local out = {}
    for _, e in self._entries do
        if predicate(e) then out[#out + 1] = e end
    end
    return out
end

-- ---------------------------------------------------------------------
-- Stats
-- ---------------------------------------------------------------------

function FunctionRegistry:stats()
    local byKind, bySource = {}, 0
    for _, e in self._entries do
        byKind[e.kind] = (byKind[e.kind] or 0) + 1
        if e.source then bySource = bySource + 1 end
    end
    local fpCount = 0
    for _ in self._byFingerprint do fpCount = fpCount + 1 end
    local sourceCount = 0
    for _ in self._bySource do sourceCount = sourceCount + 1 end
    local linked = 0
    for _, e in self._entries do if e.scriptEntry then linked = linked + 1 end end
    return {
        total           = #self._entries,
        byKind          = byKind,
        uniqueFingerprints = fpCount,
        uniqueSources   = sourceCount,
        withScriptLink  = linked,
        scanCount       = self._scanCount,
        lastScanAt      = self._lastScanAt,
    }
end

return FunctionRegistry
