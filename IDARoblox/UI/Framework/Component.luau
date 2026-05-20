--!nonstrict
-- =====================================================================
-- IDARoblox / UI / Framework / Component
-- ---------------------------------------------------------------------
-- React/Roact-style class components.
--
--   local MyComp = Component.extend("MyComp")
--
--   function MyComp:init(props)
--       self.state = { count = 0 }
--   end
--
--   function MyComp:render()
--       return e("Frame", { Size = ... }, {
--           e("TextLabel", { Text = "n=" .. self.state.count })
--       })
--   end
--
--   function MyComp:didMount()
--       self.conn = bus:on("foo", function() self:setState({...}) end)
--   end
--
--   function MyComp:willUnmount()
--       self.conn:disconnect()
--   end
--
-- The Renderer instantiates the component, injects self.props,
-- self.theme, self._renderer, self._node, and calls init() then
-- render(). It also drives lifecycle calls on mount/update/unmount.
--
-- setState() can take either a partial table to merge OR a function
-- (state) -> partialTable. Updates batch within the same frame via
-- task.defer so multiple setState() calls in a single handler trigger
-- only one re-render.
-- =====================================================================

local Component = {}
Component.__index = Component

-- Marker that Element.create checks to distinguish components from raw classes.
Component.__isComponentClass = true

-- ---------------------------------------------------------------------
-- extend(name) — create a new component class
-- ---------------------------------------------------------------------

function Component.extend(name: string)
    if type(name) ~= "string" or name == "" then
        error("Component.extend: name must be a non-empty string", 2)
    end
    local cls = setmetatable({
        __isComponentClass = true,
        __componentName    = name,
        __defaultProps     = nil,
    }, { __index = Component })
    cls.__index = cls
    return cls
end

-- ---------------------------------------------------------------------
-- Class-level helpers
-- ---------------------------------------------------------------------

function Component.setDefaultProps(cls, defaults)
    cls.__defaultProps = defaults
end

function Component.getName(cls): string
    return rawget(cls, "__componentName") or "<unknown>"
end

-- ---------------------------------------------------------------------
-- Lifecycle stubs (override in subclasses)
-- ---------------------------------------------------------------------

function Component:init(_props)        end
function Component:didMount()          end
function Component:willUnmount()       end
function Component:willUpdate(_p, _s)  end
function Component:didUpdate(_p, _s)   end

function Component:render()
    error(string.format("Component '%s' has no render()", self.__componentName or "?"), 2)
end

-- Optional: subclasses can return false from shouldUpdate to skip a render.
function Component:shouldUpdate(_nextProps, _nextState): boolean return true end

-- ---------------------------------------------------------------------
-- Internal construction (called by Renderer, not user code)
-- ---------------------------------------------------------------------

function Component._instantiate(cls, props, services, node, renderer)
    local self = setmetatable({
        props          = props,
        state          = {},
        _services      = services,
        _node          = node,
        _renderer      = renderer,
        _mounted       = false,
        _pendingUpdate = false,
        _pendingMerges = {},
        __componentName = cls.__componentName,
    }, cls)
    -- Convenience accessors
    if services then
        self.theme    = services.theme
        self.eventBus = services.eventBus
        self.animator = services.animator
        self.kernel   = services.kernel
        self.logger   = services.logger
    end
    -- Apply default props (only fill missing keys)
    if cls.__defaultProps then
        for k, v in cls.__defaultProps do
            if self.props[k] == nil then self.props[k] = v end
        end
    end
    -- Subclass init
    local ok, err = pcall(self.init, self, props)
    if not ok then
        error(string.format("Component '%s'.init() failed: %s", cls.__componentName, tostring(err)), 0)
    end
    return self
end

function Component:_setMounted(value: boolean)
    self._mounted = value
end

-- ---------------------------------------------------------------------
-- setState — batched merge that triggers a re-render
-- ---------------------------------------------------------------------

function Component:setState(updaterOrTable)
    if updaterOrTable == nil then return end
    if type(updaterOrTable) == "function" or type(updaterOrTable) == "table" then
        table.insert(self._pendingMerges, updaterOrTable)
    else
        error("Component:setState expects a table or function, got " .. typeof(updaterOrTable), 2)
    end
    if not self._mounted then
        self:_applyPendingMerges()                                  -- pre-mount: apply synchronously
        return
    end
    if self._pendingUpdate then return end                          -- already scheduled
    self._pendingUpdate = true
    task.defer(function()
        if not self._mounted then return end
        self._pendingUpdate = false
        self:_applyPendingMerges()
        if self._renderer then
            self._renderer:_requestComponentUpdate(self._node)
        end
    end)
end

function Component:_applyPendingMerges()
    if #self._pendingMerges == 0 then return end
    for _, m in self._pendingMerges do
        local partial = if type(m) == "function" then m(self.state) else m
        if partial then
            for k, v in partial do
                if v == Component.None then
                    self.state[k] = nil
                else
                    self.state[k] = v
                end
            end
        end
    end
    table.clear(self._pendingMerges)
end

-- Sentinel for explicit nil-set inside a state merge
Component.None = newproxy(false)

-- forceUpdate — bypass setState's merge logic to trigger a re-render
function Component:forceUpdate()
    if not self._mounted then return end
    if self._pendingUpdate then return end
    self._pendingUpdate = true
    task.defer(function()
        self._pendingUpdate = false
        if self._renderer and self._mounted then
            self._renderer:_requestComponentUpdate(self._node)
        end
    end)
end

-- ---------------------------------------------------------------------
-- Update path — called by the Renderer when parent re-renders us
-- ---------------------------------------------------------------------

function Component:_receiveNewProps(newProps)
    local cls = getmetatable(self).__index or getmetatable(self)
    if cls.__defaultProps then
        for k, v in cls.__defaultProps do
            if newProps[k] == nil then newProps[k] = v end
        end
    end
    local prevProps, prevState = self.props, self.state
    if self.shouldUpdate and not self:shouldUpdate(newProps, prevState) then
        self.props = newProps
        return false
    end
    if self.willUpdate then pcall(self.willUpdate, self, newProps, prevState) end
    self.props = newProps
    return true, prevProps, prevState
end

function Component:_fireDidUpdate(prevProps, prevState)
    if self.didUpdate then
        local ok, err = pcall(self.didUpdate, self, prevProps, prevState)
        if not ok and self.logger then
            self.logger:warn("%s.didUpdate error: %s", self.__componentName, tostring(err))
        end
    end
end

function Component:_fireDidMount()
    self._mounted = true
    if self.didMount then
        local ok, err = pcall(self.didMount, self)
        if not ok and self.logger then
            self.logger:warn("%s.didMount error: %s", self.__componentName, tostring(err))
        end
    end
end

function Component:_fireWillUnmount()
    if self.willUnmount then
        local ok, err = pcall(self.willUnmount, self)
        if not ok and self.logger then
            self.logger:warn("%s.willUnmount error: %s", self.__componentName, tostring(err))
        end
    end
    self._mounted = false
end

-- ---------------------------------------------------------------------
-- Helpful introspection
-- ---------------------------------------------------------------------

function Component:__tostring()
    return string.format("<%s mounted=%s>", self.__componentName or "?", tostring(self._mounted))
end

return Component
