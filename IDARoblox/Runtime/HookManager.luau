--!nonstrict
-- =====================================================================
-- IDARoblox / Runtime / HookManager
-- ---------------------------------------------------------------------
-- Manages function hooks installed via the executor's hookfunction
-- (or aliases: replaceclosure / hookfunc). Tracks every active hook
-- with metadata, originals for safe restoration, call counts, and
-- error counts. Surfaces install/uninstall/error events via an
-- EventBus so the UI can react.
--
-- Hook record:
--   {
--     id           = N,
--     target       = <function>,        -- the original function being replaced
--     replacement  = <function>,        -- what callers will actually invoke
--     original     = <function>,        -- safe pointer to the original behaviour
--     label        = string,            -- short user-facing name
--     sourceLabel  = string?,           -- optional context ("MyScript.luau:42")
--     kind         = "raw"|"logger"|"counter"|"print"|"return",
--     installedAt  = os.clock(),
--     active       = boolean,
--     callCount    = N,                 -- how many times the hook fired
--     errorCount   = N,                 -- how many calls raised errors
--     log          = { … } | nil,       -- per-call log (logger kind only)
--     maxLogSize   = N?,                -- ring-buffer cap for log
--   }
--
-- Events emitted on opts.eventBus (if provided):
--   "hook.installed"   payload = record
--   "hook.uninstalled" payload = record
--   "hook.called"      payload = { record, args, ok, results }
--                                     (only when track-calls is true)
--   "hook.error"       payload = { record, err }
-- =====================================================================

local HookManager = {}
HookManager.__index = HookManager

-- ---------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------

function HookManager.new(opts)
    opts = opts or {}
    if not opts.scanner then error("HookManager.new: opts.scanner required", 2) end
    return setmetatable({
        _scanner    = opts.scanner,
        _logger     = opts.logger,
        _eventBus   = opts.eventBus,
        _registry   = opts.functionRegistry,                         -- optional
        _hooks      = {},                                            -- id → record
        _byTarget   = {},                                            -- fn → id
        _nextId     = 1,
        _installCount = 0,
        _uninstallCount = 0,
    }, HookManager)
end

-- ---------------------------------------------------------------------
-- Capability check
-- ---------------------------------------------------------------------

function HookManager:available()
    return self._scanner:capabilities().hookfunction ~= nil
end

local function emit(self, event, payload)
    if self._eventBus and type(self._eventBus.emit) == "function" then
        pcall(self._eventBus.emit, self._eventBus, event, payload)
    end
end

-- ---------------------------------------------------------------------
-- Raw install / uninstall
-- ---------------------------------------------------------------------

function HookManager:install(target, replacement, opts)
    opts = opts or {}
    if type(target) ~= "function" then
        return nil, "install: target must be a function"
    end
    if type(replacement) ~= "function" then
        return nil, "install: replacement must be a function"
    end
    if self._byTarget[target] then
        return nil, "install: target already hooked"
    end
    if not self:available() then
        return nil, "install: hookfunction not available in this environment"
    end

    local hookFn = self._scanner:capabilities().hookfunction
    local ok, original = pcall(hookFn, target, replacement)
    if not ok then
        return nil, "install: hookfunction failed → " .. tostring(original)
    end

    local id = self._nextId
    self._nextId = id + 1
    local record = {
        id           = id,
        target       = target,
        replacement  = replacement,
        original     = original,
        label        = opts.label       or string.format("hook#%d", id),
        sourceLabel  = opts.sourceLabel,
        kind         = opts.kind        or "raw",
        installedAt  = os.clock(),
        active       = true,
        callCount    = 0,
        errorCount   = 0,
        log          = opts.log,
        maxLogSize   = opts.maxLogSize,
    }
    self._hooks[id] = record
    self._byTarget[target] = id
    self._installCount = self._installCount + 1

    emit(self, "hook.installed", record)
    if self._logger then
        self._logger:info("HookManager: installed hook #%d (%s)", id, record.label)
    end
    return record
end

function HookManager:uninstall(idOrRecord)
    local record = type(idOrRecord) == "number"
        and self._hooks[idOrRecord]
        or idOrRecord
    if not record then return false, "no such hook" end
    if not record.active then return false, "hook already inactive" end

    local hookFn = self._scanner:capabilities().hookfunction
    if not hookFn then return false, "hookfunction not available" end

    -- Restore: hookfunction(target, original) returns the current replacement
    -- and installs `original` as the new behaviour.
    local ok, err = pcall(hookFn, record.target, record.original)
    if not ok then
        emit(self, "hook.error", { record = record, err = err })
        return false, "uninstall failed: " .. tostring(err)
    end

    record.active = false
    self._byTarget[record.target] = nil
    self._uninstallCount = self._uninstallCount + 1

    emit(self, "hook.uninstalled", record)
    if self._logger then
        self._logger:info("HookManager: uninstalled hook #%d (%s)", record.id, record.label)
    end
    return true
end

function HookManager:uninstallAll()
    local n = 0
    for id, record in self._hooks do
        if record.active then
            local ok = self:uninstall(id)
            if ok then n = n + 1 end
        end
    end
    return n
end

-- ---------------------------------------------------------------------
-- Queries
-- ---------------------------------------------------------------------

function HookManager:listActive()
    local out = {}
    for _, record in self._hooks do
        if record.active then out[#out + 1] = record end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

function HookManager:listAll()
    local out = {}
    for _, record in self._hooks do out[#out + 1] = record end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

function HookManager:findByTarget(target)
    local id = self._byTarget[target]
    return id and self._hooks[id] or nil
end

function HookManager:get(id) return self._hooks[id] end

-- ---------------------------------------------------------------------
-- Bookkeeping helpers used by convenience installers
-- ---------------------------------------------------------------------

local function bumpCall(record, ok, err)
    record.callCount = record.callCount + 1
    if not ok then
        record.errorCount = record.errorCount + 1
        if record._owner then emit(record._owner, "hook.error", { record = record, err = err }) end
    end
end

local function pushLog(record, entry)
    local log = record.log
    if not log then return end
    log[#log + 1] = entry
    if record.maxLogSize and #log > record.maxLogSize then
        table.remove(log, 1)
    end
end

-- ---------------------------------------------------------------------
-- Convenience installers
-- ---------------------------------------------------------------------

-- Counter: just bumps callCount on each call, returns original results.
function HookManager:installCounter(target, opts)
    opts = opts or {}
    local self_ref = self
    local recordRef                                                  -- assigned below
    local replacement = function(...)
        local ok, a, b, c, d, e, f, g, h = pcall(recordRef.original, ...)
        bumpCall(recordRef, ok, a)
        if not ok then return nil end
        return a, b, c, d, e, f, g, h
    end
    local record, err = self:install(target, replacement, {
        label = opts.label or "counter",
        sourceLabel = opts.sourceLabel,
        kind = "counter",
    })
    if record then
        recordRef = record
        record._owner = self_ref
    end
    return record, err
end

-- Logger: records every call (timestamp + arg count + arg type list).
-- Optional argCapture controls whether arg values are captured (via
-- tostring; default off for memory safety).
function HookManager:installLogger(target, opts)
    opts = opts or {}
    local maxLog = opts.maxLogSize or 256
    local capture = opts.argCapture == true
    local log = {}
    local recordRef
    local function callbackFor(record) record._owner = self end
    local replacement = function(...)
        local n = select("#", ...)
        local types = table.create(n)
        for i = 1, n do types[i] = type(select(i, ...)) end
        local args = nil
        if capture then
            args = table.create(n)
            for i = 1, n do
                local v = select(i, ...)
                local repr = tostring(v)
                if #repr > 80 then repr = string.sub(repr, 1, 77) .. "..." end
                args[i] = repr
            end
        end
        local ok, a, b, c, d, e, f, g, h = pcall(recordRef.original, ...)
        bumpCall(recordRef, ok, a)
        pushLog(recordRef, {
            at       = os.clock(),
            argCount = n,
            argTypes = types,
            args     = args,
            ok       = ok,
            err      = (not ok) and tostring(a) or nil,
        })
        emit(self, "hook.called", { record = recordRef, ok = ok })
        if not ok then return nil end
        return a, b, c, d, e, f, g, h
    end
    local record, err = self:install(target, replacement, {
        label       = opts.label or "logger",
        sourceLabel = opts.sourceLabel,
        kind        = "logger",
        log         = log,
        maxLogSize  = maxLog,
    })
    if record then
        recordRef = record
        callbackFor(record)
    end
    return record, err
end

-- Print-trace: same as logger, but also prints args to the output panel.
function HookManager:installPrintTrace(target, opts)
    opts = opts or {}
    local recordRef
    local replacement = function(...)
        local n = select("#", ...)
        local parts = table.create(n)
        for i = 1, n do
            local v = select(i, ...)
            local repr = tostring(v)
            if #repr > 80 then repr = string.sub(repr, 1, 77) .. "..." end
            parts[i] = repr
        end
        if self._logger then
            self._logger:debug("[%s] called(%s)", recordRef.label, table.concat(parts, ", "))
        end
        local ok, a, b, c, d, e, f, g, h = pcall(recordRef.original, ...)
        bumpCall(recordRef, ok, a)
        if not ok then return nil end
        return a, b, c, d, e, f, g, h
    end
    local record, err = self:install(target, replacement, {
        label       = opts.label or "print-trace",
        sourceLabel = opts.sourceLabel,
        kind        = "print",
    })
    if record then
        recordRef = record
        record._owner = self
    end
    return record, err
end

-- Replace-return: always returns the given values, ignoring the original.
function HookManager:installReplaceReturn(target, opts)
    opts = opts or {}
    local returnValues = opts.values or {}
    local recordRef
    local replacement = function(...)
        recordRef.callCount = recordRef.callCount + 1
        return table.unpack(returnValues)
    end
    local record, err = self:install(target, replacement, {
        label       = opts.label or "replace-return",
        sourceLabel = opts.sourceLabel,
        kind        = "return",
    })
    if record then
        recordRef = record
        record._owner = self
        record.returnValues = returnValues
    end
    return record, err
end

-- ---------------------------------------------------------------------
-- Stats
-- ---------------------------------------------------------------------

function HookManager:stats()
    local active, total, callsTotal, errorsTotal = 0, 0, 0, 0
    local byKind = {}
    for _, record in self._hooks do
        total = total + 1
        if record.active then active = active + 1 end
        callsTotal   = callsTotal + record.callCount
        errorsTotal  = errorsTotal + record.errorCount
        byKind[record.kind] = (byKind[record.kind] or 0) + 1
    end
    return {
        active         = active,
        total          = total,
        installCount   = self._installCount,
        uninstallCount = self._uninstallCount,
        callsTotal     = callsTotal,
        errorsTotal    = errorsTotal,
        byKind         = byKind,
    }
end

return HookManager
