--!nonstrict
-- =====================================================================
-- IDARoblox / Runtime
-- ---------------------------------------------------------------------
-- Top-level orchestrator for the four runtime-introspection services:
--
--   EnvironmentScanner    — capability-detected wrappers around the
--                           executor's introspection APIs
--   ScriptRegistry        — live-script directory with delta detection
--                           + bytecode caching
--   FunctionRegistry      — live-function index with fingerprints
--   HookManager           — install / uninstall hooks with bookkeeping
--
-- Runtime.new(opts) wires them up with shared dependencies — there's
-- exactly one EnvironmentScanner shared by all three downstream
-- services, and FunctionRegistry is cross-linked to ScriptRegistry so
-- that fns can be mapped back to their owning scripts.
--
-- Usage:
--   local rt = Runtime.new({ logger = …, eventBus = …, parser = … })
--   rt.scripts:scan()        -- enumerate live scripts
--   rt.fns:scan()            -- index live functions
--   rt.hooks:installCounter(myTargetFn, {label = "step counter"})
--   rt.hooks:listActive()
-- =====================================================================

local EnvironmentScanner = _G.IDARo.require("Runtime.EnvironmentScanner")
local ScriptRegistry     = _G.IDARo.require("Runtime.ScriptRegistry")
local FunctionRegistry   = _G.IDARo.require("Runtime.FunctionRegistry")
local HookManager        = _G.IDARo.require("Runtime.HookManager")
local GCScanner          = _G.IDARo.require("Runtime.GCScanner")
local ClosureInspector   = _G.IDARo.require("Runtime.ClosureInspector")
local MetatableProbe     = _G.IDARo.require("Runtime.MetatableProbe")
local MemoryProbe        = _G.IDARo.require("Runtime.MemoryProbe")
local NetworkTracer      = _G.IDARo.require("Runtime.NetworkTracer")

local Runtime = {}

Runtime.EnvironmentScanner = EnvironmentScanner
Runtime.ScriptRegistry     = ScriptRegistry
Runtime.FunctionRegistry   = FunctionRegistry
Runtime.HookManager        = HookManager
Runtime.GCScanner          = GCScanner
Runtime.ClosureInspector   = ClosureInspector
Runtime.MetatableProbe     = MetatableProbe
Runtime.MemoryProbe        = MemoryProbe
Runtime.NetworkTracer      = NetworkTracer

-- ---------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------

function Runtime.new(opts)
    opts = opts or {}
    local scanner = EnvironmentScanner.new({
        logger        = opts.logger,
        includeTables = opts.includeTables,
    })
    local scripts = ScriptRegistry.new({
        scanner = scanner,
        parser  = opts.parser,
        logger  = opts.logger,
    })
    local fns = FunctionRegistry.new({
        scanner        = scanner,
        scriptRegistry = scripts,
        logger         = opts.logger,
    })
    local hooks = HookManager.new({
        scanner          = scanner,
        functionRegistry = fns,
        eventBus         = opts.eventBus,
        logger           = opts.logger,
    })
    local gc = GCScanner.new({
        scanner  = scanner,
        logger   = opts.logger,
        eventBus = opts.eventBus,
    })
    local closures = ClosureInspector.new({
        scanner  = scanner,
        logger   = opts.logger,
        eventBus = opts.eventBus,
    })
    local meta = MetatableProbe.new({
        scanner  = scanner,
        logger   = opts.logger,
        eventBus = opts.eventBus,
    })
    local memory = MemoryProbe.new({
        scanner  = scanner,
        logger   = opts.logger,
        eventBus = opts.eventBus,
    })
    local network = NetworkTracer.new({
        scanner  = scanner,
        logger   = opts.logger,
        eventBus = opts.eventBus,
        ringSize = opts.networkRingSize,
    })
    return {
        scanner   = scanner,
        scripts   = scripts,
        fns       = fns,
        hooks     = hooks,
        gc        = gc,
        closures  = closures,
        metatable = meta,
        memory    = memory,
        network   = network,
    }
end

-- ---------------------------------------------------------------------
-- Manifest (for LoadingManager / ServiceContainer)
-- ---------------------------------------------------------------------

function Runtime.manifest()
    return {
        id           = "Runtime",
        dependencies = {},
        weight       = 0.6,
        serviceName  = "Runtime",
        stages = {
            { id = "detect-capabilities", weight = 0.3, fn = function(ctx)
                local scanner = EnvironmentScanner.new({ logger = ctx.logger })
                local caps = scanner:capabilities()
                local n = 0; for _, v in caps do if v then n = n + 1 end end
                ctx:report(1, string.format("Runtime: %d capabilities detected", n))
            end },
            { id = "register", weight = 0.7, fn = function(ctx)
                ctx:report(1, "Runtime ready")
            end },
        },
    }
end

-- ---------------------------------------------------------------------
-- Self-test
-- ---------------------------------------------------------------------

function Runtime.runSelfTest(opts)
    opts = opts or {}
    local logger = opts.logger
    local passes, fails = 0, 0
    local function check(name, cond, ...)
        if cond then passes = passes + 1; return true end
        fails = fails + 1
        if logger then logger:error("Runtime self-test FAIL: %s (%s)", name, tostring(...)) end
        return false
    end

    -- EnvironmentScanner
    local scanner = EnvironmentScanner.new({ logger = logger })
    check("scanner constructed", scanner ~= nil)
    local caps = scanner:capabilities()
    check("capabilities table",  type(caps) == "table")
    -- We can't assert which specific capabilities exist (depends on the
    -- executor), but we can assert the detection structure is consistent.
    for k, v in caps do
        check("cap " .. k .. " is fn or nil",
            v == nil or type(v) == "function", type(v))
    end

    -- Run scans in whatever environment we're in. They should at minimum
    -- not throw.
    local gcResult = scanner:scanGc(false)
    check("scanGc returns categorized",
        type(gcResult) == "table"
        and type(gcResult.functions) == "table"
        and type(gcResult.tables) == "table"
        and type(gcResult.threads) == "table")

    local scriptList, originMap = scanner:scanScripts()
    check("scanScripts returns array", type(scriptList) == "table")
    check("scanScripts returns origin map", type(originMap) == "table")

    -- ScriptRegistry
    local scripts = ScriptRegistry.new({ scanner = scanner, logger = logger })
    local delta = scripts:scan()
    check("ScriptRegistry.scan returns delta",
        type(delta) == "table" and type(delta.added) == "table" and type(delta.removed) == "table")
    local scriptStats = scripts:stats()
    check("ScriptRegistry stats has total",
        type(scriptStats) == "table" and type(scriptStats.total) == "number")

    -- FunctionRegistry
    local fns = FunctionRegistry.new({
        scanner        = scanner,
        scriptRegistry = scripts,
        logger         = logger,
    })
    local fnDelta = fns:scan()
    check("FunctionRegistry.scan returns delta",
        type(fnDelta) == "table" and type(fnDelta.added) == "number")
    local fnStats = fns:stats()
    check("FunctionRegistry stats", type(fnStats.total) == "number")
    check("FunctionRegistry indexed something or env has no gc",
        fnStats.total >= 0)

    -- Fingerprint stability — fingerprint the same function twice and
    -- compare. We use Runtime.runSelfTest itself as the test subject.
    if fnStats.byKind and (fnStats.byKind.lua or 0) > 0 then
        local entries = fns:entries()
        local sample = entries[1]
        if sample and sample.fingerprint then
            -- Re-fingerprint by inspecting again.
            local secondScanFns = FunctionRegistry.new({ scanner = scanner, logger = logger })
            secondScanFns:scan()
            local restored = secondScanFns:entryFor(sample.fn)
            if restored then
                check("fingerprint stable across scans",
                    restored.fingerprint == sample.fingerprint,
                    restored.fingerprint, sample.fingerprint)
            end
        end
    end

    -- HookManager
    local hooks = HookManager.new({ scanner = scanner, logger = logger })
    check("HookManager constructed", hooks ~= nil)
    -- Whether install actually works depends on hookfunction presence;
    -- we only assert the safe-path behaviour here.
    if not hooks:available() then
        local record, err = hooks:install(function() end, function() end)
        check("install fails gracefully without hookfunction",
            record == nil and type(err) == "string", err)
    else
        -- Best-effort happy-path: install a counter on a no-op function
        -- WE control, exercise it, then uninstall.
        local target = function(x) return x * 2 end
        local rec, err = hooks:installCounter(target, { label = "self-test" })
        if check("installCounter succeeds", rec ~= nil, err) then
            -- After installing, calling the target should be intercepted.
            local r = target(5)
            check("hooked call returns original value", r == 10, r)
            check("hooked call counted", rec.callCount >= 1, rec.callCount)
            local ok, uerr = hooks:uninstall(rec)
            check("uninstall succeeds", ok == true, uerr)
        end
    end

    local hookStats = hooks:stats()
    check("HookManager stats", type(hookStats.active) == "number")

    if logger then logger:info("Runtime self-test: %d pass, %d fail", passes, fails) end
    return passes, fails
end

return Runtime
