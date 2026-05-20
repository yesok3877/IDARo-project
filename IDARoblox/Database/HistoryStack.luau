--!nonstrict
-- =====================================================================
-- IDARoblox / Database / HistoryStack
-- ---------------------------------------------------------------------
-- Undo/redo via the command pattern. Every mutation in ProjectDB goes
-- through HistoryStack:execute(cmd), which calls cmd.apply() to perform
-- the change and stores the (apply, revert) pair so the operation can
-- be reversed later. Undo invokes cmd.revert(), redo re-applies.
--
-- A command:
--   {
--     kind         = "symbol.rename" | "comment.add" | …      (free-form)
--     label        = "rename 'foo' → 'bar'"                    (UI text)
--     apply        = function() … end                          (required)
--     revert       = function() … end                          (required)
--     coalesceKey  = "rename:42"  (optional — merges with the previous
--                                  command if same key + within window)
--     timestamp    = filled by execute()
--   }
--
-- Composite commands (transactions) are produced by `transaction`:
--   undo:    runs children's revert in original order
--   apply:   re-runs children's apply in reverse-of-revert order
--
-- Suppression flag: `isSuppressed()` returns true while a revert/apply
-- is in flight. Stores observing the history use this to skip recording
-- nested commands during undo/redo. Without this, undoing an action
-- would itself create a new redo entry, breaking the stack semantics.
--
-- Events: history.executed, history.undone, history.redone, history.cleared.
-- =====================================================================

local HistoryStack = {}
HistoryStack.__index = HistoryStack

local DEFAULT_MAX_DEPTH       = 500
local DEFAULT_COALESCE_WINDOW = 0.5                                  -- seconds

-- ---------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------

function HistoryStack.new(opts)
    opts = opts or {}
    return setmetatable({
        _undo            = {},
        _redo            = {},
        _maxDepth        = opts.maxDepth or DEFAULT_MAX_DEPTH,
        _coalesceWindow  = opts.coalesceWindow or DEFAULT_COALESCE_WINDOW,
        _eventBus        = opts.eventBus,
        _logger          = opts.logger,
        _suppressed      = 0,                                        -- nesting counter
        _txStack         = {},                                       -- in-flight transaction marks
        _stats = {
            executed = 0,
            undone   = 0,
            redone   = 0,
            coalesced = 0,
            evicted   = 0,
            txCount   = 0,
            rollbacks = 0,
        },
    }, HistoryStack)
end

local function emit(self, evt, payload)
    if self._eventBus and type(self._eventBus.emit) == "function" then
        pcall(self._eventBus.emit, self._eventBus, evt, payload)
    end
end

-- ---------------------------------------------------------------------
-- Validation helpers
-- ---------------------------------------------------------------------

local function validateCommand(cmd)
    if type(cmd) ~= "table" then return false, "command must be a table" end
    if type(cmd.apply)  ~= "function" then return false, "cmd.apply must be a function"  end
    if type(cmd.revert) ~= "function" then return false, "cmd.revert must be a function" end
    return true
end

-- ---------------------------------------------------------------------
-- Suppression — used by stores to detect "I'm running inside an
-- already-recorded apply/revert, don't record this as a new command".
-- ---------------------------------------------------------------------

function HistoryStack:isSuppressed() return self._suppressed > 0 end

function HistoryStack:_enterSuppressed()
    self._suppressed = self._suppressed + 1
end
function HistoryStack:_exitSuppressed()
    self._suppressed = self._suppressed - 1
end

-- ---------------------------------------------------------------------
-- Coalesce
-- ---------------------------------------------------------------------

local function tryCoalesce(self, cmd)
    if not cmd.coalesceKey then return false end
    local prev = self._undo[#self._undo]
    if not prev or prev.kind == "composite" then return false end
    if prev.coalesceKey ~= cmd.coalesceKey then return false end
    if (cmd.timestamp - (prev.timestamp or 0)) > self._coalesceWindow then return false end

    -- Merge semantics:
    --   apply  ← cmd.apply         (latest user action)
    --   revert ← prev.revert       (rolls all the way back to before the first)
    -- We retain prev's `revert` so a single undo unwinds the entire coalesced burst.
    prev.apply       = cmd.apply
    prev.label       = cmd.label or prev.label
    prev.timestamp   = cmd.timestamp
    prev.coalesceCount = (prev.coalesceCount or 1) + 1
    self._stats.coalesced = self._stats.coalesced + 1
    return true
end

-- ---------------------------------------------------------------------
-- Execute
-- ---------------------------------------------------------------------

function HistoryStack:execute(cmd)
    local ok, err = validateCommand(cmd)
    if not ok then error("HistoryStack:execute — " .. err, 2) end

    -- Apply with suppression so the apply path doesn't recursively record.
    self:_enterSuppressed()
    local applyOk, applyErr = pcall(cmd.apply)
    self:_exitSuppressed()
    if not applyOk then
        if self._logger then
            self._logger:error("HistoryStack: apply failed: %s", tostring(applyErr))
        end
        error("HistoryStack: apply failed: " .. tostring(applyErr), 2)
    end

    cmd.timestamp = os.clock()
    cmd.coalesceCount = 1
    self._stats.executed = self._stats.executed + 1

    -- If we're inside a transaction, just push to the in-flight list and
    -- defer wrapping until commit.
    if #self._txStack > 0 then
        local tx = self._txStack[#self._txStack]
        tx.children[#tx.children + 1] = cmd
        emit(self, "history.executed", cmd)
        return
    end

    if not tryCoalesce(self, cmd) then
        self._undo[#self._undo + 1] = cmd
        while #self._undo > self._maxDepth do
            table.remove(self._undo, 1)
            self._stats.evicted = self._stats.evicted + 1
        end
    end
    -- New action invalidates redo stack.
    if #self._redo > 0 then self._redo = {} end
    emit(self, "history.executed", cmd)
end

-- ---------------------------------------------------------------------
-- Undo / Redo
-- ---------------------------------------------------------------------

function HistoryStack:undo()
    if #self._txStack > 0 then
        error("HistoryStack:undo called inside transaction", 2)
    end
    local cmd = self._undo[#self._undo]
    if not cmd then return false end
    self._undo[#self._undo] = nil
    self:_enterSuppressed()
    local ok, err = pcall(cmd.revert)
    self:_exitSuppressed()
    if not ok then
        -- Put it back; user can retry. Surface the error.
        self._undo[#self._undo + 1] = cmd
        if self._logger then
            self._logger:error("HistoryStack: revert failed: %s", tostring(err))
        end
        error("HistoryStack: revert failed: " .. tostring(err), 2)
    end
    self._redo[#self._redo + 1] = cmd
    self._stats.undone = self._stats.undone + 1
    emit(self, "history.undone", cmd)
    return true
end

function HistoryStack:redo()
    if #self._txStack > 0 then
        error("HistoryStack:redo called inside transaction", 2)
    end
    local cmd = self._redo[#self._redo]
    if not cmd then return false end
    self._redo[#self._redo] = nil
    self:_enterSuppressed()
    local ok, err = pcall(cmd.apply)
    self:_exitSuppressed()
    if not ok then
        self._redo[#self._redo + 1] = cmd
        if self._logger then
            self._logger:error("HistoryStack: redo apply failed: %s", tostring(err))
        end
        error("HistoryStack: redo apply failed: " .. tostring(err), 2)
    end
    self._undo[#self._undo + 1] = cmd
    self._stats.redone = self._stats.redone + 1
    emit(self, "history.redone", cmd)
    return true
end

-- ---------------------------------------------------------------------
-- Transactions
-- ---------------------------------------------------------------------

-- `transaction(label, fn)` wraps every command executed inside fn into a
-- single composite undo unit. If fn errors, every command that was
-- executed before the error is reverted in reverse order, and the error
-- propagates. Nested transactions push onto a stack — only the outermost
-- one commits.
function HistoryStack:transaction(label, fn)
    if type(fn) ~= "function" then
        error("HistoryStack:transaction requires a function", 2)
    end
    local tx = { label = label or "transaction", children = {}, openedAt = os.clock() }
    self._txStack[#self._txStack + 1] = tx
    self._stats.txCount = self._stats.txCount + 1

    local ok, err = pcall(fn)

    -- Pop our frame regardless
    self._txStack[#self._txStack] = nil

    if not ok then
        -- Rollback every executed child in reverse order. Suppression
        -- prevents the reverts from recording themselves.
        self._stats.rollbacks = self._stats.rollbacks + 1
        self:_enterSuppressed()
        for i = #tx.children, 1, -1 do
            pcall(tx.children[i].revert)
        end
        self:_exitSuppressed()
        if self._logger then
            self._logger:warn("HistoryStack: transaction '%s' rolled back: %s",
                tx.label, tostring(err))
        end
        error(err, 2)
    end

    if #tx.children == 0 then return end                             -- no-op tx

    -- If we're still inside an outer transaction, just append our
    -- children directly so the outer composite owns them.
    if #self._txStack > 0 then
        local outer = self._txStack[#self._txStack]
        for _, c in tx.children do outer.children[#outer.children + 1] = c end
        return
    end

    -- Single-child tx: don't wrap, just keep the bare command (cheaper).
    if #tx.children == 1 then
        local single = tx.children[1]
        single.label = tx.label or single.label
        self._undo[#self._undo + 1] = single
        while #self._undo > self._maxDepth do
            table.remove(self._undo, 1)
            self._stats.evicted = self._stats.evicted + 1
        end
        if #self._redo > 0 then self._redo = {} end
        return
    end

    -- Build composite. Capture children by upvalue so they can't be
    -- mutated externally.
    local children = tx.children
    local composite = {
        kind        = "composite",
        label       = tx.label,
        children    = children,
        coalesceKey = nil,
        timestamp   = os.clock(),
        apply = function()
            -- Re-apply in the original order; suppression is set at the
            -- HistoryStack level around the outer call, but apply is also
            -- called during redo, so we don't need anything special here.
            for i = 1, #children do children[i].apply() end
        end,
        revert = function()
            for i = #children, 1, -1 do children[i].revert() end
        end,
    }
    self._undo[#self._undo + 1] = composite
    while #self._undo > self._maxDepth do
        table.remove(self._undo, 1)
        self._stats.evicted = self._stats.evicted + 1
    end
    if #self._redo > 0 then self._redo = {} end
    emit(self, "history.executed", composite)
end

-- ---------------------------------------------------------------------
-- Inspection
-- ---------------------------------------------------------------------

function HistoryStack:canUndo() return #self._undo > 0 end
function HistoryStack:canRedo() return #self._redo > 0 end

function HistoryStack:undoDepth() return #self._undo end
function HistoryStack:redoDepth() return #self._redo end

function HistoryStack:peekUndo() return self._undo[#self._undo] end
function HistoryStack:peekRedo() return self._redo[#self._redo] end

function HistoryStack:labels()
    -- Returns (undoLabels, redoLabels) for UI menus.
    local u, r = {}, {}
    for i = #self._undo, 1, -1 do u[#u + 1] = self._undo[i].label or self._undo[i].kind or "?" end
    for i = #self._redo, 1, -1 do r[#r + 1] = self._redo[i].label or self._redo[i].kind or "?" end
    return u, r
end

function HistoryStack:clear()
    self._undo = {}
    self._redo = {}
    emit(self, "history.cleared", nil)
end

function HistoryStack:setMaxDepth(n)
    self._maxDepth = math.max(1, math.floor(n))
    while #self._undo > self._maxDepth do
        table.remove(self._undo, 1)
        self._stats.evicted = self._stats.evicted + 1
    end
end

function HistoryStack:stats()
    return {
        undoDepth      = #self._undo,
        redoDepth      = #self._redo,
        maxDepth       = self._maxDepth,
        executed       = self._stats.executed,
        undone         = self._stats.undone,
        redone         = self._stats.redone,
        coalesced      = self._stats.coalesced,
        evicted        = self._stats.evicted,
        txCount        = self._stats.txCount,
        rollbacks      = self._stats.rollbacks,
        inTransaction  = #self._txStack > 0,
        suppressed     = self:isSuppressed(),
    }
end

return HistoryStack
