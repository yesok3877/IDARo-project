--!nonstrict
-- =====================================================================
-- IDARoblox / Core / SessionManager
-- ---------------------------------------------------------------------
-- Capture + restore a complete workspace session.
--
-- File format (line-oriented, UTF-8-safe text):
--
--   IDARBLX-SESSION-V1
--   [meta]
--   created=<unix-time>
--   version=13
--   executor=<name>
--   [state]
--   viewMode=disasm
--   bottomTab=output
--   selectedProtoId=0
--   selectedPc=42
--   selectedBlockId=
--   selectedDecLine=
--   treeRatio=0.18
--   outputRatio=0.78
--   xrefQueryKind=string
--   xrefQueryKey=Players
--   xrefQueryLabel=Players · 3 refs
--   [bytecode]
--   size=12345
--   content=<base64-payload-on-a-single-line>
--   [bookmarks]
--   <protoId>|<pc>|<label>
--   <protoId>|<pc>|<label>
--   …
--   [hooks_metadata]
--   <id>|<kind>|<label>|<sourceLabel>
--   …
--
-- Field/label values that contain "|" or newlines are escaped as "\|"
-- and "\n" respectively. Both serializer and parser implement the same
-- escape convention.
--
-- Hook metadata is informational: function references can't be
-- serialised across sessions, so the entries are restored as a list the
-- user can review but not re-install automatically.
--
-- Public API:
--   SessionManager.new(opts)
--     opts.storage    — StorageBackend instance (optional)
--     opts.logger     — logger
--     opts.executorName — for the meta section
--
--   sm:captureCurrentState(workspace, originalBytecode?) → session table
--   sm:serialize(session) → string blob
--   sm:deserialize(text)  → (session, err?)
--   sm:applyToWorkspace(workspace, session)
--
--   sm:saveToFile(filename, workspace, originalBytecode?) → (ok, err?)
--   sm:loadFromFile(filename, workspace) → (ok, err?)
--   sm:clipboardSave(workspace, originalBytecode?) → (ok, err?)
--   sm:clipboardLoad(workspace) → (ok, err?)
-- =====================================================================

local Base64 = _G.IDARo.require("Core.Base64")
local SerializeBinary = _G.IDARo.require("Database.SerializeBinary")

local SessionManager = {}
SessionManager.__index = SessionManager

local MAGIC          = "IDARBLX-SESSION-V1"
local BINARY_MAGIC   = "IDARBLX-DB-V1\0"                              -- ProjectDB blob marker
local CURRENT_VERSION = 14                                            -- bumped: ProjectDB integration

-- ---------------------------------------------------------------------
-- Escape helpers
-- ---------------------------------------------------------------------

local function escapeField(s)
    if type(s) ~= "string" then return tostring(s or "") end
    s = string.gsub(s, "\\", "\\\\")
    s = string.gsub(s, "|", "\\|")
    s = string.gsub(s, "\n", "\\n")
    s = string.gsub(s, "\r", "\\r")
    return s
end

local function unescapeField(s)
    if type(s) ~= "string" then return s end
    local out = {}
    local i = 1
    local n = #s
    while i <= n do
        local c = string.sub(s, i, i)
        if c == "\\" and i < n then
            local nxt = string.sub(s, i + 1, i + 1)
            if nxt == "\\" then out[#out + 1] = "\\"
            elseif nxt == "|" then out[#out + 1] = "|"
            elseif nxt == "n" then out[#out + 1] = "\n"
            elseif nxt == "r" then out[#out + 1] = "\r"
            else out[#out + 1] = nxt
            end
            i = i + 2
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
    return table.concat(out)
end

local function tobool(s)
    if s == "true" then return true end
    if s == "false" then return false end
    return nil
end

-- ---------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------

function SessionManager.new(opts)
    opts = opts or {}
    return setmetatable({
        _storage      = opts.storage,
        _logger       = opts.logger,
        _executorName = opts.executorName or "unknown",
    }, SessionManager)
end

-- ---------------------------------------------------------------------
-- Capture from workspace
-- ---------------------------------------------------------------------

function SessionManager:captureCurrentState(workspace, originalBytecode)
    if not workspace or not workspace.state then
        error("SessionManager.captureCurrentState: workspace expected", 2)
    end
    local s = workspace.state
    local session = {
        meta = {
            created  = os.time(),
            version  = CURRENT_VERSION,
            executor = self._executorName,
        },
        state = {
            viewMode        = s.viewMode        or "disasm",
            bottomTab       = s.bottomTab       or "output",
            selectedProtoId = s.selectedProtoId,
            selectedPc      = s.selectedPc,
            selectedBlockId = s.selectedBlockId,
            selectedDecLine = s.selectedDecLine,
            treeRatio       = s.treeRatio,
            outputRatio     = s.outputRatio,
            xrefQueryKind   = s.xrefQuery and s.xrefQuery.kind,
            xrefQueryKey    = s.xrefQuery and tostring(s.xrefQuery.key or ""),
            xrefQueryLabel  = s.xrefQuery and s.xrefQuery.label,
        },
        bookmarks        = {},
        hooks_metadata   = {},
        bytecodeBytes    = originalBytecode,
    }
    -- Bookmarks: prefer projectDB if present, fall back to legacy state array
    local db = s.projectDB
    if db and type(db.bookmarks) == "function" then
        for _, bm in db:bookmarks():all() do
            session.bookmarks[#session.bookmarks + 1] = {
                protoId = bm.protoId,
                pc      = bm.pc,
                label   = bm.label,
            }
        end
    elseif s.bookmarks then
        for _, bm in s.bookmarks do
            session.bookmarks[#session.bookmarks + 1] = {
                protoId = bm.protoId,
                pc      = bm.pc,
                label   = bm.label,
            }
        end
    end
    -- Hook metadata (informational only — function refs don't survive)
    if s.runtime and s.runtime.hooks then
        for _, hook in s.runtime.hooks:listAll() do
            session.hooks_metadata[#session.hooks_metadata + 1] = {
                id          = hook.id,
                kind        = hook.kind,
                label       = hook.label,
                sourceLabel = hook.sourceLabel,
                active      = hook.active,
            }
        end
    end
    return session
end

-- ---------------------------------------------------------------------
-- Serialize
-- ---------------------------------------------------------------------

function SessionManager:serialize(session)
    if type(session) ~= "table" then
        error("SessionManager.serialize: session table expected", 2)
    end
    local lines = { MAGIC }

    -- [meta]
    lines[#lines + 1] = "[meta]"
    lines[#lines + 1] = "created="  .. tostring(session.meta and session.meta.created  or os.time())
    lines[#lines + 1] = "version="  .. tostring(session.meta and session.meta.version  or CURRENT_VERSION)
    lines[#lines + 1] = "executor=" .. escapeField(session.meta and session.meta.executor or self._executorName)

    -- [state]
    lines[#lines + 1] = "[state]"
    if session.state then
        local st = session.state
        local function kv(key, value)
            if value == nil then
                lines[#lines + 1] = key .. "="
            elseif type(value) == "string" then
                lines[#lines + 1] = key .. "=" .. escapeField(value)
            else
                lines[#lines + 1] = key .. "=" .. tostring(value)
            end
        end
        kv("viewMode",        st.viewMode)
        kv("bottomTab",       st.bottomTab)
        kv("selectedProtoId", st.selectedProtoId)
        kv("selectedPc",      st.selectedPc)
        kv("selectedBlockId", st.selectedBlockId)
        kv("selectedDecLine", st.selectedDecLine)
        kv("treeRatio",       st.treeRatio)
        kv("outputRatio",     st.outputRatio)
        kv("xrefQueryKind",   st.xrefQueryKind)
        kv("xrefQueryKey",    st.xrefQueryKey)
        kv("xrefQueryLabel",  st.xrefQueryLabel)
    end

    -- [bytecode]
    if session.bytecodeBytes and #session.bytecodeBytes > 0 then
        lines[#lines + 1] = "[bytecode]"
        lines[#lines + 1] = "size=" .. tostring(#session.bytecodeBytes)
        lines[#lines + 1] = "content=" .. Base64.encode(session.bytecodeBytes)
    end

    -- [bookmarks]
    if session.bookmarks and #session.bookmarks > 0 then
        lines[#lines + 1] = "[bookmarks]"
        for _, bm in session.bookmarks do
            lines[#lines + 1] = string.format("%s|%s|%s",
                tostring(bm.protoId or ""),
                tostring(bm.pc or ""),
                escapeField(bm.label or ""))
        end
    end

    -- [hooks_metadata]
    if session.hooks_metadata and #session.hooks_metadata > 0 then
        lines[#lines + 1] = "[hooks_metadata]"
        for _, h in session.hooks_metadata do
            lines[#lines + 1] = string.format("%s|%s|%s|%s",
                tostring(h.id or ""),
                escapeField(h.kind or ""),
                escapeField(h.label or ""),
                escapeField(h.sourceLabel or ""))
        end
    end

    return table.concat(lines, "\n") .. "\n"
end

-- ---------------------------------------------------------------------
-- Deserialize
-- ---------------------------------------------------------------------

function SessionManager:deserialize(text)
    if type(text) ~= "string" or text == "" then
        return nil, "empty session text"
    end
    local lines = string.split(text, "\n")
    if #lines == 0 or lines[1] ~= MAGIC then
        return nil, "invalid magic header (expected '" .. MAGIC .. "')"
    end
    local session = {
        meta           = {},
        state          = {},
        bookmarks      = {},
        hooks_metadata = {},
        bytecodeBytes  = nil,
    }
    local section = nil
    local bcSize    = nil
    local bcContent = nil

    for i = 2, #lines do
        local raw = lines[i]
        -- Skip trailing CR from CRLF files
        if string.sub(raw, -1) == "\r" then raw = string.sub(raw, 1, -2) end
        if raw == "" then continue end

        if string.sub(raw, 1, 1) == "[" and string.sub(raw, -1) == "]" then
            section = string.sub(raw, 2, -2)
            continue
        end

        if section == "meta" or section == "state" then
            local eq = string.find(raw, "=", 1, true)
            if eq then
                local key = string.sub(raw, 1, eq - 1)
                local val = string.sub(raw, eq + 1)
                val = unescapeField(val)
                if section == "meta" then
                    if key == "created" or key == "version" then
                        session.meta[key] = tonumber(val) or val
                    else
                        session.meta[key] = val
                    end
                else
                    -- Convert known-numeric / boolean fields
                    if key == "selectedProtoId" or key == "selectedPc"
                        or key == "selectedBlockId" or key == "selectedDecLine" then
                        session.state[key] = tonumber(val)
                    elseif key == "treeRatio" or key == "outputRatio" then
                        session.state[key] = tonumber(val)
                    elseif val == "" then
                        session.state[key] = nil
                    elseif tobool(val) ~= nil then
                        session.state[key] = tobool(val)
                    else
                        session.state[key] = val
                    end
                end
            end
        elseif section == "bytecode" then
            local eq = string.find(raw, "=", 1, true)
            if eq then
                local key = string.sub(raw, 1, eq - 1)
                local val = string.sub(raw, eq + 1)
                if key == "size"    then bcSize = tonumber(val) end
                if key == "content" then bcContent = val end
            end
        elseif section == "bookmarks" then
            -- protoId|pc|label
            local parts = string.split(raw, "|")
            if #parts >= 2 then
                session.bookmarks[#session.bookmarks + 1] = {
                    protoId = tonumber(parts[1]),
                    pc      = tonumber(parts[2]),
                    label   = unescapeField(parts[3] or ""),
                }
            end
        elseif section == "hooks_metadata" then
            -- id|kind|label|sourceLabel
            local parts = string.split(raw, "|")
            if #parts >= 3 then
                session.hooks_metadata[#session.hooks_metadata + 1] = {
                    id          = tonumber(parts[1]),
                    kind        = unescapeField(parts[2] or ""),
                    label       = unescapeField(parts[3] or ""),
                    sourceLabel = unescapeField(parts[4] or ""),
                }
            end
        end
    end

    if bcContent then
        local ok, decoded = pcall(Base64.decode, bcContent)
        if not ok then
            return nil, "bytecode section: base64 decode failed: " .. tostring(decoded)
        end
        if bcSize and bcSize ~= #decoded then
            return nil, string.format(
                "bytecode size mismatch: header=%d, decoded=%d", bcSize, #decoded)
        end
        session.bytecodeBytes = decoded
    end

    return session, nil
end

-- ---------------------------------------------------------------------
-- Apply session to workspace
-- ---------------------------------------------------------------------

function SessionManager:applyToWorkspace(workspace, session, opts)
    if not workspace or not workspace.setState then
        return false, "workspace expected"
    end
    if not session then return false, "session expected" end
    opts = opts or {}

    -- If a bytecode payload is present and a parser is wired into the
    -- workspace, reload it through workspace:setBytecode. The workspace
    -- must already have a BytecodeParser available (via Bootstrap).
    if session.bytecodeBytes and opts.parser and workspace.setBytecode then
        local ok, parsed = pcall(opts.parser.parse, session.bytecodeBytes)
        if not ok then
            if self._logger then
                self._logger:error("SessionManager: parse failed: %s", tostring(parsed))
            end
            return false, "parse failed: " .. tostring(parsed)
        end
        workspace:setBytecode(parsed)
    end

    -- Apply state. Use setState so the component re-renders cleanly.
    local st = session.state or {}
    local update = {}
    if st.viewMode        ~= nil then update.viewMode        = st.viewMode end
    if st.bottomTab       ~= nil then update.bottomTab       = st.bottomTab end
    if st.selectedProtoId ~= nil then update.selectedProtoId = st.selectedProtoId end
    if st.selectedPc      ~= nil then update.selectedPc      = st.selectedPc end
    if st.selectedBlockId ~= nil then update.selectedBlockId = st.selectedBlockId end
    if st.selectedDecLine ~= nil then update.selectedDecLine = st.selectedDecLine end
    if st.treeRatio       ~= nil then update.treeRatio       = st.treeRatio end
    if st.outputRatio     ~= nil then update.outputRatio     = st.outputRatio end
    if st.xrefQueryKind and st.xrefQueryKey then
        update.xrefQuery = {
            kind  = st.xrefQueryKind,
            key   = st.xrefQueryKey,
            label = st.xrefQueryLabel or st.xrefQueryKey,
        }
    end
    -- Restore bookmarks
    if session.bookmarks then
        update.bookmarks = session.bookmarks
    end
    workspace:setState(update)

    -- If the protoId came back valid, refresh the open stream/cfg.
    if st.selectedProtoId and workspace.openProto then
        pcall(workspace.openProto, workspace, st.selectedProtoId)
    end

    if self._logger then
        self._logger:info(
            "SessionManager: applied session (v%s, %d bookmarks, %d hook records, bytecode=%s)",
            tostring(session.meta and session.meta.version or "?"),
            #(session.bookmarks or {}),
            #(session.hooks_metadata or {}),
            session.bytecodeBytes and "yes" or "no")
    end
    return true
end

-- ---------------------------------------------------------------------
-- File / clipboard convenience
-- ---------------------------------------------------------------------

function SessionManager:saveToFile(filename, workspace, originalBytecode)
    if not self._storage then return false, "no storage backend" end
    -- Prefer the dense binary ProjectDB format when a projectDB is wired
    -- into the workspace. Fall back to the legacy V1 text format otherwise.
    local db = workspace and workspace.state and workspace.state.projectDB
    if db and type(db.serialize) == "function" then
        local blob = db:serialize()
        return self._storage:write(filename, blob)
    end
    local session = self:captureCurrentState(workspace, originalBytecode)
    local text = self:serialize(session)
    return self._storage:write(filename, text)
end

function SessionManager:loadFromFile(filename, workspace, parser)
    if not self._storage then return false, "no storage backend" end
    local ok, blob = self._storage:read(filename)
    if not ok then return false, blob end
    return self:_loadFromString(blob, workspace, parser)
end

function SessionManager:clipboardSave(workspace, originalBytecode)
    if not self._storage then return false, "no storage backend" end
    local db = workspace and workspace.state and workspace.state.projectDB
    if db and type(db.serialize) == "function" then
        local blob = db:serialize()
        return self._storage:setClipboard(blob)
    end
    local session = self:captureCurrentState(workspace, originalBytecode)
    local text = self:serialize(session)
    return self._storage:setClipboard(text)
end

function SessionManager:clipboardLoad(workspace, parser)
    if not self._storage then return false, "no storage backend" end
    local ok, blob = self._storage:getClipboard()
    if not ok then return false, blob end
    return self:_loadFromString(blob, workspace, parser)
end

-- Auto-detect binary ProjectDB vs legacy V1 text. Apply via the appropriate
-- path; if binary, also propagate the restored view-state back through the
-- workspace's setState so views refresh.
function SessionManager:_loadFromString(blob, workspace, parser)
    if type(blob) ~= "string" or #blob == 0 then
        return false, "empty session blob"
    end
    -- Binary format (ProjectDB) — check magic
    if string.sub(blob, 1, #BINARY_MAGIC) == BINARY_MAGIC then
        local db = workspace and workspace.state and workspace.state.projectDB
        if not db then
            return false, "binary session loaded but no ProjectDB on workspace"
        end
        local ok, err = db:deserialize(blob, { parser = parser })
        if not ok then return false, err end
        -- Reflect the restored bytecode through workspace:setBytecode so
        -- analysis services (Disassembler/CFG/XRef/Decompiler) rebuild.
        local parsed   = db:bytecode()
        local rawBytes = db:bytecodeBytes()
        if parsed and workspace.setBytecode then
            -- Suppress: setBytecode would call projectDB:attachBytecode again
            -- and clobber the restored symbol names. We temporarily detach
            -- the projectDB during this call.
            local origPdb = workspace.state.projectDB
            workspace.state.projectDB = nil
            local ok2, err2 = pcall(workspace.setBytecode, workspace, parsed, rawBytes)
            workspace.state.projectDB = origPdb
            if not ok2 then return false, "setBytecode failed: " .. tostring(err2) end
        end
        -- Restore view-state into workspace render state
        local vs = db:viewState()
        local update = {
            viewMode        = vs.viewMode        or "disasm",
            bottomTab       = vs.bottomTab       or "output",
            selectedProtoId = vs.selectedProtoId,
            selectedPc      = vs.selectedPc,
            selectedBlockId = vs.selectedBlockId,
            selectedDecLine = vs.selectedDecLine,
            treeRatio       = vs.treeRatio,
            outputRatio     = vs.outputRatio,
            xrefQuery       = vs.xrefQuery,
            bookmarkCount   = db:bookmarks():count(),
        }
        workspace:setState(update)
        if vs.selectedProtoId and workspace.openProto then
            pcall(workspace.openProto, workspace, vs.selectedProtoId)
        end
        if self._logger then
            local stats = db:stats()
            self._logger:info(
                "SessionManager: loaded binary session — %d symbols, %d comments, %d bookmarks, bytecode=%s",
                stats.symbols.total, stats.commentsCount or stats.comments.total,
                stats.bookmarks.total, parsed and "yes" or "no")
        end
        return true
    end
    -- Legacy V1 text format
    local session, err = self:deserialize(blob)
    if not session then return false, err end
    local ok, err2 = self:applyToWorkspace(workspace, session, { parser = parser })
    if not ok then return false, err2 end
    -- Migrate legacy bookmarks/state into projectDB if one is available
    local db = workspace and workspace.state and workspace.state.projectDB
    if db and session.bookmarks then
        db:transaction("migrate legacy bookmarks", function()
            for _, bm in session.bookmarks do
                db:bookmarks():add(bm.protoId, bm.pc, bm.label or "")
            end
        end)
        workspace:setState({ bookmarkCount = db:bookmarks():count() })
    end
    return true
end

-- ---------------------------------------------------------------------
-- Manifest
-- ---------------------------------------------------------------------

function SessionManager.manifest()
    return {
        id           = "Core.SessionManager",
        dependencies = {},
        weight       = 0.2,
        serviceName  = "SessionManager",
        stages = {
            { id = "register", weight = 1.0, fn = function(ctx)
                ctx:report(1, "SessionManager ready")
            end },
        },
    }
end

return SessionManager
