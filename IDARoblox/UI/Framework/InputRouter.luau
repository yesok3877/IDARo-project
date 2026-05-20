--!nonstrict
-- =====================================================================
-- IDARoblox / UI / Framework / InputRouter
-- ---------------------------------------------------------------------
-- Centralised keyboard-shortcut dispatch + focus tracking.
--
-- Usage:
--   local router = InputRouter.new()
--   router:bind("Ctrl+S",       "save",            function() … end)
--   router:bind("Ctrl+Shift+P", "command-palette", function() … end)
--   router:bind("F5",           "reload",          function() … end)
--
--   -- Scoped bindings only fire when that scope has focus:
--   router:bindScoped("disasm", "Enter", "follow-jump", function() … end)
--   router:setFocus("disasm")
--
-- Chord syntax: "[Ctrl+][Alt+][Shift+][Meta+]<Key>"
--   * Modifiers in any order, case-insensitive
--   * Key is anything in Enum.KeyCode (e.g. "P", "F5", "Return", "Slash")
--
-- Each binding declares an action id ("save", "reload"…) so callers can
-- look up the current chord for a known action (used by Menu/Toolbar to
-- render the shortcut next to its label).
-- =====================================================================

local UserInputService = game:GetService("UserInputService")

local InputRouter = {}
InputRouter.__index = InputRouter

-- ---------------------------------------------------------------------
-- Chord parsing
-- ---------------------------------------------------------------------

local MOD_NAMES = { ctrl = true, alt = true, shift = true, meta = true }

-- Returns a canonical chord key like "ctrl+shift+p" from a user input
-- string. Modifiers ordered ctrl/alt/shift/meta for stable matching.
local function parseChord(input: string): (string?, { [string]: boolean }?, string?)
    if type(input) ~= "string" or input == "" then return nil end
    local mods = { ctrl = false, alt = false, shift = false, meta = false }
    local key
    for part in string.gmatch(input, "[^%+]+") do
        local lower = string.lower(part)
        if MOD_NAMES[lower] then
            mods[lower] = true
        else
            -- Preserve original casing for the key itself
            key = part
        end
    end
    if not key then return nil end

    local norm = {}
    if mods.ctrl  then norm[#norm + 1] = "ctrl"  end
    if mods.alt   then norm[#norm + 1] = "alt"   end
    if mods.shift then norm[#norm + 1] = "shift" end
    if mods.meta  then norm[#norm + 1] = "meta"  end
    norm[#norm + 1] = string.lower(key)
    return table.concat(norm, "+"), mods, key
end

-- Build the chord key for an actual InputObject + modifier state.
local function chordOfInput(keyCode: Enum.KeyCode): string
    local parts = {}
    if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl)
        or UserInputService:IsKeyDown(Enum.KeyCode.RightControl) then
        parts[#parts + 1] = "ctrl"
    end
    if UserInputService:IsKeyDown(Enum.KeyCode.LeftAlt)
        or UserInputService:IsKeyDown(Enum.KeyCode.RightAlt) then
        parts[#parts + 1] = "alt"
    end
    if UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
        or UserInputService:IsKeyDown(Enum.KeyCode.RightShift) then
        parts[#parts + 1] = "shift"
    end
    if UserInputService:IsKeyDown(Enum.KeyCode.LeftMeta)
        or UserInputService:IsKeyDown(Enum.KeyCode.RightMeta) then
        parts[#parts + 1] = "meta"
    end
    parts[#parts + 1] = string.lower(keyCode.Name)
    return table.concat(parts, "+")
end

-- ---------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------

function InputRouter.new(opts)
    opts = opts or {}
    local self = setmetatable({
        _logger     = opts.logger,
        _globalBindings = {},                                       -- chordKey → Binding
        _scopes     = {},                                           -- scopeName → { chordKey → Binding }
        _scopeOrder = {},                                           -- ordered scope-name list (top = highest priority)
        _focusStack = {},                                           -- stack of focused-scope names
        _enabled    = true,
        _conn       = nil,
        _onChord    = {},                                           -- subscribers (raw chord listeners)
    }, InputRouter)

    -- Hook into UserInputService.
    self._conn = UserInputService.InputBegan:Connect(function(input, processed)
        if processed then return end                                -- typed into TextBox etc.
        if not self._enabled then return end
        if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
        self:_handleKey(input.KeyCode)
    end)
    return self
end

function InputRouter:destroy()
    if self._conn then self._conn:Disconnect() end
    self._conn = nil
end

function InputRouter:setEnabled(v: boolean)
    self._enabled = v
end

-- ---------------------------------------------------------------------
-- Binding registry
-- ---------------------------------------------------------------------

local function bindIn(self, table_, chord: string, action: string?, handler, opts)
    local norm = parseChord(chord)
    if not norm then
        error("InputRouter: invalid chord '" .. tostring(chord) .. "'", 3)
    end
    table_[norm] = {
        chord     = chord,
        normChord = norm,
        action    = action,
        handler   = handler,
        consumes  = (opts and opts.consumes) ~= false,              -- default: consume input
        priority  = (opts and opts.priority) or 0,
        ttl       = (opts and opts.ttl),                            -- optional auto-expire counter
    }
    return norm
end

function InputRouter:bind(chord, action, handler, opts)
    if type(action) == "function" and handler == nil then
        -- Allow router:bind(chord, fn) with no action id
        handler = action
        action = nil
    end
    return bindIn(self, self._globalBindings, chord, action, handler, opts)
end

function InputRouter:bindScoped(scope, chord, action, handler, opts)
    if type(action) == "function" and handler == nil then
        handler = action
        action = nil
    end
    if not self._scopes[scope] then
        self._scopes[scope] = {}
    end
    return bindIn(self._scopes[scope], scope, chord, action, handler, opts)
end

-- Actually scopes use a slightly different table layout; let me wire properly.
function InputRouter:bindScoped(scope, chord, action, handler, opts)
    if type(action) == "function" and handler == nil then
        handler = action
        action = nil
    end
    if not self._scopes[scope] then
        self._scopes[scope] = {}
    end
    return bindIn(self, self._scopes[scope], chord, action, handler, opts)
end

function InputRouter:unbind(chord)
    local norm = parseChord(chord)
    if not norm then return end
    self._globalBindings[norm] = nil
    for _, scopeTable in self._scopes do
        scopeTable[norm] = nil
    end
end

function InputRouter:unbindAllInScope(scope: string)
    self._scopes[scope] = nil
end

-- ---------------------------------------------------------------------
-- Focus management
-- ---------------------------------------------------------------------

function InputRouter:setFocus(scope: string)
    -- Single-element stack (most common case).
    self._focusStack = scope and { scope } or {}
end

function InputRouter:pushFocus(scope: string)
    table.insert(self._focusStack, scope)
end

function InputRouter:popFocus()
    table.remove(self._focusStack)
end

function InputRouter:currentFocus(): string?
    return self._focusStack[#self._focusStack]
end

-- ---------------------------------------------------------------------
-- Lookups (for Menu/Toolbar to render shortcut text)
-- ---------------------------------------------------------------------

function InputRouter:chordForAction(action: string): string?
    for _, b in self._globalBindings do
        if b.action == action then return b.chord end
    end
    for _, scopeTable in self._scopes do
        for _, b in scopeTable do
            if b.action == action then return b.chord end
        end
    end
    return nil
end

function InputRouter:fireAction(action: string, ...): boolean
    for _, b in self._globalBindings do
        if b.action == action then
            local ok, err = pcall(b.handler, ...)
            if not ok and self._logger then
                self._logger:warn("InputRouter action '%s' handler error: %s",
                    action, tostring(err))
            end
            return true
        end
    end
    for _, scopeTable in self._scopes do
        for _, b in scopeTable do
            if b.action == action then
                local ok, err = pcall(b.handler, ...)
                if not ok and self._logger then
                    self._logger:warn("InputRouter action '%s' handler error: %s",
                        action, tostring(err))
                end
                return true
            end
        end
    end
    return false
end

-- ---------------------------------------------------------------------
-- Raw-chord subscribers (e.g. command-palette debug overlay)
-- ---------------------------------------------------------------------

function InputRouter:onChord(fn): { disconnect: () -> () }
    table.insert(self._onChord, fn)
    return {
        disconnect = function()
            for i, f in self._onChord do
                if f == fn then table.remove(self._onChord, i) return end
            end
        end,
    }
end

-- ---------------------------------------------------------------------
-- Dispatch
-- ---------------------------------------------------------------------

function InputRouter:_handleKey(keyCode: Enum.KeyCode)
    -- Ignore lone modifier presses (Ctrl/Alt/Shift/Meta).
    local n = keyCode.Name
    if n == "LeftControl" or n == "RightControl"
        or n == "LeftAlt" or n == "RightAlt"
        or n == "LeftShift" or n == "RightShift"
        or n == "LeftMeta" or n == "RightMeta" then
        return
    end

    local chord = chordOfInput(keyCode)

    -- Notify raw subscribers (debug overlay etc.) without consumption.
    for _, fn in self._onChord do
        local ok, err = pcall(fn, chord, keyCode)
        if not ok and self._logger then
            self._logger:warn("InputRouter chord-listener error: %s", tostring(err))
        end
    end

    -- Try focused scopes first (most-specific has highest priority).
    for i = #self._focusStack, 1, -1 do
        local scope = self._focusStack[i]
        local tbl = self._scopes[scope]
        if tbl then
            local b = tbl[chord]
            if b and self:_invoke(b) and b.consumes then return end
        end
    end

    -- Then global.
    local b = self._globalBindings[chord]
    if b then self:_invoke(b) end
end

function InputRouter:_invoke(b): boolean
    local ok, err = pcall(b.handler)
    if not ok and self._logger then
        self._logger:warn("InputRouter binding '%s' (%s) error: %s",
            b.chord, b.action or "?", tostring(err))
    end
    if b.ttl then
        b.ttl = b.ttl - 1
        if b.ttl <= 0 then
            self._globalBindings[b.normChord] = nil
            for _, scopeTable in self._scopes do
                if scopeTable[b.normChord] == b then scopeTable[b.normChord] = nil end
            end
        end
    end
    return ok
end

return InputRouter
