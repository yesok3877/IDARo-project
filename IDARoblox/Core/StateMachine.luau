--!nonstrict
-- =====================================================================
-- IDARoblox / Core / StateMachine
-- ---------------------------------------------------------------------
-- A flat finite state machine with:
--   * Per-state onEnter / onExit hooks (sync or async via Promise)
--   * Event-driven transitions with guard predicates
--   * Optional transition data payload (passed to onExit/onEnter)
--   * Bounded history of recent transitions for diagnostics
--   * Optional EventBus integration: emits 'sm.<name>.transition' events
--   * Strict validation: refuses transitions not declared in the table
--
-- The FSM is the backbone of module lifecycle in the Kernel:
--   Unloaded → Loading → Ready
--             ↘ Error  ↗ (reset)
-- =====================================================================

local StateMachine = {}
StateMachine.__index = StateMachine

-- ---------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------
-- definition = {
--   name = "ModuleLifecycle",
--   initial = "Unloaded",
--   states = {
--     Unloaded = { onEnter = fn, onExit = fn },
--     Loading  = { onEnter = fn, onExit = fn },
--     Ready    = { onEnter = fn, onExit = fn },
--     Error    = { onEnter = fn, onExit = fn },
--   },
--   transitions = {
--     { from = "Unloaded", to = "Loading", on = "load",  guard = fn? },
--     { from = "Loading",  to = "Ready",   on = "ready"           },
--     { from = "Loading",  to = "Error",   on = "fail"            },
--     { from = "Ready",    to = "Unloaded",on = "unload"          },
--     { from = "*",        to = "Error",   on = "fail"            },  -- wildcard
--   },
--   historyCap = 32,
--   eventBus = optional,
-- }

function StateMachine.new(def)
    if not def or type(def) ~= "table" then
        error("StateMachine: definition table required", 2)
    end
    if not def.initial then error("StateMachine: 'initial' state required", 2) end
    if not def.states or not def.states[def.initial] then
        error("StateMachine: initial state must exist in 'states'", 2)
    end

    local self = setmetatable({
        _name        = def.name or "FSM",
        _states      = def.states,
        _transitions = def.transitions or {},
        _current     = def.initial,
        _previous    = nil,
        _history     = table.create(def.historyCap or 32),
        _historyCap  = def.historyCap or 32,
        _eventBus    = def.eventBus,
        _onError     = def.onError,
        _logger      = def.logger,
        _locked      = false,                                       -- prevents reentrant transition
        _byEvent     = {},                                          -- event → array of transitions (precomputed)
    }, StateMachine)
    self:_indexTransitions()
    -- Fire initial state onEnter
    local stateDef = self._states[self._current]
    if stateDef.onEnter then
        local ok, err = pcall(stateDef.onEnter, self, nil, self._current)
        if not ok and self._onError then pcall(self._onError, err) end
    end
    return self
end

function StateMachine:_indexTransitions()
    local by = {}
    for _, t in self._transitions do
        local ev = t.on or "<transition>"
        by[ev] = by[ev] or table.create(2)
        table.insert(by[ev], t)
    end
    self._byEvent = by
end

-- ---------------------------------------------------------------------
-- Queries
-- ---------------------------------------------------------------------

function StateMachine:current(): string return self._current end
function StateMachine:previous(): string? return self._previous end

function StateMachine:is(name: string): boolean return self._current == name end

function StateMachine:can(event: string): boolean
    local list = self._byEvent[event]
    if not list then return false end
    for _, t in list do
        if (t.from == "*" or t.from == self._current)
            and (not t.guard or t.guard(self, self._current)) then
            return true
        end
    end
    return false
end

function StateMachine:availableEvents(): { string }
    local out = {}
    for ev in self._byEvent do
        if self:can(ev) then out[#out + 1] = ev end
    end
    return out
end

function StateMachine:history(): { any }
    local out = table.create(#self._history)
    for i, h in self._history do out[i] = h end
    return out
end

-- ---------------------------------------------------------------------
-- Transition
-- ---------------------------------------------------------------------

function StateMachine:fire(event: string, data: any?)
    if self._locked then
        error(string.format("StateMachine '%s': nested fire('%s') not allowed", self._name, event), 2)
    end
    local list = self._byEvent[event]
    if not list then
        if self._logger then
            self._logger:debug("FSM[%s]: no transition for event '%s' from '%s'",
                self._name, event, self._current)
        end
        return false, "no_transition"
    end
    local chosen
    for _, t in list do
        if (t.from == "*" or t.from == self._current)
            and (not t.guard or t.guard(self, self._current, data)) then
            chosen = t
            break
        end
    end
    if not chosen then
        if self._logger then
            self._logger:debug("FSM[%s]: event '%s' rejected from '%s' (guard or wrong source)",
                self._name, event, self._current)
        end
        return false, "rejected"
    end

    self._locked = true
    local from = self._current
    local to = chosen.to

    -- Exit hook
    local fromDef = self._states[from]
    if fromDef and fromDef.onExit then
        local ok, err = pcall(fromDef.onExit, self, from, to, data)
        if not ok then
            self._locked = false
            if self._onError then pcall(self._onError, err) end
            return false, err
        end
    end

    -- Transition action
    if chosen.action then
        local ok, err = pcall(chosen.action, self, from, to, data)
        if not ok then
            self._locked = false
            if self._onError then pcall(self._onError, err) end
            return false, err
        end
    end

    self._previous = from
    self._current = to

    -- Record history
    table.insert(self._history, {
        from = from, to = to, event = event,
        at = os.clock(), data = data,
    })
    if #self._history > self._historyCap then
        table.remove(self._history, 1)
    end

    -- Enter hook
    local toDef = self._states[to]
    if toDef and toDef.onEnter then
        local ok, err = pcall(toDef.onEnter, self, from, to, data)
        if not ok then
            self._locked = false
            if self._onError then pcall(self._onError, err) end
            return false, err
        end
    end

    -- EventBus broadcast
    if self._eventBus then
        self._eventBus:emit("sm." .. self._name .. ".transition",
            { from = from, to = to, event = event, data = data })
        self._eventBus:emit("sm." .. self._name .. ".enter." .. to,
            { from = from, data = data })
    end

    if self._logger then
        self._logger:debug("FSM[%s]: %s -- %s --> %s", self._name, from, event, to)
    end

    self._locked = false
    return true, to
end

-- Force a direct state set, bypassing transitions (for restore-from-save).
function StateMachine:forceSet(target: string)
    if not self._states[target] then
        error("StateMachine: unknown state '" .. target .. "'", 2)
    end
    self._previous = self._current
    self._current = target
end

return StateMachine
