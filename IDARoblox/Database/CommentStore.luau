--!nonstrict
-- =====================================================================
-- IDARoblox / Database / CommentStore
-- ---------------------------------------------------------------------
-- IDA-style address-addressable comments. Each comment is anchored to a
-- (protoId, pc) site and has one of four kinds:
--
--   anterior    — line(s) shown ABOVE the instruction (block header)
--   regular     — comment appended INLINE to the instruction
--   posterior   — line(s) shown BELOW the instruction (block footer)
--   repeatable  — inline + propagated to every cross-reference site
--
-- All mutations route through the HistoryStack injected at construction
-- so add/update/remove are undoable. Update coalesces by per-comment id
-- so rapid keystrokes collapse to one undo entry.
-- =====================================================================

local CommentStore = {}
CommentStore.__index = CommentStore

CommentStore.Kind = table.freeze({
    ANTERIOR   = "anterior",
    REGULAR    = "regular",
    POSTERIOR  = "posterior",
    REPEATABLE = "repeatable",
})

local function isValidKind(k)
    return k == CommentStore.Kind.ANTERIOR
        or k == CommentStore.Kind.REGULAR
        or k == CommentStore.Kind.POSTERIOR
        or k == CommentStore.Kind.REPEATABLE
end

local function addrKey(protoId, pc)
    return tostring(protoId) .. ":" .. tostring(pc)
end

-- ---------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------

function CommentStore.new(opts)
    opts = opts or {}
    return setmetatable({
        _byId         = {},
        _byAddress    = {},                                          -- "p:pc" → { Comment, … }
        _byKind       = {},                                          -- kind → { Comment, … }
        _nextId       = 1,
        _history      = opts.history,
        _eventBus     = opts.eventBus,
        _logger       = opts.logger,
        _defaultAuthor = opts.author or "user",
        _stats = {
            added   = 0,
            updated = 0,
            removed = 0,
        },
    }, CommentStore)
end

local function emit(self, evt, payload)
    if self._eventBus and type(self._eventBus.emit) == "function" then
        pcall(self._eventBus.emit, self._eventBus, evt, payload)
    end
end

-- ---------------------------------------------------------------------
-- Index maintenance
-- ---------------------------------------------------------------------

local function _insert(self, comment)
    self._byId[comment.id] = comment
    local k = addrKey(comment.protoId, comment.pc)
    local addrList = self._byAddress[k]
    if not addrList then addrList = {}; self._byAddress[k] = addrList end
    addrList[#addrList + 1] = comment
    local kindList = self._byKind[comment.kind]
    if not kindList then kindList = {}; self._byKind[comment.kind] = kindList end
    kindList[#kindList + 1] = comment
end

local function _remove(self, comment)
    self._byId[comment.id] = nil
    local k = addrKey(comment.protoId, comment.pc)
    local addrList = self._byAddress[k]
    if addrList then
        for i, c in addrList do
            if c == comment then table.remove(addrList, i); break end
        end
        if #addrList == 0 then self._byAddress[k] = nil end
    end
    local kindList = self._byKind[comment.kind]
    if kindList then
        for i, c in kindList do
            if c == comment then table.remove(kindList, i); break end
        end
        if #kindList == 0 then self._byKind[comment.kind] = nil end
    end
end

-- ---------------------------------------------------------------------
-- Add
-- ---------------------------------------------------------------------

function CommentStore:add(protoId, pc, text, opts)
    if type(protoId) ~= "number" or type(pc) ~= "number" then
        error("CommentStore:add requires (protoId, pc) numerics", 2)
    end
    opts = opts or {}
    local kind = opts.kind or CommentStore.Kind.REGULAR
    if not isValidKind(kind) then
        error("CommentStore:add — invalid kind " .. tostring(kind), 2)
    end
    local comment = {
        id        = self._nextId,
        protoId   = protoId,
        pc        = pc,
        text      = tostring(text or ""),
        kind      = kind,
        author    = opts.author or self._defaultAuthor,
        timestamp = os.time(),
    }
    self._nextId = self._nextId + 1
    local s = self

    if self._history and not self._history:isSuppressed() then
        self._history:execute({
            kind  = "comment.add",
            label = string.format("add %s comment", kind),
            apply = function()
                _insert(s, comment)
                s._stats.added = s._stats.added + 1
                emit(s, "comment.added", comment)
            end,
            revert = function()
                _remove(s, comment)
                emit(s, "comment.removed", comment)
            end,
        })
    else
        _insert(self, comment)
        self._stats.added = self._stats.added + 1
        emit(self, "comment.added", comment)
    end
    return comment
end

-- ---------------------------------------------------------------------
-- Update
-- ---------------------------------------------------------------------

function CommentStore:update(id, newText)
    local comment = self._byId[id]
    if not comment then return false, "no such comment" end
    local nextText = tostring(newText or "")
    if comment.text == nextText then return true end
    local oldText = comment.text
    local s = self
    local function doSet(t)
        comment.text = t
        s._stats.updated = s._stats.updated + 1
        emit(s, "comment.updated", comment)
    end
    if self._history and not self._history:isSuppressed() then
        self._history:execute({
            kind        = "comment.update",
            label       = "edit comment",
            coalesceKey = "comment-edit:" .. tostring(id),
            apply  = function() doSet(nextText) end,
            revert = function() doSet(oldText) end,
        })
    else
        doSet(nextText)
    end
    return true
end

-- ---------------------------------------------------------------------
-- Change kind (e.g. promote regular → repeatable)
-- ---------------------------------------------------------------------

function CommentStore:setKind(id, newKind)
    if not isValidKind(newKind) then
        return false, "invalid kind " .. tostring(newKind)
    end
    local comment = self._byId[id]
    if not comment then return false, "no such comment" end
    if comment.kind == newKind then return true end
    local oldKind = comment.kind
    local s = self
    local function doSet(k)
        -- Re-index by kind
        local oldList = s._byKind[comment.kind]
        if oldList then
            for i, c in oldList do
                if c == comment then table.remove(oldList, i); break end
            end
            if #oldList == 0 then s._byKind[comment.kind] = nil end
        end
        comment.kind = k
        local newList = s._byKind[k]
        if not newList then newList = {}; s._byKind[k] = newList end
        newList[#newList + 1] = comment
        emit(s, "comment.updated", comment)
    end
    if self._history and not self._history:isSuppressed() then
        self._history:execute({
            kind  = "comment.kind",
            label = string.format("change comment kind %s → %s", oldKind, newKind),
            apply  = function() doSet(newKind) end,
            revert = function() doSet(oldKind) end,
        })
    else
        doSet(newKind)
    end
    return true
end

-- ---------------------------------------------------------------------
-- Remove
-- ---------------------------------------------------------------------

function CommentStore:remove(id)
    local comment = self._byId[id]
    if not comment then return false, "no such comment" end
    local s = self
    if self._history and not self._history:isSuppressed() then
        self._history:execute({
            kind  = "comment.remove",
            label = "remove comment",
            apply = function()
                _remove(s, comment)
                s._stats.removed = s._stats.removed + 1
                emit(s, "comment.removed", comment)
            end,
            revert = function()
                _insert(s, comment)
                emit(s, "comment.added", comment)
            end,
        })
    else
        _remove(self, comment)
        self._stats.removed = self._stats.removed + 1
        emit(self, "comment.removed", comment)
    end
    return true
end

-- ---------------------------------------------------------------------
-- Queries
-- ---------------------------------------------------------------------

function CommentStore:byId(id) return self._byId[id] end

function CommentStore:byAddress(protoId, pc)
    local list = self._byAddress[addrKey(protoId, pc)]
    if not list then return {} end
    local out = table.create(#list)
    for i, c in list do out[i] = c end
    return out
end

function CommentStore:byKind(kind)
    local list = self._byKind[kind]
    if not list then return {} end
    local out = table.create(#list)
    for i, c in list do out[i] = c end
    return out
end

function CommentStore:byProto(protoId)
    local out = {}
    for _, comment in self._byId do
        if comment.protoId == protoId then out[#out + 1] = comment end
    end
    table.sort(out, function(a, b)
        if a.pc == b.pc then return a.id < b.id end
        return a.pc < b.pc
    end)
    return out
end

function CommentStore:all()
    local out = {}
    for _, c in self._byId do out[#out + 1] = c end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

function CommentStore:count()
    local n = 0
    for _ in self._byId do n = n + 1 end
    return n
end

-- ---------------------------------------------------------------------
-- Search across comment text
-- ---------------------------------------------------------------------

function CommentStore:findByText(needle, opts)
    opts = opts or {}
    if needle == nil or needle == "" then return {} end
    local caseInsensitive = opts.caseInsensitive ~= false
    local query = caseInsensitive and string.lower(needle) or needle
    local kindFilter = opts.kind
    local out = {}
    for _, c in self._byId do
        if not kindFilter or c.kind == kindFilter then
            local hay = caseInsensitive and string.lower(c.text) or c.text
            if string.find(hay, query, 1, true) then out[#out + 1] = c end
        end
    end
    return out
end

-- ---------------------------------------------------------------------
-- Snapshot
-- ---------------------------------------------------------------------

function CommentStore:exportSnapshot()
    local comments = {}
    for _, c in self._byId do
        comments[#comments + 1] = {
            id        = c.id,
            protoId   = c.protoId,
            pc        = c.pc,
            text      = c.text,
            kind      = c.kind,
            author    = c.author,
            timestamp = c.timestamp,
        }
    end
    table.sort(comments, function(a, b) return a.id < b.id end)
    return { comments = comments, nextId = self._nextId }
end

function CommentStore:importSnapshot(snap)
    self._byId = {}; self._byAddress = {}; self._byKind = {}
    self._nextId = (snap and snap.nextId) or 1
    if not snap or not snap.comments then return end
    for _, c in snap.comments do
        local comment = {
            id        = c.id,
            protoId   = c.protoId,
            pc        = c.pc,
            text      = c.text or "",
            kind      = isValidKind(c.kind) and c.kind or CommentStore.Kind.REGULAR,
            author    = c.author or self._defaultAuthor,
            timestamp = c.timestamp or os.time(),
        }
        _insert(self, comment)
    end
end

function CommentStore:stats()
    return {
        total    = self:count(),
        byKind   = (function()
            local out = {}
            for k, list in self._byKind do out[k] = #list end
            return out
        end)(),
        added    = self._stats.added,
        updated  = self._stats.updated,
        removed  = self._stats.removed,
    }
end

return CommentStore
