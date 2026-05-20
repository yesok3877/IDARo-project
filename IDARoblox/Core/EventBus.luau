--!nonstrict
-- =====================================================================
-- IDARoblox / Core / EventBus
-- ---------------------------------------------------------------------
-- A namespaced pub/sub bus with priority-ordered delivery, wildcards,
-- once handlers, deferred emit, error isolation, and (optional) per-
-- topic history rings for late-subscriber replay.
--
-- Topic syntax: dot-delimited identifiers, e.g.
--   "loading.module.begin"
--   "ui.view.activated"
--
-- Wildcards (subscription side only):
--   "loading.*"          — direct children of loading
--   "loading.**"         — loading and any descendant
--   "*"                  — top-level events
--   "**"                 — every event
--
-- Subscribers receive (topic, ...args) and are called in priority order
-- (higher priority first; equal priority falls back to subscription
-- order). Each subscription returns a Connection with :disconnect(),
-- :pause(), :resume(), and :isConnected().
-- =====================================================================

local EventBus = {}
EventBus.__index = EventBus

local Connection = {}
Connection.__index = Connection

-- ---------------------------------------------------------------------
-- Connection
-- ---------------------------------------------------------------------

function Connection:disconnect()
    if not self._connected then return end
    self._connected = false
    self._bus:_remove(self)
end

function Connection:pause()  self._paused = true end
function Connection:resume() self._paused = false end
function Connection:isConnected(): boolean return self._connected end
function Connection:topic(): string return self._topic end

-- ---------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------

local function isWildcard(topic: string): boolean
    return string.find(topic, "%*", 1, false) ~= nil
end

local function patternToMatcher(pattern: string)
    -- "**" matches any sequence including dots; "*" matches one segment.
    -- We build a Lua pattern that does this.
    local p = pattern
    -- Escape special chars except '*' and '.'
    p = string.gsub(p, "([%(%)%[%]%+%-%?%^%$%%])", "%%%1")
    -- '.' stays literal but should match only '.' (already literal after escape skip — re-escape)
    p = string.gsub(p, "%.", "%%.")
    -- Now substitute wildcards
    p = string.gsub(p, "%*%*", ".+")
    p = string.gsub(p, "%*", "[^%%.]+")
    return "^" .. p .. "$"
end

-- ---------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------

function EventBus.new(opts)
    opts = opts or {}
    local self = setmetatable({
        _exact      = {},                                           -- topic → array of subs
        _wild       = table.create(8),                              -- array of {topic, pattern, sub}
        _history    = {},                                           -- topic → ring (if enabled)
        _historyCap = opts.historyCap or 0,                         -- 0 disables history
        _seq        = 0,                                            -- monotonic sub id
        _emitDepth  = 0,                                            -- guard against unbounded reentrancy
        _maxDepth   = opts.maxEmitDepth or 32,
        _logger     = opts.logger,                                  -- optional Logger reference
    }, EventBus)
    return self
end

-- ---------------------------------------------------------------------
-- Subscribe variants
-- ---------------------------------------------------------------------

function EventBus:on(topic: string, handler, priority: number?)
    if type(topic) ~= "string" or topic == "" then
        error("EventBus: topic must be a non-empty string", 2)
    end
    if type(handler) ~= "function" then
        error("EventBus: handler must be a function", 2)
    end
    self._seq += 1
    local sub = setmetatable({
        _bus       = self,
        _topic     = topic,
        _handler   = handler,
        _priority  = priority or 0,
        _seq       = self._seq,
        _connected = true,
        _paused    = false,
        _once      = false,
        _isWild    = isWildcard(topic),
        _pattern   = nil,
    }, Connection)
    if sub._isWild then
        sub._pattern = patternToMatcher(topic)
        table.insert(self._wild, sub)
    else
        local list = self._exact[topic]
        if not list then
            list = table.create(2)
            self._exact[topic] = list
        end
        -- Insert sorted by descending priority, ascending seq
        local insertIdx = #list + 1
        for i, s in list do
            if sub._priority > s._priority then
                insertIdx = i
                break
            end
        end
        table.insert(list, insertIdx, sub)
    end
    return sub
end

function EventBus:once(topic: string, handler, priority: number?)
    local conn
    conn = self:on(topic, function(...)
        conn:disconnect()
        handler(...)
    end, priority)
    conn._once = true
    return conn
end

-- ---------------------------------------------------------------------
-- Internal: remove a subscription
-- ---------------------------------------------------------------------

function EventBus:_remove(sub)
    if sub._isWild then
        for i, s in self._wild do
            if s == sub then table.remove(self._wild, i) return end
        end
    else
        local list = self._exact[sub._topic]
        if not list then return end
        for i, s in list do
            if s == sub then
                table.remove(list, i)
                if #list == 0 then self._exact[sub._topic] = nil end
                return
            end
        end
    end
end

-- ---------------------------------------------------------------------
-- History rings
-- ---------------------------------------------------------------------

function EventBus:enableHistory(topic: string, cap: number?)
    cap = cap or self._historyCap
    if cap <= 0 then return end
    self._history[topic] = self._history[topic] or {
        cap = cap, items = table.create(cap), head = 0, count = 0,
    }
end

function EventBus:replayHistory(topic: string, handler)
    local ring = self._history[topic]
    if not ring or ring.count == 0 then return end
    local startIdx = if ring.count < ring.cap then 1 else (ring.head % ring.cap) + 1
    for i = 1, ring.count do
        local idx = ((startIdx + i - 2) % ring.cap) + 1
        local args = ring.items[idx]
        handler(topic, table.unpack(args, 1, args.n))
    end
end

local function ringPush(ring, args)
    ring.head = (ring.head % ring.cap) + 1
    ring.items[ring.head] = args
    if ring.count < ring.cap then ring.count = ring.count + 1 end
end

-- ---------------------------------------------------------------------
-- Emit
-- ---------------------------------------------------------------------

function EventBus:emit(topic: string, ...)
    if self._emitDepth >= self._maxDepth then
        if self._logger then
            self._logger:warn("EventBus: max emit depth exceeded for '%s'", topic)
        end
        return
    end
    self._emitDepth += 1

    -- Push to history before dispatch
    local ring = self._history[topic]
    if ring then ringPush(ring, table.pack(...)) end

    -- Build a merged delivery list, ordered by priority desc, seq asc.
    -- We iterate snapshots so handlers can mutate subscriptions safely.
    local pending = {}
    local exact = self._exact[topic]
    if exact then
        for _, s in exact do pending[#pending + 1] = s end
    end
    for _, s in self._wild do
        if string.match(topic, s._pattern) then pending[#pending + 1] = s end
    end
    if #pending > 1 then
        table.sort(pending, function(a, b)
            if a._priority ~= b._priority then return a._priority > b._priority end
            return a._seq < b._seq
        end)
    end

    for _, sub in pending do
        if sub._connected and not sub._paused then
            local ok, err = pcall(sub._handler, topic, ...)
            if not ok and self._logger then
                self._logger:error("EventBus: handler error on '%s': %s", topic, tostring(err))
            end
        end
    end

    self._emitDepth -= 1
end

function EventBus:emitDeferred(topic: string, ...)
    local args = table.pack(...)
    task.defer(function()
        self:emit(topic, table.unpack(args, 1, args.n))
    end)
end

function EventBus:emitAsync(topic: string, ...)
    local args = table.pack(...)
    task.spawn(function()
        self:emit(topic, table.unpack(args, 1, args.n))
    end)
end

-- ---------------------------------------------------------------------
-- Bulk operations
-- ---------------------------------------------------------------------

function EventBus:hasSubscribers(topic: string): boolean
    if self._exact[topic] and #self._exact[topic] > 0 then return true end
    for _, s in self._wild do
        if string.match(topic, s._pattern) then return true end
    end
    return false
end

function EventBus:disconnectAll(topicOrPrefix: string?)
    if not topicOrPrefix then
        self._exact = {}
        self._wild = table.create(8)
        return
    end
    -- Walk exact map
    for topic, list in self._exact do
        if topic == topicOrPrefix or string.sub(topic, 1, #topicOrPrefix + 1) == topicOrPrefix .. "." then
            for _, s in list do s._connected = false end
            self._exact[topic] = nil
        end
    end
    for i = #self._wild, 1, -1 do
        local s = self._wild[i]
        if s._topic == topicOrPrefix then
            s._connected = false
            table.remove(self._wild, i)
        end
    end
end

function EventBus:countSubscribers(topic: string?): number
    if topic then
        local n = (self._exact[topic] and #self._exact[topic]) or 0
        for _, s in self._wild do
            if string.match(topic, s._pattern) then n = n + 1 end
        end
        return n
    end
    local n = 0
    for _, l in self._exact do n = n + #l end
    n = n + #self._wild
    return n
end

return EventBus
