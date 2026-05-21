--!nonstrict
-- =====================================================================
-- IDARoblox / UI / Workspace
-- ---------------------------------------------------------------------
-- The main IDA-style shell. Renders the chrome (Menu / Toolbar /
-- StatusBar) around a docked content area (ProtoTreeView | DisassemblyView
-- + OutputView). Owns the active Disassembler and connects keybinds.
--
-- Props:
--   bytecode      — initial parsed bytecode (optional; can be set later)
--   router        — InputRouter (optional; one is created if missing)
--   kernel        — for service-locator lookups (Logger / Theme)
--   statusText    — initial status-bar text
--   onOpenScript  — fn() invoked when File→Open / Ctrl+O fires
--   onReload      — fn() invoked when F5 fires
--
-- Imperative methods on the component instance (caller does
-- `workspaceRef:setBytecode(...)` etc.):
--   :setBytecode(parsed)            — install new bytecode + new disassembler
--   :openProto(id)                  — select + display this proto
--   :focusPc(pc)                    — scroll the disassembly to a PC
--   :setStatusText(text)
--   :loadScript(scriptInstance)     — parseScript(...) + setBytecode
-- =====================================================================

local Component         = _G.IDARo.require("UI.Framework.Component")
local Element           = _G.IDARo.require("UI.Framework.Element")
local LayoutEngine      = _G.IDARo.require("UI.Framework.LayoutEngine")
local InputRouter       = _G.IDARo.require("UI.Framework.InputRouter")

local Menu              = _G.IDARo.require("UI.Widgets.Menu")
local Toolbar           = _G.IDARo.require("UI.Widgets.Toolbar")
local StatusBar         = _G.IDARo.require("UI.Widgets.StatusBar")
local ProgressBar       = _G.IDARo.require("UI.Widgets.ProgressBar")
local Dialog            = _G.IDARo.require("UI.Widgets.Dialog")

local ProtoTreeView     = _G.IDARo.require("UI.Views.ProtoTreeView")
local DisassemblyView   = _G.IDARo.require("UI.Views.DisassemblyView")
local OutputView        = _G.IDARo.require("UI.Views.OutputView")
local GraphView         = _G.IDARo.require("UI.Views.GraphView")
local StringsView       = _G.IDARo.require("UI.Views.StringsView")
local NamesView         = _G.IDARo.require("UI.Views.NamesView")
local XRefView          = _G.IDARo.require("UI.Views.XRefView")
local PseudocodeView    = _G.IDARo.require("UI.Views.PseudocodeView")
local SearchView        = _G.IDARo.require("UI.Views.SearchView")
local HexView           = _G.IDARo.require("UI.Views.HexView")
local ConstantsView     = _G.IDARo.require("UI.Views.ConstantsView")
local ImportsView       = _G.IDARo.require("UI.Views.ImportsView")
local PatternsView      = _G.IDARo.require("UI.Views.PatternsView")
local HooksView         = _G.IDARo.require("UI.Views.HooksView")
local FunctionsView     = _G.IDARo.require("UI.Views.FunctionsView")
local ClosuresView      = _G.IDARo.require("UI.Views.ClosuresView")
local GCHeapView        = _G.IDARo.require("UI.Views.GCHeapView")
local PluginManagerView = _G.IDARo.require("UI.Views.PluginManagerView")
local NetworkView       = _G.IDARo.require("UI.Views.NetworkView")
local ConsoleView       = _G.IDARo.require("UI.Views.ConsoleView")
local HeapGraphView     = _G.IDARo.require("UI.Views.HeapGraphView")

local Disassembler      = _G.IDARo.require("Analysis.Disassembler")
local CFGBuilder        = _G.IDARo.require("Analysis.CFGBuilder")
local XRefEngine        = _G.IDARo.require("Analysis.XRefEngine")
local Decompiler        = _G.IDARo.require("Analysis.Decompiler")
local PatternMatcher    = _G.IDARo.require("Analysis.PatternMatcher")
local Heuristics        = _G.IDARo.require("Analysis.Heuristics")
local Plugins           = _G.IDARo.require("Analysis.Plugins")
local Runtime           = _G.IDARo.require("Runtime")

local BytecodeParser    = _G.IDARo.require("Analysis.BytecodeParser")
local StorageBackend    = _G.IDARo.require("Core.StorageBackend")
local SessionManager    = _G.IDARo.require("Core.SessionManager")

local Database          = _G.IDARo.require("Database")
local ProjectDB         = Database.ProjectDB
local BookmarkStore     = Database.BookmarkStore

local e = Element.create

local Splitter = LayoutEngine.Splitter
local Panel    = LayoutEngine.Panel

local Workspace = Component.extend("Workspace")

Component.setDefaultProps(Workspace, {
    bytecode      = nil,
    router        = nil,
    statusText    = "Ready",
    treeRatio     = 0.22,
    outputRatio   = 0.70,
    onOpenScript  = nil,
    onReload      = nil,
})

-- ---------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------

function Workspace:init(props)
    -- Stable handler references. Bound here once so that re-renders
    -- don't pass new closures into child views — passing fresh
    -- closures every render makes the child's didUpdate fire every
    -- frame, which triggers its setState, which re-queues the parent,
    -- which sends a fresh closure, which… infinite loop. Don't recreate
    -- callbacks on each render — bind them once and reuse.
    self._onCopyResult     = function(ok, warnings) self:_setToast(ok, warnings) end
    self._onClearXrefQuery = function() self:setState({ xrefQuery = nil }) end
    self._onBlockSelectFn  = function(id, block) self:_onBlockSelect(id, block) end
    self._onBlockActivateFn = function(id, block) self:_onBlockActivate(id, block) end
    self._onGraphMount     = function(component) self._graphRef = component end
    self._onGraphUnmount   = function() self._graphRef = nil end
    self._onDecLineSelect  = function(line, text) self:_onDecompLineSelect(line, text) end
    self._onRowSelectFn    = function(pc, row) self:_onRowSelect(pc, row) end
    self._onRowActivateFn  = function(pc, row) self:_onRowActivate(pc, row) end
    self._onDisasmMount    = function(component) self._disasmRef = component end
    self._onDisasmUnmount  = function() self._disasmRef = nil end

    self.state = {
        bytecode        = props.bytecode,
        bytecodeBytes   = props.bytecodeBytes,                       -- raw bytes for session save
        disassembler    = nil,
        cfgBuilder      = nil,
        currentCfg      = nil,
        xrefIndex       = nil,
        decompiler      = nil,
        patternMatcher  = nil,
        plugins         = nil,
        runtime         = nil,
        storage         = nil,
        sessionManager  = nil,
        projectDB       = nil,                                       -- Database/ProjectDB facade
        selectedProtoId = nil,
        currentStream   = nil,
        selectedPc      = nil,
        selectedBlockId = nil,
        selectedDecLine = nil,                                       -- selected line in decomp view
        statusText      = props.statusText,
        showOutput      = true,
        viewMode        = "disasm",                                  -- "disasm" | "graph" | "decomp"
        bottomTab       = "output",                                  -- "output"|"strings"|"names"|"xrefs"|…
        xrefQuery       = nil,
        treeRatio       = props.treeRatio,
        outputRatio     = props.outputRatio,
        runningBusy     = false,
        runningProgress = 0,
        runningLabel    = nil,
        bookmarkCount   = 0,                                         -- mirrored from projectDB for status bar
    }
    self._ownsRouter = false
    self._router = props.router
    if not self._router then
        self._router = InputRouter.new({ logger = self.logger })
        self._ownsRouter = true
    end
    -- PatternMatcher + Plugins are bytecode-independent; construct
    -- them eagerly with built-in heuristics pre-registered.
    self.state.patternMatcher = PatternMatcher.new({ logger = self.logger })
    Heuristics.registerAll(self.state.patternMatcher)
    self.state.plugins = Plugins.new({
        matcher  = self.state.patternMatcher,
        services = { logger = self.logger },
        logger   = self.logger,
        eventBus = self.eventBus,
    })
    -- Runtime services (live-environment introspection). Accept a
    -- pre-built instance from props, otherwise lazy-construct so the
    -- HooksView always has something to render.
    self.state.runtime = props.runtime or Runtime.new({
        logger   = self.logger,
        eventBus = self.eventBus,
    })

    -- Persistence: storage backend + session manager.
    self.state.storage = props.storage or StorageBackend.new({
        logger  = self.logger,
        rootDir = "IDARo",
    })
    self.state.sessionManager = props.sessionManager or SessionManager.new({
        storage      = self.state.storage,
        logger       = self.logger,
        executorName = self.state.runtime
            and self.state.runtime.scanner:executorName() or nil,
    })

    -- ProjectDB: the IDA "IDB" — owns symbols, comments, bookmarks,
    -- history (undo/redo), and the canonical view state. Workspace
    -- treats ProjectDB as the source of truth; render-time state is
    -- mirrored into self.state for view convenience.
    self.state.projectDB = props.projectDB or ProjectDB.new({
        logger      = self.logger,
        eventBus    = self.eventBus,
        executor    = self.state.runtime
            and self.state.runtime.scanner:executorName() or nil,
        toolVersion = "1.0",
    })
    -- Keep status-bar bookmark count in sync with the store.
    if self.eventBus then
        local function refreshBmCount()
            if self.state and self.state.projectDB then
                local n = self.state.projectDB:bookmarks():count()
                if self.state.bookmarkCount ~= n then
                    self:setState({ bookmarkCount = n })
                end
            end
        end
        self.eventBus:on("bookmark.added",   refreshBmCount)
        self.eventBus:on("bookmark.removed", refreshBmCount)
        self.eventBus:on("bookmark.updated", refreshBmCount)
        self.eventBus:on("project.loaded",   refreshBmCount)
        self.eventBus:on("project.cleared",  refreshBmCount)
    end

    if props.bytecode then
        self.state.disassembler = Disassembler.new(props.bytecode, {
            useDebugNames = true,
            logger        = self.logger,
        })
        self.state.cfgBuilder      = CFGBuilder.new(self.state.disassembler, { logger = self.logger })
        self.state.xrefIndex       = XRefEngine.build(
            self.state.disassembler, props.bytecode, { logger = self.logger })
        self.state.decompiler      = Decompiler.new(
            self.state.disassembler, self.state.cfgBuilder, props.bytecode,
            { logger = self.logger })
        self.state.selectedProtoId = props.bytecode.mainProtoId
        self.state.currentStream   = self.state.disassembler:disassembleProto(
            props.bytecode.mainProtoId)
        self.state.currentCfg      = self.state.cfgBuilder:cfgForProto(props.bytecode.mainProtoId)
        self.state.plugins:onBytecodeLoaded(props.bytecode)
    end
end

function Workspace:didMount()
    self:_installKeybinds()
    if self.eventBus then
        -- Subscribe to global progress events so the toolbar progress bar
        -- shows long-running analyses.
        self._busSub = self.eventBus:on("loading.global.progress", function(_, payload)
            if not self._mounted then return end
            -- Only show when there's an active operation that started post-boot.
            if payload.progress and payload.progress < 1 then
                self:setState({
                    runningBusy     = true,
                    runningProgress = payload.progress,
                    runningLabel    = payload.stageLabel or payload.currentModule,
                })
            else
                self:setState({ runningBusy = false, runningProgress = 1 })
            end
        end)
    end
    if self.props.onMount then
        local ok, err = pcall(self.props.onMount, self)
        if not ok and self.logger then
            self.logger:warn("Workspace onMount error: %s", tostring(err))
        end
    end
end

function Workspace:willUnmount()
    if self._busSub then self._busSub:disconnect() end
    if self._ownsRouter and self._router then self._router:destroy() end
end

-- ---------------------------------------------------------------------
-- Public API (called by parents via ref)
-- ---------------------------------------------------------------------

function Workspace:setBytecode(parsed, rawBytes)
    local d = Disassembler.new(parsed, {
        useDebugNames = true,
        logger        = self.logger,
    })
    local cfgb = CFGBuilder.new(d, { logger = self.logger })
    local xref = XRefEngine.build(d, parsed, { logger = self.logger })
    local dec  = Decompiler.new(d, cfgb, parsed, { logger = self.logger })
    self:setState({
        bytecode        = parsed,
        bytecodeBytes   = rawBytes,
        disassembler    = d,
        cfgBuilder      = cfgb,
        xrefIndex       = xref,
        decompiler      = dec,
        selectedProtoId = parsed.mainProtoId,
        currentStream   = d:disassembleProto(parsed.mainProtoId),
        currentCfg      = cfgb:cfgForProto(parsed.mainProtoId),
        selectedPc      = nil,
        selectedBlockId = nil,
        selectedDecLine = nil,
        xrefQuery       = nil,
    })
    -- Notify plugins of the new bytecode (matcher and plugins survive
    -- reloads — they're bytecode-independent).
    if self.state.plugins then
        self.state.plugins:onBytecodeLoaded(parsed)
    end
    -- Hand the bytecode to ProjectDB so symbols get registered
    -- (one transaction → one undo unit).
    if self.state.projectDB then
        self.state.projectDB:attachBytecode(parsed, rawBytes)
        self.state.projectDB:setViewState({
            selectedProtoId = parsed.mainProtoId,
            selectedPc      = nil,
            selectedBlockId = nil,
            selectedDecLine = nil,
            xrefQuery       = nil,
        })
    end
    if self.logger then
        self.logger:info("Workspace: bytecode loaded (%d protos, %d strings, %d insns, %d xref sites)",
            parsed.stats.protos, parsed.stats.totalStrings,
            parsed.stats.totalInstructions,
            xref.stats.totalSites)
    end
end

function Workspace:openProto(id)
    if not self.state.disassembler then return end
    local stream = self.state.disassembler:disassembleProto(id)
    local cfg    = self.state.cfgBuilder and self.state.cfgBuilder:cfgForProto(id)
    self:setState({
        selectedProtoId = id,
        currentStream   = stream,
        currentCfg      = cfg,
        selectedPc      = nil,
        selectedBlockId = nil,
    })
end

function Workspace:focusPc(pc)
    self:setState({ selectedPc = pc })
    if self._disasmRef and self._disasmRef.scrollToPc then
        self._disasmRef:scrollToPc(pc, "center")
    end
end

function Workspace:setStatusText(text)
    if text == self.state.statusText then return end
    self:setState({ statusText = text })
end

-- Used by ScriptGenerator-backed views (FunctionsView, ClosuresView,
-- GCHeapView, HeapGraphView, NetworkView, ConsoleView,
-- PluginManagerView) to report the result of a "Copy script"
-- operation. `ok` is the boolean return from setclipboard; `warnings`
-- is a list of strings describing executor-capability caveats.
function Workspace:_setToast(ok, warnings)
    if ok then
        local msg = "✓ copied to clipboard"
        if warnings and #warnings > 0 then
            msg = msg .. " · " .. table.concat(warnings, "; ")
        end
        self:setStatusText(msg)
    else
        local err = (warnings and warnings[1]) or "copy failed"
        self:setStatusText("✗ " .. tostring(err))
    end
end

function Workspace:loadScript(scriptInstance)
    if not scriptInstance then return end
    local BytecodeParser = _G.IDARo.require("Analysis.BytecodeParser")
    local ok, parsed = pcall(BytecodeParser.parseScript, scriptInstance)
    if not ok then
        if self.logger then self.logger:error("loadScript failed: %s", tostring(parsed)) end
        self:setStatusText("Load failed: " .. tostring(parsed))
        return
    end
    self:setBytecode(parsed)
    self:setStatusText(string.format("Loaded %s (%d protos)",
        scriptInstance:GetFullName(), parsed.stats.protos))
end

-- ---------------------------------------------------------------------
-- Internal handlers
-- ---------------------------------------------------------------------

function Workspace:_installKeybinds()
    local r = self._router
    if not r then return end

    r:bind("F5", "reload", function()
        if self.props.onReload then pcall(self.props.onReload, self) end
    end)
    r:bind("Ctrl+O", "open-script", function()
        if self.props.onOpenScript then pcall(self.props.onOpenScript, self) end
    end)
    r:bind("Ctrl+G", "goto-proto", function()
        self:_openGotoProtoDialog()
    end)
    r:bind("Ctrl+F", "find", function()
        self:_openFind()
    end)
    r:bind("Ctrl+`", "toggle-output", function()
        self:setState({ showOutput = not self.state.showOutput })
    end)
    r:bind("Alt+Right", "next-proto", function() self:_moveProto(1) end)
    r:bind("Alt+Left",  "prev-proto", function() self:_moveProto(-1) end)
    -- IDA convention: Space cycles primary views (text → graph → decomp → text).
    local VIEW_CYCLE = { disasm = "graph", graph = "decomp", decomp = "disasm" }
    r:bind("Space", "toggle-view", function()
        local next = VIEW_CYCLE[self.state.viewMode] or "disasm"
        self:setState({ viewMode = next })
        self:setStatusText("View: " .. next)
    end)
    -- F5: decompile (IDA-style)
    r:bind("F5", "decompile-view", function()
        self:setState({ viewMode = "decomp" })
        self:setStatusText("View: decomp")
    end)
    -- Direct view-mode selection.
    r:bind("Ctrl+1", "view-disasm", function() self:setState({ viewMode = "disasm" }) end)
    r:bind("Ctrl+2", "view-graph",  function() self:setState({ viewMode = "graph"  }) end)
    r:bind("Ctrl+3", "view-decomp", function() self:setState({ viewMode = "decomp" }) end)
    -- Bottom-panel tab switching: Alt+1..Alt+9 cover output/strings/names/
    -- xrefs/search/constants/imports/patterns/hex; Alt+0 maps to Hooks
    -- (since Alt+10 isn't a thing on most keyboards).
    local TAB_ORDER = { "output", "strings", "names", "xrefs",
                        "search", "constants", "imports", "patterns", "hex", "hooks" }
    for i, tabId in TAB_ORDER do
        local key = i == 10 and "Alt+0" or ("Alt+" .. tostring(i))
        local action = "show-" .. tabId
        r:bind(key, action, function()
            self:setState({ bottomTab = tabId })
        end)
    end

    -- Bookmarks: Ctrl+B toggles a bookmark on the currently-selected row.
    r:bind("Ctrl+B", "toggle-bookmark", function() self:_toggleBookmark() end)

    r:bind("Ctrl+Z",       "undo",       function() self:_undo() end)
    r:bind("Ctrl+Y",       "redo",       function() self:_redo() end)
    r:bind("Ctrl+Shift+Z", "redo-alt",   function() self:_redo() end)

    -- Session save/load.
    r:bind("Ctrl+S",        "save-session",        function() self:_saveSession() end)
    r:bind("Ctrl+Shift+S",  "save-clipboard",      function() self:_saveSession({ target = "clipboard" }) end)
    r:bind("Ctrl+Shift+V",  "load-clipboard",      function() self:_loadSession({ target = "clipboard" }) end)
end

-- ---------------------------------------------------------------------
-- Dialog handling — Goto Proto, Find, etc.
-- ---------------------------------------------------------------------

function Workspace:_closeDialog()
    self:setState({ dialog = nil })
end

function Workspace:_openGotoProtoDialog()
    local bc = self.state.bytecode
    local hint = ""
    if bc and bc.protos then
        hint = string.format("Range: 1 – %d", #bc.protos)
    elseif bc then
        hint = "No protos loaded yet"
    else
        hint = "No bytecode loaded yet"
    end
    self:setState({
        dialog = {
            kind        = "goto-proto",
            title       = "Goto Proto",
            label       = "Enter a proto ID to jump to. " .. hint,
            placeholder = "e.g. 12 or 0x0C",
            initialText = tostring(self.state.selectedProtoId or ""),
            submitLabel = "Go",
            onSubmit    = function(text)
                local id = tonumber(text)
                if not id and text and text:match("^0[xX]") then
                    id = tonumber(text:sub(3), 16)
                end
                if not id then
                    self:setStatusText("Goto Proto: invalid ID '" .. tostring(text) .. "'")
                    self:_closeDialog()
                    return
                end
                local bc2 = self.state.bytecode
                if not bc2 or not bc2.protos or not bc2.protos[id] then
                    self:setStatusText(string.format(
                        "Goto Proto: id %d out of range (have %d protos)",
                        id, bc2 and bc2.protos and #bc2.protos or 0))
                    self:_closeDialog()
                    return
                end
                self:openProto(id)
                self:setStatusText(string.format("Jumped to proto %d", id))
                self:_closeDialog()
            end,
            onCancel    = function() self:_closeDialog() end,
        }
    })
end

function Workspace:_openFind()
    -- Find = switch to the Search tab (where SearchView lives) and
    -- focus its input. SearchView lives in the bottom tab strip if
    -- present; otherwise we surface a status message.
    local hasSearchTab = false
    for _, tab in ({ "search" }) do
        if self.state.bottomTab ~= tab then
            -- check the tab is wired in our render
            hasSearchTab = true
        end
    end
    if hasSearchTab then
        self:setState({ bottomTab = "search" })
        self:setStatusText("Find: switched to Search tab. Type a query in the box.")
        -- Try to focus the search input if SearchView exposes it
        task.defer(function()
            if self._searchViewRef and type(self._searchViewRef.focus) == "function" then
                pcall(function() self._searchViewRef:focus() end)
            end
        end)
    else
        self:setStatusText("Find: Search tab not available in this workspace")
    end
end

function Workspace:_moveProto(delta)
    local bc = self.state.bytecode
    if not bc or not self.state.selectedProtoId then return end
    local next = self.state.selectedProtoId + delta
    if bc.protos[next] then
        self:openProto(next)
    end
end

function Workspace:_onProtoSelect(id)
    self:openProto(id)
end

function Workspace:_onProtoOpen(id)
    self:openProto(id)
    self._router:setFocus("disasm")
end

function Workspace:_onRowSelect(pc, row)
    self:setState({ selectedPc = pc })
    -- Status text shows the row's symbolic name (label or address)
    local txt = row.label and (row.label .. ":  " .. row.mnemonic)
        or string.format("0x%04X  %s", row.address, row.mnemonic)
    self:setStatusText(txt)
end

function Workspace:_onRowActivate(pc, row)
    -- For branch rows, jump to target. For call/import, log a note for
    -- now (Step 7's XRef view will resolve targets properly).
    if not row.references then return end
    for _, ref in row.references do
        if ref.kind == "branch" and ref.target then
            self:focusPc(ref.target)
            return
        end
    end
    if self.logger then
        self.logger:debug("Workspace: no jump target for %s @ pc=%d", row.mnemonic, pc)
    end
end

function Workspace:_onBlockSelect(blockId, block)
    self:setState({ selectedBlockId = blockId })
    local stripeKind
    if blockId == 1 then stripeKind = "entry"
    elseif block.terminator == "return" then stripeKind = "return"
    elseif block.isLoopHeader then stripeKind = "loop-header"
    else stripeKind = "block" end
    self:setStatusText(string.format(
        "B%d (%s) · %d insn · %d→ · ←%d · depth %d",
        blockId, stripeKind,
        #block.instructions, #block.successors, #block.predecessors,
        block.nestingDepth or 0))
end

function Workspace:_onBlockActivate(blockId, block)
    -- Switch to text view focused on the block's first PC.
    local firstRow = block.instructions[1]
    if not firstRow then return end
    self:setState({
        viewMode   = "disasm",
        selectedPc = firstRow.pc,
    })
    -- Defer scroll until the DisassemblyView re-mounts.
    task.defer(function()
        if self._mounted and self._disasmRef and self._disasmRef.scrollToPc then
            self._disasmRef:scrollToPc(firstRow.pc, "center")
        end
    end)
end

-- ---------------------------------------------------------------------
-- Strings / Names / XRefs navigation
-- ---------------------------------------------------------------------

local function escapeForLabel(s, max)
    max = max or 40
    if type(s) ~= "string" then return tostring(s) end
    if #s > max then s = s:sub(1, max - 3) .. "…" end
    return s
end

function Workspace:_onStringSelect(value, entry)
    if not value then return end
    self:setState({
        xrefQuery = {
            kind  = "string",
            key   = value,
            label = string.format('"%s"  · %d ref%s',
                escapeForLabel(value, 48),
                entry and entry.refCount or 0,
                entry and entry.refCount == 1 and "" or "s"),
        },
        bottomTab = "xrefs",
    })
end

function Workspace:_onNameSelect(protoId, entry)
    -- Selecting a name opens that proto in the disassembly. We don't
    -- automatically flip to the XRefs tab — the user just wants to look
    -- at the function. A separate "find references" gesture handles the
    -- XRef case (planned: right-click in Step 11's context menus).
    self:openProto(protoId)
    self:setStatusText(string.format("Opened %s (p%d)",
        entry and entry.debugName or "?", protoId))
end

function Workspace:_onXrefJump(protoId, pc, site)
    if not self.state.bytecode then return end
    if self.state.selectedProtoId ~= protoId then
        self:openProto(protoId)
    end
    self:setState({
        viewMode   = "disasm",
        selectedPc = pc,
    })
    task.defer(function()
        if self._mounted and self._disasmRef and self._disasmRef.scrollToPc then
            self._disasmRef:scrollToPc(pc, "center")
        end
    end)
end

function Workspace:_onDecompLineSelect(lineIdx, lineText)
    self:setState({ selectedDecLine = lineIdx })
    self:setStatusText(string.format("line %d", lineIdx))
end

-- ---------------------------------------------------------------------
-- Bookmarks
-- ---------------------------------------------------------------------

function Workspace:_toggleBookmark()
    local protoId = self.state.selectedProtoId
    local pc      = self.state.selectedPc
    if protoId == nil or pc == nil then
        self:setStatusText("No row selected to bookmark")
        return
    end
    local db = self.state.projectDB
    if not db then self:setStatusText("ProjectDB not initialised"); return end

    local bc      = self.state.bytecode
    local proto   = bc and bc.protos[protoId]
    local pname   = (proto and proto.debugName ~= "" and proto.debugName)
        or string.format("p[%d]", protoId)
    local label   = string.format("%s @ 0x%04X", pname, (pc - 1) * 4)

    local added, _ = db:toggleBookmark(protoId, pc, label, BookmarkStore.Color.DEFAULT)
    if added then
        self:setStatusText(string.format("Bookmark added: %s", label))
    else
        self:setStatusText(string.format("Bookmark cleared at proto %d pc %d",
            protoId, pc))
    end
end

-- ---------------------------------------------------------------------
-- Undo / redo wrappers (Ctrl+Z / Ctrl+Y / Ctrl+Shift+Z)
-- ---------------------------------------------------------------------

function Workspace:_undo()
    local db = self.state.projectDB
    if not db then return end
    if not db:canUndo() then self:setStatusText("Nothing to undo"); return end
    local peek = db:history():peekUndo()
    local ok, err = pcall(function() db:undo() end)
    if not ok then
        self:setStatusText("Undo failed: " .. tostring(err))
        return
    end
    self:setStatusText(string.format("Undid: %s", peek and peek.label or "action"))
    -- Pull viewState back from DB into render state.
    self:_syncFromProjectDB()
end

function Workspace:_redo()
    local db = self.state.projectDB
    if not db then return end
    if not db:canRedo() then self:setStatusText("Nothing to redo"); return end
    local peek = db:history():peekRedo()
    local ok, err = pcall(function() db:redo() end)
    if not ok then
        self:setStatusText("Redo failed: " .. tostring(err))
        return
    end
    self:setStatusText(string.format("Redid: %s", peek and peek.label or "action"))
    self:_syncFromProjectDB()
end

function Workspace:_syncFromProjectDB()
    local db = self.state.projectDB
    if not db then return end
    local vs = db:viewState()
    local update = {}
    if vs.viewMode and vs.viewMode ~= self.state.viewMode then
        update.viewMode = vs.viewMode
    end
    if vs.bottomTab and vs.bottomTab ~= self.state.bottomTab then
        update.bottomTab = vs.bottomTab
    end
    if next(update) then self:setState(update) end
end

-- ---------------------------------------------------------------------
-- Save / load
-- ---------------------------------------------------------------------

local function defaultSessionFilename()
    return string.format("session-%d.idarblx", os.time())
end

function Workspace:_saveSession(opts)
    opts = opts or {}
    local sm = self.state.sessionManager
    if not sm then self:setStatusText("Session manager not initialised"); return end
    local bytes = self.state.bytecodeBytes                          -- may be nil
    if opts.target == "clipboard" then
        if not self.state.storage:hasClipboard() then
            self:setStatusText("setclipboard unavailable")
            return
        end
        local ok, err = sm:clipboardSave(self, bytes)
        if ok then
            self:setStatusText("Session copied to clipboard")
        else
            self:setStatusText("Clipboard save failed: " .. tostring(err))
        end
        return
    end
    -- File save
    if not self.state.storage:available() then
        self:setStatusText("writefile unavailable — try clipboard save (Ctrl+Shift+S)")
        return
    end
    local filename = opts.filename or defaultSessionFilename()
    local ok, err = sm:saveToFile(filename, self, bytes)
    if ok then
        self:setStatusText("Saved to " .. self.state.storage:rootDir() .. "/" .. filename)
    else
        self:setStatusText("Save failed: " .. tostring(err))
    end
end

function Workspace:_loadSession(opts)
    opts = opts or {}
    local sm = self.state.sessionManager
    if not sm then self:setStatusText("Session manager not initialised"); return end
    if opts.target == "clipboard" then
        if not self.state.storage:hasClipboard() then
            self:setStatusText("getclipboard unavailable")
            return
        end
        local ok, err = sm:clipboardLoad(self, BytecodeParser)
        if ok then
            self:setStatusText("Session restored from clipboard")
        else
            self:setStatusText("Clipboard load failed: " .. tostring(err))
        end
        return
    end
    -- File load — opts.filename is required for now
    if not opts.filename then
        self:setStatusText("File load needs a filename — paste with Ctrl+Shift+V")
        return
    end
    local ok, err = sm:loadFromFile(opts.filename, self, BytecodeParser)
    if ok then
        self:setStatusText("Session loaded from " .. opts.filename)
    else
        self:setStatusText("Load failed: " .. tostring(err))
    end
end

function Workspace:_listSessions()
    if not self.state.storage then return {} end
    local files = self.state.storage:list()
    local sessions = {}
    for _, name in files do
        if string.sub(name, -8) == ".idarblx" then
            sessions[#sessions + 1] = name
        end
    end
    table.sort(sessions)
    return sessions
end

function Workspace:_onConstantSelect(entry, kidx)
    -- For STRING / IMPORT constants we have natural XRef queries; for
    -- others (NUMBER, BOOLEAN, TABLE, etc.) there's no inverted bucket
    -- so we just report selection.
    if not entry or not entry.tag then return end
    if entry.tag == "STRING" then
        self:_onStringSelect(entry.value, nil)
    elseif entry.tag == "IMPORT" and entry.chain then
        self:setState({
            xrefQuery = {
                kind  = "import",
                key   = table.concat(entry.chain, "."),
                label = table.concat(entry.chain, "."),
            },
            bottomTab = "xrefs",
        })
    else
        self:setStatusText(string.format("K%d = %s (%s)",
            kidx - 1, tostring(entry.value), entry.tag or "?"))
    end
end

function Workspace:_onImportSelect(chain, count, sites)
    self:setState({
        xrefQuery = {
            kind  = "import",
            key   = chain,
            label = string.format("%s  · %d ref%s", chain, count, count == 1 and "" or "s"),
        },
        bottomTab = "xrefs",
    })
end

-- ---------------------------------------------------------------------
-- Menu / Toolbar definitions
-- ---------------------------------------------------------------------

function Workspace:_menuItems()
    return {
        { label = "File", submenu = {
            { label = "Open Script…", icon = "📂", action = "open-script",
              onClick = function() self._router:fireAction("open-script") end },
            { label = "Reload",       icon = "🔄", action = "reload",
              onClick = function() self._router:fireAction("reload") end },
            { separator = true },
            { label = "Quit", icon = "✕",
              onClick = function() if self.props.onQuit then pcall(self.props.onQuit) end end },
        } },
        { label = "Edit", submenu = {
            { label = "Find…",         icon = "🔍", action = "find",
              onClick = function() self._router:fireAction("find") end },
            { label = "Goto Proto…",   icon = "→",  action = "goto-proto",
              onClick = function() self._router:fireAction("goto-proto") end },
        } },
        { label = "View", submenu = {
            { label = "Toggle Graph ↔ Text", icon = "◇", action = "toggle-view",
              onClick = function() self._router:fireAction("toggle-view") end },
            { label = "Toggle Output",        icon = "⊞", action = "toggle-output",
              onClick = function() self._router:fireAction("toggle-output") end },
        } },
        { label = "Analysis", submenu = {
            { label = "Build CFG (auto)",        icon = "◇", disabled = true },
            { label = "Build XRefs (Step 7)",    disabled = true, icon = "→" },
            { label = "Decompile (Step 8)",      disabled = true, icon = "{}" },
        } },
        { label = "Help", submenu = {
            { label = "About IDARoblox", icon = "ⓘ",
              onClick = function() self:setStatusText("IDARoblox · static & runtime analysis for Roblox Luau") end },
        } },
    }
end

function Workspace:_toolbarGroups()
    return {
        {
            { icon = "📂", label = "Open",   action = "open-script", tooltip = "Open a Roblox script" },
            { icon = "🔄", label = "Reload", action = "reload",      tooltip = "Re-parse the current script" },
        },
        {
            { icon = "🔍", label = "Find",      action = "find",       tooltip = "Find in disassembly" },
            { icon = "→",  label = "Goto",      action = "goto-proto", tooltip = "Goto proto by id or name" },
        },
        {
            { icon = "◇", label = "Graph", action = "toggle-view",
              tooltip = "Toggle graph ↔ text (Space)",
              primary = self.state.viewMode == "graph",
              disabled = self.state.bytecode == nil },
        },
    }
end

function Workspace:_statusItems()
    local bc = self.state.bytecode
    if not bc then return { { icon = "ƒ", label = "no script" } } end
    local proto = self.state.selectedProtoId and bc.protos[self.state.selectedProtoId]
    local cfg   = self.state.currentCfg
    local items = {
        { icon = "ƒ", label = string.format("proto %s/%d",
            tostring(self.state.selectedProtoId or "?"), bc.stats.protos) },
        { icon = "ƒ", label = string.format("%d insn", proto and proto.sizecode or 0) },
    }
    if cfg then
        items[#items + 1] = { icon = "◇", label = string.format("%d blk", cfg.stats.blockCount) }
        if cfg.stats.loopCount > 0 then
            items[#items + 1] = { icon = "↻", label = string.format("%d loop", cfg.stats.loopCount) }
        end
    end
    if self.state.xrefIndex then
        items[#items + 1] = { icon = "→",
            label = string.format("%d xref", self.state.xrefIndex.stats.totalSites) }
    end
    if self.state.bookmarkCount > 0 then
        items[#items + 1] = { icon = "★",
            label = string.format("%d bkmk", self.state.bookmarkCount) }
    end
    items[#items + 1] = { icon = "k", label = string.format("%d k", bc.stats.totalConstants or 0) }
    return items
end

-- ---------------------------------------------------------------------
-- Render
-- ---------------------------------------------------------------------

function Workspace:render()
    local theme    = self.theme
    local menuH    = theme:size("menuBar")
    local toolbarH = theme:size("toolbar")
    local statusH  = theme:size("statusBar")
    local chromeTop = menuH + toolbarH
    local chromeBot = statusH

    -- Primary view: text disassembly OR control-flow graph OR pseudocode.
    local function primaryView(title)
        local mode = self.state.viewMode
        local content
        if mode == "graph" then
            content = e(GraphView, {
                cfg              = self.state.currentCfg,
                stream           = self.state.currentStream,
                selectedBlockId  = self.state.selectedBlockId,
                onSelectBlock = self._onBlockSelectFn,
                onActivateBlock = self._onBlockActivateFn,
                onMount = self._onGraphMount,
                onUnmount = self._onGraphUnmount,
            })
        elseif mode == "decomp" then
            content = e(PseudocodeView, {
                decompiler     = self.state.decompiler,
                protoId        = self.state.selectedProtoId,
                selectedLine   = self.state.selectedDecLine,
                onSelectLine = self._onDecLineSelect,
            })
        else
            content = e(DisassemblyView, {
                stream         = self.state.currentStream,
                selectedPc     = self.state.selectedPc,
                onSelectRow = self._onRowSelectFn,
                onActivateRow = self._onRowActivateFn,
                onMount = self._onDisasmMount,
                onUnmount = self._onDisasmUnmount,
            })
        end
        return e(Panel, { title = title }, { content })
    end

    local viewTitle
    if self.state.viewMode == "graph" then
        viewTitle = "Graph  (Space cycles)"
    elseif self.state.viewMode == "decomp" then
        viewTitle = "Pseudocode  (Space cycles · F5)"
    else
        viewTitle = "Disassembly  (Space cycles)"
    end

    -- Bottom panel: a tab strip + the active tab's view. All views
    -- are mounted simultaneously, with `Visible` toggling so per-view
    -- state (search text, scroll position, etc.) is preserved when the
    -- user flips between them.
    local function bottomPanel()
        local tabs = { "output", "strings", "names", "xrefs", "search",
                       "constants", "imports", "patterns", "hex", "hooks",
                       "functions", "closures", "gcheap", "heapgraph",
                       "network", "console", "plugins" }
        local labels = {
            output    = "Output",
            strings   = string.format("Strings (%d)",
                self.state.xrefIndex and self.state.xrefIndex.stats.uniqueStrings or 0),
            names     = string.format("Names (%d)",
                self.state.xrefIndex and #self.state.xrefIndex:namedProtos() or 0),
            xrefs     = self.state.xrefQuery and "XRefs •" or "XRefs",
            search    = "Search",
            constants = string.format("Const (%d)",
                self.state.bytecode and self.state.selectedProtoId ~= nil
                and self.state.bytecode.protos[self.state.selectedProtoId]
                and #(self.state.bytecode.protos[self.state.selectedProtoId].constants or {}) or 0),
            imports   = string.format("Imports (%d)",
                self.state.xrefIndex and self.state.xrefIndex.stats.uniqueImports or 0),
            patterns  = string.format("Patterns (%d)",
                self.state.patternMatcher and self.state.patternMatcher:stats().registered or 0),
            hex       = "Hex",
            hooks     = self.state.runtime
                and string.format("Hooks (%d)", self.state.runtime.hooks:stats().active)
                or "Hooks",
            functions = (self.state.runtime
                and type(self.state.runtime.fns) == "table"
                and type(self.state.runtime.fns.stats) == "function"
                and string.format("Functions (%d)",
                    (self.state.runtime.fns:stats() or {}).total or 0))
                or "Functions",
            closures  = "Closures",
            gcheap    = (self.state.runtime
                and type(self.state.runtime.gc) == "table"
                and type(self.state.runtime.gc.stats) == "function"
                and string.format("GC Heap (%d)",
                    (self.state.runtime.gc:stats() or {}).objectsSeen or 0))
                or "GC Heap",
            heapgraph = "Heap Graph",
            network   = (self.state.runtime
                and self.state.runtime.network
                and type(self.state.runtime.network.stats) == "function"
                and string.format("Net (%d)",
                    (self.state.runtime.network:stats() or {}).captured or 0))
                or "Net",
            console   = "Console",
            plugins   = (function()
                local p = self.props.pluginLoader or self.state.plugins
                if type(p) ~= "table" then return "Plugins" end
                -- The plugins surface may be either Plugins.PluginLoader
                -- (props, the canonical loader) or Analysis.Plugins (the
                -- older pass manager from state). Try several count
                -- surfaces; fall back to the plain label.
                local n
                if type(p.list) == "function" then
                    local ok, lst = pcall(p.list, p)
                    if ok and type(lst) == "table" then n = #lst end
                end
                if n == nil and type(p.count) == "function" then
                    local ok, c = pcall(p.count, p)
                    if ok and type(c) == "number" then n = c end
                end
                if n == nil and type(p.listPlugins) == "function" then
                    local ok, lst = pcall(p.listPlugins, p)
                    if ok and type(lst) == "table" then n = #lst end
                end
                if n then return string.format("Plugins (%d)", n) end
                return "Plugins"
            end)(),
        }
        local tabButtons = {}
        for i, id in tabs do
            local active = self.state.bottomTab == id
            tabButtons[i] = e("TextButton", {
                key              = "tab:" .. id,
                Size             = UDim2.fromOffset(88, 22),
                Text             = labels[id] or id,
                Font             = active and Enum.Font.GothamMedium or Enum.Font.Gotham,
                TextSize         = theme:size("font.ui") - 1,
                TextColor3       = active and theme:color("text") or theme:color("textMuted"),
                BackgroundColor3 = active and theme:color("surfaceAlt") or theme:color("background"),
                BorderSizePixel  = 0,
                AutoButtonColor  = false,
                LayoutOrder      = i,
                [Element.Event.Activated] = function()
                    self:setState({ bottomTab = id })
                end,
            }, {
                e("UICorner", { CornerRadius = UDim.new(0, theme:radius("sm")) }),
                active and e("Frame", {
                    Position         = UDim2.new(0, 0, 1, -2),
                    Size             = UDim2.new(1, 0, 0, 2),
                    BackgroundColor3 = theme:color("primary"),
                    BorderSizePixel  = 0,
                }),
            })
        end

        local TAB_STRIP_H = 28
        local function pane(id, view)
            return e("Frame", {
                key                    = "pane:" .. id,
                Position               = UDim2.fromOffset(0, TAB_STRIP_H),
                Size                   = UDim2.new(1, 0, 1, -TAB_STRIP_H),
                BackgroundTransparency = 1,
                Visible                = self.state.bottomTab == id,
            }, { view })
        end

        local currentProto = self.state.bytecode and self.state.selectedProtoId ~= nil
            and self.state.bytecode.protos[self.state.selectedProtoId] or nil

        return e("Frame", {
            Size             = UDim2.fromScale(1, 1),
            BackgroundColor3 = theme:color("background"),
            BorderSizePixel  = 0,
        }, {
            e("Frame", {
                key              = "tabstrip",
                Size             = UDim2.new(1, 0, 0, TAB_STRIP_H),
                BackgroundColor3 = theme:color("background"),
                BorderSizePixel  = 0,
            }, {
                e("UIPadding", {
                    PaddingLeft  = UDim.new(0, 6), PaddingRight = UDim.new(0, 6),
                    PaddingTop   = UDim.new(0, 3), PaddingBottom = UDim.new(0, 3),
                }),
                e("UIListLayout", {
                    FillDirection     = Enum.FillDirection.Horizontal,
                    VerticalAlignment = Enum.VerticalAlignment.Center,
                    SortOrder         = Enum.SortOrder.LayoutOrder,
                    Padding           = UDim.new(0, 4),
                }),
                Element.fragment(tabButtons),
            }),
            pane("output",  e(OutputView, { logger = self.logger })),
            pane("strings", e(StringsView, {
                xrefIndex      = self.state.xrefIndex,
                onSelectString = function(value, entry) self:_onStringSelect(value, entry) end,
            })),
            pane("names", e(NamesView, {
                xrefIndex       = self.state.xrefIndex,
                selectedProtoId = self.state.selectedProtoId,
                onSelectProto   = function(protoId, entry) self:_onNameSelect(protoId, entry) end,
            })),
            pane("xrefs", e(XRefView, {
                xrefIndex    = self.state.xrefIndex,
                query        = self.state.xrefQuery,
                onJumpToSite = function(protoId, pc, site) self:_onXrefJump(protoId, pc, site) end,
                onClearQuery = self._onClearXrefQuery,
            })),
            pane("search", e(SearchView, {
                bytecode     = self.state.bytecode,
                disassembler = self.state.disassembler,
                xrefIndex    = self.state.xrefIndex,
                onJumpToSite = function(protoId, pc, hit) self:_onXrefJump(protoId, pc, hit) end,
            })),
            pane("constants", e(ConstantsView, {
                proto             = currentProto,
                onSelectConstant  = function(entry, kidx) self:_onConstantSelect(entry, kidx) end,
            })),
            pane("imports", e(ImportsView, {
                xrefIndex     = self.state.xrefIndex,
                onSelectChain = function(chain, count, sites) self:_onImportSelect(chain, count, sites) end,
            })),
            pane("patterns", e(PatternsView, {
                matcher       = self.state.patternMatcher,
                bytecode      = self.state.bytecode,
                disassembler  = self.state.disassembler,
                onJumpToMatch = function(protoId, pc, match) self:_onXrefJump(protoId, pc, match) end,
            })),
            pane("hex", e(HexView, {
                proto      = currentProto,
                selectedPc = self.state.selectedPc,
                onSelectPc = function(pc, row) self:_onRowSelect(pc, row) end,
            })),
            pane("hooks", e(HooksView, {
                runtime = self.state.runtime,
            })),
            pane("functions", e(FunctionsView, {
                runtime = self.state.runtime,
                onCopyResult = self._onCopyResult,
            })),
            pane("closures", e(ClosuresView, {
                runtime = self.state.runtime,
                onCopyResult = self._onCopyResult,
            })),
            pane("gcheap", e(GCHeapView, {
                runtime = self.state.runtime,
                onCopyResult = self._onCopyResult,
            })),
            pane("heapgraph", e(HeapGraphView, {
                runtime = self.state.runtime,
                onCopyResult = self._onCopyResult,
            })),
            pane("network", e(NetworkView, {
                tracer = self.state.runtime and self.state.runtime.network,
                onCopyResult = self._onCopyResult,
            })),
            pane("console", e(ConsoleView, {
                onCopyResult = self._onCopyResult,
            })),
            pane("plugins", e(PluginManagerView, {
                loader   = self.props.pluginLoader or self.state.plugins,
                bytecode = self.state.bytecode,
                onCopyResult = self._onCopyResult,
            })),
            e("Frame", {
                key              = "tabborder",
                Position         = UDim2.fromOffset(0, TAB_STRIP_H - 1),
                Size             = UDim2.new(1, 0, 0, 1),
                BackgroundColor3 = theme:color("border"),
                BorderSizePixel  = 0,
            }),
        })
    end

    -- The middle workspace area is a horizontal Splitter:
    --   left  = ProtoTreeView (in a Panel)
    --   right = vertical Splitter (primary view / bottom panel)
    local rightSide
    if self.state.showOutput then
        rightSide = e(Splitter, {
            orientation = "vertical",
            ratio       = self.state.outputRatio,
            minFirst    = 120,
            minSecond   = 120,
            onResize    = function(r) self.state.outputRatio = r end,
        }, {
            primaryView(viewTitle),
            bottomPanel(),
        })
    else
        rightSide = primaryView(viewTitle)
    end

    local body = e(Splitter, {
        orientation = "horizontal",
        ratio       = self.state.treeRatio,
        minFirst    = 180,
        minSecond   = 260,
        onResize    = function(r) self.state.treeRatio = r end,
    }, {
        -- Left: ProtoTree
        e(Panel, { title = "Functions" }, {
            e(ProtoTreeView, {
                bytecode        = self.state.bytecode,
                selectedProtoId = self.state.selectedProtoId,
                onSelect        = function(id) self:_onProtoSelect(id) end,
                onOpen          = function(id) self:_onProtoOpen(id) end,
            }),
        }),
        rightSide,
    })

    return e("Frame", {
        Size             = UDim2.fromScale(1, 1),
        BackgroundColor3 = theme:color("background"),
        BorderSizePixel  = 0,
    }, {
        -- Menu
        e(Menu, {
            key      = "menu",
            items    = self:_menuItems(),
            router   = self._router,
            Position = UDim2.fromOffset(0, 0),
        }),
        -- Toolbar
        e(Toolbar, {
            key      = "toolbar",
            groups   = self:_toolbarGroups(),
            router   = self._router,
            Position = UDim2.fromOffset(0, menuH),
        }),
        -- Optional busy progress bar inset along the bottom of the toolbar
        self.state.runningBusy and e("Frame", {
            key              = "busybar",
            Position         = UDim2.fromOffset(0, menuH + toolbarH - 2),
            Size             = UDim2.new(1, 0, 0, 2),
            BackgroundTransparency = 1,
            ZIndex           = 6,
        }, {
            e(ProgressBar, {
                value           = self.state.runningProgress,
                height          = 2,
                rounded         = false,
                animateDuration = 0.15,
            }),
        }),
        -- Body
        e("Frame", {
            key              = "body",
            Position         = UDim2.fromOffset(0, chromeTop),
            Size             = UDim2.new(1, 0, 1, -(chromeTop + chromeBot)),
            BackgroundTransparency = 1,
            ClipsDescendants = true,
            ZIndex           = 2,
        }, { body }),
        -- StatusBar
        e(StatusBar, {
            key        = "status",
            statusText = self.state.statusText,
            items      = self:_statusItems(),
            showFps    = true,
            Position   = UDim2.new(0, 0, 1, -statusH),
        }),
        -- Modal Dialog (e.g. Goto Proto). Rendered last so it overlays everything.
        self.state.dialog and e(Dialog, {
            key         = "dialog:" .. (self.state.dialog.kind or "?"),
            title       = self.state.dialog.title,
            label       = self.state.dialog.label,
            placeholder = self.state.dialog.placeholder,
            initialText = self.state.dialog.initialText,
            submitLabel = self.state.dialog.submitLabel,
            cancelLabel = self.state.dialog.cancelLabel,
            onSubmit    = self.state.dialog.onSubmit,
            onCancel    = self.state.dialog.onCancel,
        }) or nil,
    })
end

return Workspace
