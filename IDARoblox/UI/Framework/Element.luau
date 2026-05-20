--!nonstrict
-- =====================================================================
-- IDARoblox / UI / Framework / Element
-- ---------------------------------------------------------------------
-- Virtual elements — plain tables describing intended UI structure.
-- The Renderer consumes elements and reconciles them with real Roblox
-- Instances.
--
-- Two element kinds:
--
--   * Host:       { kind = "host",  class = "Frame", props = {}, children = {} }
--   * Component:  { kind = "comp",  class = MyComponent, props = {}, children = {} }
--
-- Special prop keys are sentinels (unique tables), not strings, so they
-- can never collide with Roblox property names:
--
--   Element.Event.Activated  → an event subscription marker; value must
--                              be a function (instance event handler)
--   Element.Ref              → callback receiving the actual Instance
--                              when mounted (and nil when unmounted)
--   Element.Children         → alternative to the 3rd-arg children form
-- =====================================================================

local Element = {}

local HOST_KIND = "host"
local COMP_KIND = "comp"
local FRAG_KIND = "frag"

Element.HOST_KIND = HOST_KIND
Element.COMP_KIND = COMP_KIND
Element.FRAG_KIND = FRAG_KIND

-- ---------------------------------------------------------------------
-- Event sentinel:  Element.Event.Activated, Element.Event.MouseEnter, …
-- The value at a sentinel key is the table { __isEvent = true, name = … }
-- ---------------------------------------------------------------------

Element.Event = setmetatable({}, {
    __index = function(t, key)
        local existing = rawget(t, key)
        if existing then return existing end
        local sentinel = setmetatable({
            __isEvent  = true,
            eventName  = key,
        }, { __tostring = function() return "Element.Event." .. key end })
        rawset(t, key, sentinel)
        return sentinel
    end,
    -- Call syntax: `Event "Activated"`  ≡  `Event.Activated`. Several
    -- widget files use the call form; we keep it working as a thin
    -- alias for __index so both styles produce the same sentinel.
    __call = function(t, key) return t[key] end,
})

function Element.isEvent(v): boolean
    return type(v) == "table" and rawget(v, "__isEvent") == true
end

-- ---------------------------------------------------------------------
-- Property-changed sentinel: Element.Changed.AbsoluteSize  (etc.)
-- Hooks up via instance:GetPropertyChangedSignal(name)
-- ---------------------------------------------------------------------

Element.Changed = setmetatable({}, {
    __index = function(t, key)
        local existing = rawget(t, key)
        if existing then return existing end
        local sentinel = setmetatable({
            __isChanged = true,
            property    = key,
        }, { __tostring = function() return "Element.Changed." .. key end })
        rawset(t, key, sentinel)
        return sentinel
    end,
    __call = function(t, key) return t[key] end,                     -- Changed "X" ≡ Changed.X
})

function Element.isChanged(v): boolean
    return type(v) == "table" and rawget(v, "__isChanged") == true
end

-- ---------------------------------------------------------------------
-- Ref sentinel — single, unique
-- ---------------------------------------------------------------------

Element.Ref      = newproxy(false)
Element.Children = newproxy(false)

-- ---------------------------------------------------------------------
-- Element factory: e(class, props?, children?)
-- ---------------------------------------------------------------------

local function flattenChildren(arr, out)
    -- Iterate sparse-safely so `false`/`nil` slots from conditional
    -- expressions like `cond and e(…)` don't terminate iteration.
    for i = 1, #arr do
        local v = arr[i]
        if v == nil or v == false then
            -- skip
        elseif type(v) == "table" and v.kind == FRAG_KIND then
            flattenChildren(v.children, out)
        elseif type(v) == "table" and (v.kind == HOST_KIND or v.kind == COMP_KIND) then
            out[#out + 1] = v
        elseif type(v) == "table" and v.kind == nil then
            -- An array of elements (e.g. results of map()) — recurse if it
            -- looks list-shaped (numeric indexed).
            flattenChildren(v, out)
        end
    end
end

function Element.create(class, props, children)
    props = props or {}
    -- Children may be passed positionally OR via [Children] in props.
    if not children and props[Element.Children] then
        children = props[Element.Children]
        props[Element.Children] = nil
    end
    local resolvedChildren = {}
    if children then
        flattenChildren(children, resolvedChildren)
    end

    local kind
    if type(class) == "string" then
        kind = HOST_KIND
    elseif type(class) == "table" and class.__isComponentClass then
        kind = COMP_KIND
    else
        error("Element.create: class must be a host string or a Component class", 2)
    end

    -- For component classes, expose children through props.children too —
    -- this is the idiomatic access pattern in JSX-style frameworks and
    -- keeps the component API symmetrical with class-level introspection.
    if kind == COMP_KIND then
        props.children = resolvedChildren
    end

    return {
        kind     = kind,
        class    = class,
        props    = props,
        children = resolvedChildren,
        -- Stable identity (key) lifted out of props for diffing
        key      = props.key,
    }
end

-- Short alias
Element.e = Element.create

-- ---------------------------------------------------------------------
-- Fragment — groups children without adding a wrapper Instance
-- ---------------------------------------------------------------------

function Element.fragment(children)
    local out = {}
    if children then flattenChildren(children, out) end
    return { kind = FRAG_KIND, children = out }
end

-- ---------------------------------------------------------------------
-- Predicates / introspection
-- ---------------------------------------------------------------------

function Element.isElement(v): boolean
    return type(v) == "table"
        and (v.kind == HOST_KIND or v.kind == COMP_KIND or v.kind == FRAG_KIND)
end

function Element.isHost(v): boolean
    return type(v) == "table" and v.kind == HOST_KIND
end

function Element.isComponent(v): boolean
    return type(v) == "table" and v.kind == COMP_KIND
end

function Element.isFragment(v): boolean
    return type(v) == "table" and v.kind == FRAG_KIND
end

-- ---------------------------------------------------------------------
-- Walks an element's prop table, splitting into:
--   regular  — name -> value (set on instance directly)
--   events   — eventName -> handler
--   changed  — propName  -> handler
--   ref      — function or nil
--   children — { Element, ... }  (always present, may be empty)
-- ---------------------------------------------------------------------

function Element.dissectProps(props, children)
    local regular, events, changed = {}, {}, {}
    local ref = nil
    for k, v in props do
        if k == Element.Ref then
            ref = v
        elseif Element.isEvent(k) then
            events[k.eventName] = v
        elseif Element.isChanged(k) then
            changed[k.property] = v
        elseif k ~= "key" then                                      -- key is metadata, not a prop
            regular[k] = v
        end
    end
    return regular, events, changed, ref, children or {}
end

return Element
