--!nonstrict
-- =====================================================================
-- IDARoblox / Core / Memoize
-- ---------------------------------------------------------------------
-- Two cache flavors plus a function-memoization helper.
--
--   * LRU(capacity, ttl?) — bounded least-recently-used. O(1) get/put
--     using a doubly-linked list of {key,value,prev,next,expiresAt}.
--     Optional per-cache TTL evicts on read.
--
--   * Weak(weakness)      — table-backed cache with weak keys or values.
--     Best for closure→metadata maps where you don't want to pin the
--     closure alive (Luau's GC will reap dead keys).
--
--   * memoize(fn, opts)    — wraps `fn` so repeated identical calls return
--     cached results. Keys are hashed from arguments. By default uses a
--     bounded LRU; pass `weak=true` to use a weak-keyed cache (only
--     useful when the first argument is a unique object reference).
-- =====================================================================

local Memoize = {}

-- ---------------------------------------------------------------------
-- LRU cache
-- ---------------------------------------------------------------------

local LRU = {}
LRU.__index = LRU
Memoize.LRU = LRU

function LRU.new(capacity: number, ttl: number?)
    if not capacity or capacity < 1 then
        error("LRU: capacity must be >= 1", 2)
    end
    local self = setmetatable({
        _cap   = capacity,
        _ttl   = ttl,                                              -- seconds; nil = no expiry
        _map   = {},                                               -- key → node
        _head  = nil,                                              -- most recently used
        _tail  = nil,                                              -- least recently used
        _size  = 0,
        _stats = {
            hits = 0, misses = 0, evictions = 0, expirations = 0,
            sets = 0, deletes = 0,
        },
    }, LRU)
    return self
end

local function lruUnlink(self, node)
    if node._prev then node._prev._next = node._next else self._head = node._next end
    if node._next then node._next._prev = node._prev else self._tail = node._prev end
    node._prev, node._next = nil, nil
end

local function lruLinkFront(self, node)
    node._prev, node._next = nil, self._head
    if self._head then self._head._prev = node end
    self._head = node
    if not self._tail then self._tail = node end
end

local function lruTouch(self, node)
    if self._head == node then return end
    lruUnlink(self, node)
    lruLinkFront(self, node)
end

local function lruEvictOne(self)
    local victim = self._tail
    if not victim then return end
    lruUnlink(self, victim)
    self._map[victim._key] = nil
    self._size -= 1
    self._stats.evictions += 1
end

function LRU:get(key)
    local node = self._map[key]
    if not node then
        self._stats.misses += 1
        return nil
    end
    if self._ttl and node._expiresAt and os.clock() >= node._expiresAt then
        lruUnlink(self, node)
        self._map[key] = nil
        self._size -= 1
        self._stats.expirations += 1
        self._stats.misses += 1
        return nil
    end
    lruTouch(self, node)
    self._stats.hits += 1
    return node._value
end

function LRU:peek(key)
    local node = self._map[key]
    if not node then return nil end
    if self._ttl and node._expiresAt and os.clock() >= node._expiresAt then return nil end
    return node._value
end

function LRU:set(key, value)
    self._stats.sets += 1
    local node = self._map[key]
    if node then
        node._value = value
        if self._ttl then node._expiresAt = os.clock() + self._ttl end
        lruTouch(self, node)
        return
    end
    if self._size >= self._cap then
        lruEvictOne(self)
    end
    node = {
        _key       = key,
        _value     = value,
        _prev      = nil,
        _next      = nil,
        _expiresAt = if self._ttl then os.clock() + self._ttl else nil,
    }
    self._map[key] = node
    lruLinkFront(self, node)
    self._size += 1
end

function LRU:delete(key)
    local node = self._map[key]
    if not node then return false end
    lruUnlink(self, node)
    self._map[key] = nil
    self._size -= 1
    self._stats.deletes += 1
    return true
end

function LRU:has(key): boolean
    local node = self._map[key]
    if not node then return false end
    if self._ttl and node._expiresAt and os.clock() >= node._expiresAt then return false end
    return true
end

function LRU:clear()
    self._map = {}
    self._head, self._tail = nil, nil
    self._size = 0
end

function LRU:size(): number return self._size end
function LRU:capacity(): number return self._cap end

function LRU:stats()
    local total = self._stats.hits + self._stats.misses
    local hitRate = if total > 0 then self._stats.hits / total else 0
    return {
        hits        = self._stats.hits,
        misses      = self._stats.misses,
        evictions   = self._stats.evictions,
        expirations = self._stats.expirations,
        sets        = self._stats.sets,
        deletes     = self._stats.deletes,
        size        = self._size,
        capacity    = self._cap,
        hitRate     = hitRate,
    }
end

function LRU:keysOrdered(): { any }
    -- Returns keys from most-recently-used to least-recently-used.
    local out = table.create(self._size)
    local n = self._head
    while n do
        out[#out + 1] = n._key
        n = n._next
    end
    return out
end

-- ---------------------------------------------------------------------
-- Weak-keyed cache
-- ---------------------------------------------------------------------

local Weak = {}
Weak.__index = Weak
Memoize.Weak = Weak

function Weak.new(mode: string?)
    -- mode: "k" (weak keys, default), "v" (weak values), "kv" (both)
    local m = mode or "k"
    if m ~= "k" and m ~= "v" and m ~= "kv" then
        error("Weak: invalid mode '" .. m .. "'", 2)
    end
    local self = setmetatable({
        _store = setmetatable({}, { __mode = m }),
        _stats = { hits = 0, misses = 0, sets = 0 },
    }, Weak)
    return self
end

function Weak:get(key)
    local v = self._store[key]
    if v == nil then self._stats.misses += 1 else self._stats.hits += 1 end
    return v
end

function Weak:set(key, value)
    self._store[key] = value
    self._stats.sets += 1
end

function Weak:has(key): boolean return self._store[key] ~= nil end

function Weak:delete(key)
    if self._store[key] == nil then return false end
    self._store[key] = nil
    return true
end

function Weak:clear() self._store = setmetatable({}, getmetatable(self._store)) end

function Weak:stats() return table.clone(self._stats) end

-- ---------------------------------------------------------------------
-- Argument key normalization
-- ---------------------------------------------------------------------
-- Builds a stable string key from a varargs tuple. Tables are addressed
-- by identity (tostring) — for value-equality keying use the explicit
-- `serializeKey` mode.

local function defaultKeyFromArgs(n: number, ...): string
    if n == 0 then return "()" end
    if n == 1 then
        local a = ...
        local t = type(a)
        if t == "string" then return "s:" .. a end
        if t == "number" then return "n:" .. tostring(a) end
        if t == "boolean" then return if a then "b:1" else "b:0" end
        return t .. ":" .. tostring(a)
    end
    local parts = table.create(n)
    for i = 1, n do
        local a = select(i, ...)
        local t = type(a)
        if t == "string" then parts[i] = "s:" .. a
        elseif t == "number" then parts[i] = "n:" .. tostring(a)
        elseif t == "boolean" then parts[i] = if a then "b:1" else "b:0"
        else parts[i] = t .. ":" .. tostring(a)
        end
    end
    return table.concat(parts, "\0")
end

Memoize.keyFromArgs = defaultKeyFromArgs

-- ---------------------------------------------------------------------
-- memoize(fn, opts) → wrapped function
-- ---------------------------------------------------------------------
-- opts: { capacity=128, ttl=nil, weak=false, keyFn=defaultKeyFromArgs,
--         arity=nil (use #args), errors="rethrow"|"cache" }

function Memoize.memoize(fn, opts)
    opts = opts or {}
    local capacity = opts.capacity or 128
    local ttl      = opts.ttl
    local weak     = opts.weak == true
    local keyFn    = opts.keyFn or defaultKeyFromArgs
    local errMode  = opts.errors or "rethrow"

    local cache = if weak then Weak.new("k") else LRU.new(capacity, ttl)

    local wrapper = function(...)
        local n = select("#", ...)
        local key = keyFn(n, ...)
        local hit = cache:get(key)
        if hit ~= nil then
            if type(hit) == "table" and hit._memoErr then
                if errMode == "rethrow" then error(hit._memoErr, 2) end
                return nil
            end
            if type(hit) == "table" and hit._memoMulti then
                return table.unpack(hit, 1, hit._memoMulti)
            end
            return hit
        end
        local results = table.pack(pcall(fn, ...))
        if results[1] then
            if results.n == 2 then
                cache:set(key, results[2])
                return results[2]
            else
                local boxed = table.move(results, 2, results.n, 1, table.create(results.n - 1))
                boxed._memoMulti = results.n - 1
                cache:set(key, boxed)
                return table.unpack(boxed, 1, boxed._memoMulti)
            end
        else
            if errMode == "cache" then
                cache:set(key, { _memoErr = results[2] })
            end
            error(results[2], 2)
        end
    end

    return wrapper, cache
end

return Memoize
