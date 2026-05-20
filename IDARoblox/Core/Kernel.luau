--!nonstrict
-- =====================================================================
-- IDARoblox / Core / Kernel
-- ---------------------------------------------------------------------
-- The runtime backbone. Responsibilities:
--
--   * Owns one EventBus, one Scheduler, one Logger, one Profiler,
--     and one LoadingManager — the singleton "platform" of the app.
--   * Service locator: anything can register itself by name and be
--     resolved later. Resolution is lazy — `kernel:get("foo")` blocks
--     (yields) until that service registers, with an optional timeout.
--   * Module lifecycle: modules are registered as manifests with the
--     LoadingManager and assigned a StateMachine (Unloaded→Loading→
--     Ready→Error). The Kernel records the FSM state and exposes a
--     `kernel:status(id)` query.
--   * Global error handler routes unhandled rejections, scheduler
--     errors, and event-handler errors to the Logger.
--   * Shutdown sequence: walks modules in reverse topo order, calls
--     each module's `onShutdown` if provided.
--
-- This module DOES NOT import other Core modules at file scope — they
-- are passed in to Kernel.new(). This keeps the Kernel decoupled and
-- testable, and also allows the entry script to swap implementations
-- (e.g. an in-memory logger for tests).
-- =====================================================================

local Kernel = {}
Kernel.__index = Kernel

local DEFAULT_GET_TIMEOUT = 5.0

-- ---------------------------------------------------------------------
-- The module-lifecycle FSM definition (shared by every module)
-- ---------------------------------------------------------------------

local function lifecycleDef(name, eventBus, logger)
    return {
        name = "lifecycle." .. name,
        initial = "Unloaded",
        states = {
            Unloaded = {},
            Loading  = {},
            Ready    = {},
            Error    = {},
            ShutDown = {},
        },
        transitions = {
            { from = "Unloaded", to = "Loading",  on = "load"     },
            { from = "Loading",  to = "Ready",    on = "ready"    },
            { from = "Loading",  to = "Error",    on = "fail"     },
            { from = "Ready",    to = "ShutDown", on = "shutdown" },
            { from = "Error",    to = "Unloaded", on = "reset"    },
            { from = "ShutDown", to = "Unloaded", on = "reset"    },
        },
        historyCap = 16,
        eventBus   = eventBus,
        logger     = logger,
    }
end

-- ---------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------

function Kernel.new(opts)
    opts = opts or {}
    local self = setmetatable({
        _logger          = opts.logger,
        _eventBus        = opts.eventBus,
        _scheduler       = opts.scheduler,
        _profiler        = opts.profiler,
        _loadingManager  = opts.loadingManager,
        _stateMachineCtor = opts.stateMachineCtor,                   -- function returning new SM

        _services        = {},                                       -- name → instance
        _serviceWaiters  = {},                                       -- name → list of threads

        _modules         = {},                                       -- id → { manifest, fsm, returned }
        _moduleOrder     = {},                                       -- order of registration (insertion)

        _booted          = false,
        _shutdownStarted = false,

        _onUnhandled     = opts.onUnhandledError,                    -- (err, source) -> ()
    }, Kernel)
    return self
end

-- ---------------------------------------------------------------------
-- Accessors for the platform singletons
-- ---------------------------------------------------------------------

function Kernel:logger()         return self._logger end
function Kernel:eventBus()       return self._eventBus end
function Kernel:scheduler()      return self._scheduler end
function Kernel:profiler()       return self._profiler end
function Kernel:loadingManager() return self._loadingManager end

-- ---------------------------------------------------------------------
-- Service locator
-- ---------------------------------------------------------------------

function Kernel:register(name: string, instance)
    if type(name) ~= "string" or name == "" then
        error("Kernel:register name must be a non-empty string", 2)
    end
    if self._services[name] then
        error("Kernel: service '" .. name .. "' already registered", 2)
    end
    self._services[name] = instance
    if self._logger then self._logger:debug("Kernel: registered '%s'", name) end
    self._eventBus:emit("kernel.service.registered", { name = name })
    -- Wake any waiters
    local waiters = self._serviceWaiters[name]
    if waiters then
        self._serviceWaiters[name] = nil
        for _, thread in waiters do
            task.spawn(thread, instance)
        end
    end
    return instance
end

function Kernel:has(name: string): boolean
    return self._services[name] ~= nil
end

function Kernel:tryGet(name: string)
    return self._services[name]
end

-- Yielding fetch. Blocks the calling coroutine until the service is
-- registered, or until `timeout` seconds have elapsed. Pass timeout=0
-- (or omit) to use DEFAULT_GET_TIMEOUT.
function Kernel:get(name: string, timeout: number?)
    local existing = self._services[name]
    if existing then return existing end

    local thread = coroutine.running()
    assert(thread, "Kernel:get must be called from a coroutine if the service is not yet registered")

    self._serviceWaiters[name] = self._serviceWaiters[name] or {}
    table.insert(self._serviceWaiters[name], thread)

    local t = if (timeout and timeout > 0) then timeout else DEFAULT_GET_TIMEOUT
    local timeoutThread = task.delay(t, function()
        local list = self._serviceWaiters[name]
        if not list then return end
        for i, th in list do
            if th == thread then
                table.remove(list, i)
                task.spawn(thread, nil, "timeout")
                return
            end
        end
    end)

    local result, err = coroutine.yield()
    task.cancel(timeoutThread)
    if not result then
        error(string.format("Kernel: service '%s' unavailable: %s", name, tostring(err or "?")), 2)
    end
    return result
end

function Kernel:unregister(name: string)
    self._services[name] = nil
    self._eventBus:emit("kernel.service.unregistered", { name = name })
end

function Kernel:listServices(): { string }
    local out = {}
    for n in self._services do out[#out + 1] = n end
    table.sort(out)
    return out
end

-- ---------------------------------------------------------------------
-- Module registration
-- ---------------------------------------------------------------------
-- Module manifest format extends LoadingManager's by adding:
--   onShutdown = function(kernel) ... end   -- optional
--   serviceName = "Analysis.BytecodeParser" -- if set, the module's
--                                              return value is registered
--                                              as a service under that name

function Kernel:registerModule(manifest)
    if self._modules[manifest.id] then
        error("Kernel: module '" .. manifest.id .. "' already registered", 2)
    end
    local fsm
    if self._stateMachineCtor then
        fsm = self._stateMachineCtor(lifecycleDef(manifest.id, self._eventBus, self._logger))
    end
    self._modules[manifest.id] = {
        manifest    = manifest,
        fsm         = fsm,
        returned    = nil,
        loadedAt    = 0,
    }
    table.insert(self._moduleOrder, manifest.id)
    -- Forward to LoadingManager. We wrap each stage's fn to drive the FSM.
    local wrappedStages = {}
    for i, s in manifest.stages do
        wrappedStages[i] = {
            id = s.id,
            weight = s.weight,
            fn = function(ctx)
                if fsm and i == 1 and fsm:current() == "Unloaded" then
                    fsm:fire("load")
                end
                local r = s.fn(ctx)
                if i == #manifest.stages then
                    self._modules[manifest.id].returned = r
                end
                return r
            end,
        }
    end
    self._loadingManager:register({
        id = manifest.id,
        dependencies = manifest.dependencies,
        weight = manifest.weight,
        stages = wrappedStages,
        ctx = manifest.ctx,
    })

    -- Hook into LoadingManager events to drive the FSM
    self._eventBus:on("loading.module.end", function(_, payload)
        if payload.id ~= manifest.id then return end
        local rec = self._modules[manifest.id]
        if fsm then fsm:fire("ready") end
        rec.loadedAt = os.clock()
        if manifest.serviceName then
            local val = rec.returned
            if val ~= nil then
                self:register(manifest.serviceName, val)
            end
        end
    end)
    self._eventBus:on("loading.module.error", function(_, payload)
        if payload.id ~= manifest.id then return end
        if fsm then fsm:fire("fail", payload) end
    end)
end

function Kernel:moduleStatus(id: string): string?
    local m = self._modules[id]
    if not m then return nil end
    if m.fsm then return m.fsm:current() end
    return self._loadingManager:moduleStatus(id)
end

function Kernel:moduleManifest(id: string)
    local m = self._modules[id]
    return m and m.manifest
end

function Kernel:listModules(): { string }
    return table.clone(self._moduleOrder)
end

-- ---------------------------------------------------------------------
-- Boot
-- ---------------------------------------------------------------------

function Kernel:boot()
    if self._booted then
        error("Kernel: already booted", 2)
    end
    self._booted = true
    if self._logger then self._logger:info("Kernel: booting (%d modules)", #self._moduleOrder) end
    self._eventBus:emit("kernel.boot.begin", { modules = #self._moduleOrder })

    -- Install scheduler error sink
    if self._scheduler and self._logger then
        self._scheduler._onError = function(err, info)
            self._logger:error("Scheduler task error: %s", tostring(err))
            if self._onUnhandled then pcall(self._onUnhandled, err, "scheduler") end
        end
    end

    local ok, err = pcall(function()
        self._loadingManager:loadAll()
    end)
    if not ok then
        if self._logger then self._logger:fatal("Kernel: boot failed: %s", tostring(err)) end
        self._eventBus:emit("kernel.boot.error", { error = err })
        if self._onUnhandled then pcall(self._onUnhandled, err, "boot") end
        error(err, 0)
    end

    if self._logger then self._logger:info("Kernel: boot complete") end
    self._eventBus:emit("kernel.boot.end", {})
end

function Kernel:bootAsync()
    return task.spawn(function() self:boot() end)
end

-- ---------------------------------------------------------------------
-- Shutdown
-- ---------------------------------------------------------------------

function Kernel:shutdown()
    if self._shutdownStarted then return end
    self._shutdownStarted = true
    if self._logger then self._logger:info("Kernel: shutting down") end
    self._eventBus:emit("kernel.shutdown.begin", {})

    -- Reverse order — last-loaded first
    for i = #self._moduleOrder, 1, -1 do
        local id = self._moduleOrder[i]
        local rec = self._modules[id]
        if rec and rec.manifest.onShutdown then
            local ok, err = pcall(rec.manifest.onShutdown, self)
            if not ok then
                if self._logger then
                    self._logger:warn("Kernel: '%s' shutdown error: %s", id, tostring(err))
                end
            end
        end
        if rec and rec.fsm then
            pcall(function() rec.fsm:fire("shutdown") end)
        end
        if rec and rec.manifest.serviceName then
            self:unregister(rec.manifest.serviceName)
        end
    end

    self._scheduler:stop()
    self._eventBus:emit("kernel.shutdown.end", {})
    if self._logger then self._logger:info("Kernel: shutdown complete") end
end

-- ---------------------------------------------------------------------
-- Convenience: built-in service shortcuts
-- ---------------------------------------------------------------------

function Kernel:installDefaults()
    -- Registers the platform singletons under conventional names so
    -- modules can `kernel:get("EventBus")` without going through accessors.
    if self._eventBus       then self:register("EventBus", self._eventBus) end
    if self._logger         then self:register("Logger", self._logger) end
    if self._scheduler      then self:register("Scheduler", self._scheduler) end
    if self._profiler       then self:register("Profiler", self._profiler) end
    if self._loadingManager then self:register("LoadingManager", self._loadingManager) end
    self:register("Kernel", self)
end

return Kernel
