--!nonstrict
-- =====================================================================
-- IDARo / Runtime / NetworkTracer
-- ---------------------------------------------------------------------
-- Captures every Roblox remote and bindable in flight:
--
--   RemoteEvent          :FireServer / :FireClient / :FireAllClients
--   RemoteFunction       :InvokeServer / :InvokeClient
--   UnreliableRemoteEvent:FireServer / :FireClient / :FireAllClients
--   BindableEvent        :Fire
--   BindableFunction     :Invoke
--
-- Each captured call becomes an entry:
--
--   {
--     id         = monotonic counter,
--     ts         = os.clock(),
--     direction  = "outgoing" | "incoming",
--     kind       = "RemoteEvent" | "RemoteFunction" | …
--     method     = "FireServer" | "InvokeServer" | …
--     instance   = the Instance object (kept weak when possible)
--     path       = Instance:GetFullName() snapshot
--     args       = safe-stringified args (capped depth + length)
--     returns    = safe-stringified return values (for *Function calls)
--     traceback  = debug.traceback(nil, 2)
--     callerFn   = the closure that made the call (if resolvable)
--   }
--
-- Hooking strategy
--   Preferred: executor's `hookmetamethod(game, "__namecall", fn)` —
--   one hook intercepts every :FireServer / :InvokeServer call on the
--   entire game. Fallback: hookfunction() applied to each method on a
--   per-class basis (slower, but works on executors without metamethod
--   hooking).
--
-- Storage is a fixed-size ring buffer (default 2048 entries) so a busy
-- game with a chatty replicator doesn't OOM the analyzer. EventBus
-- emits "network.entry" on every capture; views subscribe.
-- =====================================================================

local NetworkTracer = {}
NetworkTracer.__index = NetworkTracer

local DEFAULT_RING_SIZE   = 2048
local STRINGIFY_MAX_DEPTH = 6
local STRINGIFY_MAX_LEN   = 256
local STRINGIFY_MAX_KEYS  = 32

-- ---------------------------------------------------------------------
-- Tracked method specs
-- ---------------------------------------------------------------------

-- Each entry tells the tracer which class it targets, which method,
-- which direction the call goes, and whether the method returns a value.
local METHOD_SPECS = {
    -- RemoteEvent
    { class = "RemoteEvent",           method = "FireServer",     direction = "outgoing", returns = false },
    { class = "RemoteEvent",           method = "FireClient",     direction = "outgoing", returns = false },
    { class = "RemoteEvent",           method = "FireAllClients", direction = "outgoing", returns = false },
    -- RemoteFunction
    { class = "RemoteFunction",        method = "InvokeServer",   direction = "outgoing", returns = true  },
    { class = "RemoteFunction",        method = "InvokeClient",   direction = "outgoing", returns = true  },
    -- UnreliableRemoteEvent
    { class = "UnreliableRemoteEvent", method = "FireServer",     direction = "outgoing", returns = false },
    { class = "UnreliableRemoteEvent", method = "FireClient",     direction = "outgoing", returns = false },
    { class = "UnreliableRemoteEvent", method = "FireAllClients", direction = "outgoing", returns = false },
    -- BindableEvent
    { class = "BindableEvent",         method = "Fire",           direction = "outgoing", returns = false },
    -- BindableFunction
    { class = "BindableFunction",      method = "Invoke",         direction = "outgoing", returns = true  },
}

-- Class membership check — `instance:IsA(class)`-ish via Roblox API.
local function isOfClass(instance, className)
    if not instance or type(instance) ~= "userdata" then return false end
    local ok, isA = pcall(function() return instance:IsA(className) end)
    return ok and isA == true
end

-- ---------------------------------------------------------------------
-- Safe arg stringifier
-- ---------------------------------------------------------------------

local function safeStringify(v, depth)
    depth = depth or 0
    if depth > STRINGIFY_MAX_DEPTH then return "<…>" end
    local t = type(v)
    if t == "nil"     then return "nil" end
    if t == "boolean" then return tostring(v) end
    if t == "number"  then return tostring(v) end
    if t == "string" then
        if #v > STRINGIFY_MAX_LEN then
            return string.format("%q…(%d)", string.sub(v, 1, STRINGIFY_MAX_LEN), #v)
        end
        return string.format("%q", v)
    end
    if t == "function" then return "<function>" end
    if t == "thread"   then return "<thread>" end
    if t == "userdata" then
        -- Try Roblox-ish: typeof + getFullName for Instances
        local ok, tof = pcall(typeof, v)
        if ok and tof == "Instance" then
            local nameOk, fullName = pcall(function() return v:GetFullName() end)
            return string.format("<Instance:%s>", nameOk and fullName or "?")
        end
        if ok then return string.format("<%s>", tostring(tof)) end
        return "<userdata>"
    end
    if t == "table" then
        local parts = {}
        local count = 0
        for k, val in pairs(v) do
            count = count + 1
            if count > STRINGIFY_MAX_KEYS then
                parts[#parts + 1] = "…"
                break
            end
            local ks = type(k) == "string" and k or tostring(k)
            parts[#parts + 1] = ks .. "=" .. safeStringify(val, depth + 1)
        end
        return "{" .. table.concat(parts, ", ") .. "}"
    end
    -- vector / buffer / EnumItem / etc.
    local ok, s = pcall(tostring, v)
    return ok and s or "<?>"
end

local function stringifyArgs(args, n)
    local parts = {}
    for i = 1, n do parts[i] = safeStringify(args[i], 0) end
    return table.concat(parts, ", ")
end

NetworkTracer.safeStringify = safeStringify

-- ---------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------

function NetworkTracer.new(opts)
    opts = opts or {}
    return setmetatable({
        _logger      = opts.logger,
        _eventBus    = opts.eventBus,
        _scanner     = opts.scanner,
        _ringSize    = opts.ringSize or DEFAULT_RING_SIZE,
        _ring        = table.create(opts.ringSize or DEFAULT_RING_SIZE),
        _ringHead    = 0,                                            -- next write slot (0..ringSize-1)
        _ringCount   = 0,
        _idCounter   = 0,
        _paused      = false,
        _installed   = false,
        _hookedMethods = {},                                         -- methodFn → originalFn
        _filters     = {                                             -- per-class enable
            RemoteEvent = true, RemoteFunction = true,
            UnreliableRemoteEvent = true,
            BindableEvent = true, BindableFunction = true,
        },
        _stats = {
            captured        = 0,
            droppedByFilter = 0,
            byClass         = {},
            byMethod        = {},
            installMode     = nil,
        },
    }, NetworkTracer)
end

-- ---------------------------------------------------------------------
-- Hook installation
-- ---------------------------------------------------------------------

function NetworkTracer:_resolve(fnName)
    -- (1) Capability-aware path through the scanner.
    if self._scanner and self._scanner.getRaw then
        local ok, v = pcall(function() return self._scanner:getRaw(fnName) end)
        if ok and type(v) == "function" then return v end
    end
    -- (2) Plain _G.
    local v = rawget(_G, fnName)
    if type(v) == "function" then return v end
    -- (3) getgenv() — Wave / Synapse / Krnl pattern; the executor's
    -- own globals live here and may not be merged into _G.
    local getgenv = rawget(_G, "getgenv") or rawget(getfenv(0), "getgenv")
    if type(getgenv) == "function" then
        local okEnv, env = pcall(getgenv)
        if okEnv and type(env) == "table" then
            local fn = rawget(env, fnName)
            if type(fn) == "function" then return fn end
        end
    end
    -- (4) getrenv() — Roblox's renv mirror in some executors.
    local getrenv = rawget(_G, "getrenv") or rawget(getfenv(0), "getrenv")
    if type(getrenv) == "function" then
        local okEnv, env = pcall(getrenv)
        if okEnv and type(env) == "table" then
            local fn = rawget(env, fnName)
            if type(fn) == "function" then return fn end
        end
    end
    -- (5) getfenv(0) — the calling script's global env.
    local okF, fenv = pcall(getfenv, 0)
    if okF and type(fenv) == "table" then
        local fn = fenv[fnName]
        if type(fn) == "function" then return fn end
    end
    return nil
end

function NetworkTracer:_captureCall(spec, instance, args, n)
    if self._paused then return end
    if not self._filters[spec.class] then
        self._stats.droppedByFilter = self._stats.droppedByFilter + 1
        return
    end
    self._idCounter = self._idCounter + 1
    local pathOk, path = pcall(function() return instance:GetFullName() end)
    local tb = ""
    pcall(function() tb = debug.traceback(nil, 4) end)
    local callerFn
    do
        local infoFn = (debug and debug.info) or (debug and debug.getinfo)
        if infoFn then
            local ok, info = pcall(infoFn, 3, "f")
            if ok and info then callerFn = type(info) == "table" and info.func or info end
        end
    end
    local entry = {
        id        = self._idCounter,
        ts        = os.clock(),
        direction = spec.direction,
        kind      = spec.class,
        method    = spec.method,
        instance  = instance,
        path      = pathOk and path or "(detached)",
        args      = stringifyArgs(args, n),
        argCount  = n,
        rawArgs   = args,                                            -- kept alongside stringified form for re-emit
        returns   = nil,
        traceback = tb,
        callerFn  = callerFn,
    }
    self._ringHead = (self._ringHead % self._ringSize) + 1
    self._ring[self._ringHead] = entry
    if self._ringCount < self._ringSize then
        self._ringCount = self._ringCount + 1
    end
    self._stats.captured = self._stats.captured + 1
    self._stats.byClass[spec.class] = (self._stats.byClass[spec.class] or 0) + 1
    self._stats.byMethod[spec.method] = (self._stats.byMethod[spec.method] or 0) + 1
    if self._eventBus and self._eventBus.emit then
        pcall(self._eventBus.emit, self._eventBus, "network.entry", entry)
    end
    return entry
end

-- Path A: metamethod hook (preferred). One hook covers every namecall
-- on every Instance in the game.
function NetworkTracer:_installNamecallHook()
    local hookmm = self:_resolve("hookmetamethod")
    if type(hookmm) ~= "function" then return false end
    local getnamecallmethod = self:_resolve("getnamecallmethod")
    if type(getnamecallmethod) ~= "function" then return false end
    local checkcaller = self:_resolve("checkcaller")                 -- guard against re-entry from our own UI

    local specByMethod = {}
    for _, s in METHOD_SPECS do
        local key = s.class .. "." .. s.method
        specByMethod[key] = s
    end

    local original
    local function newNamecall(self_arg, ...)
        local method = getnamecallmethod()
        if method then
            -- Quickly check the class+method tuple
            local cls
            local okT, t = pcall(typeof, self_arg)
            if okT and t == "Instance" then
                cls = self_arg.ClassName
            end
            if cls then
                local spec = specByMethod[cls .. "." .. method]
                if spec and not (checkcaller and checkcaller()) then
                    local args = table.pack(...)
                    self:_captureCall(spec, self_arg, args, args.n)
                end
            end
        end
        return original(self_arg, ...)
    end
    local ok, prev = pcall(hookmm, game, "__namecall", function(self_arg, ...)
        return newNamecall(self_arg, ...)
    end)
    if not ok then return false end
    original = prev
    self._stats.installMode = "namecall"
    return true
end

-- Path B: per-method hookfunction (fallback). For each method on each
-- class, find an example instance, grab the bound function, hookfunction
-- it. Slower install, but works without metamethod hooking.
function NetworkTracer:_installPerMethodHooks()
    local hookfunction = self:_resolve("hookfunction")
    if type(hookfunction) ~= "function" then return false end
    -- We need a *method function* to hook. The cleanest path is to take
    -- one example instance per class and grab `instance.Method`. Failing
    -- that, we walk getgc looking for one.
    local examples = {}
    -- Try walking the workspace + replicated storage for any matching
    -- class. (FindFirstChildOfClass is recursive=false by default; we
    -- recurse manually.)
    local function findExample(className, root)
        if not root then return nil end
        local ok, descendants = pcall(function() return root:GetDescendants() end)
        if not ok then return nil end
        for _, d in descendants do
            local okT, isA = pcall(function() return d:IsA(className) end)
            if okT and isA then return d end
        end
        return nil
    end
    local roots = {}
    pcall(function()
        roots[#roots + 1] = game:GetService("ReplicatedStorage")
        roots[#roots + 1] = game:GetService("ReplicatedFirst")
        roots[#roots + 1] = game:GetService("Workspace")
    end)
    local distinct = {}
    for _, spec in METHOD_SPECS do distinct[spec.class] = true end
    for className in distinct do
        for _, root in roots do
            local inst = findExample(className, root)
            if inst then examples[className] = inst; break end
        end
    end
    local hookedAny = false
    for _, spec in METHOD_SPECS do
        local inst = examples[spec.class]
        if inst then
            local methodFn = inst[spec.method]
            if type(methodFn) == "function" and not self._hookedMethods[methodFn] then
                local original
                local function replacement(self_arg, ...)
                    local checkcaller = self:_resolve("checkcaller")
                    if not (checkcaller and checkcaller()) then
                        local args = table.pack(...)
                        self:_captureCall(spec, self_arg, args, args.n)
                    end
                    return original(self_arg, ...)
                end
                local ok, prev = pcall(hookfunction, methodFn, replacement)
                if ok then
                    self._hookedMethods[methodFn] = prev
                    original = prev
                    hookedAny = true
                end
            end
        end
    end
    if hookedAny then
        self._stats.installMode = "hookfunction"
        return true
    end
    return false
end

function NetworkTracer:install()
    if self._installed then return true, "already installed" end
    if self:_installNamecallHook() then
        self._installed = true
        if self._logger then self._logger:info("NetworkTracer: installed via namecall hook") end
        return true
    end
    if self:_installPerMethodHooks() then
        self._installed = true
        if self._logger then self._logger:info("NetworkTracer: installed via per-method hookfunction") end
        return true
    end
    if self._logger then
        self._logger:warn("NetworkTracer: install failed (no hookmetamethod or hookfunction available)")
    end
    return false, "no available hook primitives"
end

-- ---------------------------------------------------------------------
-- Capture control
-- ---------------------------------------------------------------------

function NetworkTracer:pause()  self._paused = true end
function NetworkTracer:resume() self._paused = false end
function NetworkTracer:isPaused() return self._paused end

function NetworkTracer:clear()
    self._ring = table.create(self._ringSize)
    self._ringHead  = 0
    self._ringCount = 0
end

function NetworkTracer:setFilter(className, enabled)
    self._filters[className] = enabled and true or false
end

function NetworkTracer:filters() return self._filters end

-- ---------------------------------------------------------------------
-- Entry queries
-- ---------------------------------------------------------------------

function NetworkTracer:entries(opts)
    opts = opts or {}
    local out = {}
    local n = self._ringCount
    if n == 0 then return out end
    -- Iterate oldest → newest
    local startIdx
    if n < self._ringSize then
        startIdx = 1                                                 -- ring not yet wrapped
    else
        startIdx = (self._ringHead % self._ringSize) + 1
    end
    for i = 0, n - 1 do
        local idx = ((startIdx - 1 + i) % self._ringSize) + 1
        local e = self._ring[idx]
        if e then
            local accept = true
            if opts.direction and e.direction ~= opts.direction then accept = false end
            if accept and opts.kind and e.kind ~= opts.kind then accept = false end
            if accept and opts.pathSubstring then
                if not string.find(string.lower(e.path), string.lower(opts.pathSubstring), 1, true) then
                    accept = false
                end
            end
            if accept then out[#out + 1] = e end
        end
    end
    return out
end

function NetworkTracer:latest(n)
    local entries = self:entries()
    n = n or 50
    if #entries <= n then return entries end
    local out = table.create(n)
    for i = 1, n do out[i] = entries[#entries - n + i] end
    return out
end

function NetworkTracer:byId(id)
    for i = 1, self._ringCount do
        if self._ring[i] and self._ring[i].id == id then
            return self._ring[i]
        end
    end
    return nil
end

-- ---------------------------------------------------------------------
-- Re-emit (replay): re-fire a captured outgoing call with stored args.
-- Useful for replaying a malformed or suspicious payload while testing.
-- ---------------------------------------------------------------------

function NetworkTracer:replay(entryId)
    local entry = self:byId(entryId)
    if not entry then return false, "no such entry" end
    if not entry.instance or not entry.rawArgs then return false, "no live ref" end
    local methodFn = entry.instance[entry.method]
    if type(methodFn) ~= "function" then return false, "method not on instance" end
    local ok, err = pcall(function()
        methodFn(entry.instance, table.unpack(entry.rawArgs, 1, entry.argCount))
    end)
    return ok, err
end

-- ---------------------------------------------------------------------
-- Stats
-- ---------------------------------------------------------------------

function NetworkTracer:stats()
    return {
        captured        = self._stats.captured,
        droppedByFilter = self._stats.droppedByFilter,
        byClass         = self._stats.byClass,
        byMethod        = self._stats.byMethod,
        installed       = self._installed,
        installMode     = self._stats.installMode,
        paused          = self._paused,
        ringCount       = self._ringCount,
        ringSize        = self._ringSize,
    }
end

return NetworkTracer
