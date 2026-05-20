--!nonstrict
-- =====================================================================
-- IDARoblox / Database / SymbolTable
-- ---------------------------------------------------------------------
-- First-class store for every named entity in a project:
--
--   proto       — function prototype (per-protoId)
--   register    — register at a specific (protoId, pc) site
--   upvalue     — upvalue at (protoId, upvalIdx)
--   global      — globally-resolved name (e.g. "warn", "print")
--   field       — field accessed via GETTABLEKS / SETTABLEKS
--   method      — method invoked via NAMECALL
--   constant    — entry in a proto's k-table at (protoId, kidx)
--   label       — user-defined named PC (anchor for navigation)
--   plugin      — symbols defined by plugins (free-form key)
--
-- Each symbol carries: id (auto), kind, key (canonical identifier within
-- kind), name (user-facing label), type (string tag), flags (bitfield),
-- meta (arbitrary table for plugin-attached data), createdAt timestamp.
--
-- Three indices:
--   byId   : id → symbol            (O(1) lookup)
--   byKey  : "<kind>:<key>" → sym   (O(1) "is there one here?" lookup)
--   byName : name → { sym, sym, … } (O(1) "what shares this name?")
--
-- All mutations (rename, setType, setFlag, delete) route through the
-- HistoryStack injected at construction so they are undoable.
-- =====================================================================

local SymbolTable = {}
SymbolTable.__index = SymbolTable

SymbolTable.Kind = table.freeze({
    PROTO    = "proto",
    REGISTER = "register",
    UPVALUE  = "upvalue",
    GLOBAL   = "global",
    FIELD    = "field",
    METHOD   = "method",
    CONSTANT = "constant",
    LABEL    = "label",
    PLUGIN   = "plugin",
})

-- Flags as a bitfield. Combine via bit32.bor.
SymbolTable.Flags = table.freeze({
    NONE         = 0x0000,
    USER_NAMED   = 0x0001,
    LIBRARY      = 0x0002,
    IMPORT       = 0x0004,
    ARGUMENT     = 0x0008,
    UPVALUE      = 0x0010,
    ANON         = 0x0020,
    ENTRY        = 0x0040,
    DEAD         = 0x0080,
    HOOK_TARGET  = 0x0100,
    OBFUSCATED   = 0x0200,
    PINNED       = 0x0400,
})

-- ---------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------

function SymbolTable.new(opts)
    opts = opts or {}
    return setmetatable({
        _byId      = {},
        _byKey     = {},
        _byName    = {},
        _byKind    = {},                                             -- kind → { sym, sym, … }
        _nextId    = 1,
        _history   = opts.history,
        _eventBus  = opts.eventBus,
        _logger    = opts.logger,
        _stats = {
            created    = 0,
            renamed    = 0,
            retyped    = 0,
            flagged    = 0,
            deleted    = 0,
        },
    }, SymbolTable)
end

local function emit(self, evt, payload)
    if self._eventBus and type(self._eventBus.emit) == "function" then
        pcall(self._eventBus.emit, self._eventBus, evt, payload)
    end
end

local function fullKey(kind, key)
    return tostring(kind) .. ":" .. tostring(key)
end

-- ---------------------------------------------------------------------
-- Index maintenance helpers
-- ---------------------------------------------------------------------

local function addToNameIndex(self, name, sym)
    if name == nil or name == "" then return end
    local list = self._byName[name]
    if not list then list = {}; self._byName[name] = list end
    list[#list + 1] = sym
end

local function removeFromNameIndex(self, name, sym)
    if name == nil or name == "" then return end
    local list = self._byName[name]
    if not list then return end
    for i, s in list do
        if s == sym then table.remove(list, i); break end
    end
    if #list == 0 then self._byName[name] = nil end
end

local function addToKindIndex(self, kind, sym)
    local list = self._byKind[kind]
    if not list then list = {}; self._byKind[kind] = list end
    list[#list + 1] = sym
end

local function removeFromKindIndex(self, kind, sym)
    local list = self._byKind[kind]
    if not list then return end
    for i, s in list do
        if s == sym then table.remove(list, i); break end
    end
    if #list == 0 then self._byKind[kind] = nil end
end

-- ---------------------------------------------------------------------
-- Direct mutation primitives (used by apply/revert closures)
-- ---------------------------------------------------------------------

local function _insertSym(self, sym)
    self._byId[sym.id] = sym
    self._byKey[fullKey(sym.kind, sym.key)] = sym
    addToNameIndex(self, sym.name, sym)
    addToKindIndex(self, sym.kind, sym)
end

local function _removeSym(self, sym)
    self._byId[sym.id] = nil
    self._byKey[fullKey(sym.kind, sym.key)] = nil
    removeFromNameIndex(self, sym.name, sym)
    removeFromKindIndex(self, sym.kind, sym)
end

-- ---------------------------------------------------------------------
-- Create
-- ---------------------------------------------------------------------

function SymbolTable:create(kind, key, name, opts)
    if not kind or not key then
        error("SymbolTable:create requires (kind, key)", 2)
    end
    opts = opts or {}
    local existing = self._byKey[fullKey(kind, key)]
    if existing then
        -- Already created — return existing; caller may want to rename.
        return existing, true
    end
    local sym = {
        id        = self._nextId,
        kind      = kind,
        key       = key,
        name      = name,
        type      = opts.type,
        flags     = opts.flags or 0,
        meta      = opts.meta,
        createdAt = os.clock(),
    }
    self._nextId = self._nextId + 1

    if self._history and not self._history:isSuppressed() then
        local s = self
        self._history:execute({
            kind  = "symbol.create",
            label = string.format("create %s %s",
                kind, name or tostring(key)),
            apply = function()
                _insertSym(s, sym)
                s._stats.created = s._stats.created + 1
                emit(s, "symbol.created", sym)
            end,
            revert = function()
                _removeSym(s, sym)
                emit(s, "symbol.deleted", sym)
            end,
        })
    else
        _insertSym(self, sym)
        self._stats.created = self._stats.created + 1
        emit(self, "symbol.created", sym)
    end
    return sym, false
end

-- ---------------------------------------------------------------------
-- Rename
-- ---------------------------------------------------------------------

function SymbolTable:rename(symId, newName)
    local sym = self._byId[symId]
    if not sym then return false, "no such symbol id " .. tostring(symId) end
    if sym.name == newName then return true end
    local oldName = sym.name
    local s = self

    local function doRename(target)
        removeFromNameIndex(s, sym.name, sym)
        sym.name = target
        addToNameIndex(s, sym.name, sym)
        s._stats.renamed = s._stats.renamed + 1
        emit(s, "symbol.renamed", { sym = sym, old = oldName, new = newName })
    end

    if self._history and not self._history:isSuppressed() then
        self._history:execute({
            kind        = "symbol.rename",
            label       = string.format("rename %s → %s",
                tostring(oldName or "?"), tostring(newName or "?")),
            coalesceKey = "rename:" .. tostring(symId),
            apply  = function() doRename(newName) end,
            revert = function() doRename(oldName) end,
        })
    else
        doRename(newName)
    end
    return true
end

-- ---------------------------------------------------------------------
-- setType
-- ---------------------------------------------------------------------

function SymbolTable:setType(symId, newType)
    local sym = self._byId[symId]
    if not sym then return false, "no such symbol" end
    if sym.type == newType then return true end
    local oldType = sym.type
    local s = self
    local function doSet(t)
        sym.type = t
        s._stats.retyped = s._stats.retyped + 1
        emit(s, "symbol.updated", sym)
    end
    if self._history and not self._history:isSuppressed() then
        self._history:execute({
            kind  = "symbol.type",
            label = string.format("type %s: %s → %s",
                sym.name or "?", tostring(oldType), tostring(newType)),
            apply  = function() doSet(newType) end,
            revert = function() doSet(oldType) end,
        })
    else
        doSet(newType)
    end
    return true
end

-- ---------------------------------------------------------------------
-- Flags
-- ---------------------------------------------------------------------

function SymbolTable:setFlag(symId, flag, value)
    local sym = self._byId[symId]
    if not sym then return false, "no such symbol" end
    local old = sym.flags or 0
    local new = value
        and bit32.bor(old, flag)
        or  bit32.band(old, bit32.bnot(flag))
    if new == old then return true end
    local s = self
    local function doSet(v)
        sym.flags = v
        s._stats.flagged = s._stats.flagged + 1
        emit(s, "symbol.updated", sym)
    end
    if self._history and not self._history:isSuppressed() then
        self._history:execute({
            kind  = "symbol.flag",
            label = string.format("flag %s", sym.name or sym.key),
            apply  = function() doSet(new) end,
            revert = function() doSet(old) end,
        })
    else
        doSet(new)
    end
    return true
end

function SymbolTable:hasFlag(symOrId, flag)
    local sym = type(symOrId) == "number" and self._byId[symOrId] or symOrId
    if type(sym) ~= "table" then return false end
    return bit32.band(sym.flags or 0, flag) ~= 0
end

-- ---------------------------------------------------------------------
-- Meta (arbitrary attached payload)
-- ---------------------------------------------------------------------

function SymbolTable:setMeta(symId, newMeta)
    local sym = self._byId[symId]
    if not sym then return false end
    local oldMeta = sym.meta
    local s = self
    if self._history and not self._history:isSuppressed() then
        self._history:execute({
            kind  = "symbol.meta",
            label = string.format("set meta %s", sym.name or sym.key),
            apply  = function() sym.meta = newMeta; emit(s, "symbol.updated", sym) end,
            revert = function() sym.meta = oldMeta; emit(s, "symbol.updated", sym) end,
        })
    else
        sym.meta = newMeta
        emit(self, "symbol.updated", sym)
    end
    return true
end

-- ---------------------------------------------------------------------
-- Delete
-- ---------------------------------------------------------------------

function SymbolTable:delete(symId)
    local sym = self._byId[symId]
    if not sym then return false, "no such symbol" end
    local s = self
    if self._history and not self._history:isSuppressed() then
        self._history:execute({
            kind  = "symbol.delete",
            label = string.format("delete %s %s", sym.kind, sym.name or sym.key),
            apply = function()
                _removeSym(s, sym)
                s._stats.deleted = s._stats.deleted + 1
                emit(s, "symbol.deleted", sym)
            end,
            revert = function()
                _insertSym(s, sym)
                emit(s, "symbol.created", sym)
            end,
        })
    else
        _removeSym(self, sym)
        self._stats.deleted = self._stats.deleted + 1
        emit(self, "symbol.deleted", sym)
    end
    return true
end

-- ---------------------------------------------------------------------
-- Queries
-- ---------------------------------------------------------------------

function SymbolTable:byId(id) return self._byId[id] end

function SymbolTable:byKey(kind, key)
    return self._byKey[fullKey(kind, key)]
end

function SymbolTable:byName(name)
    local list = self._byName[name]
    if not list then return {} end
    local out = table.create(#list)
    for i, s in list do out[i] = s end
    return out
end

function SymbolTable:findByPattern(pattern, opts)
    opts = opts or {}
    local caseInsensitive = opts.caseInsensitive ~= false
    local kindFilter      = opts.kind
    local out = {}
    if pattern == nil or pattern == "" then
        for _, sym in self._byId do
            if not kindFilter or sym.kind == kindFilter then out[#out + 1] = sym end
        end
        return out
    end
    local needle = caseInsensitive and string.lower(pattern) or pattern
    for name, list in self._byName do
        local hay = caseInsensitive and string.lower(name) or name
        if string.find(hay, needle, 1, true) then
            for _, sym in list do
                if not kindFilter or sym.kind == kindFilter then out[#out + 1] = sym end
            end
        end
    end
    return out
end

function SymbolTable:allOfKind(kind)
    local src = self._byKind[kind]
    if not src then return {} end
    local out = table.create(#src)
    for i, s in src do out[i] = s end
    return out
end

function SymbolTable:all()
    local out = {}
    for _, sym in self._byId do out[#out + 1] = sym end
    return out
end

function SymbolTable:count()
    local n = 0
    for _ in self._byId do n = n + 1 end
    return n
end

-- ---------------------------------------------------------------------
-- Bulk operations (used by ProjectDB on bytecode attach)
-- ---------------------------------------------------------------------

-- Create-or-update: if a symbol exists at (kind, key), update its name
-- (without history) only if it doesn't already have USER_NAMED set.
function SymbolTable:upsert(kind, key, name, opts)
    local existing = self._byKey[fullKey(kind, key)]
    if existing then
        if name and not self:hasFlag(existing, SymbolTable.Flags.USER_NAMED) then
            if existing.name ~= name then
                removeFromNameIndex(self, existing.name, existing)
                existing.name = name
                addToNameIndex(self, existing.name, existing)
                emit(self, "symbol.renamed",
                    { sym = existing, old = existing.name, new = name })
            end
        end
        if opts and opts.flags then
            existing.flags = bit32.bor(existing.flags or 0, opts.flags)
            emit(self, "symbol.updated", existing)
        end
        return existing, true
    end
    return self:create(kind, key, name, opts), false
end

-- ---------------------------------------------------------------------
-- Snapshot (for serialization)
-- ---------------------------------------------------------------------

function SymbolTable:exportSnapshot()
    local symbols = {}
    for id, sym in self._byId do
        symbols[#symbols + 1] = {
            id     = id,
            kind   = sym.kind,
            key    = sym.key,
            name   = sym.name,
            type   = sym.type,
            flags  = sym.flags,
            meta   = sym.meta,
        }
    end
    -- Stable ordering by id
    table.sort(symbols, function(a, b) return a.id < b.id end)
    return { symbols = symbols, nextId = self._nextId }
end

function SymbolTable:importSnapshot(snap)
    self._byId = {}; self._byKey = {}; self._byName = {}; self._byKind = {}
    self._nextId = (snap and snap.nextId) or 1
    if not snap or not snap.symbols then return end
    for _, s in snap.symbols do
        local sym = {
            id        = s.id,
            kind      = s.kind,
            key       = s.key,
            name      = s.name,
            type      = s.type,
            flags     = s.flags or 0,
            meta      = s.meta,
            createdAt = os.clock(),
        }
        _insertSym(self, sym)
    end
end

function SymbolTable:stats()
    return {
        total   = self:count(),
        byKind  = (function()
            local out = {}
            for k, list in self._byKind do out[k] = #list end
            return out
        end)(),
        created = self._stats.created,
        renamed = self._stats.renamed,
        retyped = self._stats.retyped,
        flagged = self._stats.flagged,
        deleted = self._stats.deleted,
    }
end

return SymbolTable
