--!nonstrict
-- =====================================================================
-- IDARoblox / Core / Scheduler
-- ---------------------------------------------------------------------
-- Cooperative scheduler over Roblox's task library. Three priority lanes
-- (High / Normal / Low). The pump dequeues work each frame until the
-- frame budget (default 6 ms) is exhausted, then yields. Long-running
-- parser loops should call :yield() periodically — that call is a no-op
-- when budget remains, and a `task.wait()` when it doesn't.
--
-- The Scheduler is the substrate that lets the BytecodeParser feed
-- progress to the LoadingManager without freezing the UI.
-- =====================================================================

local Scheduler = {}
Scheduler.__index = Scheduler

Scheduler.Priority = {
    High   = 1,
    Normal = 2,
    Low    = 3,
}

local PRIORITY_COUNT = 3
local DEFAULT_BUDGET_MS = 6.0
local DEFAULT_MAX_FRAME_TIME_MS = 16.0
local STARVATION_BOOST_FRAMES = 30                                  -- promote lanes if starved

-- ---------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------

function Scheduler.new(opts)
    opts = opts or {}
    local self = setmetatable({
        _budgetMs        = opts.budgetMs or DEFAULT_BUDGET_MS,
        _maxFrameMs      = opts.maxFrameMs or DEFAULT_MAX_FRAME_TIME_MS,
        _lanes           = { table.create(8), table.create(16), table.create(32) },
        _laneAge         = { 0, 0, 0 },                            -- frames since last drained
        _frameStart      = os.clock(),
        _running         = false,
        _runner          = nil,
        _stats = {
            framesPumped  = 0,
            tasksRun      = 0,
            yieldsForced  = 0,
            yieldsBudget  = 0,
            errors        = 0,
            laneCounts    = { 0, 0, 0 },
        },
        _onError         = opts.onError,                           -- (err, taskInfo) -> ()
        _running_co      = nil :: thread?,
    }, Scheduler)
    return self
end

-- ---------------------------------------------------------------------
-- Lane operations
-- ---------------------------------------------------------------------

function Scheduler:queue(fn, priority, ...)
    local p = priority or Scheduler.Priority.Normal
    if p < 1 or p > PRIORITY_COUNT then
        error("Scheduler: invalid priority " .. tostring(priority), 2)
    end
    local args = table.pack(...)
    local entry = {
        fn        = fn,
        args      = args,
        priority  = p,
        queuedAt  = os.clock(),
        label     = nil,
    }
    table.insert(self._lanes[p], entry)
    self._stats.laneCounts[p] = self._stats.laneCounts[p] + 1
    -- Auto-start pump on first queue if not already running.
    if not self._running then self:start() end
    return entry
end

function Scheduler:queueHigh(fn, ...)   return self:queue(fn, 1, ...) end
function Scheduler:queueNormal(fn, ...) return self:queue(fn, 2, ...) end
function Scheduler:queueLow(fn, ...)    return self:queue(fn, 3, ...) end

function Scheduler:pending(priority: number?): number
    if priority then return #self._lanes[priority] end
    return #self._lanes[1] + #self._lanes[2] + #self._lanes[3]
end

-- ---------------------------------------------------------------------
-- Frame budget primitives
-- ---------------------------------------------------------------------

function Scheduler:frameElapsedMs(): number
    return (os.clock() - self._frameStart) * 1000.0
end

function Scheduler:remainingBudgetMs(): number
    return math.max(0, self._budgetMs - self:frameElapsedMs())
end

function Scheduler:overBudget(): boolean
    return self:frameElapsedMs() >= self._budgetMs
end

-- yield() is the cooperative break-point that parsers should call inside
-- hot loops. It's cheap when there's budget remaining and only forces a
-- task.wait when the frame budget is exhausted.
function Scheduler:yield()
    if self:overBudget() then
        self._stats.yieldsBudget += 1
        task.wait()
        self._frameStart = os.clock()
    end
end

function Scheduler:yieldEvery(counter: { n: number }, every: number)
    counter.n = counter.n + 1
    if counter.n >= every then
        counter.n = 0
        self:yield()
    end
end

function Scheduler:forceYield()
    self._stats.yieldsForced += 1
    task.wait()
    self._frameStart = os.clock()
end

-- ---------------------------------------------------------------------
-- Pump
-- ---------------------------------------------------------------------

function Scheduler:_selectLane(): number
    -- Round-robin with starvation protection. We prefer higher priority
    -- but if a lane has been waiting longer than STARVATION_BOOST_FRAMES,
    -- it is serviced first.
    for p = 1, PRIORITY_COUNT do
        if #self._lanes[p] > 0 then
            if p == 1 then return p end
            if self._laneAge[p] >= STARVATION_BOOST_FRAMES then return p end
        end
    end
    for p = 1, PRIORITY_COUNT do
        if #self._lanes[p] > 0 then return p end
    end
    return 0
end

function Scheduler:_pumpOnce()
    self._frameStart = os.clock()
    -- Age all lanes that have pending work
    for p = 1, PRIORITY_COUNT do
        if #self._lanes[p] > 0 then
            self._laneAge[p] += 1
        else
            self._laneAge[p] = 0
        end
    end
    -- Drain until budget exhausted
    while not self:overBudget() do
        local lane = self:_selectLane()
        if lane == 0 then break end
        local entry = table.remove(self._lanes[lane], 1)
        if not entry then break end
        self._laneAge[lane] = 0
        local ok, err = pcall(entry.fn, table.unpack(entry.args, 1, entry.args.n))
        self._stats.tasksRun += 1
        if not ok then
            self._stats.errors += 1
            if self._onError then pcall(self._onError, err, entry) end
        end
    end
    self._stats.framesPumped += 1
end

function Scheduler:start()
    if self._running then return end
    self._running = true
    self._runner = task.spawn(function()
        while self._running do
            if self:pending() == 0 then
                task.wait()
                self._frameStart = os.clock()
            else
                self:_pumpOnce()
                task.wait()
            end
        end
    end)
end

function Scheduler:stop()
    self._running = false
end

-- ---------------------------------------------------------------------
-- Helpers wrapping task.* but with bookkeeping
-- ---------------------------------------------------------------------

function Scheduler:spawn(fn, ...)
    local args = table.pack(...)
    return task.spawn(function()
        local ok, err = pcall(fn, table.unpack(args, 1, args.n))
        if not ok then
            self._stats.errors += 1
            if self._onError then pcall(self._onError, err, { fn = fn }) end
        end
    end)
end

function Scheduler:defer(fn, ...)
    local args = table.pack(...)
    return task.defer(function()
        local ok, err = pcall(fn, table.unpack(args, 1, args.n))
        if not ok then
            self._stats.errors += 1
            if self._onError then pcall(self._onError, err, { fn = fn }) end
        end
    end)
end

function Scheduler:delay(seconds: number, fn, ...)
    local args = table.pack(...)
    return task.delay(seconds, function()
        local ok, err = pcall(fn, table.unpack(args, 1, args.n))
        if not ok then
            self._stats.errors += 1
            if self._onError then pcall(self._onError, err, { fn = fn }) end
        end
    end)
end

-- ---------------------------------------------------------------------
-- Batch processing helper
-- ---------------------------------------------------------------------
-- Runs `processor(item, index)` over `items`, yielding via :yield() every
-- `chunkSize` items. Optional `onProgress(done, total)` ticks per chunk.
-- Returns when finished.

function Scheduler:processBatch(items, processor, chunkSize: number?, onProgress)
    chunkSize = chunkSize or 64
    local total = #items
    local counter = { n = 0 }
    for i = 1, total do
        processor(items[i], i)
        self:yieldEvery(counter, chunkSize)
        if onProgress and (i % chunkSize == 0 or i == total) then
            onProgress(i, total)
        end
    end
end

-- ---------------------------------------------------------------------
-- Diagnostics
-- ---------------------------------------------------------------------

function Scheduler:stats()
    return {
        framesPumped = self._stats.framesPumped,
        tasksRun     = self._stats.tasksRun,
        yieldsForced = self._stats.yieldsForced,
        yieldsBudget = self._stats.yieldsBudget,
        errors       = self._stats.errors,
        pending      = { #self._lanes[1], #self._lanes[2], #self._lanes[3] },
        laneCounts   = table.clone(self._stats.laneCounts),
        budgetMs     = self._budgetMs,
        running      = self._running,
    }
end

function Scheduler:setBudgetMs(ms: number)
    self._budgetMs = math.max(0.5, ms)
end

return Scheduler
