--!nonstrict
-- =====================================================================
-- IDARoblox / Plugins / PluginLoader
-- ---------------------------------------------------------------------
-- Host for IDARoblox plugins. Owns:
--   * a registry of installed plugins (id → record)
--   * lifecycle dispatch (init, onBytecodeLoad, scan, onRow, cleanup)
--   * automatic registration of plugin-declared patterns with the
--     PatternMatcher
--   * error-threshold disable (a plugin that errors >N times is auto-
--     disabled so it can't keep crashing the host)
--   * per-plugin stats (calls per hook, errors, last error message)
--
-- Construction
--   PluginLoader.new {
--     matcher        = PatternMatcher,
--     logger         = Logger,
--     eventBus       = EventBus,
--     projectDB      = ProjectDB,            -- optional
--     runtime        = Runtime,              -- optional
--     search         = SearchEngine,         -- optional
--     errorThreshold = 5,
--   }
--
-- Plugin manifests follow the schema in PluginAPI.
-- =====================================================================

local PluginAPI = _G.IDARo.require("Plugins.PluginAPI")

local PluginLoader = {}
PluginLoader.__index = PluginLoader

local DEFAULT_ERROR_THRESHOLD = 5
local DEFAULT_PRIORITY        = 100

-- ---------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------

function PluginLoader.new(opts)
    opts = opts or {}
    local services = {
        logger    = opts.logger,
        eventBus  = opts.eventBus,
        matcher   = opts.matcher,
        projectDB = opts.projectDB,
        runtime   = opts.runtime,
        bytecode  = opts.bytecode,
        search    = opts.search,
    }
    return setmetatable({
        _services       = services,
        _logger         = opts.logger,
        _matcher        = opts.matcher,
        _eventBus       = opts.eventBus,
        _projectDB      = opts.projectDB,
        _errorThreshold = opts.errorThreshold or DEFAULT_ERROR_THRESHOLD,
        _plugins        = {},
        _order          = {},
        _bytecode       = nil,
        _stats = {
            registered = 0,
            disabled   = 0,
            scanCount  = 0,
        },
    }, PluginLoader)
end

local function emit(self, evt, payload)
    if self._eventBus and type(self._eventBus.emit) == "function" then
        pcall(self._eventBus.emit, self._eventBus, evt, payload)
    end
end

-- ---------------------------------------------------------------------
-- Service updates (workspace re-points these as bytecode reloads)
-- ---------------------------------------------------------------------

function PluginLoader:setBytecode(bc)
    self._bytecode = bc
    self._services.bytecode = bc
end
function PluginLoader:setProjectDB(db)
    self._projectDB = db
    self._services.projectDB = db
end
function PluginLoader:setRuntime(r) self._services.runtime = r end
function PluginLoader:setSearch(s)  self._services.search  = s  end

-- ---------------------------------------------------------------------
-- Safe-call wrapper
-- ---------------------------------------------------------------------

local function safeCall(self, record, hook, ...)
    local fn = record.manifest[hook]
    if not fn then return true, nil end
    local args = table.pack(...)
    local results = table.pack(pcall(fn, record.self, table.unpack(args, 1, args.n)))
    if results[1] then
        record.stats.calls[hook] = (record.stats.calls[hook] or 0) + 1
        return true, table.unpack(results, 2, results.n)
    end
    record.stats.errors    = record.stats.errors + 1
    record.stats.lastError = tostring(results[2])
    if self._logger then
        self._logger:warn("Plugin '%s' [%s] failed: %s",
            record.manifest.id, hook, tostring(results[2]))
    end
    emit(self, "plugin.error",
        { id = record.manifest.id, hook = hook, err = tostring(results[2]) })
    if record.stats.errors >= self._errorThreshold and record.enabled then
        record.enabled = false
        self._stats.disabled = self._stats.disabled + 1
        if self._logger then
            self._logger:error(
                "Plugin '%s' auto-disabled after %d errors (threshold %d)",
                record.manifest.id, record.stats.errors, self._errorThreshold)
        end
        emit(self, "plugin.disabled",
            { id = record.manifest.id, reason = "error-threshold" })
    end
    return false, results[2]
end

-- ---------------------------------------------------------------------
-- Registration
-- ---------------------------------------------------------------------

function PluginLoader:register(manifest)
    local ok, err = PluginAPI.validateManifest(manifest)
    if not ok then return nil, err end
    if self._plugins[manifest.id] then
        return nil, "plugin already registered: " .. manifest.id
    end
    if manifest.dependencies then
        for _, dep in manifest.dependencies do
            if not self._plugins[dep] then
                return nil, "missing dependency: " .. dep
            end
        end
    end
    -- Service requirements
    local availability = {}
    for key, svc in self._services do
        if svc ~= nil then availability[key] = true end
    end
    local rok, rerr = PluginAPI.validateRequires(manifest, availability)
    if not rok then return nil, rerr end

    local record = {
        manifest      = manifest,
        self          = setmetatable({}, { __index = manifest }),
        enabled       = manifest.enabledByDefault ~= false,
        priority      = manifest.priority or DEFAULT_PRIORITY,
        registeredAt  = os.clock(),
        stats = {
            calls     = {},
            errors    = 0,
            lastError = nil,
        },
    }
    -- Auto-register patterns
    if manifest.patterns and self._matcher then
        for _, p in manifest.patterns do
            local pCopy = {
                id          = manifest.id .. "." .. (p.id or "pattern"),
                description = p.description or "",
                category    = p.category or manifest.id,
                atoms       = p.atoms,
                onMatch     = p.onMatch,
                _pluginId   = manifest.id,
            }
            self._matcher:register(pCopy)
        end
    end
    self._plugins[manifest.id] = record
    self._order[#self._order + 1] = manifest.id
    -- Keep _order sorted by priority (low priority runs first)
    table.sort(self._order, function(a, b)
        local pa = self._plugins[a].priority
        local pb = self._plugins[b].priority
        if pa == pb then return a < b end
        return pa < pb
    end)
    self._stats.registered = self._stats.registered + 1

    local ctx = PluginAPI.buildContext(self._services)
    safeCall(self, record, PluginAPI.Hook.INIT, ctx)
    emit(self, "plugin.registered", { id = manifest.id })
    return record
end

function PluginLoader:unregister(id)
    local record = self._plugins[id]
    if not record then return false, "not registered" end
    local ctx = PluginAPI.buildContext(self._services)
    safeCall(self, record, PluginAPI.Hook.CLEANUP, ctx)
    self._plugins[id] = nil
    for i, pid in self._order do
        if pid == id then table.remove(self._order, i); break end
    end
    emit(self, "plugin.unregistered", { id = id })
    return true
end

-- ---------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------

function PluginLoader:onBytecodeLoaded(bytecode)
    self:setBytecode(bytecode)
    local ctx = PluginAPI.buildContext(self._services)
    for _, id in self._order do
        local r = self._plugins[id]
        if r.enabled then
            safeCall(self, r, PluginAPI.Hook.ON_BYTECODE_LOAD, bytecode, ctx)
        end
    end
    -- Run scan after all onBytecodeLoad — gives plugins a chance to set
    -- up shared state before scans collect findings.
    for _, id in self._order do
        local r = self._plugins[id]
        if r.enabled then
            self._stats.scanCount = self._stats.scanCount + 1
            safeCall(self, r, PluginAPI.Hook.SCAN, bytecode, ctx)
        end
    end
end

function PluginLoader:annotateRow(row, proto)
    local out = {}
    local ctx = PluginAPI.buildContext(self._services)
    for _, id in self._order do
        local r = self._plugins[id]
        if r.enabled and r.manifest.onRow then
            local ok, ann = safeCall(self, r, PluginAPI.Hook.ON_ROW, row, proto, ctx)
            if ok and ann then
                if type(ann) == "table" and ann.source then
                    out[#out + 1] = ann
                elseif type(ann) == "table" then
                    for _, a in ann do out[#out + 1] = a end
                end
            end
        end
    end
    return out
end

-- ---------------------------------------------------------------------
-- Enable / disable
-- ---------------------------------------------------------------------

function PluginLoader:setEnabled(id, enabled)
    local r = self._plugins[id]
    if not r then return false, "not registered" end
    if r.enabled == enabled then return true end
    r.enabled = enabled
    emit(self, enabled and "plugin.enabled" or "plugin.disabled",
        { id = id, reason = "user" })
    return true
end

-- ---------------------------------------------------------------------
-- Inspection
-- ---------------------------------------------------------------------

function PluginLoader:get(id) return self._plugins[id] end

function PluginLoader:list()
    local out = {}
    for _, id in self._order do out[#out + 1] = self._plugins[id] end
    return out
end

function PluginLoader:listSorted(comparator)
    local out = self:list()
    table.sort(out, comparator or function(a, b)
        return (a.priority or 0) < (b.priority or 0)
    end)
    return out
end

function PluginLoader:count() return #self._order end

function PluginLoader:stats()
    return {
        registered  = self._stats.registered,
        currentCount = #self._order,
        disabledCount = (function()
            local n = 0
            for _, r in self._plugins do
                if not r.enabled then n = n + 1 end
            end
            return n
        end)(),
        autoDisabled = self._stats.disabled,
        scanCount    = self._stats.scanCount,
    }
end

function PluginLoader:pluginStats(id)
    local r = self._plugins[id]
    if not r then return nil end
    return {
        id        = id,
        enabled   = r.enabled,
        priority  = r.priority,
        calls     = r.stats.calls,
        errors    = r.stats.errors,
        lastError = r.stats.lastError,
    }
end

return PluginLoader
