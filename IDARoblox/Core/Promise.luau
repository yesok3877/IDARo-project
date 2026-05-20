--!nonstrict
-- =====================================================================
-- IDARoblox / Core / Promise
-- ---------------------------------------------------------------------
-- A Promises/A+ compatible implementation with explicit cancellation,
-- combinators (all, allSettled, any, race), and time helpers (delay,
-- retry, timeout). Designed for cooperative use inside Roblox's task
-- scheduler.
--
-- States: Pending → Fulfilled | Rejected | Cancelled
--
-- Cancellation propagates *forward* through chains (children of a
-- cancelled promise are also cancelled) and *backward* through pending
-- parents (cancelling a child cancels its sole parent if the parent has
-- no other live children). Cancellation runs registered onCancel hooks
-- synchronously in registration order.
-- =====================================================================

local Promise = {}
Promise.__index = Promise

local STATE_PENDING   = "Pending"
local STATE_FULFILLED = "Fulfilled"
local STATE_REJECTED  = "Rejected"
local STATE_CANCELLED = "Cancelled"

Promise.Status = {
    Pending = STATE_PENDING,
    Fulfilled = STATE_FULFILLED,
    Rejected = STATE_REJECTED,
    Cancelled = STATE_CANCELLED,
}

-- Global unhandled-rejection tracking. Subscribers (e.g. the Logger module)
-- can register a sink to receive any promise whose rejection traveled to
-- the end of its chain without a `:catch`.
local _unhandledSinks: { (err: any, promise: any) -> () } = {}

function Promise.onUnhandledRejection(sink: (err: any, promise: any) -> ()): () -> ()
    table.insert(_unhandledSinks, sink)
    return function()
        for i, s in _unhandledSinks do
            if s == sink then table.remove(_unhandledSinks, i) return end
        end
    end
end

local function reportUnhandled(err, promise)
    for _, sink in _unhandledSinks do
        task.spawn(sink, err, promise)
    end
end

-- ---------------------------------------------------------------------
-- isPromise / thenable detection
-- ---------------------------------------------------------------------

local function isPromise(v): boolean
    return type(v) == "table" and getmetatable(v) == Promise
end

local function isThenable(v): boolean
    return type(v) == "table" and type(v.andThen) == "function"
end

Promise.is = isPromise

-- ---------------------------------------------------------------------
-- Core constructor
-- ---------------------------------------------------------------------

local function newPromise()
    return setmetatable({
        _state        = STATE_PENDING,
        _value        = nil,                                       -- single value slot
        _values       = nil :: { any }?,                           -- multi-return on resolve
        _queue        = table.create(4),                           -- chain {onFul, onRej, child}
        _cancelHooks  = table.create(2),
        _parent       = nil,                                       -- back-link for cancel propagation
        _children     = setmetatable({}, { __mode = "v" }),        -- weak
        _consumed     = false,                                     -- has any handler been attached?
        _trace        = nil,                                       -- debug traceback at construction
    }, Promise)
end

local function captureTrace(level: number?)
    if debug and debug.traceback then
        return debug.traceback(nil, (level or 1) + 1)
    end
    return ""
end

function Promise.new(executor: (resolve: (...any) -> (), reject: (any) -> (), onCancel: ((() -> ())?) -> boolean) -> ())
    local self = newPromise()
    self._trace = captureTrace(2)

    local resolved = false
    local function settleResolve(...)
        if resolved or self._state ~= STATE_PENDING then return end
        resolved = true
        self:_resolve(...)
    end

    local function settleReject(reason)
        if resolved or self._state ~= STATE_PENDING then return end
        resolved = true
        self:_reject(reason)
    end

    local function onCancel(callback: (() -> ())?): boolean
        if self._state == STATE_CANCELLED then
            if callback then task.spawn(callback) end
            return true
        end
        if self._state ~= STATE_PENDING then return false end
        if callback then table.insert(self._cancelHooks, callback) end
        return false
    end

    local ok, err = pcall(executor, settleResolve, settleReject, onCancel)
    if not ok and not resolved then
        self:_reject(err)
    end
    return self
end

-- ---------------------------------------------------------------------
-- Static helpers
-- ---------------------------------------------------------------------

function Promise.resolve(...)
    local n = select("#", ...)
    local p = newPromise()
    if n <= 1 then
        local v = ...
        if isPromise(v) then return v end
        if isThenable(v) then
            return Promise.new(function(res, rej)
                v:andThen(res, rej)
            end)
        end
        p._state = STATE_FULFILLED
        p._value = v
    else
        p._state = STATE_FULFILLED
        p._values = table.pack(...)
    end
    return p
end

function Promise.reject(reason)
    local p = newPromise()
    p._state = STATE_REJECTED
    p._value = reason
    -- Schedule unhandled check on next tick.
    task.defer(function()
        if not p._consumed and p._state == STATE_REJECTED then
            reportUnhandled(reason, p)
        end
    end)
    return p
end

function Promise.delay(seconds: number)
    return Promise.new(function(resolve, _, onCancel)
        local cancelled = false
        onCancel(function() cancelled = true end)
        task.delay(seconds, function()
            if not cancelled then resolve() end
        end)
    end)
end

function Promise.fromTask(fn: (...any) -> ...any, ...)
    local args = table.pack(...)
    return Promise.new(function(resolve, reject)
        task.spawn(function()
            local results = table.pack(pcall(fn, table.unpack(args, 1, args.n)))
            if results[1] then
                resolve(table.unpack(results, 2, results.n))
            else
                reject(results[2])
            end
        end)
    end)
end

function Promise.try(fn: (...any) -> ...any, ...)
    return Promise.fromTask(fn, ...)
end

function Promise.all(promises: { any })
    return Promise.new(function(resolve, reject, onCancel)
        local n = #promises
        if n == 0 then resolve({}) return end
        local results = table.create(n)
        local remaining = n
        local cancelled = false
        onCancel(function()
            cancelled = true
            for _, p in promises do
                if isPromise(p) and p._state == STATE_PENDING then p:cancel() end
            end
        end)
        for i, p in promises do
            local prom = if isPromise(p) then p else Promise.resolve(p)
            prom:andThen(function(v)
                if cancelled then return end
                results[i] = v
                remaining = remaining - 1
                if remaining == 0 then resolve(results) end
            end, function(err)
                if cancelled then return end
                cancelled = true
                reject(err)
            end)
        end
    end)
end

function Promise.allSettled(promises: { any })
    return Promise.new(function(resolve, _, onCancel)
        local n = #promises
        if n == 0 then resolve({}) return end
        local results = table.create(n)
        local remaining = n
        onCancel(function()
            for _, p in promises do
                if isPromise(p) and p._state == STATE_PENDING then p:cancel() end
            end
        end)
        for i, p in promises do
            local prom = if isPromise(p) then p else Promise.resolve(p)
            prom:andThen(
                function(v)
                    results[i] = { status = STATE_FULFILLED, value = v }
                    remaining = remaining - 1
                    if remaining == 0 then resolve(results) end
                end,
                function(reason)
                    results[i] = { status = STATE_REJECTED, reason = reason }
                    remaining = remaining - 1
                    if remaining == 0 then resolve(results) end
                end
            )
        end
    end)
end

function Promise.race(promises: { any })
    return Promise.new(function(resolve, reject, onCancel)
        local settled = false
        onCancel(function()
            for _, p in promises do
                if isPromise(p) and p._state == STATE_PENDING then p:cancel() end
            end
        end)
        for _, p in promises do
            local prom = if isPromise(p) then p else Promise.resolve(p)
            prom:andThen(function(v)
                if settled then return end
                settled = true
                resolve(v)
            end, function(err)
                if settled then return end
                settled = true
                reject(err)
            end)
        end
    end)
end

function Promise.any(promises: { any })
    return Promise.new(function(resolve, reject, onCancel)
        local n = #promises
        if n == 0 then reject("Promise.any: empty input") return end
        local errors = table.create(n)
        local remaining = n
        onCancel(function()
            for _, p in promises do
                if isPromise(p) and p._state == STATE_PENDING then p:cancel() end
            end
        end)
        for i, p in promises do
            local prom = if isPromise(p) then p else Promise.resolve(p)
            prom:andThen(function(v) resolve(v) end, function(err)
                errors[i] = err
                remaining = remaining - 1
                if remaining == 0 then reject({ aggregate = true, errors = errors }) end
            end)
        end
    end)
end

function Promise.retry(fn: (attempt: number) -> any, attempts: number, intervalSec: number?)
    return Promise.new(function(resolve, reject, onCancel)
        local cancelled = false
        onCancel(function() cancelled = true end)
        task.spawn(function()
            local lastErr
            for i = 1, attempts do
                if cancelled then reject("cancelled") return end
                local r = Promise.try(fn, i)
                local ok, val = r:awaitStatus()
                if ok == STATE_FULFILLED then
                    resolve(val) return
                else
                    lastErr = val
                    if i < attempts and intervalSec then
                        task.wait(intervalSec)
                    end
                end
            end
            reject(lastErr)
        end)
    end)
end

function Promise.timeout(promise, seconds: number, reason: any?)
    return Promise.new(function(resolve, reject, onCancel)
        local done = false
        local timer = task.delay(seconds, function()
            if done then return end
            done = true
            promise:cancel()
            reject(reason or "timeout")
        end)
        onCancel(function()
            if done then return end
            done = true
            task.cancel(timer)
            promise:cancel()
        end)
        promise:andThen(function(...)
            if done then return end
            done = true
            task.cancel(timer)
            resolve(...)
        end, function(err)
            if done then return end
            done = true
            task.cancel(timer)
            reject(err)
        end)
    end)
end

-- ---------------------------------------------------------------------
-- Internal settlement
-- ---------------------------------------------------------------------

function Promise:_resolve(...)
    local n = select("#", ...)
    local v = ...
    if v == self then
        return self:_reject("Promise resolved with itself")
    end
    -- Adoption of nested promises / thenables
    if n == 1 and (isPromise(v) or isThenable(v)) then
        if isPromise(v) then
            v._parent = self                                       -- adopt for cancel
        end
        v:andThen(function(...) self:_resolve(...) end, function(err) self:_reject(err) end)
        return
    end
    if n > 1 then
        self._values = table.pack(...)
    else
        self._value = v
    end
    self._state = STATE_FULFILLED
    self:_drain()
end

function Promise:_reject(reason)
    self._value = reason
    self._state = STATE_REJECTED
    -- Defer unhandled detection; let any synchronously-attached handlers consume.
    if #self._queue == 0 then
        task.defer(function()
            if self._state == STATE_REJECTED and not self._consumed then
                reportUnhandled(reason, self)
            end
        end)
    end
    self:_drain()
end

function Promise:_drain()
    local queue = self._queue
    self._queue = table.create(2)
    for _, entry in queue do
        local onFul, onRej, child = entry[1], entry[2], entry[3]
        self:_dispatch(onFul, onRej, child)
    end
end

function Promise:_dispatch(onFul, onRej, child)
    local state = self._state
    if state == STATE_CANCELLED then
        child:_propagateCancel()
        return
    end
    local cb = if state == STATE_FULFILLED then onFul else onRej
    if not cb then
        -- Pass-through
        if state == STATE_FULFILLED then
            if self._values then
                child:_resolve(table.unpack(self._values, 1, self._values.n))
            else
                child:_resolve(self._value)
            end
        else
            child:_reject(self._value)
        end
        return
    end
    task.defer(function()
        local args
        if state == STATE_FULFILLED and self._values then
            args = self._values
        else
            args = { self._value, n = 1 }
        end
        local results = table.pack(pcall(cb, table.unpack(args, 1, args.n)))
        if results[1] then
            child:_resolve(table.unpack(results, 2, results.n))
        else
            child:_reject(results[2])
        end
    end)
end

-- ---------------------------------------------------------------------
-- Chain operations
-- ---------------------------------------------------------------------

function Promise:andThen(onFulfilled, onRejected)
    self._consumed = true
    local child = newPromise()
    child._parent = self
    table.insert(self._children, child)
    if self._state == STATE_PENDING then
        table.insert(self._queue, { onFulfilled, onRejected, child })
    else
        self:_dispatch(onFulfilled, onRejected, child)
    end
    return child
end

function Promise:catch(onRejected)
    return self:andThen(nil, onRejected)
end

function Promise:finally(onFinally)
    return self:andThen(function(...)
        local args = table.pack(...)
        local ok, r = pcall(onFinally)
        if not ok then error(r) end
        return table.unpack(args, 1, args.n)
    end, function(err)
        local ok, r = pcall(onFinally)
        if not ok then error(r) end
        error(err)
    end)
end

function Promise:tap(callback)
    return self:andThen(function(...)
        pcall(callback, ...)
        return ...
    end)
end

-- ---------------------------------------------------------------------
-- Cancellation
-- ---------------------------------------------------------------------

function Promise:_propagateCancel()
    if self._state ~= STATE_PENDING then return end
    self._state = STATE_CANCELLED
    for _, cb in self._cancelHooks do
        pcall(cb)
    end
    for _, entry in self._queue do
        entry[3]:_propagateCancel()
    end
    self._queue = table.create(0)
end

function Promise:cancel()
    if self._state ~= STATE_PENDING then return end
    self:_propagateCancel()
    -- Walk up: if our parent has no other live children we can cancel it.
    local p = self._parent
    while p and p._state == STATE_PENDING do
        local liveChild = false
        for _, c in p._children do
            if c and c._state == STATE_PENDING then liveChild = true break end
        end
        if liveChild then break end
        p:_propagateCancel()
        p = p._parent
    end
end

-- ---------------------------------------------------------------------
-- Awaiting (yielding form — must be called from a coroutine/task)
-- ---------------------------------------------------------------------

function Promise:awaitStatus(): (string, ...any)
    self._consumed = true
    if self._state == STATE_PENDING then
        local thread = coroutine.running()
        assert(thread, "Promise:awaitStatus must be called from a coroutine")
        self:andThen(function(...)
            task.spawn(thread, STATE_FULFILLED, ...)
        end, function(err)
            task.spawn(thread, STATE_REJECTED, err)
        end)
        return coroutine.yield()
    end
    if self._state == STATE_FULFILLED then
        if self._values then
            return STATE_FULFILLED, table.unpack(self._values, 1, self._values.n)
        end
        return STATE_FULFILLED, self._value
    elseif self._state == STATE_REJECTED then
        return STATE_REJECTED, self._value
    else
        return STATE_CANCELLED
    end
end

function Promise:await(): (boolean, ...any)
    local status, a, b, c, d, e = self:awaitStatus()
    if status == STATE_FULFILLED then return true, a, b, c, d, e end
    if status == STATE_REJECTED then return false, a end
    return false, "cancelled"
end

function Promise:expect(): ...any
    local results = table.pack(self:awaitStatus())
    if results[1] == STATE_FULFILLED then
        return table.unpack(results, 2, results.n)
    elseif results[1] == STATE_REJECTED then
        error(results[2], 2)
    else
        error("Promise was cancelled", 2)
    end
end

function Promise:getStatus(): string return self._state end
function Promise:isPending(): boolean return self._state == STATE_PENDING end
function Promise:isFulfilled(): boolean return self._state == STATE_FULFILLED end
function Promise:isRejected(): boolean return self._state == STATE_REJECTED end
function Promise:isCancelled(): boolean return self._state == STATE_CANCELLED end

function Promise:__tostring()
    return string.format("Promise(%s)", self._state)
end

return Promise
