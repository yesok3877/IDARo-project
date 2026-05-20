--!nonstrict
-- =====================================================================
-- IDARoblox / Core / Profiler
-- ---------------------------------------------------------------------
-- Hierarchical, sample-based instrumentation profiler.
--
-- Usage:
--   local s = Profiler:enter("BytecodeParser.parseProtos")
--   ...
--   Profiler:exit(s)
--
-- Or scoped:
--   Profiler:measure("BytecodeParser.parseProtos", function() ... end)
--
-- For each measured name the profiler tracks:
--   * count, total, min, max, mean, lastMs
--   * percentile estimates (p50/p95/p99) via a reservoir of up to N samples
--   * children: the names entered while this scope was active, with their
--     own (count, totalMs) under this parent — yielding a call tree
--
-- The Profiler is purely Lua — no external timing source other than
-- os.clock() — and is safe to leave on in production builds. Disabled
-- calls cost a single boolean read.
-- =====================================================================

local Profiler = {}
Profiler.__index = Profiler

local DEFAULT_RESERVOIR = 256
local DEFAULT_FRAME_BUDGET_MS = 8.0

-- ---------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------

function Profiler.new(opts)
    opts = opts or {}
    local self = setmetatable({
        _enabled     = opts.enabled ~= false,
        _records     = {},                                          -- name → record
        _stack       = table.create(16),                            -- active scope stack
        _root        = { name = "<root>", children = {}, count = 0, totalMs = 0 },
        _frameBudget = opts.frameBudgetMs or DEFAULT_FRAME_BUDGET_MS,
        _onBudget    = opts.onFrameBudgetExceeded,
        _reservoirCap= opts.reservoirCap or DEFAULT_RESERVOIR,
        _rngState    = math.random(1, 2^31 - 1),
    }, Profiler)
    self._stack[1] = self._root
    return self
end

function Profiler:enable()  self._enabled = true  end
function Profiler:disable() self._enabled = false end

-- ---------------------------------------------------------------------
-- Records
-- ---------------------------------------------------------------------

local function newRecord(name, reservoirCap)
    return {
        name       = name,
        count      = 0,
        totalMs    = 0,
        minMs      = math.huge,
        maxMs      = -math.huge,
        lastMs     = 0,
        reservoir  = table.create(reservoirCap),       -- sample buffer
        reservoirN = 0,                                 -- count of total samples (for skip prob)
        reservoirCap = reservoirCap,
    }
end

local function reservoirAdd(self, rec, value)
    if rec.reservoirN < rec.reservoirCap then
        rec.reservoirN += 1
        rec.reservoir[rec.reservoirN] = value
    else
        rec.reservoirN += 1
        -- Vitter's R: replace at uniform index with probability cap/n
        local idx = math.random(1, rec.reservoirN)
        if idx <= rec.reservoirCap then
            rec.reservoir[idx] = value
        end
    end
end

local function ensureRecord(self, name)
    local r = self._records[name]
    if not r then
        r = newRecord(name, self._reservoirCap)
        self._records[name] = r
    end
    return r
end

local function ensureChild(parent, name)
    local c = parent.children[name]
    if not c then
        c = { name = name, children = {}, count = 0, totalMs = 0 }
        parent.children[name] = c
    end
    return c
end

-- ---------------------------------------------------------------------
-- Enter / exit
-- ---------------------------------------------------------------------

function Profiler:enter(name: string)
    if not self._enabled then return false end
    local parent = self._stack[#self._stack]
    local treeNode = ensureChild(parent, name)
    local frame = {
        name      = name,
        startedAt = os.clock(),
        treeNode  = treeNode,
    }
    table.insert(self._stack, frame)
    return frame
end

function Profiler:exit(frame)
    if frame == false or not self._enabled then return end
    if not frame then
        error("Profiler:exit called with nil frame", 2)
    end
    local top = self._stack[#self._stack]
    if top ~= frame then
        -- Mismatched exit (probably nested errors). Unwind to the matching frame.
        local idx
        for i = #self._stack, 1, -1 do
            if self._stack[i] == frame then idx = i break end
        end
        if not idx then return end                                  -- unknown frame
        while #self._stack >= idx do table.remove(self._stack) end
    else
        table.remove(self._stack)
    end

    local elapsedMs = (os.clock() - frame.startedAt) * 1000
    local rec = ensureRecord(self, frame.name)
    rec.count += 1
    rec.totalMs += elapsedMs
    if elapsedMs < rec.minMs then rec.minMs = elapsedMs end
    if elapsedMs > rec.maxMs then rec.maxMs = elapsedMs end
    rec.lastMs = elapsedMs
    reservoirAdd(self, rec, elapsedMs)

    -- Tree node aggregate
    frame.treeNode.count += 1
    frame.treeNode.totalMs += elapsedMs

    -- Frame-budget alert
    if elapsedMs > self._frameBudget and self._onBudget then
        pcall(self._onBudget, frame.name, elapsedMs, self._frameBudget)
    end
end

function Profiler:measure(name: string, fn, ...)
    if not self._enabled then return fn(...) end
    local frame = self:enter(name)
    local results = table.pack(pcall(fn, ...))
    self:exit(frame)
    if results[1] then
        return table.unpack(results, 2, results.n)
    end
    error(results[2], 2)
end

-- ---------------------------------------------------------------------
-- Percentile estimation
-- ---------------------------------------------------------------------

local function percentile(samples, n, p)
    if n == 0 then return 0 end
    -- Use a copy to avoid mutating the live reservoir
    local sorted = table.create(n)
    for i = 1, n do sorted[i] = samples[i] end
    table.sort(sorted)
    local rank = p * (n - 1) + 1
    local lo = math.floor(rank)
    local hi = math.ceil(rank)
    if lo == hi then return sorted[lo] end
    local frac = rank - lo
    return sorted[lo] * (1 - frac) + sorted[hi] * frac
end

function Profiler:stats(name: string?)
    if name then
        local r = self._records[name]
        if not r then return nil end
        local nSamples = math.min(r.reservoirN, r.reservoirCap)
        return {
            name      = r.name,
            count     = r.count,
            totalMs   = r.totalMs,
            minMs     = if r.count > 0 then r.minMs else 0,
            maxMs     = if r.count > 0 then r.maxMs else 0,
            meanMs    = if r.count > 0 then r.totalMs / r.count else 0,
            lastMs    = r.lastMs,
            p50Ms     = percentile(r.reservoir, nSamples, 0.50),
            p95Ms     = percentile(r.reservoir, nSamples, 0.95),
            p99Ms     = percentile(r.reservoir, nSamples, 0.99),
            samples   = nSamples,
        }
    end
    local all = {}
    for k in self._records do
        all[k] = self:stats(k)
    end
    return all
end

-- ---------------------------------------------------------------------
-- Reports
-- ---------------------------------------------------------------------

function Profiler:flatReport(opts)
    opts = opts or {}
    local sortKey = opts.sortBy or "totalMs"
    local rows = {}
    for _, r in self._records do
        rows[#rows + 1] = self:stats(r.name)
    end
    table.sort(rows, function(a, b) return (a[sortKey] or 0) > (b[sortKey] or 0) end)
    local lines = { string.format(
        "%-44s %8s %10s %9s %9s %9s %9s %9s",
        "name", "count", "total", "mean", "min", "max", "p95", "p99")
    }
    for _, r in rows do
        lines[#lines + 1] = string.format(
            "%-44s %8d %9.2fm %8.3fm %8.3fm %8.3fm %8.3fm %8.3fm",
            string.sub(r.name, 1, 44), r.count, r.totalMs, r.meanMs,
            r.minMs, r.maxMs, r.p95Ms, r.p99Ms)
    end
    return table.concat(lines, "\n")
end

local function renderTreeNode(node, indent, lines)
    if node.name ~= "<root>" then
        lines[#lines + 1] = string.format(
            "%s%s  ×%d  %.3fms total  %.3fms avg",
            indent, node.name, node.count, node.totalMs,
            if node.count > 0 then node.totalMs / node.count else 0)
        indent = indent .. "  "
    end
    -- Sort children by total time desc
    local childList = {}
    for _, c in node.children do childList[#childList + 1] = c end
    table.sort(childList, function(a, b) return a.totalMs > b.totalMs end)
    for _, c in childList do renderTreeNode(c, indent, lines) end
end

function Profiler:treeReport()
    local lines = {}
    renderTreeNode(self._root, "", lines)
    return table.concat(lines, "\n")
end

function Profiler:reset()
    self._records = {}
    self._stack = table.create(16)
    self._root = { name = "<root>", children = {}, count = 0, totalMs = 0 }
    self._stack[1] = self._root
end

return Profiler
