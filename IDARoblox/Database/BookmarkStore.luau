--!nonstrict
-- =====================================================================
-- IDARoblox / Database / BookmarkStore
-- ---------------------------------------------------------------------
-- Bookmark = a named, colored anchor at a specific (protoId, pc) site.
-- Used for "places to come back to" and as quick navigation targets.
-- All mutations are undoable via the injected HistoryStack.
-- =====================================================================

local BookmarkStore = {}
BookmarkStore.__index = BookmarkStore

BookmarkStore.Color = table.freeze({
    DEFAULT = "default",
    RED     = "red",
    GREEN   = "green",
    BLUE    = "blue",
    YELLOW  = "yellow",
    PURPLE  = "purple",
    ORANGE  = "orange",
})

local VALID_COLORS = {}
for _, c in BookmarkStore.Color do VALID_COLORS[c] = true end

local function isValidColor(c) return VALID_COLORS[c] == true end

local function addrKey(protoId, pc)
    return tostring(protoId) .. ":" .. tostring(pc)
end

-- ---------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------

function BookmarkStore.new(opts)
    opts = opts or {}
    return setmetatable({
        _byId       = {},
        _byAddress  = {},                                            -- "p:pc" → { bm, … }
        _byColor    = {},                                            -- color → { bm, … }
        _nextId     = 1,
        _history    = opts.history,
        _eventBus   = opts.eventBus,
        _logger     = opts.logger,
        _stats = {
            added   = 0,
            removed = 0,
            renamed = 0,
            recolored = 0,
        },
    }, BookmarkStore)
end

local function emit(self, evt, payload)
    if self._eventBus and type(self._eventBus.emit) == "function" then
        pcall(self._eventBus.emit, self._eventBus, evt, payload)
    end
end

-- ---------------------------------------------------------------------
-- Index maintenance
-- ---------------------------------------------------------------------

local function _insert(self, bm)
    self._byId[bm.id] = bm
    local k = addrKey(bm.protoId, bm.pc)
    local addrList = self._byAddress[k]
    if not addrList then addrList = {}; self._byAddress[k] = addrList end
    addrList[#addrList + 1] = bm
    local colorList = self._byColor[bm.color]
    if not colorList then colorList = {}; self._byColor[bm.color] = colorList end
    colorList[#colorList + 1] = bm
end

local function _remove(self, bm)
    self._byId[bm.id] = nil
    local k = addrKey(bm.protoId, bm.pc)
    local addrList = self._byAddress[k]
    if addrList then
        for i, b in addrList do
            if b == bm then table.remove(addrList, i); break end
        end
        if #addrList == 0 then self._byAddress[k] = nil end
    end
    local colorList = self._byColor[bm.color]
    if colorList then
        for i, b in colorList do
            if b == bm then table.remove(colorList, i); break end
        end
        if #colorList == 0 then self._byColor[bm.color] = nil end
    end
end

-- ---------------------------------------------------------------------
-- Add
-- ---------------------------------------------------------------------

function BookmarkStore:add(protoId, pc, label, color)
    if type(protoId) ~= "number" or type(pc) ~= "number" then
        error("BookmarkStore:add requires (protoId, pc) numerics", 2)
    end
    color = color or BookmarkStore.Color.DEFAULT
    if not isValidColor(color) then
        error("BookmarkStore:add — invalid color " .. tostring(color), 2)
    end
    local bm = {
        id        = self._nextId,
        protoId   = protoId,
        pc        = pc,
        label     = tostring(label or ""),
        color     = color,
        createdAt = os.time(),
    }
    self._nextId = self._nextId + 1
    local s = self
    if self._history and not self._history:isSuppressed() then
        self._history:execute({
            kind  = "bookmark.add",
            label = string.format("add bookmark '%s'", bm.label),
            apply = function()
                _insert(s, bm)
                s._stats.added = s._stats.added + 1
                emit(s, "bookmark.added", bm)
            end,
            revert = function()
                _remove(s, bm)
                emit(s, "bookmark.removed", bm)
            end,
        })
    else
        _insert(self, bm)
        self._stats.added = self._stats.added + 1
        emit(self, "bookmark.added", bm)
    end
    return bm
end

-- ---------------------------------------------------------------------
-- Remove
-- ---------------------------------------------------------------------

function BookmarkStore:remove(id)
    local bm = self._byId[id]
    if not bm then return false, "no such bookmark" end
    local s = self
    if self._history and not self._history:isSuppressed() then
        self._history:execute({
            kind  = "bookmark.remove",
            label = string.format("remove bookmark '%s'", bm.label),
            apply = function()
                _remove(s, bm)
                s._stats.removed = s._stats.removed + 1
                emit(s, "bookmark.removed", bm)
            end,
            revert = function()
                _insert(s, bm)
                emit(s, "bookmark.added", bm)
            end,
        })
    else
        _remove(self, bm)
        self._stats.removed = self._stats.removed + 1
        emit(self, "bookmark.removed", bm)
    end
    return true
end

-- ---------------------------------------------------------------------
-- Toggle (add if absent at address, remove the first present)
-- ---------------------------------------------------------------------

function BookmarkStore:toggle(protoId, pc, label, color)
    local existing = self._byAddress[addrKey(protoId, pc)]
    if existing and existing[1] then
        local id = existing[1].id
        self:remove(id)
        return false, id                                             -- removed
    else
        local bm = self:add(protoId, pc, label, color)
        return true, bm.id                                           -- added
    end
end

-- ---------------------------------------------------------------------
-- Rename
-- ---------------------------------------------------------------------

function BookmarkStore:rename(id, newLabel)
    local bm = self._byId[id]
    if not bm then return false, "no such bookmark" end
    local nextLabel = tostring(newLabel or "")
    if bm.label == nextLabel then return true end
    local oldLabel = bm.label
    local s = self
    if self._history and not self._history:isSuppressed() then
        self._history:execute({
            kind        = "bookmark.rename",
            label       = string.format("rename bookmark → '%s'", nextLabel),
            coalesceKey = "bm-rename:" .. tostring(id),
            apply  = function() bm.label = nextLabel
                s._stats.renamed = s._stats.renamed + 1
                emit(s, "bookmark.updated", bm) end,
            revert = function() bm.label = oldLabel
                emit(s, "bookmark.updated", bm) end,
        })
    else
        bm.label = nextLabel
        self._stats.renamed = self._stats.renamed + 1
        emit(self, "bookmark.updated", bm)
    end
    return true
end

-- ---------------------------------------------------------------------
-- Recolor
-- ---------------------------------------------------------------------

function BookmarkStore:recolor(id, newColor)
    if not isValidColor(newColor) then
        return false, "invalid color " .. tostring(newColor)
    end
    local bm = self._byId[id]
    if not bm then return false, "no such bookmark" end
    if bm.color == newColor then return true end
    local oldColor = bm.color
    local s = self
    local function doSet(c)
        local oldList = s._byColor[bm.color]
        if oldList then
            for i, b in oldList do
                if b == bm then table.remove(oldList, i); break end
            end
            if #oldList == 0 then s._byColor[bm.color] = nil end
        end
        bm.color = c
        local newList = s._byColor[c]
        if not newList then newList = {}; s._byColor[c] = newList end
        newList[#newList + 1] = bm
        s._stats.recolored = s._stats.recolored + 1
        emit(s, "bookmark.updated", bm)
    end
    if self._history and not self._history:isSuppressed() then
        self._history:execute({
            kind  = "bookmark.recolor",
            label = string.format("recolor bookmark → %s", newColor),
            apply  = function() doSet(newColor) end,
            revert = function() doSet(oldColor) end,
        })
    else
        doSet(newColor)
    end
    return true
end

-- ---------------------------------------------------------------------
-- Queries
-- ---------------------------------------------------------------------

function BookmarkStore:byId(id) return self._byId[id] end

function BookmarkStore:byAddress(protoId, pc)
    local list = self._byAddress[addrKey(protoId, pc)]
    if not list then return {} end
    local out = table.create(#list)
    for i, b in list do out[i] = b end
    return out
end

function BookmarkStore:byColor(color)
    local list = self._byColor[color]
    if not list then return {} end
    local out = table.create(#list)
    for i, b in list do out[i] = b end
    return out
end

function BookmarkStore:byProto(protoId)
    local out = {}
    for _, bm in self._byId do
        if bm.protoId == protoId then out[#out + 1] = bm end
    end
    table.sort(out, function(a, b)
        if a.pc == b.pc then return a.id < b.id end
        return a.pc < b.pc
    end)
    return out
end

function BookmarkStore:all()
    local out = {}
    for _, bm in self._byId do out[#out + 1] = bm end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

function BookmarkStore:hasAt(protoId, pc)
    local list = self._byAddress[addrKey(protoId, pc)]
    return list ~= nil and #list > 0
end

function BookmarkStore:count()
    local n = 0
    for _ in self._byId do n = n + 1 end
    return n
end

-- ---------------------------------------------------------------------
-- Snapshot
-- ---------------------------------------------------------------------

function BookmarkStore:exportSnapshot()
    local bookmarks = {}
    for _, b in self._byId do
        bookmarks[#bookmarks + 1] = {
            id        = b.id,
            protoId   = b.protoId,
            pc        = b.pc,
            label     = b.label,
            color     = b.color,
            createdAt = b.createdAt,
        }
    end
    table.sort(bookmarks, function(a, b) return a.id < b.id end)
    return { bookmarks = bookmarks, nextId = self._nextId }
end

function BookmarkStore:importSnapshot(snap)
    self._byId = {}; self._byAddress = {}; self._byColor = {}
    self._nextId = (snap and snap.nextId) or 1
    if not snap or not snap.bookmarks then return end
    for _, b in snap.bookmarks do
        local bm = {
            id        = b.id,
            protoId   = b.protoId,
            pc        = b.pc,
            label     = b.label or "",
            color     = isValidColor(b.color) and b.color or BookmarkStore.Color.DEFAULT,
            createdAt = b.createdAt or os.time(),
        }
        _insert(self, bm)
    end
end

function BookmarkStore:stats()
    return {
        total      = self:count(),
        byColor    = (function()
            local out = {}
            for c, list in self._byColor do out[c] = #list end
            return out
        end)(),
        added      = self._stats.added,
        removed    = self._stats.removed,
        renamed    = self._stats.renamed,
        recolored  = self._stats.recolored,
    }
end

return BookmarkStore
