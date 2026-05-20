--!nonstrict
-- =====================================================================
-- IDARoblox / Database / ProjectDB
-- ---------------------------------------------------------------------
-- Central project state. The IDA "IDB" equivalent: every named entity,
-- comment, bookmark, view-position, and the loaded bytecode all live
-- under this single object so they can be saved/loaded as one unit.
--
-- Owned services
--   :history()    HistoryStack
--   :symbols()    SymbolTable
--   :comments()   CommentStore
--   :bookmarks()  BookmarkStore
--
-- Auto-population
--   When attachBytecode(parsed, rawBytes) is called, ProjectDB creates a
--   `proto`-kind symbol for every proto in the bytecode. The main proto
--   gets the ENTRY flag; any proto whose debugName is non-empty also gets
--   USER_NAMED so subsequent loads won't clobber user renames. These
--   bulk creates are wrapped in a single transaction so they appear as
--   one undo unit ("attach bytecode").
--
-- Persistence
--   :serialize()   → binary string via SerializeBinary
--   :deserialize() ← binary string + parser ref; rebuilds every store
--   :exportSnapshot() / :importSnapshot() for in-memory use
--
-- Events emitted on the shared eventBus:
--   project.bytecodeChanged, project.viewStateChanged,
--   project.loaded, project.cleared
--   plus the bubbled-up store events:
--     symbol.created/renamed/updated/deleted
--     comment.added/updated/removed
--     bookmark.added/updated/removed
--     history.executed/undone/redone
-- =====================================================================

local HistoryStack    = _G.IDARo.require("Database.HistoryStack")
local SymbolTable     = _G.IDARo.require("Database.SymbolTable")
local CommentStore    = _G.IDARo.require("Database.CommentStore")
local BookmarkStore   = _G.IDARo.require("Database.BookmarkStore")
local SerializeBinary = _G.IDARo.require("Database.SerializeBinary")

local ProjectDB = {}
ProjectDB.__index = ProjectDB

local PROJECT_VERSION = 1                                            -- snapshot schema version

-- ---------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------

function ProjectDB.new(opts)
    opts = opts or {}
    local history = HistoryStack.new({
        maxDepth = opts.historyDepth or 500,
        eventBus = opts.eventBus,
        logger   = opts.logger,
    })
    local self = setmetatable({
        _logger        = opts.logger,
        _eventBus      = opts.eventBus,
        _history       = history,
        _symbols       = SymbolTable.new({ history = history, eventBus = opts.eventBus, logger = opts.logger }),
        _comments      = CommentStore.new({ history = history, eventBus = opts.eventBus, logger = opts.logger,
                                            author = opts.author }),
        _bookmarks     = BookmarkStore.new({ history = history, eventBus = opts.eventBus, logger = opts.logger }),
        _bytecode      = nil,
        _bytecodeBytes = nil,
        _viewState = {
            viewMode        = "disasm",
            bottomTab       = "output",
            selectedProtoId = nil,
            selectedPc      = nil,
            selectedBlockId = nil,
            selectedDecLine = nil,
            treeRatio       = nil,
            outputRatio     = nil,
            xrefQuery       = nil,
        },
        _meta = {
            created     = os.time(),
            modified    = os.time(),
            name        = opts.name or "untitled",
            executor    = opts.executor,
            sourceLabel = opts.sourceLabel,
            tool        = "IDARo",
            toolVersion = opts.toolVersion or "1.0",
        },
    }, ProjectDB)
    return self
end

local function emit(self, evt, payload)
    if self._eventBus and type(self._eventBus.emit) == "function" then
        pcall(self._eventBus.emit, self._eventBus, evt, payload)
    end
end

local function markModified(self)
    self._meta.modified = os.time()
end

-- ---------------------------------------------------------------------
-- Service accessors
-- ---------------------------------------------------------------------

function ProjectDB:history()  return self._history  end
function ProjectDB:symbols()  return self._symbols  end
function ProjectDB:comments() return self._comments end
function ProjectDB:bookmarks() return self._bookmarks end

function ProjectDB:bytecode()      return self._bytecode end
function ProjectDB:bytecodeBytes() return self._bytecodeBytes end
function ProjectDB:meta()          return self._meta end
function ProjectDB:viewState()     return self._viewState end

-- ---------------------------------------------------------------------
-- View state
-- ---------------------------------------------------------------------

function ProjectDB:setViewState(patch)
    if type(patch) ~= "table" then return end
    local changed = false
    for k, v in patch do
        if self._viewState[k] ~= v then
            self._viewState[k] = v
            changed = true
        end
    end
    if changed then
        markModified(self)
        emit(self, "project.viewStateChanged", self._viewState)
    end
end

-- ---------------------------------------------------------------------
-- Attach / detach bytecode
-- ---------------------------------------------------------------------

local function defaultProtoName(proto, protoId)
    if proto.debugName and proto.debugName ~= "" then return proto.debugName end
    return string.format("proto_%d", protoId)
end

function ProjectDB:attachBytecode(parsed, rawBytes)
    if type(parsed) ~= "table" or not parsed.protos then
        error("ProjectDB:attachBytecode — expected parsed bytecode table", 2)
    end
    self._bytecode      = parsed
    self._bytecodeBytes = rawBytes
    markModified(self)

    -- Wrap auto-population in a single transaction so the user can undo
    -- the entire attach in one click.
    local s = self
    self._history:transaction("attach bytecode", function()
        for protoId, proto in parsed.protos do
            local name = defaultProtoName(proto, protoId)
            local flags = 0
            if protoId == parsed.mainProtoId then
                flags = bit32.bor(flags, SymbolTable.Flags.ENTRY)
            end
            if proto.debugName and proto.debugName ~= "" then
                flags = bit32.bor(flags, SymbolTable.Flags.USER_NAMED)
            else
                flags = bit32.bor(flags, SymbolTable.Flags.ANON)
            end
            s._symbols:upsert(SymbolTable.Kind.PROTO, tostring(protoId), name, { flags = flags })
        end
    end)
    emit(self, "project.bytecodeChanged",
        { bytecode = parsed, bytes = rawBytes })
end

function ProjectDB:detachBytecode()
    self._bytecode      = nil
    self._bytecodeBytes = nil
    markModified(self)
    emit(self, "project.bytecodeChanged", { bytecode = nil })
end

-- ---------------------------------------------------------------------
-- High-level convenience operations
-- ---------------------------------------------------------------------

function ProjectDB:renameProto(protoId, newName)
    local sym = self._symbols:byKey(SymbolTable.Kind.PROTO, tostring(protoId))
    if not sym then return false, "no symbol for proto " .. tostring(protoId) end
    local s = self
    self._history:transaction(string.format("rename proto %d → %s", protoId, newName), function()
        s._symbols:rename(sym.id, newName)
        s._symbols:setFlag(sym.id, SymbolTable.Flags.USER_NAMED, true)
        s._symbols:setFlag(sym.id, SymbolTable.Flags.ANON, false)
    end)
    return true
end

function ProjectDB:protoName(protoId)
    local sym = self._symbols:byKey(SymbolTable.Kind.PROTO, tostring(protoId))
    return sym and sym.name or nil
end

function ProjectDB:addComment(protoId, pc, text, kind)
    return self._comments:add(protoId, pc, text, { kind = kind })
end

function ProjectDB:commentsAt(protoId, pc)
    return self._comments:byAddress(protoId, pc)
end

function ProjectDB:toggleBookmark(protoId, pc, label, color)
    return self._bookmarks:toggle(protoId, pc, label, color)
end

function ProjectDB:hasBookmark(protoId, pc)
    return self._bookmarks:hasAt(protoId, pc)
end

-- ---------------------------------------------------------------------
-- Undo / redo passthrough
-- ---------------------------------------------------------------------

function ProjectDB:undo()    return self._history:undo() end
function ProjectDB:redo()    return self._history:redo() end
function ProjectDB:canUndo() return self._history:canUndo() end
function ProjectDB:canRedo() return self._history:canRedo() end
function ProjectDB:transaction(label, fn)
    return self._history:transaction(label, fn)
end

-- ---------------------------------------------------------------------
-- Snapshot (in-memory)
-- ---------------------------------------------------------------------

function ProjectDB:exportSnapshot(opts)
    opts = opts or {}
    local includeBytecode = opts.includeBytecode ~= false
    local snap = {
        format          = "IDARoblox.ProjectDB",
        formatVersion   = PROJECT_VERSION,
        meta            = {
            created     = self._meta.created,
            modified    = self._meta.modified,
            name        = self._meta.name,
            executor    = self._meta.executor,
            sourceLabel = self._meta.sourceLabel,
            tool        = self._meta.tool,
            toolVersion = self._meta.toolVersion,
        },
        viewState  = self:_serialisableViewState(),
        symbols    = self._symbols:exportSnapshot(),
        comments   = self._comments:exportSnapshot(),
        bookmarks  = self._bookmarks:exportSnapshot(),
    }
    if includeBytecode and self._bytecodeBytes then
        snap.bytecode = SerializeBinary.wrapBytes(self._bytecodeBytes)
    end
    return snap
end

function ProjectDB:_serialisableViewState()
    local vs = self._viewState
    local copy = {}
    for k, v in vs do
        -- xrefQuery may have non-string keys; ensure it's serializable
        if k == "xrefQuery" and type(v) == "table" then
            copy[k] = { kind = v.kind, key = v.key, label = v.label }
        else
            copy[k] = v
        end
    end
    return copy
end

function ProjectDB:importSnapshot(snap, opts)
    if type(snap) ~= "table" then return false, "snapshot expected" end
    if snap.format and snap.format ~= "IDARoblox.ProjectDB" then
        return false, "wrong format tag: " .. tostring(snap.format)
    end
    if snap.formatVersion and snap.formatVersion > PROJECT_VERSION then
        return false, string.format(
            "snapshot version too new: %d (max %d)", snap.formatVersion, PROJECT_VERSION)
    end
    opts = opts or {}
    -- Wipe history before importing so the load itself isn't undoable
    -- (and the imported state is the new ground truth).
    self._history:clear()
    if snap.meta then
        for k, v in snap.meta do self._meta[k] = v end
    end
    if snap.viewState then
        for k, v in snap.viewState do self._viewState[k] = v end
    end
    if snap.symbols then self._symbols:importSnapshot(snap.symbols) end
    if snap.comments then self._comments:importSnapshot(snap.comments) end
    if snap.bookmarks then self._bookmarks:importSnapshot(snap.bookmarks) end

    local rawBytes = nil
    if snap.bytecode then
        if SerializeBinary.isBytesBlob(snap.bytecode) then
            rawBytes = snap.bytecode.data
        elseif type(snap.bytecode) == "string" then
            rawBytes = snap.bytecode
        end
    end
    if rawBytes and opts.parser then
        local ok, parsed = pcall(opts.parser.parse, rawBytes)
        if ok then
            self._bytecode      = parsed
            self._bytecodeBytes = rawBytes
        else
            if self._logger then
                self._logger:warn("ProjectDB.importSnapshot: parse failed: %s",
                    tostring(parsed))
            end
        end
    elseif rawBytes then
        self._bytecodeBytes = rawBytes
    end
    emit(self, "project.loaded", self)
    return true
end

-- ---------------------------------------------------------------------
-- Binary persistence
-- ---------------------------------------------------------------------

function ProjectDB:serialize(opts)
    return SerializeBinary.encode(self:exportSnapshot(opts))
end

function ProjectDB:deserialize(data, opts)
    if type(data) ~= "string" then return false, "data must be string" end
    local snap, err = SerializeBinary.decode(data)
    if not snap then return false, err end
    return self:importSnapshot(snap, opts)
end

-- ---------------------------------------------------------------------
-- Clear (new project)
-- ---------------------------------------------------------------------

function ProjectDB:clear()
    self._symbols:importSnapshot({})
    self._comments:importSnapshot({})
    self._bookmarks:importSnapshot({})
    self._history:clear()
    self._bytecode = nil
    self._bytecodeBytes = nil
    self._viewState = {
        viewMode = "disasm", bottomTab = "output",
        selectedProtoId = nil, selectedPc = nil, selectedBlockId = nil,
        selectedDecLine = nil, treeRatio = nil, outputRatio = nil,
        xrefQuery = nil,
    }
    self._meta.modified = os.time()
    emit(self, "project.cleared", self)
end

-- ---------------------------------------------------------------------
-- Stats
-- ---------------------------------------------------------------------

function ProjectDB:stats()
    return {
        meta       = self._meta,
        history    = self._history:stats(),
        symbols    = self._symbols:stats(),
        comments   = self._comments:stats(),
        bookmarks  = self._bookmarks:stats(),
        hasBytecode = self._bytecode ~= nil,
        bytecodeSize = self._bytecodeBytes and #self._bytecodeBytes or 0,
    }
end

-- ---------------------------------------------------------------------
-- Manifest (for LoadingManager)
-- ---------------------------------------------------------------------

function ProjectDB.manifest()
    return {
        id           = "Database.ProjectDB",
        dependencies = {},
        weight       = 0.3,
        serviceName  = "ProjectDB",
        stages = {
            { id = "register", weight = 1.0, fn = function(ctx)
                ctx:report(1, "ProjectDB ready")
            end },
        },
    }
end

return ProjectDB
