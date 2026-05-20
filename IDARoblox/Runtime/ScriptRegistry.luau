--!nonstrict
-- =====================================================================
-- IDARoblox / Runtime / ScriptRegistry
-- ---------------------------------------------------------------------
-- Live-script directory. Wraps EnvironmentScanner's script enumeration
-- with caching, delta computation, and filtering helpers.
--
-- Each registry entry:
--   {
--     script       = <Instance>,      -- the actual script object
--     id           = N,               -- stable id within this registry
--     name         = string,          -- script.Name (cached at scan time)
--     className    = string,          -- ClassName ("LocalScript", …)
--     path         = string,          -- full Roblox path "game.Workspace.…"
--     origin       = "modules"|"running"|"both",
--     firstSeenAt  = os.clock(),
--     lastSeenAt   = os.clock(),
--     bytecode     = string?,         -- cached after first getBytecode call
--     bytecodeAge  = os.clock()?,     -- when the cache was filled
--     bytecodeError= string?,         -- if retrieval failed
--     parsed       = ParsedBytecode?, -- cached after first parse
--     parseError   = string?,
--   }
--
-- Lookup indexes:
--   _byScript   : Instance → entry
--   _byName     : string   → { entry, … }   (multiple scripts can share a name)
--   _byClass    : string   → { entry, … }
--   _entries    : flat list, stable order = first-seen
--
-- :scan() repopulates from EnvironmentScanner and returns
--   { added = { entry, … }, removed = { entry, … }, kept = N }
-- so the UI can show "+3 new scripts" notifications.
-- =====================================================================

local ScriptRegistry = {}
ScriptRegistry.__index = ScriptRegistry

-- ---------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------

function ScriptRegistry.new(opts)
    if not opts or not opts.scanner then
        error("ScriptRegistry.new: opts.scanner required", 2)
    end
    return setmetatable({
        _scanner    = opts.scanner,
        _parser     = opts.parser,                                   -- optional BytecodeParser
        _logger     = opts.logger,
        _entries    = {},
        _byScript   = {},
        _byName     = {},
        _byClass    = {},
        _nextId     = 1,
        _lastScanAt = nil,
        _scanCount  = 0,
    }, ScriptRegistry)
end

-- ---------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------

local function safeName(script)
    local ok, n = pcall(function() return script.Name end)
    return ok and n or "<?>"
end

local function safeClass(script)
    local ok, c = pcall(function() return script.ClassName end)
    return ok and c or "<?>"
end

local function safePath(script)
    -- Build a Roblox-style path. Falls back to short name if walk fails.
    local ok, p = pcall(function()
        return script:GetFullName()
    end)
    if ok and p then return p end
    return safeName(script)
end

local function ensureNameBucket(self, name)
    local b = self._byName[name]
    if not b then b = {}; self._byName[name] = b end
    return b
end

local function ensureClassBucket(self, className)
    local b = self._byClass[className]
    if not b then b = {}; self._byClass[className] = b end
    return b
end

-- ---------------------------------------------------------------------
-- Scan / delta computation
-- ---------------------------------------------------------------------

function ScriptRegistry:scan()
    local scripts, originMap = self._scanner:scanScripts()
    local now = os.clock()
    self._scanCount = self._scanCount + 1
    self._lastScanAt = now

    -- Build the set of currently-live scripts.
    local liveSet = {}
    for _, s in scripts do liveSet[s] = true end

    -- Detect added.
    local added = {}
    for _, s in scripts do
        local existing = self._byScript[s]
        if existing then
            existing.lastSeenAt = now
            -- Origin may upgrade between scans (loaded → loaded+running).
            local origin = originMap[s]
            if origin and existing.origin ~= "both" and origin ~= existing.origin then
                existing.origin = "both"
            end
        else
            local id = self._nextId
            self._nextId = id + 1
            local entry = {
                script       = s,
                id           = id,
                name         = safeName(s),
                className    = safeClass(s),
                path         = safePath(s),
                origin       = originMap[s] or "modules",
                firstSeenAt  = now,
                lastSeenAt   = now,
                bytecode     = nil,
                bytecodeAge  = nil,
                bytecodeError= nil,
                parsed       = nil,
                parseError   = nil,
            }
            self._byScript[s] = entry
            self._entries[#self._entries + 1] = entry
            local nb = ensureNameBucket(self, entry.name)
            nb[#nb + 1] = entry
            local cb = ensureClassBucket(self, entry.className)
            cb[#cb + 1] = entry
            added[#added + 1] = entry
        end
    end

    -- Detect removed (entries whose script object is no longer enumerated).
    local removed = {}
    for i = #self._entries, 1, -1 do
        local entry = self._entries[i]
        if not liveSet[entry.script] then
            removed[#removed + 1] = entry
            self._byScript[entry.script] = nil
            -- Don't compact name/class buckets immediately — they're
            -- reconstructed on next scan; rebuilding them in-place here
            -- would be O(N²) for large script counts.
            entry._removed = true
        end
    end
    if #removed > 0 then
        -- Compact the main list.
        local compact = {}
        for _, e in self._entries do
            if not e._removed then compact[#compact + 1] = e end
        end
        self._entries = compact
        -- Rebuild bucket indexes once.
        self._byName, self._byClass = {}, {}
        for _, e in self._entries do
            local nb = ensureNameBucket(self, e.name); nb[#nb + 1] = e
            local cb = ensureClassBucket(self, e.className); cb[#cb + 1] = e
        end
    end

    if self._logger then
        self._logger:info("ScriptRegistry: scan #%d → %d live (added %d, removed %d)",
            self._scanCount, #self._entries, #added, #removed)
    end

    return { added = added, removed = removed, kept = #self._entries - #added }
end

-- ---------------------------------------------------------------------
-- Bytecode + parsed-bytecode caching
-- ---------------------------------------------------------------------

function ScriptRegistry:getBytecode(entryOrScript)
    local entry = type(entryOrScript) == "userdata"
        and self._byScript[entryOrScript] or entryOrScript
    if not entry then return nil, "no such script" end
    if entry.bytecode then return entry.bytecode end
    if entry.bytecodeError then return nil, entry.bytecodeError end

    local bc = self._scanner:getBytecode(entry.script)
    if bc then
        entry.bytecode = bc
        entry.bytecodeAge = os.clock()
        return bc
    end
    entry.bytecodeError = "retrieval failed"
    return nil, entry.bytecodeError
end

function ScriptRegistry:getParsed(entryOrScript)
    local entry = type(entryOrScript) == "userdata"
        and self._byScript[entryOrScript] or entryOrScript
    if not entry then return nil, "no such script" end
    if entry.parsed then return entry.parsed end
    if entry.parseError then return nil, entry.parseError end
    if not self._parser then return nil, "no parser configured" end

    local bc, bcErr = self:getBytecode(entry)
    if not bc then return nil, bcErr end

    local ok, parsed = pcall(function()
        return self._parser.parse(bc)
    end)
    if not ok then
        entry.parseError = "parse failed: " .. tostring(parsed)
        if self._logger then
            self._logger:warn("ScriptRegistry: parse failed for %s — %s",
                entry.path, tostring(parsed))
        end
        return nil, entry.parseError
    end
    entry.parsed = parsed
    return parsed
end

function ScriptRegistry:invalidateBytecode(entryOrScript)
    local entry = type(entryOrScript) == "userdata"
        and self._byScript[entryOrScript] or entryOrScript
    if not entry then return end
    entry.bytecode = nil
    entry.bytecodeAge = nil
    entry.bytecodeError = nil
    entry.parsed = nil
    entry.parseError = nil
end

-- ---------------------------------------------------------------------
-- Queries
-- ---------------------------------------------------------------------

function ScriptRegistry:entries() return self._entries end

function ScriptRegistry:entryFor(script) return self._byScript[script] end

function ScriptRegistry:findByName(name)
    return self._byName[name] or {}
end

function ScriptRegistry:findByClass(className)
    return self._byClass[className] or {}
end

function ScriptRegistry:findByPath(substring)
    local sub = string.lower(substring or "")
    if sub == "" then return self._entries end
    local out = {}
    for _, e in self._entries do
        if string.find(string.lower(e.path), sub, 1, true) then
            out[#out + 1] = e
        end
    end
    return out
end

function ScriptRegistry:stats()
    local byClass = {}
    local withBytecode = 0
    local withParsed   = 0
    for _, e in self._entries do
        byClass[e.className] = (byClass[e.className] or 0) + 1
        if e.bytecode then withBytecode = withBytecode + 1 end
        if e.parsed   then withParsed   = withParsed   + 1 end
    end
    return {
        total        = #self._entries,
        byClass      = byClass,
        withBytecode = withBytecode,
        withParsed   = withParsed,
        scanCount    = self._scanCount,
        lastScanAt   = self._lastScanAt,
    }
end

return ScriptRegistry
