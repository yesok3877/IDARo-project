--!nonstrict
-- =====================================================================
-- IDARoblox / Core / init
-- ---------------------------------------------------------------------
-- One-call bootstrap that wires together every Core primitive in the
-- correct dependency order and returns a fully-formed Kernel.
--
-- Usage from the entry script:
--
--   local Core = require(path.to.IDARoblox.Core)
--   local kernel = Core.bootstrap({
--     loggerLevel  = Core.Logger.Level.DEBUG,
--     ringSize     = 2048,
--     budgetMs     = 6,
--   })
--   kernel:registerModule({ ... manifest ... })
--   kernel:boot()
--
-- The kernel returned here has every platform singleton installed:
--   kernel:eventBus()        / kernel:get("EventBus")
--   kernel:logger()          / kernel:get("Logger")
--   kernel:scheduler()       / kernel:get("Scheduler")
--   kernel:profiler()        / kernel:get("Profiler")
--   kernel:loadingManager()  / kernel:get("LoadingManager")
-- =====================================================================

local BinaryStream    = _G.IDARo.require("Core.BinaryStream")
local Promise         = _G.IDARo.require("Core.Promise")
local Scheduler       = _G.IDARo.require("Core.Scheduler")
local Logger          = _G.IDARo.require("Core.Logger")
local Memoize         = _G.IDARo.require("Core.Memoize")
local Profiler        = _G.IDARo.require("Core.Profiler")
local EventBus        = _G.IDARo.require("Core.EventBus")
local StateMachine    = _G.IDARo.require("Core.StateMachine")
local LoadingManager  = _G.IDARo.require("Core.LoadingManager")
local Kernel          = _G.IDARo.require("Core.Kernel")
local Base64          = _G.IDARo.require("Core.Base64")
local StorageBackend  = _G.IDARo.require("Core.StorageBackend")
local SessionManager  = _G.IDARo.require("Core.SessionManager")

local Core = {}

-- Re-export every module so downstream files can `Core.LRU.new(...)` etc.
Core.BinaryStream   = BinaryStream
Core.Promise        = Promise
Core.Scheduler      = Scheduler
Core.Logger         = Logger
Core.Memoize        = Memoize
Core.Profiler       = Profiler
Core.EventBus       = EventBus
Core.StateMachine   = StateMachine
Core.LoadingManager = LoadingManager
Core.Kernel         = Kernel
Core.Base64         = Base64
Core.StorageBackend = StorageBackend
Core.SessionManager = SessionManager

-- ---------------------------------------------------------------------
-- bootstrap(opts) → Kernel
-- ---------------------------------------------------------------------

function Core.bootstrap(opts)
    opts = opts or {}

    -- 1. Logger first so subsequent constructors can plug in.
    local logger = Logger.new({
        tag          = opts.rootTag or "IDARo",
        defaultLevel = opts.loggerLevel or Logger.Level.INFO,
        ringSize     = opts.ringSize or 1024,
    })

    -- 2. EventBus — pass the logger so handler errors get reported.
    local eventBus = EventBus.new({
        logger     = logger,
        historyCap = opts.eventHistoryCap or 0,
    })

    -- 3. Promise: install an unhandled-rejection sink that drives the logger.
    Promise.onUnhandledRejection(function(err, _promise)
        logger:warn("Unhandled promise rejection: %s", tostring(err))
    end)

    -- 4. Scheduler — frame budget tunable from opts.
    local scheduler = Scheduler.new({
        budgetMs = opts.budgetMs or 6,
        onError  = function(err, info)
            logger:error("Scheduler task error: %s", tostring(err))
            eventBus:emit("kernel.scheduler.error", { error = err, info = info })
        end,
    })

    -- 5. Profiler — wired to the logger for budget-exceeded warnings.
    local profiler = Profiler.new({
        enabled               = opts.profilerEnabled ~= false,
        frameBudgetMs         = opts.profilerBudgetMs or 8,
        reservoirCap          = opts.profilerReservoir or 256,
        onFrameBudgetExceeded = function(name, ms, budget)
            logger:warn("Profiler: '%s' took %.2f ms (budget %.2f ms)", name, ms, budget)
        end,
    })

    -- 6. LoadingManager — driven by the event bus and scheduler.
    local loadingManager = LoadingManager.new({
        eventBus  = eventBus,
        scheduler = scheduler,
        logger    = logger,
        failFast  = opts.failFast,
        velocityWindow = opts.etaWindow or 32,
    })

    -- 7. Kernel orchestrates it all.
    local kernel = Kernel.new({
        logger            = logger,
        eventBus          = eventBus,
        scheduler         = scheduler,
        profiler          = profiler,
        loadingManager    = loadingManager,
        stateMachineCtor  = StateMachine.new,
        onUnhandledError  = function(err, source)
            logger:fatal("Unhandled error in %s: %s", tostring(source), tostring(err))
            eventBus:emit("kernel.unhandled", { error = err, source = source })
        end,
    })

    kernel:installDefaults()
    -- Make a few extra utilities available through the service locator.
    kernel:register("Promise", Promise)
    kernel:register("BinaryStream", BinaryStream)
    kernel:register("Memoize", Memoize)

    logger:debug("Core bootstrap complete (budgetMs=%d)", scheduler._budgetMs)
    return kernel
end

-- ---------------------------------------------------------------------
-- Self-test (lightweight) — run only if Core.runSelfTest() is called.
-- Useful before wiring real modules; exercises every Core primitive.
-- ---------------------------------------------------------------------

function Core.runSelfTest(kernel)
    local logger = kernel:logger()
    local bus = kernel:eventBus()
    local scheduler = kernel:scheduler()
    local lm = kernel:loadingManager()
    local profiler = kernel:profiler()
    local passes, fails = 0, 0
    local function check(name, ok, info)
        if ok then
            passes = passes + 1
            logger:debug("self-test pass: %s", name)
        else
            fails = fails + 1
            logger:error("self-test FAIL: %s — %s", name, tostring(info))
        end
    end

    -- BinaryStream round-trip
    local w = BinaryStream.writer()
    w:writeU8(0x7F); w:writeU16(0xABCD); w:writeU32(0xDEADBEEF)
    w:writeVarInt(123456); w:writeString("hello"); w:writeF64(3.14159265358979)
    local r = BinaryStream.new(w:toString())
    check("BinaryStream u8",  r:readU8() == 0x7F)
    check("BinaryStream u16", r:readU16() == 0xABCD)
    check("BinaryStream u32", r:readU32() == 0xDEADBEEF)
    check("BinaryStream varint", r:readVarInt() == 123456)
    check("BinaryStream string", r:readString() == "hello")
    local d = r:readF64()
    check("BinaryStream f64", math.abs(d - 3.14159265358979) < 1e-12, d)

    -- Promise basics
    local p1 = Promise.resolve(42):andThen(function(v) return v + 1 end)
    local ok, val = p1:await()
    check("Promise chain", ok and val == 43, val)

    -- EventBus priority
    local order = {}
    bus:on("test.evt", function() table.insert(order, "B") end, 0)
    bus:on("test.evt", function() table.insert(order, "A") end, 10)
    bus:emit("test.evt")
    check("EventBus priority", order[1] == "A" and order[2] == "B")
    bus:disconnectAll("test.evt")

    -- LRU
    local lru = Memoize.LRU.new(2)
    lru:set("a", 1); lru:set("b", 2); lru:get("a"); lru:set("c", 3)
    check("LRU evict tail", lru:get("a") == 1 and lru:get("b") == nil and lru:get("c") == 3)

    -- Profiler scope
    profiler:measure("self.test", function() task.wait() end)
    local stats = profiler:stats("self.test")
    check("Profiler captured", stats and stats.count == 1)

    -- StateMachine
    local sm = StateMachine.new({
        name = "test",
        initial = "A",
        states = { A = {}, B = {} },
        transitions = { { from = "A", to = "B", on = "go" } },
    })
    sm:fire("go")
    check("FSM transition", sm:current() == "B")

    -- LoadingManager mini run
    local mini = LoadingManager.new({ eventBus = bus, scheduler = scheduler, logger = logger })
    local touched = {}
    mini:register({
        id = "self.test.alpha",
        stages = {
            { id = "s1", weight = 1, fn = function(ctx)
                for i = 1, 5 do ctx:report(i / 5, "tick " .. i); ctx:yield() end
                touched.alpha = true
            end },
        },
    })
    mini:register({
        id = "self.test.beta",
        dependencies = { "self.test.alpha" },
        stages = { { id = "s1", weight = 1, fn = function(ctx) ctx:report(1); touched.beta = true end } },
    })
    mini:loadAll()
    check("LoadingManager ran in order", touched.alpha and touched.beta)
    check("LoadingManager 100% global", math.abs(mini:globalProgress() - 1) < 1e-9, mini:globalProgress())

    -- Base64 roundtrip
    do
        local payloads = {
            "",
            "a",
            "ab",
            "abc",
            "abcd",
            "Hello, world!",
            string.rep("\x00\x01\x02\xFF", 64),                       -- binary
            string.rep("X", 1024),
        }
        for _, p in payloads do
            local encoded = Base64.encode(p)
            local decoded = Base64.decode(encoded)
            check("Base64 roundtrip (#" .. #p .. ")", decoded == p,
                #p, #encoded, #decoded)
        end
        -- Padding correctness
        check("Base64 empty → empty",  Base64.encode("") == "")
        check("Base64 'a' has 2 pad",  string.sub(Base64.encode("a"), -2) == "==")
        check("Base64 'ab' has 1 pad", string.sub(Base64.encode("ab"), -1) == "=")
        check("Base64 'abc' no pad",   string.sub(Base64.encode("abc"), -1) ~= "=")
    end

    -- SessionManager serialize/deserialize roundtrip on a mock workspace
    do
        local mockWorkspace = {
            state = {
                viewMode        = "decomp",
                bottomTab       = "names",
                selectedProtoId = 3,
                selectedPc      = 42,
                selectedBlockId = 7,
                selectedDecLine = 12,
                treeRatio       = 0.18,
                outputRatio     = 0.77,
                xrefQuery       = { kind = "string", key = "PlayerAdded",
                                    label = "PlayerAdded · 3 refs" },
                bookmarks = {
                    { protoId = 0, pc = 10, label = "first bookmark" },
                    { protoId = 1, pc = 5,  label = "with | pipe and \n newline" },
                },
                runtime = nil,                                       -- omit hooks for the test
            },
        }

        local sm = SessionManager.new({ logger = logger })
        local session = sm:captureCurrentState(mockWorkspace, "\x01\x02\x03\xFFBYTECODE")
        check("session captured", session ~= nil)
        check("session has state",          type(session.state) == "table")
        check("session has bookmarks (2)",  #session.bookmarks == 2, #session.bookmarks)
        check("session has bytecode bytes", session.bytecodeBytes ~= nil)

        local text = sm:serialize(session)
        check("serialize non-empty",        text and #text > 0, #text)
        check("serialize has magic",        string.sub(text, 1, #"IDARBLX-SESSION-V1") == "IDARBLX-SESSION-V1")

        local round, err = sm:deserialize(text)
        check("deserialize succeeded",      round ~= nil, err)
        check("deserialize viewMode",       round and round.state.viewMode == "decomp",
            round and round.state.viewMode)
        check("deserialize selectedPc",     round and round.state.selectedPc == 42,
            round and round.state.selectedPc)
        check("deserialize treeRatio",      round and math.abs(round.state.treeRatio - 0.18) < 1e-6,
            round and round.state.treeRatio)
        check("deserialize xref kind",
            round and round.state.xrefQueryKind == "string",
            round and round.state.xrefQueryKind)
        check("deserialize bookmark count", round and #round.bookmarks == 2,
            round and #round.bookmarks)
        check("deserialize bookmark escaping",
            round and round.bookmarks[2].label == "with | pipe and \n newline",
            round and round.bookmarks[2].label)
        check("deserialize bytecode bytes preserved",
            round and round.bytecodeBytes == "\x01\x02\x03\xFFBYTECODE",
            round and #round.bytecodeBytes)

        -- Reject malformed input
        local bad1, err1 = sm:deserialize("not a session")
        check("deserialize rejects bad magic", bad1 == nil and type(err1) == "string")
        local bad2, err2 = sm:deserialize("")
        check("deserialize rejects empty",     bad2 == nil and type(err2) == "string")

        -- applyToWorkspace updates the mock state correctly
        local applied = {}
        local mock2 = {
            state    = {},
            setState = function(self, update) for k, v in update do applied[k] = v end end,
        }
        sm:applyToWorkspace(mock2, round)
        check("apply: viewMode",        applied.viewMode == "decomp", applied.viewMode)
        check("apply: selectedPc",      applied.selectedPc == 42, applied.selectedPc)
        check("apply: bookmarks",       applied.bookmarks and #applied.bookmarks == 2,
            applied.bookmarks and #applied.bookmarks)
        check("apply: xrefQuery",       applied.xrefQuery and applied.xrefQuery.kind == "string",
            applied.xrefQuery and applied.xrefQuery.kind)
    end

    -- StorageBackend exists and reports capabilities (functional or not)
    do
        local sb = StorageBackend.new({ logger = logger, rootDir = "IDARoblox-test" })
        check("StorageBackend constructed", sb ~= nil)
        check("StorageBackend caps table", type(sb:capabilities()) == "table")
        -- Path safety
        local ok, _ = sb:write("../escape.txt", "x")
        check("StorageBackend rejects path traversal", ok == false, ok)
        local ok2, _ = sb:write("/etc/passwd", "x")
        check("StorageBackend rejects absolute path", ok2 == false, ok2)
    end

    logger:info("Core self-test: %d pass, %d fail", passes, fails)
    return passes, fails
end

return Core
