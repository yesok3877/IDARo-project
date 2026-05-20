--!nonstrict
-- =====================================================================
-- IDARoblox / Runtime / GCScanner
-- ---------------------------------------------------------------------
-- Walks the GC heap (`getgc(true)`) and categorizes every reachable
-- object. Produces a queryable inventory that powers GCHeapView,
-- ClosuresView, and several plugins.
--
-- Output schema (after :scan())
--   {
--     summary  = { totalObjects, byType = {function=N, table=M, …},
--                  totalUpvalues, totalFields, scanDuration },
--
--     functions = [{ ref = fn, source = "core"|"script"|"executor"|"anon",
--                    nupvalues, scriptRef, what, source, lineDefined,
--                    bytecodeHash, hooked }],
--
--     tables    = [{ ref = tbl, shapeHash, arrayLen, mapLen, mtClass,
--                    isFrozen, sampledKeys, looksLikeRoblox }],
--
--     userdata  = [{ ref, mtClass = "Vector3"|"CFrame"|…, isInstance }],
--
--     threads   = [{ ref, status = "running"|"suspended"|"normal"|"dead" }],
--
--     graph     = {
--       fnUpvaluesOf[fn]     = { fn, fn, fn }   (which captured fns)
--       fnCalledBy[fn]       = { fn, … }        (call edges; best-effort)
--       tableMembersOf[tbl]  = { fn, … }        (fn-valued fields)
--     },
--
--     cycles    = [{ ref, kind, length }],     (cycle detector findings)
--   }
--
-- Streaming variants exist for huge heaps:
--   :stream(callback, opts) iterates objects without building the full
--   result, yielding every N objects so the UI thread doesn't stall.
-- =====================================================================

local GCScanner = {}
GCScanner.__index = GCScanner

-- ---------------------------------------------------------------------
-- Source classification for functions
-- ---------------------------------------------------------------------

local function fnSourceTag(info)
    if not info then return "anon" end
    local what = info.what or ""
    local src  = info.source or ""
    if what == "C" then return "core" end                            -- C builtins
    if string.sub(src, 1, 9) == "[C] -> " then return "core" end
    if string.sub(src, 1, 1) == "=" then return "executor" end       -- "=injected"
    if string.sub(src, 1, 1) == "@" then return "script" end         -- "@game.Workspace.X"
    if src ~= "" then return "script" end
    return "anon"
end

-- ---------------------------------------------------------------------
-- Shape hashing for tables
--
-- A "shape" is the sorted list of string keys plus their value-type
-- tags. Two tables with the same shape are likely instances of the same
-- "class" (e.g. Player objects, OOP class instances).
--
-- We sample at most SHAPE_SAMPLE keys to keep cost bounded on huge maps.
-- ---------------------------------------------------------------------

local SHAPE_SAMPLE = 24

local function fnvHash(s)
    local h = 2166136261
    for i = 1, #s do
        h = bit32.bxor(h, string.byte(s, i))
        h = (h * 16777619) % 4294967296
    end
    return h
end

local function shapeOf(t)
    local keys = {}
    local arrayLen = 0
    local mapLen   = 0
    local sampled = 0
    for k in pairs(t) do
        if type(k) == "number" and k > 0 and math.floor(k) == k then
            arrayLen = arrayLen + 1
        elseif type(k) == "string" then
            mapLen = mapLen + 1
            if sampled < SHAPE_SAMPLE then
                keys[#keys + 1] = k
                sampled = sampled + 1
            end
        else
            mapLen = mapLen + 1
        end
    end
    table.sort(keys)
    local parts = table.create(#keys * 2)
    for _, k in keys do
        parts[#parts + 1] = k
        parts[#parts + 1] = type(t[k])
    end
    local sig = table.concat(parts, "|")
    return {
        hash       = fnvHash(sig),
        sig        = sig,
        arrayLen   = arrayLen,
        mapLen     = mapLen,
        sampledKeys = keys,
    }
end

-- ---------------------------------------------------------------------
-- Metatable classifier
-- ---------------------------------------------------------------------

local ROBLOX_MT_HINTS = {
    -- Class names that appear on the metatable's __index when the
    -- object is a typical Roblox userdata or wrapper
    Vector3 = true, Vector2 = true, CFrame = true,
    UDim = true, UDim2 = true, Color3 = true, ColorSequence = true,
    NumberRange = true, NumberSequence = true, Region3 = true,
    Rect = true, Ray = true, Axes = true, Faces = true,
    Instance = true, EnumItem = true, Enum = true,
    BrickColor = true, RBXScriptSignal = true, RBXScriptConnection = true,
    TweenInfo = true, PathWaypoint = true, RaycastParams = true,
    RaycastResult = true, OverlapParams = true,
}

local function classifyMetatable(getRawMt, obj)
    if not getRawMt then return nil end
    local ok, mt = pcall(getRawMt, obj)
    if not ok or type(mt) ~= "table" then return nil end
    -- Try __type first (some executors stamp it)
    local class = rawget(mt, "__type")
    if type(class) == "string" then return class end
    -- Try __index.ClassName (common pattern)
    local idx = rawget(mt, "__index")
    if type(idx) == "table" then
        local cn = rawget(idx, "ClassName")
        if type(cn) == "string" then return cn end
        for k in pairs(idx) do
            if type(k) == "string" and ROBLOX_MT_HINTS[k] then return k end
        end
    end
    return nil
end

-- ---------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------

function GCScanner.new(opts)
    opts = opts or {}
    return setmetatable({
        _scanner   = opts.scanner,                                   -- EnvironmentScanner
        _logger    = opts.logger,
        _eventBus  = opts.eventBus,
        _lastScan  = nil,
        _stats = {
            scans          = 0,
            objectsSeen    = 0,
            functionsSeen  = 0,
            tablesSeen     = 0,
            userdataSeen   = 0,
            threadsSeen    = 0,
            cyclesDetected = 0,
            lastDuration   = 0,
        },
    }, GCScanner)
end

function GCScanner:setScanner(s) self._scanner = s end

-- ---------------------------------------------------------------------
-- Capability accessors
-- ---------------------------------------------------------------------

function GCScanner:_getgc()
    if not self._scanner then return nil end
    if type(self._scanner.getRaw) == "function" then
        return self._scanner:getRaw("getgc")
    end
    return getfenv(0).getgc
end

function GCScanner:_getRawMetatable()
    if not self._scanner then return nil end
    if type(self._scanner.getRaw) == "function" then
        return self._scanner:getRaw("getrawmetatable")
    end
    return getfenv(0).getrawmetatable
end

function GCScanner:_getFnInfo()
    -- We use debug.info if available (Roblox), otherwise debug.getinfo.
    local dbg = (self._scanner and self._scanner.getRaw and self._scanner:getRaw("debug")) or debug
    if not dbg then return nil end
    if type(dbg.info) == "function" then
        return function(fn) return dbg.info(fn, "slna") end
    end
    if type(dbg.getinfo) == "function" then
        return function(fn) return dbg.getinfo(fn, "Sln") end
    end
    return nil
end

function GCScanner:_getUpvalues()
    local dbg = (self._scanner and self._scanner.getRaw and self._scanner:getRaw("debug")) or debug
    if dbg and type(dbg.getupvalues) == "function" then
        -- Wave / most executors: dbg.getupvalues(fn) returns a flat
        -- array of values. Normalise to records so the call sites can
        -- always do `up.value`.
        return function(fn)
            local raw = dbg.getupvalues(fn)
            if type(raw) ~= "table" then return nil end
            local out = table.create(#raw)
            for i, v in ipairs(raw) do
                if type(v) == "table" and v.value ~= nil then
                    -- Already in record shape — pass through.
                    out[i] = v
                else
                    out[i] = { name = nil, value = v, index = i }
                end
            end
            return out
        end
    end
    if dbg and type(dbg.getupvalue) == "function" then
        return function(fn)
            -- Iterate by index until nil
            local out = {}
            local i = 1
            while true do
                local ok, name, value = pcall(dbg.getupvalue, fn, i)
                if not ok or name == nil then break end
                out[i] = { name = name, value = value, index = i }
                i = i + 1
            end
            return out
        end
    end
    return nil
end

-- ---------------------------------------------------------------------
-- Full scan
-- ---------------------------------------------------------------------

function GCScanner:scan(opts)
    opts = opts or {}
    local includeTables = opts.includeTables ~= false                -- default true
    local maxObjects    = opts.maxObjects or 250000
    local getgc = self:_getgc()
    if not getgc then
        if self._logger then self._logger:warn("GCScanner: getgc unavailable") end
        return nil, "getgc unavailable"
    end
    local startedAt = os.clock()
    local ok, all = pcall(getgc, includeTables)
    if not ok then
        return nil, "getgc failed: " .. tostring(all)
    end

    local getInfo = self:_getFnInfo()
    local getUpvalues = self:_getUpvalues()
    local getRawMt = self:_getRawMetatable()

    local result = {
        summary   = {
            totalObjects = 0, byType = {},
            totalUpvalues = 0, totalFields = 0,
            scanDuration = 0, startedAt = startedAt,
        },
        functions = {},
        tables    = {},
        userdata  = {},
        threads   = {},
        graph     = { fnUpvaluesOf = {}, tableMembersOf = {} },
        cycles    = {},
    }

    local fnByRef    = {}                                            -- fn → record
    local tableByRef = {}                                            -- t  → record
    local n = 0

    for _, obj in all do
        if n >= maxObjects then break end
        n = n + 1
        local tag = type(obj)
        result.summary.byType[tag] = (result.summary.byType[tag] or 0) + 1

        pcall(function()

        if tag == "function" then
            local info = getInfo and (pcall(getInfo, obj) and getInfo(obj)) or nil
            local source = fnSourceTag(info)
            local upvCount = 0
            if getUpvalues then
                local ok2, ups = pcall(getUpvalues, obj)
                if ok2 and type(ups) == "table" then upvCount = #ups end
            end
            local rec = {
                ref          = obj,
                source       = source,
                nupvalues    = upvCount,
                what         = info and info.what,
                src          = info and info.source,
                lineDefined  = info and (info.linedefined or info.currentline),
                name         = info and info.name,
                isC          = info and info.what == "C",
                hooked       = false,                                -- set externally if known
            }
            result.functions[#result.functions + 1] = rec
            fnByRef[obj] = rec
            result.summary.totalUpvalues = result.summary.totalUpvalues + upvCount
            self._stats.functionsSeen = self._stats.functionsSeen + 1

        elseif tag == "table" and includeTables then
            local shape = shapeOf(obj)
            local mtClass = classifyMetatable(getRawMt, obj)
            local isFrozen = false
            if type(table.isfrozen) == "function" then
                isFrozen = pcall(table.isfrozen, obj) and table.isfrozen(obj) or false
            end
            local rec = {
                ref         = obj,
                shapeHash   = shape.hash,
                arrayLen    = shape.arrayLen,
                mapLen      = shape.mapLen,
                mtClass     = mtClass,
                isFrozen    = isFrozen,
                sampledKeys = shape.sampledKeys,
                looksLikeRoblox = mtClass ~= nil,
            }
            result.tables[#result.tables + 1] = rec
            tableByRef[obj] = rec
            result.summary.totalFields = result.summary.totalFields
                + shape.arrayLen + shape.mapLen
            self._stats.tablesSeen = self._stats.tablesSeen + 1

        elseif tag == "userdata" then
            local mtClass = classifyMetatable(getRawMt, obj)
            local isInstance = false
            -- Roblox Instance: typeof(obj) == "Instance" works in-game.
            -- We can't rely on it but check pcall(getProp ClassName).
            local okCN, cn = pcall(function() return obj.ClassName end)
            if okCN and type(cn) == "string" then
                isInstance = true
                mtClass = mtClass or cn
            end
            result.userdata[#result.userdata + 1] = {
                ref = obj, mtClass = mtClass, isInstance = isInstance,
            }
            self._stats.userdataSeen = self._stats.userdataSeen + 1

        elseif tag == "thread" then
            local status
            if type(coroutine.status) == "function" then
                local okS, st = pcall(coroutine.status, obj)
                status = okS and st or "?"
            end
            result.threads[#result.threads + 1] = { ref = obj, status = status }
            self._stats.threadsSeen = self._stats.threadsSeen + 1
        end

        end)                                                          -- close per-object pcall
    end
    result.summary.totalObjects = n
    self._stats.objectsSeen = self._stats.objectsSeen + n

    -- ---------------------------------------------------------------
    -- Pass 2: build reference graph
    -- ---------------------------------------------------------------
    if getUpvalues then
        for fn, rec in fnByRef do
            pcall(function()
                local ups = getUpvalues(fn)
                if type(ups) == "table" then
                    local edges = {}
                    for _, up in ups do
                        local v = up.value
                        if type(v) == "function" and fnByRef[v] then
                            edges[#edges + 1] = v
                        end
                    end
                    if #edges > 0 then result.graph.fnUpvaluesOf[fn] = edges end
                end
            end)
        end
    end

    if includeTables then
        for tbl, rec in tableByRef do
            local fnFields = {}
            local count = 0
            local okPairs = pcall(function()
                for _, v in pairs(tbl) do
                    if type(v) == "function" and fnByRef[v] then
                        fnFields[#fnFields + 1] = v
                    end
                    count = count + 1
                    if count > 256 then break end                        -- bound per-table
                end
            end)
            if okPairs and #fnFields > 0 then
                result.graph.tableMembersOf[tbl] = fnFields
            end
        end
    end

    -- ---------------------------------------------------------------
    -- Pass 3: simple cycle detector over fn-upvalue graph
    --
    -- Tarjan's SCC is overkill at this scale; a DFS with grey/black sets
    -- finds the cycles we care about (function references function via
    -- upvalue chain that returns to itself).
    -- ---------------------------------------------------------------
    do
        local WHITE, GREY, BLACK = 0, 1, 2
        local color = {}
        local function dfs(fn, stack)
            color[fn] = GREY
            stack[#stack + 1] = fn
            local edges = result.graph.fnUpvaluesOf[fn]
            if edges then
                for _, other in edges do
                    if color[other] == GREY then
                        -- Found a back-edge → cycle from `other` to fn
                        local cycleStart
                        for i = #stack, 1, -1 do
                            if stack[i] == other then cycleStart = i; break end
                        end
                        if cycleStart then
                            local len = #stack - cycleStart + 1
                            result.cycles[#result.cycles + 1] = {
                                ref = other,
                                kind = "fn-upvalue",
                                length = len,
                            }
                            self._stats.cyclesDetected = self._stats.cyclesDetected + 1
                        end
                    elseif color[other] == WHITE then
                        dfs(other, stack)
                    end
                end
            end
            color[fn] = BLACK
            stack[#stack] = nil
        end
        for fn in fnByRef do
            if color[fn] == nil then dfs(fn, {}) end
        end
    end

    local dur = os.clock() - startedAt
    result.summary.scanDuration = dur
    self._stats.lastDuration = dur
    self._stats.scans = self._stats.scans + 1
    self._lastScan = result

    if self._logger then
        self._logger:info(
            "GCScanner: %d objects scanned in %.3fs (%d fns, %d tables, %d userdata, %d threads, %d cycles)",
            n, dur, #result.functions, #result.tables, #result.userdata,
            #result.threads, #result.cycles)
    end
    if self._eventBus then
        pcall(self._eventBus.emit, self._eventBus, "gc.scanned",
            { summary = result.summary })
    end
    -- ---------------------------------------------------------------
    -- Build a unified `objects` array. Each entry is one of the
    -- type-specific records from result.functions/.tables/.userdata/.
    -- threads, tagged with a normalized `type` field. Consumers like
    -- ClosuresView, HeapGraphView, GCHeapView iterate this single list
    -- instead of dealing with five buckets.
    -- ---------------------------------------------------------------
    do
        local objs = {}
        for _, rec in result.functions do
            rec.type = "func"
            objs[#objs + 1] = rec
        end
        for _, rec in result.tables do
            rec.type = "table"
            objs[#objs + 1] = rec
        end
        for _, rec in result.userdata do
            rec.type = "userdata"
            objs[#objs + 1] = rec
        end
        for _, rec in result.threads do
            rec.type = "thread"
            objs[#objs + 1] = rec
        end
        result.objects = objs
        -- Mirror the graph fields under a name that matches what
        -- HeapGraphView already expects (referenceGraph).
        result.referenceGraph = result.graph
    end

    return result
end

function GCScanner:last() return self._lastScan end

-- ---------------------------------------------------------------------
-- Streaming scan (for very large heaps)
-- ---------------------------------------------------------------------

function GCScanner:stream(callback, opts)
    opts = opts or {}
    local yieldEvery = opts.yieldEvery or 2000
    local getgc = self:_getgc()
    if not getgc then return nil, "getgc unavailable" end
    local ok, all = pcall(getgc, opts.includeTables ~= false)
    if not ok then return nil, "getgc failed" end

    local total = #all
    local yielded = 0
    for i, obj in all do
        callback(obj, i, total)
        if i % yieldEvery == 0 then
            yielded = yielded + 1
            if task and task.wait then task.wait() end                -- cooperative yield
        end
    end
    return { iterated = total, yieldedCount = yielded }
end

-- ---------------------------------------------------------------------
-- Filter / query API
-- ---------------------------------------------------------------------

function GCScanner:byType(tag)
    if not self._lastScan then return {} end
    if tag == "function" then return self._lastScan.functions end
    if tag == "table"    then return self._lastScan.tables end
    if tag == "userdata" then return self._lastScan.userdata end
    if tag == "thread"   then return self._lastScan.threads end
    return {}
end

function GCScanner:bySource(source)
    if not self._lastScan then return {} end
    local out = {}
    for _, rec in self._lastScan.functions do
        if rec.source == source then out[#out + 1] = rec end
    end
    return out
end

function GCScanner:byMetatableClass(class)
    if not self._lastScan then return {} end
    local out = {}
    for _, rec in self._lastScan.tables do
        if rec.mtClass == class then out[#out + 1] = rec end
    end
    for _, rec in self._lastScan.userdata do
        if rec.mtClass == class then out[#out + 1] = rec end
    end
    return out
end

function GCScanner:functionsWithUpvalues(minCount)
    if not self._lastScan then return {} end
    local out = {}
    for _, rec in self._lastScan.functions do
        if rec.nupvalues >= (minCount or 1) then out[#out + 1] = rec end
    end
    table.sort(out, function(a, b) return a.nupvalues > b.nupvalues end)
    return out
end

function GCScanner:tablesByShape(shapeHash)
    if not self._lastScan then return {} end
    local out = {}
    for _, rec in self._lastScan.tables do
        if rec.shapeHash == shapeHash then out[#out + 1] = rec end
    end
    return out
end

function GCScanner:shapeHistogram()
    if not self._lastScan then return {} end
    local buckets = {}
    for _, rec in self._lastScan.tables do
        local h = rec.shapeHash
        local b = buckets[h]
        if not b then b = { hash = h, count = 0, sample = rec }; buckets[h] = b end
        b.count = b.count + 1
    end
    local out = {}
    for _, b in buckets do out[#out + 1] = b end
    table.sort(out, function(a, b) return a.count > b.count end)
    return out
end

function GCScanner:stats()
    return {
        scans          = self._stats.scans,
        objectsSeen    = self._stats.objectsSeen,
        functionsSeen  = self._stats.functionsSeen,
        tablesSeen     = self._stats.tablesSeen,
        userdataSeen   = self._stats.userdataSeen,
        threadsSeen    = self._stats.threadsSeen,
        cyclesDetected = self._stats.cyclesDetected,
        lastDuration   = self._stats.lastDuration,
        hasLast        = self._lastScan ~= nil,
    }
end

return GCScanner
