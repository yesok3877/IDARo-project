--!nonstrict
-- =====================================================================
-- IDARoblox / UI / Framework / Animator
-- ---------------------------------------------------------------------
-- Single-loop animation runtime driven by RunService.Heartbeat.
--
-- Two animation kinds:
--
--   tween(target, prop, to, duration, easing)
--       Classic eased tween, returns an Animation handle with
--       :onComplete, :onUpdate, :cancel, :complete.
--
--   spring(target, prop, to, params)
--       Critically- or under-damped harmonic spring (default tension=170,
--       damping=20). Settles when |velocity| & |delta| are below epsilon.
--
-- Both forms work on number / Color3 / UDim / UDim2 / Vector2 / Vector3
-- and respect `target` being either a Roblox Instance (sets prop with
-- assignment) or a plain Lua table (sets `target[prop]`).
--
-- The animator also exposes a `valueAnim()` form that doesn't write to
-- any target — you get an Animation handle whose :value() returns the
-- current interpolated value each frame. The ProgressBar widget uses
-- this so it can apply the value via the UI framework's render pipeline.
-- =====================================================================

local Animator = {}
Animator.__index = Animator

local RunService = game:GetService("RunService")

-- ---------------------------------------------------------------------
-- Easing functions
-- ---------------------------------------------------------------------

local Easings = {}
Animator.Easings = Easings

function Easings.linear(t)         return t end
function Easings.easeInQuad(t)     return t * t end
function Easings.easeOutQuad(t)    return 1 - (1 - t) * (1 - t) end
function Easings.easeInOutQuad(t)  return if t < 0.5 then 2 * t * t else 1 - (-2 * t + 2)^2 / 2 end
function Easings.easeInCubic(t)    return t * t * t end
function Easings.easeOutCubic(t)   local u = 1 - t return 1 - u * u * u end
function Easings.easeInOutCubic(t) return if t < 0.5 then 4 * t * t * t else 1 - (-2 * t + 2)^3 / 2 end
function Easings.easeInQuart(t)    return t * t * t * t end
function Easings.easeOutQuart(t)   local u = 1 - t return 1 - u * u * u * u end
function Easings.easeInOutQuart(t) return if t < 0.5 then 8 * t * t * t * t else 1 - (-2 * t + 2)^4 / 2 end
function Easings.easeInExpo(t)     return if t == 0 then 0 else 2^(10 * t - 10) end
function Easings.easeOutExpo(t)    return if t == 1 then 1 else 1 - 2^(-10 * t) end
function Easings.easeInOutExpo(t)
    if t == 0 then return 0 end
    if t == 1 then return 1 end
    if t < 0.5 then return 2^(20 * t - 10) / 2 end
    return (2 - 2^(-20 * t + 10)) / 2
end
function Easings.easeInBack(t, s)
    s = s or 1.70158
    return t * t * ((s + 1) * t - s)
end
function Easings.easeOutBack(t, s)
    s = s or 1.70158
    local u = t - 1
    return u * u * ((s + 1) * u + s) + 1
end
function Easings.easeInOutBack(t, s)
    s = (s or 1.70158) * 1.525
    if t < 0.5 then
        return ((2 * t)^2 * ((s + 1) * 2 * t - s)) / 2
    else
        local u = 2 * t - 2
        return (u * u * ((s + 1) * u + s) + 2) / 2
    end
end
function Easings.easeOutElastic(t)
    if t == 0 or t == 1 then return t end
    local p = 0.3
    return 2^(-10 * t) * math.sin((t - p / 4) * (2 * math.pi) / p) + 1
end
function Easings.easeInElastic(t)
    if t == 0 or t == 1 then return t end
    local p = 0.3
    return -(2^(10 * (t - 1))) * math.sin((t - 1 - p / 4) * (2 * math.pi) / p)
end
function Easings.easeOutBounce(t)
    local n1, d1 = 7.5625, 2.75
    if t < 1 / d1 then return n1 * t * t end
    if t < 2 / d1 then local u = t - 1.5 / d1 return n1 * u * u + 0.75 end
    if t < 2.5 / d1 then local u = t - 2.25 / d1 return n1 * u * u + 0.9375 end
    local u = t - 2.625 / d1
    return n1 * u * u + 0.984375
end
function Easings.easeInBounce(t) return 1 - Easings.easeOutBounce(1 - t) end

local function resolveEasing(easing)
    if type(easing) == "function" then return easing end
    if type(easing) == "string" then
        local fn = Easings[easing]
        if fn then return fn end
    end
    return Easings.easeOutCubic
end

-- ---------------------------------------------------------------------
-- Type-aware interpolation
-- ---------------------------------------------------------------------

local function lerpNumber(a, b, t)  return a + (b - a) * t end
local function lerpColor(a, b, t)   return a:Lerp(b, t) end
local function lerpUDim(a, b, t)
    return UDim.new(
        a.Scale + (b.Scale - a.Scale) * t,
        a.Offset + (b.Offset - a.Offset) * t
    )
end
local function lerpUDim2(a, b, t)
    return UDim2.new(
        a.X.Scale + (b.X.Scale - a.X.Scale) * t,
        a.X.Offset + (b.X.Offset - a.X.Offset) * t,
        a.Y.Scale + (b.Y.Scale - a.Y.Scale) * t,
        a.Y.Offset + (b.Y.Offset - a.Y.Offset) * t
    )
end
local function lerpVector2(a, b, t) return a:Lerp(b, t) end
local function lerpVector3(a, b, t) return a:Lerp(b, t) end

local function pickLerp(value)
    local t = typeof(value)
    if t == "number"  then return lerpNumber  end
    if t == "Color3"  then return lerpColor   end
    if t == "UDim"    then return lerpUDim    end
    if t == "UDim2"   then return lerpUDim2   end
    if t == "Vector2" then return lerpVector2 end
    if t == "Vector3" then return lerpVector3 end
    error("Animator: unsupported animatable type '" .. t .. "'", 3)
end

-- "Subtraction" of two values for spring physics
local function delta(value, target)
    local t = typeof(value)
    if t == "number"  then return value - target end
    if t == "Color3"  then return Vector3.new(value.R - target.R, value.G - target.G, value.B - target.B) end
    if t == "Vector2" then return value - target end
    if t == "Vector3" then return value - target end
    if t == "UDim"    then return value.Offset - target.Offset + (value.Scale - target.Scale) * 1000 end
    if t == "UDim2"   then
        return (value.X.Offset - target.X.Offset)
             + (value.Y.Offset - target.Y.Offset)
             + (value.X.Scale - target.X.Scale) * 1000
             + (value.Y.Scale - target.Y.Scale) * 1000
    end
    return 0
end

-- ---------------------------------------------------------------------
-- Animation handle
-- ---------------------------------------------------------------------

local Animation = {}
Animation.__index = Animation

function Animation:onUpdate(fn)   table.insert(self._onUpdate, fn) return self end
function Animation:onComplete(fn) table.insert(self._onComplete, fn) return self end
function Animation:onCancel(fn)   table.insert(self._onCancel, fn) return self end

function Animation:cancel()
    if self._done then return end
    self._done = true
    self._cancelled = true
    for _, fn in self._onCancel do pcall(fn) end
end

function Animation:complete()
    if self._done then return end
    self._done = true
    self._value = self._to
    self:_apply()
    for _, fn in self._onUpdate do pcall(fn, self._value) end
    for _, fn in self._onComplete do pcall(fn, self._value) end
end

function Animation:value() return self._value end
function Animation:isDone(): boolean return self._done end

function Animation:_apply()
    local target = self._target
    if not target then return end
    if typeof(target) == "Instance" then
        local ok = pcall(function() target[self._prop] = self._value end)
        if not ok then
            -- Instance probably destroyed; cancel silently.
            self._done = true
        end
    else
        target[self._prop] = self._value
    end
end

-- ---------------------------------------------------------------------
-- Animator core
-- ---------------------------------------------------------------------

function Animator.new(opts)
    opts = opts or {}
    local self = setmetatable({
        _active        = {},                                        -- array of Animation
        _activeSet     = {},                                        -- Animation -> idx (loose)
        _connection    = nil,
        _runService    = RunService,
        _useRender     = opts.useRender == true,                    -- Heartbeat by default
        _running       = false,
        _spring = {
            tension = opts.springTension or 170,
            damping = opts.springDamping or 20,
            eps     = opts.springEps or 0.001,
        },
    }, Animator)
    return self
end

function Animator:_start()
    if self._running then return end
    self._running = true
    local sig = if self._useRender then self._runService.RenderStepped else self._runService.Heartbeat
    self._connection = sig:Connect(function(dt) self:_tick(dt) end)
end

function Animator:_stop()
    if self._connection then self._connection:Disconnect() self._connection = nil end
    self._running = false
end

function Animator:_add(anim)
    table.insert(self._active, anim)
    self._activeSet[anim] = true
    self:_start()
end

function Animator:_tick(dt)
    if dt > 0.1 then dt = 0.1 end                                   -- cap big stalls
    local active = self._active
    local i = 1
    while i <= #active do
        local anim = active[i]
        if anim._cancelled then
            table.remove(active, i)
            self._activeSet[anim] = nil
        else
            anim:_step(dt)
            if anim._done then
                for _, fn in anim._onComplete do pcall(fn, anim._value) end
                table.remove(active, i)
                self._activeSet[anim] = nil
            else
                i = i + 1
            end
        end
    end
    if #active == 0 then self:_stop() end
end

-- ---------------------------------------------------------------------
-- Tween constructor
-- ---------------------------------------------------------------------

function Animator:tween(target, prop, to, duration, easing)
    local from
    if target then
        from = target[prop]
    end
    if from == nil then
        error("Animator:tween: target has no current value for '" .. tostring(prop) .. "'", 2)
    end
    local lerpFn = pickLerp(from)
    local ease = resolveEasing(easing)

    local anim = setmetatable({
        _kind       = "tween",
        _target     = target,
        _prop       = prop,
        _from       = from,
        _to         = to,
        _value      = from,
        _duration   = math.max(0.0001, duration or 0.18),
        _elapsed    = 0,
        _ease       = ease,
        _lerp       = lerpFn,
        _onUpdate   = {},
        _onComplete = {},
        _onCancel   = {},
        _done       = false,
        _cancelled  = false,
    }, Animation)

    function anim:_step(dt)
        self._elapsed = self._elapsed + dt
        local t = self._elapsed / self._duration
        if t >= 1 then
            t = 1
            self._done = true
        end
        local eased = self._ease(t)
        self._value = self._lerp(self._from, self._to, eased)
        self:_apply()
        for _, fn in self._onUpdate do pcall(fn, self._value, t) end
    end

    self:_add(anim)
    return anim
end

-- ---------------------------------------------------------------------
-- Spring constructor
-- ---------------------------------------------------------------------

function Animator:spring(target, prop, to, params)
    params = params or {}
    local tension = params.tension or self._spring.tension
    local damping = params.damping or self._spring.damping
    local eps     = params.eps or self._spring.eps

    local from = target[prop]
    if from == nil then
        error("Animator:spring: target has no current value for '" .. tostring(prop) .. "'", 2)
    end
    local lerpFn = pickLerp(from)
    local valueType = typeof(from)
    -- For non-numeric types we run the spring on a [0,1] parameter and
    -- lerp from initial→target. For numbers, true physics on the value.
    local useParam = valueType ~= "number"

    local anim = setmetatable({
        _kind       = "spring",
        _target     = target,
        _prop       = prop,
        _from       = from,
        _to         = to,
        _value      = from,
        _velocity   = if useParam then 0 else 0,
        _param      = 0,                                            -- only used when useParam
        _useParam   = useParam,
        _tension    = tension,
        _damping    = damping,
        _eps        = eps,
        _lerp       = lerpFn,
        _onUpdate   = {},
        _onComplete = {},
        _onCancel   = {},
        _done       = false,
        _cancelled  = false,
    }, Animation)

    function anim:_step(dt)
        if self._useParam then
            -- Spring on [0,1]
            local accel = -self._tension * (self._param - 1) - self._damping * self._velocity
            self._velocity = self._velocity + accel * dt
            self._param   = self._param + self._velocity * dt
            self._value   = self._lerp(self._from, self._to, math.clamp(self._param, -0.5, 1.5))
            if math.abs(self._velocity) < self._eps and math.abs(self._param - 1) < self._eps then
                self._param = 1
                self._value = self._to
                self._done = true
            end
        else
            local accel = -self._tension * (self._value - self._to) - self._damping * self._velocity
            self._velocity = self._velocity + accel * dt
            self._value    = self._value + self._velocity * dt
            if math.abs(self._velocity) < self._eps and math.abs(self._value - self._to) < self._eps then
                self._value = self._to
                self._done = true
            end
        end
        self:_apply()
        for _, fn in self._onUpdate do pcall(fn, self._value) end
    end

    self:_add(anim)
    return anim
end

-- ---------------------------------------------------------------------
-- valueAnim — no target writes, just polled value
-- ---------------------------------------------------------------------

function Animator:valueAnim(from, to, duration, easing)
    local lerpFn = pickLerp(from)
    local ease = resolveEasing(easing)
    local anim = setmetatable({
        _kind       = "value",
        _target     = nil,
        _prop       = nil,
        _from       = from,
        _to         = to,
        _value      = from,
        _duration   = math.max(0.0001, duration or 0.18),
        _elapsed    = 0,
        _ease       = ease,
        _lerp       = lerpFn,
        _onUpdate   = {},
        _onComplete = {},
        _onCancel   = {},
        _done       = false,
        _cancelled  = false,
    }, Animation)
    function anim:_step(dt)
        self._elapsed = self._elapsed + dt
        local t = self._elapsed / self._duration
        if t >= 1 then t = 1 self._done = true end
        self._value = self._lerp(self._from, self._to, self._ease(t))
        for _, fn in self._onUpdate do pcall(fn, self._value, t) end
    end
    function anim:_apply() end                                       -- no-op
    self:_add(anim)
    return anim
end

-- ---------------------------------------------------------------------
-- Bulk operations
-- ---------------------------------------------------------------------

function Animator:cancelOnTarget(target, prop)
    for _, anim in self._active do
        if anim._target == target and (not prop or anim._prop == prop) then
            anim:cancel()
        end
    end
end

function Animator:activeCount(): number
    return #self._active
end

function Animator:destroy()
    for _, anim in self._active do anim:cancel() end
    self._active = {}
    self._activeSet = {}
    self:_stop()
end

return Animator
