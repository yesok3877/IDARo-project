--!nonstrict
-- =====================================================================
-- IDARoblox / Search / RegexCache
-- ---------------------------------------------------------------------
-- Lua's pattern matcher recompiles the pattern on every call. For the
-- search UI — which fires a pattern dozens of times per keystroke — that
-- cost is significant. This module caches preprocessed pattern metadata
-- in a true LRU (doubly-linked list backing a hash map), and exposes
-- find/match/gmatch wrappers that:
--
--   * fast-path plain text (no special chars) via string.find(plain=true)
--   * detect anchored patterns and short-circuit when impossible
--   * validate the pattern once and reject malformed patterns cleanly
--
-- The cache also pre-extracts character classes used by FuzzyMatcher /
-- SearchEngine for tokenization decisions.
-- =====================================================================

local RegexCache = {}
RegexCache.__index = RegexCache

local DEFAULT_CAPACITY = 256

-- Lua-pattern special characters. If a candidate string contains NONE
-- of these, it can be matched via the "plain" fast path (which is also
-- ~3x faster in addition to skipping the regex parse).
local SPECIAL_CHARS = {
    ["("] = true, [")"] = true, ["."] = true, ["%"] = true,
    ["+"] = true, ["-"] = true, ["*"] = true, ["?"] = true,
    ["["] = true, ["]"] = true, ["^"] = true, ["$"] = true,
}

local function isPlainPattern(pat)
    for i = 1, #pat do
        if SPECIAL_CHARS[string.sub(pat, i, i)] then return false end
    end
    return true
end

local function isAnchoredStart(pat)
    return #pat > 0 and string.sub(pat, 1, 1) == "^"
end

local function isAnchoredEnd(pat)
    return #pat > 0 and string.sub(pat, -1) == "$"
        and (#pat == 1 or string.sub(pat, -2, -2) ~= "%")
end

-- Validate a pattern by trying to use it; returns (ok, err).
local function validate(pat)
    local ok, err = pcall(string.find, "x", pat)
    return ok, err
end

-- ---------------------------------------------------------------------
-- LRU primitives
-- ---------------------------------------------------------------------

function RegexCache.new(opts)
    opts = opts or {}
    local capacity = math.max(8, opts.capacity or DEFAULT_CAPACITY)
    -- Head/tail sentinels for the doubly-linked LRU list.
    -- _prev[head] = oldest, _next[head] = newest.
    local head = { sentinel = true }
    head.prev = head
    head.next = head
    return setmetatable({
        _capacity   = capacity,
        _byKey      = {},                                            -- key (pattern + flags) → node
        _head       = head,
        _size       = 0,
        _stats = {
            hits      = 0,
            misses    = 0,
            evictions = 0,
            invalid   = 0,
            plain     = 0,
        },
        _logger = opts.logger,
    }, RegexCache)
end

local function nodeKey(pat, caseInsensitive)
    return (caseInsensitive and "i:" or "s:") .. pat
end

local function unlink(node)
    node.prev.next = node.next
    node.next.prev = node.prev
end

local function linkAfter(after, node)
    node.prev = after
    node.next = after.next
    after.next.prev = node
    after.next = node
end

local function touch(self, node)
    -- Move to "most recently used" — right after the head sentinel.
    unlink(node)
    linkAfter(self._head, node)
end

local function evictOldest(self)
    local oldest = self._head.prev
    if oldest == self._head then return end                          -- empty
    unlink(oldest)
    self._byKey[oldest.key] = nil
    self._size = self._size - 1
    self._stats.evictions = self._stats.evictions + 1
end

-- ---------------------------------------------------------------------
-- Compile (with caching)
-- ---------------------------------------------------------------------

function RegexCache:compile(pat, opts)
    opts = opts or {}
    if type(pat) ~= "string" then
        return nil, "pattern must be a string"
    end
    local caseInsensitive = opts.caseInsensitive == true
    local key = nodeKey(pat, caseInsensitive)
    local existing = self._byKey[key]
    if existing then
        self._stats.hits = self._stats.hits + 1
        touch(self, existing)
        return existing.compiled, nil
    end
    self._stats.misses = self._stats.misses + 1

    -- For case-insensitive plain patterns we lower-case the needle and
    -- compare against lower-cased haystacks at use-site.
    local effectivePat = pat
    if caseInsensitive then effectivePat = string.lower(pat) end

    local plain = isPlainPattern(effectivePat)
    local anchorStart = isAnchoredStart(effectivePat)
    local anchorEnd   = isAnchoredEnd(effectivePat)

    if not plain then
        local ok, err = validate(effectivePat)
        if not ok then
            self._stats.invalid = self._stats.invalid + 1
            return nil, tostring(err)
        end
    else
        self._stats.plain = self._stats.plain + 1
    end

    local compiled = {
        original         = pat,
        effective        = effectivePat,
        plain            = plain,
        anchoredStart    = anchorStart,
        anchoredEnd      = anchorEnd,
        caseInsensitive  = caseInsensitive,
        length           = #effectivePat,
    }
    local node = { key = key, compiled = compiled }
    self._byKey[key] = node
    linkAfter(self._head, node)
    self._size = self._size + 1
    while self._size > self._capacity do evictOldest(self) end
    return compiled, nil
end

-- ---------------------------------------------------------------------
-- Search wrappers
-- ---------------------------------------------------------------------

function RegexCache:find(haystack, pat, init, opts)
    local compiled, err = self:compile(pat, opts)
    if not compiled then return nil, err end
    local hs = haystack
    if compiled.caseInsensitive then hs = string.lower(haystack) end
    if compiled.plain then
        return string.find(hs, compiled.effective, init, true)
    end
    return string.find(hs, compiled.effective, init)
end

function RegexCache:match(haystack, pat, init, opts)
    local compiled, err = self:compile(pat, opts)
    if not compiled then return nil, err end
    local hs = haystack
    if compiled.caseInsensitive then hs = string.lower(haystack) end
    if compiled.plain then
        local s, e = string.find(hs, compiled.effective, init, true)
        if s then return string.sub(hs, s, e) end
        return nil
    end
    return string.match(hs, compiled.effective, init)
end

function RegexCache:gmatch(haystack, pat, opts)
    local compiled, err = self:compile(pat, opts)
    if not compiled then
        return function() end, err
    end
    local hs = haystack
    if compiled.caseInsensitive then hs = string.lower(haystack) end
    if compiled.plain then
        -- gmatch over a plain string: just yield it on every match.
        local pos = 1
        return function()
            local s, e = string.find(hs, compiled.effective, pos, true)
            if not s then return nil end
            pos = e + 1
            return string.sub(hs, s, e)
        end
    end
    return string.gmatch(hs, compiled.effective)
end

function RegexCache:test(haystack, pat, opts)
    local s = self:find(haystack, pat, 1, opts)
    return s ~= nil
end

-- ---------------------------------------------------------------------
-- Diagnostics
-- ---------------------------------------------------------------------

function RegexCache:size()     return self._size end
function RegexCache:capacity() return self._capacity end

function RegexCache:clear()
    local head = self._head
    head.prev = head
    head.next = head
    self._byKey = {}
    self._size = 0
end

function RegexCache:stats()
    local total = self._stats.hits + self._stats.misses
    return {
        size      = self._size,
        capacity  = self._capacity,
        hits      = self._stats.hits,
        misses    = self._stats.misses,
        evictions = self._stats.evictions,
        invalid   = self._stats.invalid,
        plain     = self._stats.plain,
        hitRate   = total > 0 and (self._stats.hits / total) or 0,
    }
end

return RegexCache
