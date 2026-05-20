--!nonstrict
-- =====================================================================
-- IDARoblox / Core / LoadingManager
-- ---------------------------------------------------------------------
-- The orchestrator behind every loading bar in IDARoblox.
--
-- Modules register a manifest describing their dependencies and stages.
-- The manager:
--
--   1. Builds a dependency DAG and topologically sorts it (Kahn's
--      algorithm with explicit cycle reporting).
--   2. For each module in order, runs its stages serially. Each stage's
--      function receives a LoadingContext that exposes:
--
--         ctx:report(p, label?)   -- 0..1 progress within the stage
--         ctx:yield(every?)       -- cooperative yield via Scheduler
--         ctx:checkCancel()       -- raises if cancellation was requested
--         ctx.logger              -- a sub-logger scoped to this stage
--
--   3. Combines stage-local progress (weighted by stage.weight) into a
--      module-level progress (0..1), then combines module-level progress
--      (weighted by module.weight, default 1) into a global progress.
--
--   4. Maintains a rolling-average of progress velocity to compute ETA.
--
--   5. Emits the full event grammar to the supplied EventBus:
--
--         loading.begin           { totalModules }
--         loading.module.queued   { id }
--         loading.module.begin    { id, index, total }
--         loading.module.progress { id, progress, stageId, label }
--         loading.stage.begin     { moduleId, stageId, weight }
--         loading.stage.progress  { moduleId, stageId, progress, label }
--         loading.stage.end       { moduleId, stageId, durationMs }
--         loading.module.end      { id, durationMs }
--         loading.module.error    { id, error, stageId }
--         loading.global.progress { progress, etaSec, currentModule,
--                                   currentStage, elapsedSec }
--         loading.end             { durationMs, succeeded, failed }
--
-- The manager itself yields cooperatively, so even an enormous proto
-- parse never freezes the UI thread.
-- =====================================================================

local LoadingManager = {}
LoadingManager.__index = LoadingManager

local DEFAULT_VELOCITY_WINDOW = 32                                   -- samples in rolling average
local PROGRESS_EMIT_THRESHOLD = 0.002                                -- ~0.2% to throttle

-- ---------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------

function LoadingManager.new(opts)
    opts = opts or {}
    if not opts.eventBus then
        error("LoadingManager: eventBus is required", 2)
    end
    if not opts.scheduler then
        error("LoadingManager: scheduler is required", 2)
    end
    local self = setmetatable({
        _bus               = opts.eventBus,
        _scheduler         = opts.scheduler,
        _logger            = opts.logger,                            -- optional
        _modules           = {},                                     -- id → manifest
        _moduleOrder       = nil,                                    -- computed at load time
        _moduleProgress    = {},                                     -- id → 0..1
        _moduleStatus      = {},                                     -- id → "pending"|"loading"|"ready"|"error"
        _moduleResults     = {},                                     -- id → return value
        _moduleDurations   = {},                                     -- id → seconds
        _totalWeight       = 0,
        _started           = false,
        _cancelled         = false,
        _startedAt         = 0,
        _currentModule     = nil,
        _currentStage      = nil,
        _velocitySamples   = {},                                     -- { {t, p} }
        _velocityWindow    = opts.velocityWindow or DEFAULT_VELOCITY_WINDOW,
        _lastEmittedGlobal = -1,
        _onError           = opts.onError,                            -- callback (id, err)
        _failFast          = opts.failFast ~= false,                  -- default true
    }, LoadingManager)
    return self
end

-- ---------------------------------------------------------------------
-- Manifest registration
-- ---------------------------------------------------------------------

local function validateManifest(m)
    if type(m) ~= "table" then error("manifest must be a table", 3) end
    if type(m.id) ~= "string" or m.id == "" then error("manifest.id must be a non-empty string", 3) end
    if m.dependencies and type(m.dependencies) ~= "table" then
        error(string.format("manifest %s: dependencies must be a table", m.id), 3)
    end
    if type(m.stages) ~= "table" or #m.stages == 0 then
        error(string.format("manifest %s: must have at least one stage", m.id), 3)
    end
    for i, s in m.stages do
        if type(s.id) ~= "string" or s.id == "" then
            error(string.format("manifest %s: stage %d missing id", m.id, i), 3)
        end
        if type(s.fn) ~= "function" then
            error(string.format("manifest %s: stage '%s' missing fn", m.id, s.id), 3)
        end
        if s.weight and (type(s.weight) ~= "number" or s.weight < 0) then
            error(string.format("manifest %s: stage '%s' weight must be >= 0", m.id, s.id), 3)
        end
    end
end

function LoadingManager:register(manifest)
    validateManifest(manifest)
    if self._modules[manifest.id] then
        error("LoadingManager: duplicate module id '" .. manifest.id .. "'", 2)
    end
    -- Normalize stage weights so they sum to 1.0
    local total = 0
    for _, s in manifest.stages do total = total + (s.weight or 1) end
    if total <= 0 then total = 1 end
    local normalized = table.create(#manifest.stages)
    for i, s in manifest.stages do
        normalized[i] = {
            id     = s.id,
            fn     = s.fn,
            weight = (s.weight or 1) / total,
        }
    end
    local entry = {
        id           = manifest.id,
        dependencies = manifest.dependencies or {},
        stages       = normalized,
        weight       = manifest.weight or 1,
        ctx          = manifest.ctx,                                -- arbitrary user payload passed to stages
    }
    self._modules[manifest.id] = entry
    self._moduleStatus[manifest.id] = "pending"
    self._moduleProgress[manifest.id] = 0
    self._totalWeight = self._totalWeight + entry.weight
    self._bus:emit("loading.module.queued", { id = manifest.id })
end

function LoadingManager:isRegistered(id: string): boolean
    return self._modules[id] ~= nil
end

-- ---------------------------------------------------------------------
-- Topological sort (Kahn's algorithm with cycle reporting)
-- ---------------------------------------------------------------------

local function topoSort(modules)
    local inDegree = {}
    local adj = {}
    local ids = {}
    for id in modules do
        inDegree[id] = 0
        adj[id] = {}
        ids[#ids + 1] = id
    end
    table.sort(ids)                                                 -- deterministic order
    for _, id in ids do
        for _, dep in modules[id].dependencies do
            if modules[dep] == nil then
                error(string.format(
                    "LoadingManager: module '%s' depends on unregistered '%s'", id, dep), 3)
            end
            inDegree[id] = inDegree[id] + 1
            table.insert(adj[dep], id)
        end
    end

    local queue = {}
    for _, id in ids do
        if inDegree[id] == 0 then queue[#queue + 1] = id end
    end

    local order = {}
    while #queue > 0 do
        local id = table.remove(queue, 1)
        order[#order + 1] = id
        for _, child in adj[id] do
            inDegree[child] = inDegree[child] - 1
            if inDegree[child] == 0 then queue[#queue + 1] = child end
        end
    end

    if #order ~= #ids then
        -- Cycle present: emit which nodes are involved
        local stuck = {}
        for _, id in ids do
            if inDegree[id] > 0 then stuck[#stuck + 1] = id end
        end
        error("LoadingManager: dependency cycle involving: " .. table.concat(stuck, ", "), 3)
    end

    return order
end

-- ---------------------------------------------------------------------
-- Progress accounting
-- ---------------------------------------------------------------------

function LoadingManager:_globalProgress(): number
    local sum = 0
    for id, p in self._moduleProgress do
        sum = sum + p * self._modules[id].weight
    end
    if self._totalWeight <= 0 then return 0 end
    return sum / self._totalWeight
end

function LoadingManager:_pushVelocity(progress: number)
    local now = os.clock()
    table.insert(self._velocitySamples, { now, progress })
    if #self._velocitySamples > self._velocityWindow then
        table.remove(self._velocitySamples, 1)
    end
end

function LoadingManager:_estimateEta(currentProgress: number): number
    local samples = self._velocitySamples
    if #samples < 2 then return -1 end                              -- not enough data
    local first = samples[1]
    local last = samples[#samples]
    local dt = last[1] - first[1]
    local dp = last[2] - first[2]
    if dt <= 0 or dp <= 0 then return -1 end
    local velocity = dp / dt                                        -- progress per second
    local remaining = math.max(0, 1 - currentProgress)
    return remaining / velocity
end

function LoadingManager:_emitGlobalIfChanged(stageLabel: string?)
    local g = self:_globalProgress()
    if math.abs(g - self._lastEmittedGlobal) < PROGRESS_EMIT_THRESHOLD and g < 1 then
        return
    end
    self._lastEmittedGlobal = g
    self:_pushVelocity(g)
    self._bus:emit("loading.global.progress", {
        progress      = g,
        etaSec        = self:_estimateEta(g),
        currentModule = self._currentModule,
        currentStage  = self._currentStage,
        stageLabel    = stageLabel,
        elapsedSec    = os.clock() - self._startedAt,
    })
end

-- ---------------------------------------------------------------------
-- LoadingContext — passed to each stage fn
-- ---------------------------------------------------------------------

local LoadingContext = {}
LoadingContext.__index = LoadingContext

function LoadingContext.new(mgr, moduleEntry, stageDef, stageIndex, completedStageWeight)
    return setmetatable({
        _mgr                  = mgr,
        _module               = moduleEntry,
        _stage                = stageDef,
        _stageIndex           = stageIndex,
        _completedStageWeight = completedStageWeight,                -- cumulative weight before this stage
        _stageStartedAt       = os.clock(),
        _yieldCounter         = { n = 0 },
        moduleId              = moduleEntry.id,
        stageId               = stageDef.id,
        userCtx               = moduleEntry.ctx,
        logger                = if mgr._logger then mgr._logger:child(moduleEntry.id .. "." .. stageDef.id) else nil,
    }, LoadingContext)
end

function LoadingContext:report(progress01: number, label: string?)
    if self._mgr._cancelled then error("loading_cancelled", 0) end
    if progress01 < 0 then progress01 = 0
    elseif progress01 > 1 then progress01 = 1 end
    local moduleProgress = self._completedStageWeight + progress01 * self._stage.weight
    self._mgr._moduleProgress[self._module.id] = moduleProgress
    self._mgr._bus:emit("loading.stage.progress", {
        moduleId = self._module.id,
        stageId  = self._stage.id,
        progress = progress01,
        label    = label,
    })
    self._mgr._bus:emit("loading.module.progress", {
        id       = self._module.id,
        progress = moduleProgress,
        stageId  = self._stage.id,
        label    = label,
    })
    self._mgr:_emitGlobalIfChanged(label)
end

function LoadingContext:yield(every: number?)
    if every then
        self._mgr._scheduler:yieldEvery(self._yieldCounter, every)
    else
        self._mgr._scheduler:yield()
    end
    if self._mgr._cancelled then error("loading_cancelled", 0) end
end

function LoadingContext:checkCancel()
    if self._mgr._cancelled then error("loading_cancelled", 0) end
end

function LoadingContext:setStageWeight(newWeight: number)
    -- Allows a stage to reweight itself if it discovers more work to do.
    -- The remaining stages' weights are renormalized to keep the module
    -- total at 1.0.
    if newWeight < 0 then newWeight = 0 end
    local moduleEntry = self._module
    local idx = self._stageIndex
    local oldWeight = moduleEntry.stages[idx].weight
    moduleEntry.stages[idx].weight = newWeight
    -- Renormalize all stages
    local total = 0
    for _, s in moduleEntry.stages do total = total + s.weight end
    if total <= 0 then total = 1 end
    for _, s in moduleEntry.stages do s.weight = s.weight / total end
    self._stage = moduleEntry.stages[idx]
end

-- ---------------------------------------------------------------------
-- Stage execution
-- ---------------------------------------------------------------------

function LoadingManager:_runStage(moduleEntry, stageIndex, completedWeight)
    local stage = moduleEntry.stages[stageIndex]
    self._currentStage = stage.id
    local ctx = LoadingContext.new(self, moduleEntry, stage, stageIndex, completedWeight)
    self._bus:emit("loading.stage.begin", {
        moduleId = moduleEntry.id, stageId = stage.id, weight = stage.weight,
    })
    local stageStart = os.clock()
    -- Initial report at 0
    ctx:report(0)
    local results = table.pack(pcall(stage.fn, ctx))
    if not results[1] then
        local err = results[2]
        if err == "loading_cancelled" then
            error(err, 0)                                            -- propagate up
        end
        self._bus:emit("loading.module.error", {
            id = moduleEntry.id, error = err, stageId = stage.id,
        })
        if self._onError then pcall(self._onError, moduleEntry.id, err, stage.id) end
        error(string.format("module '%s' stage '%s' failed: %s",
            moduleEntry.id, stage.id, tostring(err)), 0)
    end
    -- Force final report at 1
    ctx:report(1)
    self._bus:emit("loading.stage.end", {
        moduleId = moduleEntry.id, stageId = stage.id,
        durationMs = (os.clock() - stageStart) * 1000,
    })
    return results
end

-- ---------------------------------------------------------------------
-- Module execution
-- ---------------------------------------------------------------------

function LoadingManager:_runModule(id: string, index: number, total: number)
    local entry = self._modules[id]
    self._currentModule = id
    self._currentStage = nil
    self._moduleStatus[id] = "loading"
    self._bus:emit("loading.module.begin", { id = id, index = index, total = total })
    local startedAt = os.clock()
    local completed = 0
    local lastResult = nil
    for i, stage in entry.stages do
        local results = self:_runStage(entry, i, completed)
        completed = completed + stage.weight
        -- Pass the last result from each stage as 'lastResult'; final stage's
        -- multi-return becomes the module result.
        if results.n > 1 then
            lastResult = table.move(results, 2, results.n, 1, {})
            lastResult.n = results.n - 1
        end
    end
    self._moduleProgress[id] = 1
    self._moduleStatus[id] = "ready"
    self._moduleDurations[id] = os.clock() - startedAt
    if lastResult and lastResult.n == 1 then
        self._moduleResults[id] = lastResult[1]
    elseif lastResult and lastResult.n > 1 then
        self._moduleResults[id] = lastResult
    end
    self._bus:emit("loading.module.end", {
        id = id, durationMs = self._moduleDurations[id] * 1000,
    })
end

-- ---------------------------------------------------------------------
-- Public load entry
-- ---------------------------------------------------------------------

function LoadingManager:loadAll()
    if self._started then
        error("LoadingManager: load already initiated", 2)
    end
    self._started = true
    self._startedAt = os.clock()
    self._lastEmittedGlobal = -1
    self._velocitySamples = {}
    self._moduleOrder = topoSort(self._modules)

    local total = #self._moduleOrder
    self._bus:emit("loading.begin", { totalModules = total })

    local succeeded = 0
    local failed = 0
    local errors = {}

    for index, id in self._moduleOrder do
        if self._cancelled then break end
        local ok, err = pcall(function()
            self:_runModule(id, index, total)
        end)
        if ok then
            succeeded = succeeded + 1
        else
            failed = failed + 1
            self._moduleStatus[id] = "error"
            errors[id] = err
            if self._failFast then
                self._bus:emit("loading.end", {
                    durationMs = (os.clock() - self._startedAt) * 1000,
                    succeeded = succeeded, failed = failed, errors = errors,
                    cancelled = self._cancelled,
                })
                error(err, 0)
            end
        end
        -- Force-yield between modules
        self._scheduler:forceYield()
    end

    self._bus:emit("loading.end", {
        durationMs = (os.clock() - self._startedAt) * 1000,
        succeeded = succeeded, failed = failed, errors = errors,
        cancelled = self._cancelled,
    })
    return succeeded, failed, errors
end

function LoadingManager:loadAsync()
    -- Spawns the load on a task and returns immediately. Caller listens
    -- to the event bus for progress.
    return task.spawn(function() self:loadAll() end)
end

-- ---------------------------------------------------------------------
-- Cancellation & queries
-- ---------------------------------------------------------------------

function LoadingManager:cancel()
    if not self._started then return end
    self._cancelled = true
end

function LoadingManager:isStarted(): boolean return self._started end
function LoadingManager:isCancelled(): boolean return self._cancelled end

function LoadingManager:globalProgress(): number return self:_globalProgress() end
function LoadingManager:moduleProgress(id: string): number? return self._moduleProgress[id] end
function LoadingManager:moduleStatus(id: string): string? return self._moduleStatus[id] end
function LoadingManager:moduleResult(id: string): any return self._moduleResults[id] end

function LoadingManager:report()
    local lines = {}
    lines[#lines + 1] = string.format("LoadingManager report (%d modules)", #self._moduleOrder or 0)
    for _, id in (self._moduleOrder or {}) do
        local status = self._moduleStatus[id]
        local dur = self._moduleDurations[id]
        lines[#lines + 1] = string.format("  %-32s  %-8s  %s",
            id, status,
            if dur then string.format("%.2f ms", dur * 1000) else "—")
    end
    return table.concat(lines, "\n")
end

return LoadingManager
