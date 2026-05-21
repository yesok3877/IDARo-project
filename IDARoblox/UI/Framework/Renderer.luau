--!nonstrict
-- =====================================================================
-- IDARoblox / UI / Framework / Renderer
-- ---------------------------------------------------------------------
-- Mounts virtual elements onto real Roblox Instances. Reconciles trees
-- on update so only the changed Instances get touched.
--
-- Public API:
--   renderer:mount(element, parentInstance) -> Tree
--   renderer:update(tree, newElement)        -> Tree   (may differ if root replaced)
--   renderer:unmount(tree)                    -> ()
--
-- Internal node shape:
--   {
--      element        = <last element used to produce this node>,
--      kind           = "host"|"comp"|"frag",
--      class          = "Frame" | Component,
--      key            = nil | string | number,
--      parentInstance = Instance,        -- physical parent
--      instance       = Instance?,        -- host nodes only
--      componentInst  = Component?,       -- component nodes only
--      eventConns     = { RBXScriptConnection },
--      changedConns   = { RBXScriptConnection },
--      ref            = function?,        -- last ref callback
--      childNodes     = { Node | { Node } },  -- ordered child slots
--      props          = { },              -- last applied regular props
--   }
-- =====================================================================

local Element   = _G.IDARo.require("UI.Framework.Element")
local Component = _G.IDARo.require("UI.Framework.Component")
local Component = _G.IDARo.require("UI.Framework.Component")

local Renderer = {}
Renderer.__index = Renderer

-- ---------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------

function Renderer.new(services)
    services = services or {}
    local self = setmetatable({
        _services       = services,
        _theme          = services.theme,
        _eventBus       = services.eventBus,
        _animator       = services.animator,
        _kernel         = services.kernel,
        _logger         = services.logger,
        _pendingUpdates = {},                                      -- Node -> true (deduped)
        _flushScheduled = false,
        _stats = {
            instancesCreated = 0,
            instancesDestroyed = 0,
            componentsCreated = 0,
            componentsDestroyed = 0,
            updatesRun = 0,
        },
    }, Renderer)
    -- Subscribe to theme changes: every component re-renders.
    if self._eventBus then
        self._themeConn = self._eventBus:on("theme.changed", function()
            self:_themeRefresh()
        end)
    end
    return self
end

function Renderer:destroy()
    if self._themeConn then self._themeConn:disconnect() end
end

function Renderer:stats() return table.clone(self._stats) end

-- ---------------------------------------------------------------------
-- Public mount / unmount
-- ---------------------------------------------------------------------

function Renderer:mount(element, parentInstance)
    if not Element.isElement(element) then
        error("Renderer:mount expects an Element", 2)
    end
    if typeof(parentInstance) ~= "Instance" then
        error("Renderer:mount expects an Instance parent", 2)
    end
    return self:_mountNode(element, parentInstance)
end

function Renderer:unmount(node)
    if not node then return end
    self:_unmountNode(node)
end

function Renderer:update(tree, newElement)
    return self:_reconcile(tree, newElement, tree.parentInstance)
end

-- ---------------------------------------------------------------------
-- Internal: prop application
-- ---------------------------------------------------------------------

local function setInstanceProp(instance, key, value, logger)
    local ok, err = pcall(function() instance[key] = value end)
    if not ok and logger then
        logger:trace("Renderer: cannot set %s.%s: %s",
            instance.ClassName, tostring(key), tostring(err))
    end
end

function Renderer:_applyHostProps(instance, oldProps, newProps)
    -- Remove props no longer present (best-effort reset to defaults).
    if oldProps then
        for k in oldProps do
            if newProps[k] == nil then
                -- Try to reset known visual properties; otherwise leave.
                local defaultVal
                if k == "Text" then defaultVal = ""
                elseif k == "BackgroundTransparency" then defaultVal = 0
                elseif k == "ImageTransparency" then defaultVal = 0
                elseif k == "Visible" then defaultVal = true
                end
                if defaultVal ~= nil then setInstanceProp(instance, k, defaultVal, self._logger) end
            end
        end
    end
    -- Apply new/changed
    for k, v in newProps do
        if oldProps == nil or oldProps[k] ~= v then
            setInstanceProp(instance, k, v, self._logger)
        end
    end
end

function Renderer:_applyEvents(node, instance, oldEvents, newEvents)
    -- Disconnect events no longer present or whose handler changed.
    for name, conn in node.eventConns do
        if oldEvents[name] and (not newEvents[name] or newEvents[name] ~= oldEvents[name]) then
            pcall(function() conn:Disconnect() end)
            node.eventConns[name] = nil
        end
    end
    -- Connect new or changed events. Every step here is pcall-guarded
    -- because in executor contexts the running thread may lack the
    -- capabilities Roblox requires for signal access — failure to
    -- connect should not abort the rest of the reconcile.
    for name, handler in newEvents do
        if not node.eventConns[name] then
            local ok, signal = pcall(function() return instance[name] end)
            if ok and typeof(signal) == "RBXScriptSignal" then
                local connOk, connOrErr = pcall(function()
                    return signal:Connect(function(...)
                        -- Each handler invocation is also pcall-guarded
                        -- so a thrown handler can't kill the signal.
                        local hOk, hErr = pcall(handler, instance, ...)
                        if not hOk and self._logger then
                            self._logger:warn("Renderer: handler '%s' on %s threw: %s",
                                name, instance.ClassName, tostring(hErr))
                        end
                    end)
                end)
                if connOk then
                    node.eventConns[name] = connOrErr
                elseif self._logger then
                    self._logger:warn("Renderer: signal:Connect('%s') failed on %s: %s",
                        name, instance.ClassName, tostring(connOrErr))
                end
            elseif self._logger then
                local className = "?"
                pcall(function() className = instance.ClassName end)
                self._logger:warn("Renderer: '%s' is not a signal on %s",
                    name, className)
            end
        end
    end
end

function Renderer:_applyChanged(node, instance, oldChanged, newChanged)
    for name, conn in node.changedConns do
        if oldChanged[name] and (not newChanged[name] or newChanged[name] ~= oldChanged[name]) then
            conn:Disconnect()
            node.changedConns[name] = nil
        end
    end
    for name, handler in newChanged do
        if not node.changedConns[name] then
            local ok, signal = pcall(function()
                return instance:GetPropertyChangedSignal(name)
            end)
            if ok and typeof(signal) == "RBXScriptSignal" then
                node.changedConns[name] = signal:Connect(function() handler(instance) end)
            end
        end
    end
end

-- ---------------------------------------------------------------------
-- Internal: mount paths
-- ---------------------------------------------------------------------

function Renderer:_mountNode(element, parentInstance)
    if element.kind == Element.HOST_KIND then
        return self:_mountHost(element, parentInstance)
    elseif element.kind == Element.COMP_KIND then
        return self:_mountComponent(element, parentInstance)
    elseif element.kind == Element.FRAG_KIND then
        return self:_mountFragment(element, parentInstance)
    else
        error("Renderer: unknown element kind: " .. tostring(element.kind), 0)
    end
end

function Renderer:_mountHost(element, parentInstance)
    local ok, instance = pcall(Instance.new, element.class)
    if not ok or not instance then
        error(string.format("Renderer: cannot create Instance of class '%s'", element.class), 0)
    end
    self._stats.instancesCreated += 1

    local regular, events, changed, ref, children =
        Element.dissectProps(element.props, element.children)

    local node = {
        element        = element,
        kind           = "host",
        class          = element.class,
        key            = element.key,
        parentInstance = parentInstance,
        instance       = instance,
        componentInst  = nil,
        eventConns     = {},
        changedConns   = {},
        ref            = nil,
        childNodes     = {},
        props          = nil,
    }

    self:_applyHostProps(instance, nil, regular)
    node.props = regular
    self:_applyEvents(node, instance, {}, events)
    self:_applyChanged(node, instance, {}, changed)

    -- Mount children before parenting (so we don't observe a tree
    -- being assembled in pieces; cheap atomicity).
    self:_mountChildren(node, instance, children)

    instance.Parent = parentInstance

    -- Fire ref last so it sees the fully-formed instance.
    if ref then
        node.ref = ref
        pcall(ref, instance)
    end

    return node
end

function Renderer:_mountComponent(element, parentInstance)
    local cls = element.class
    -- Component constructor needs a placeholder node so setState can find it.
    local node = {
        element        = element,
        kind           = "comp",
        class          = cls,
        key            = element.key,
        parentInstance = parentInstance,
        instance       = nil,
        componentInst  = nil,
        eventConns     = {},
        changedConns   = {},
        ref            = nil,
        childNodes     = {},
        props          = element.props,
    }
    local inst = Component._instantiate(cls, element.props, self._services, node, self)
    node.componentInst = inst
    self._stats.componentsCreated += 1

    -- Render & mount the produced sub-tree.
    local rendered = inst:render()
    if rendered ~= nil then
        local child = self:_mountNode(rendered, parentInstance)
        node.childNodes[1] = child
    end

    -- Fire didMount AFTER children are mounted.
    inst:_fireDidMount()
    return node
end

function Renderer:_mountFragment(element, parentInstance)
    local node = {
        element        = element,
        kind           = "frag",
        class          = nil,
        key            = element.key,
        parentInstance = parentInstance,
        instance       = nil,
        componentInst  = nil,
        eventConns     = {},
        changedConns   = {},
        ref            = nil,
        childNodes     = {},
        props          = nil,
    }
    self:_mountChildren(node, parentInstance, element.children)
    return node
end

-- ---------------------------------------------------------------------
-- Children reconciliation
-- ---------------------------------------------------------------------

local function buildKeyMap(childNodes)
    local byKey = {}
    local byPos = {}
    for i, child in childNodes do
        if child.key ~= nil then byKey[child.key] = child
        else byPos[i] = child end
    end
    return byKey, byPos
end

function Renderer:_mountChildren(parentNode, parentInstance, childElements)
    parentNode.childNodes = table.create(#childElements)
    for i, childEl in childElements do
        parentNode.childNodes[i] = self:_mountNode(childEl, parentInstance)
    end
end

function Renderer:_reconcileChildren(parentNode, parentInstance, newChildren)
    local oldChildren = parentNode.childNodes
    local oldByKey, oldByPos = buildKeyMap(oldChildren)
    local newNodes = table.create(#newChildren)
    local consumed = {}                                             -- old child -> true

    for i, newEl in newChildren do
        local key = newEl.key
        local match
        if key ~= nil then
            match = oldByKey[key]
            if match then oldByKey[key] = nil end
        else
            match = oldByPos[i]
            if match then oldByPos[i] = nil end
        end
        if match and self:_isCompatible(match, newEl) then
            consumed[match] = true
            newNodes[i] = self:_reconcile(match, newEl, parentInstance)
        else
            if match then
                self:_unmountNode(match)                            -- replace
                consumed[match] = true
            end
            newNodes[i] = self:_mountNode(newEl, parentInstance)
        end
    end
    -- Unmount any leftover old children
    for _, old in oldChildren do
        if not consumed[old] then self:_unmountNode(old) end
    end
    parentNode.childNodes = newNodes
end

function Renderer:_isCompatible(node, element): boolean
    if node.kind ~= element.kind then return false end
    if element.kind == Element.HOST_KIND then return node.class == element.class end
    if element.kind == Element.COMP_KIND then return node.class == element.class end
    if element.kind == Element.FRAG_KIND then return true end
    return false
end

-- ---------------------------------------------------------------------
-- Reconcile a single node
-- ---------------------------------------------------------------------

function Renderer:_reconcile(node, newElement, parentInstance)
    if not self:_isCompatible(node, newElement) then
        self:_unmountNode(node)
        return self:_mountNode(newElement, parentInstance)
    end
    if node.kind == "host" then
        return self:_reconcileHost(node, newElement)
    elseif node.kind == "comp" then
        return self:_reconcileComponent(node, newElement)
    elseif node.kind == "frag" then
        self:_reconcileChildren(node, parentInstance, newElement.children)
        node.element = newElement
        return node
    end
    return node
end

function Renderer:_reconcileHost(node, newElement)
    local regular, events, changed, ref, children =
        Element.dissectProps(newElement.props, newElement.children)
    local oldRegular = node.props or {}
    local oldEvents = {}
    local oldChanged = {}
    -- Build old events/changed by inspecting current conns
    for k in node.eventConns do oldEvents[k] = true end
    for k in node.changedConns do oldChanged[k] = true end

    self:_applyHostProps(node.instance, oldRegular, regular)
    self:_applyEvents(node, node.instance, oldEvents, events)
    self:_applyChanged(node, node.instance, oldChanged, changed)
    node.props = regular

    -- Ref change
    if ref ~= node.ref then
        if node.ref then pcall(node.ref, nil) end                    -- detach
        node.ref = ref
        if ref then pcall(ref, node.instance) end
    end

    self:_reconcileChildren(node, node.instance, children)
    node.element = newElement
    self._stats.updatesRun += 1
    return node
end

function Renderer:_reconcileComponent(node, newElement)
    local inst = node.componentInst
    local shouldRender, prevProps, prevState = inst:_receiveNewProps(newElement.props)
    if not shouldRender then
        node.element = newElement
        return node
    end
    local rendered = inst:render()
    if rendered == nil then
        -- Component rendered nothing; unmount any prior child.
        local prev = node.childNodes[1]
        if prev then self:_unmountNode(prev) end
        node.childNodes[1] = nil
    else
        local prev = node.childNodes[1]
        if prev then
            node.childNodes[1] = self:_reconcile(prev, rendered, node.parentInstance)
        else
            node.childNodes[1] = self:_mountNode(rendered, node.parentInstance)
        end
    end
    inst:_fireDidUpdate(prevProps, prevState)
    node.element = newElement
    self._stats.updatesRun += 1
    return node
end

-- ---------------------------------------------------------------------
-- Unmount
-- ---------------------------------------------------------------------

function Renderer:_unmountNode(node)
    if not node then return end
    if node.kind == "comp" and node.componentInst then
        node.componentInst:_fireWillUnmount()
        self._stats.componentsDestroyed += 1
    end
    for _, child in node.childNodes do
        if type(child) == "table" then self:_unmountNode(child) end
    end
    for _, conn in node.eventConns do conn:Disconnect() end
    for _, conn in node.changedConns do conn:Disconnect() end
    node.eventConns = {}
    node.changedConns = {}
    if node.ref then pcall(node.ref, nil) end
    if node.kind == "host" and node.instance then
        pcall(function() node.instance:Destroy() end)
        self._stats.instancesDestroyed += 1
    end
    node.element = nil
    node.instance = nil
    node.componentInst = nil
end

-- ---------------------------------------------------------------------
-- Component update requests (from setState/forceUpdate)
-- ---------------------------------------------------------------------

-- Defer-depth tracking for the renderer's flush. When a re-render
-- causes signals to fire that call setState again, the flush re-enters
-- itself; above a safe threshold we yield a frame via Heartbeat:Wait()
-- inside a task.spawn'd coroutine, which is the most reliable way to
-- force the Roblox scheduler to reset its task.defer re-entry counter.
local _FLUSH_DEPTH = 0
local _FLUSH_DEPTH_LIMIT = 16
local _FLUSH_MAX_ITERATIONS = 32                                     -- bounds runaway re-queues
local RunService = game:GetService("RunService")

function Renderer:_requestComponentUpdate(node)
    if not node or node.kind ~= "comp" then return end
    self._pendingUpdates[node] = true
    if self._flushScheduled then return end                          -- already queued
    self._flushScheduled = true

    local cur = _FLUSH_DEPTH
    _FLUSH_DEPTH = cur + 1

    local function doFlush()
        -- Critical: keep self._flushScheduled = true for the entire
        -- duration of the flush. setStates that fire during reconcile
        -- (Roblox signals like Changed.AbsoluteSize, MouseEnter, etc.)
        -- call _requestComponentUpdate; if _flushScheduled were false
        -- they'd schedule new task.defers, building up Roblox's 80-deep
        -- re-entry stack. By keeping it true and draining the queue in
        -- this same coroutine, we never accumulate task.defer levels.
        local iterations = 0
        local renderCounts = {}                                       -- comp -> times rendered
        while next(self._pendingUpdates) and iterations < _FLUSH_MAX_ITERATIONS do
            iterations += 1
            local pending = self._pendingUpdates
            self._pendingUpdates = {}
            for n in pending do
                if n.componentInst then
                    local inst = n.componentInst
                    if inst._mounted then
                        renderCounts[inst] = (renderCounts[inst] or 0) + 1
                        -- Apply queued state merges that setState() left for us.
                        inst:_applyPendingMerges()
                        local prevProps, prevState = inst.props, inst.state
                        local rendered = inst:render()
                        if rendered == nil then
                            local prev = n.childNodes[1]
                            if prev then self:_unmountNode(prev) end
                            n.childNodes[1] = nil
                        else
                            local prev = n.childNodes[1]
                            if prev then
                                n.childNodes[1] = self:_reconcile(prev, rendered, n.parentInstance)
                            else
                                n.childNodes[1] = self:_mountNode(rendered, n.parentInstance)
                            end
                        end
                        inst:_fireDidUpdate(prevProps, prevState)
                        self._stats.updatesRun += 1
                    end
                end
            end
        end
        if iterations >= _FLUSH_MAX_ITERATIONS and self._logger then
            -- Build a sorted ranking of who re-rendered how many times so
            -- the looping component is named directly.
            local ranked = {}
            for inst, count in renderCounts do
                if count >= 2 then                                   -- mention re-renderers, not single-pass nodes
                    local cls = "?"
                    pcall(function()
                        cls = inst.__className
                            or (getmetatable(inst) and getmetatable(inst).__name)
                            or "?"
                    end)
                    ranked[#ranked + 1] = string.format("%s x%d", cls, count)
                end
            end
            table.sort(ranked)
            self._logger:warn(
                "Renderer: flush cap (%d iters) — re-render hotspots: %s",
                _FLUSH_MAX_ITERATIONS, table.concat(ranked, ", "))
        end
        -- Only release the flag once the queue is drained.
        self._flushScheduled = false
        _FLUSH_DEPTH = math.max(0, _FLUSH_DEPTH - 1)
    end

    if cur >= _FLUSH_DEPTH_LIMIT then
        -- Above the limit, spawn a coroutine that waits one Heartbeat
        -- before running. Heartbeat:Wait() is the most reliable yield
        -- in Roblox — task.defer and even task.delay(0,...) can resume
        -- on the same task scheduler tick in executor contexts.
        task.spawn(function()
            local ok = pcall(function() RunService.Heartbeat:Wait() end)
            if not ok then task.wait(0) end
            doFlush()
        end)
    else
        (Component._elevatedDefer or task.defer)(doFlush)
    end
end

-- ---------------------------------------------------------------------
-- Theme refresh — re-render every mounted component on theme change.
-- Implementation: enqueue updates for every component instance reachable
-- from any mounted tree we know about. We don't keep a global list, so
-- this is a no-op unless the user calls renderer:forceFullRefresh().
-- The bus signal exists primarily so individual components can subscribe
-- in didMount() and refresh themselves selectively.
-- ---------------------------------------------------------------------

function Renderer:_themeRefresh()
    -- Intentionally minimal: components self-subscribe.
end

function Renderer:forceFullRefresh(tree)
    -- Walk the tree, enqueue all component nodes.
    local function walk(n)
        if not n then return end
        if n.kind == "comp" then self:_requestComponentUpdate(n) end
        for _, c in n.childNodes do
            if type(c) == "table" then walk(c) end
        end
    end
    walk(tree)
end

return Renderer
