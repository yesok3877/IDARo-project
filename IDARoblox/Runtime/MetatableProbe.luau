--!nonstrict
-- =====================================================================
-- IDARoblox / Runtime / MetatableProbe
-- ---------------------------------------------------------------------
-- Deep introspection of metatables. Reads every standard metamethod,
-- detects readonly-locked tables, walks the __index inheritance chain,
-- classifies the OOP pattern, and supports temporary unlocking +
-- patching of methods with full revert.
--
-- Inspect output
--   {
--     ref = obj,
--     hasMt = boolean,
--     locked = boolean,                              (setreadonly applied)
--     metamethods = {                                (true if defined)
--       __index, __newindex, __call, __metatable,
--       __tostring, __len, __concat, __unm, __add, __sub, __mul, __div,
--       __idiv, __mod, __pow, __eq, __lt, __le, __gc, __mode, __close,
--       __namecall, __iter, __type
--     },
--     indexKind = "table" | "function" | nil,
--     indexChain = [{ depth, table, sampledFields }]    (only for table-__index)
--     pattern = "class" | "mixin" | "tagged-table" | "raw-table" | "instance",
--     className = "Vector3" | "Player" | …                   (best-effort)
--     -- For real Roblox Instances:
--     instance = { className, fullName, parent }
--   }
-- =====================================================================

local MetatableProbe = {}
MetatableProbe.__index = MetatableProbe

local STANDARD_METAMETHODS = {
    "__index", "__newindex", "__call", "__metatable",
    "__tostring", "__len", "__concat", "__unm",
    "__add", "__sub", "__mul", "__div", "__idiv",
    "__mod", "__pow", "__eq", "__lt", "__le",
    "__gc", "__mode", "__close",
    "__namecall", "__iter", "__type",
}

local MAX_CHAIN_DEPTH = 8

-- ---------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------

function MetatableProbe.new(opts)
    opts = opts or {}
    return setmetatable({
        _scanner   = opts.scanner,
        _logger    = opts.logger,
        _eventBus  = opts.eventBus,
        _patchLog  = {},                                             -- mt → { patches = [...], wasLocked = bool }
        _cache     = {},                                             -- obj → snap
        _stats = {
            inspected     = 0,
            chainsWalked  = 0,
            methodsReplaced = 0,
            locksOverridden = 0,
            writesRefused = 0,
            writesFailed  = 0,
        },
    }, MetatableProbe)
end

function MetatableProbe:setScanner(s) self._scanner = s; self._cache = {} end

local function fetch(scanner, name)
    if scanner and type(scanner.getRaw) == "function" then
        return scanner:getRaw(name)
    end
    return getfenv(0)[name]
end

local function emit(self, evt, payload)
    if self._eventBus and type(self._eventBus.emit) == "function" then
        pcall(self._eventBus.emit, self._eventBus, evt, payload)
    end
end

-- ---------------------------------------------------------------------
-- Capability accessors
-- ---------------------------------------------------------------------

function MetatableProbe:_getrawmetatable() return fetch(self._scanner, "getrawmetatable") end
function MetatableProbe:_setrawmetatable() return fetch(self._scanner, "setrawmetatable") end
function MetatableProbe:_setreadonly()    return fetch(self._scanner, "setreadonly")    end
function MetatableProbe:_isreadonly()     return fetch(self._scanner, "isreadonly")     end
function MetatableProbe:_make_writable()  return fetch(self._scanner, "make_writeable") or fetch(self._scanner, "make_writable") end

-- ---------------------------------------------------------------------
-- Sample fields for chain display
-- ---------------------------------------------------------------------

local function sampleFields(t, n)
    local out = {}
    local count = 0
    for k, v in pairs(t) do
        if type(k) == "string" then
            out[#out + 1] = { key = k, valueKind = type(v) }
            count = count + 1
            if count >= n then break end
        end
    end
    table.sort(out, function(a, b) return a.key < b.key end)
    return out
end

local function classifyMt(mt, idxKind, chainLen)
    if not mt then return "raw-table" end
    if type(mt.__index) == "function" then return "tagged-table" end
    if idxKind == "table" then
        if chainLen >= 2 then return "class" end
        if chainLen == 1 then return "mixin" end
    end
    if rawget(mt, "__type") or rawget(mt, "__metatable") then return "tagged-table" end
    return "raw-table"
end

local function classNameOf(mt)
    if type(mt) ~= "table" then return nil end
    -- __type direct
    local t = rawget(mt, "__type")
    if type(t) == "string" then return t end
    -- __metatable === string lock
    local m = rawget(mt, "__metatable")
    if type(m) == "string" then return m end
    -- __index.ClassName
    local idx = rawget(mt, "__index")
    if type(idx) == "table" then
        local cn = rawget(idx, "ClassName")
        if type(cn) == "string" then return cn end
    end
    return nil
end

-- ---------------------------------------------------------------------
-- inspect
-- ---------------------------------------------------------------------

function MetatableProbe:inspect(obj, opts)
    opts = opts or {}
    if self._cache[obj] and not opts.refresh then return self._cache[obj] end

    local snap = {
        ref         = obj,
        type        = type(obj),
        hasMt       = false,
        locked      = false,
        metamethods = {},
        indexKind   = nil,
        indexChain  = {},
        pattern     = "raw-table",
        className   = nil,
    }
    local getMt = self:_getrawmetatable()
    if not getMt then
        if type(obj) == "table" then
            -- Fall back to standard getmetatable (will be nil if __metatable locked)
            local ok, mt = pcall(getmetatable, obj)
            if ok and mt then
                snap.hasMt = true
                for _, k in STANDARD_METAMETHODS do
                    if rawget(mt, k) ~= nil then snap.metamethods[k] = true end
                end
            end
        end
        self._cache[obj] = snap
        self._stats.inspected = self._stats.inspected + 1
        return snap
    end

    local ok, mt = pcall(getMt, obj)
    if not ok or mt == nil then
        self._cache[obj] = snap
        self._stats.inspected = self._stats.inspected + 1
        return snap
    end
    snap.hasMt = true

    -- Readonly check
    local isRO = self:_isreadonly()
    if isRO then
        local okRO, ro = pcall(isRO, mt)
        snap.locked = okRO and ro == true
    end

    -- Probe every standard metamethod
    for _, k in STANDARD_METAMETHODS do
        local v = rawget(mt, k)
        if v ~= nil then snap.metamethods[k] = true end
    end

    -- Index kind + chain walk
    local idx = rawget(mt, "__index")
    if type(idx) == "function" then
        snap.indexKind = "function"
    elseif type(idx) == "table" then
        snap.indexKind = "table"
        -- Walk the chain
        local visited = {}
        local cur = idx
        local depth = 0
        while type(cur) == "table" and depth < MAX_CHAIN_DEPTH and not visited[cur] do
            visited[cur] = true
            snap.indexChain[#snap.indexChain + 1] = {
                depth = depth,
                table = cur,
                sampledFields = sampleFields(cur, 8),
            }
            depth = depth + 1
            -- Follow this table's own metatable's __index for further chain
            local okMt, nextMt = pcall(getMt, cur)
            if okMt and type(nextMt) == "table" then
                cur = rawget(nextMt, "__index")
            else
                cur = nil
            end
        end
        self._stats.chainsWalked = self._stats.chainsWalked + 1
    end

    snap.pattern   = classifyMt(mt, snap.indexKind, #snap.indexChain)
    snap.className = classNameOf(mt)

    -- Real Roblox Instance? Probe ClassName / GetFullName
    if type(obj) == "userdata" then
        local okCN, cn = pcall(function() return obj.ClassName end)
        if okCN and type(cn) == "string" then
            local okFN, fn = pcall(function() return obj:GetFullName() end)
            local okP, parent = pcall(function() return obj.Parent end)
            snap.instance = {
                className = cn,
                fullName  = okFN and fn or nil,
                parent    = okP and parent or nil,
            }
            snap.className = cn
            snap.pattern = "instance"
        end
    end

    self._cache[obj] = snap
    self._stats.inspected = self._stats.inspected + 1
    return snap
end

function MetatableProbe:refresh(obj) return self:inspect(obj, { refresh = true }) end

-- ---------------------------------------------------------------------
-- Lock helpers
-- ---------------------------------------------------------------------

function MetatableProbe:isLocked(obj)
    local snap = self:inspect(obj)
    return snap and snap.locked or false
end

local function withUnlocked(self, mt, fn)
    local setRO = self:_setreadonly()
    local makeW = self:_make_writable()
    local wasLocked = false
    if self:_isreadonly() then
        local okR, ro = pcall(self:_isreadonly(), mt)
        wasLocked = okR and ro == true
    end
    if wasLocked then
        if makeW then pcall(makeW, mt)
        elseif setRO then pcall(setRO, mt, false)
        else return false, "cannot unlock metatable: no setreadonly / make_writable" end
        self._stats.locksOverridden = self._stats.locksOverridden + 1
    end
    local okFn, err = pcall(fn)
    if wasLocked and setRO then
        pcall(setRO, mt, true)
    end
    if not okFn then return false, "inner fn failed: " .. tostring(err) end
    return true
end

-- ---------------------------------------------------------------------
-- replaceMethod — patch a metamethod or an __index method
-- ---------------------------------------------------------------------

function MetatableProbe:replaceMethod(obj, name, newFn, opts)
    opts = opts or {}
    if type(newFn) ~= "function" then return false, "newFn must be function" end
    local getMt = self:_getrawmetatable()
    if not getMt then return false, "getrawmetatable unavailable" end
    local mt = (pcall(getMt, obj) and getMt(obj)) or nil
    if not mt then return false, "no metatable" end

    -- Determine target: direct metamethod (starts with __) or __index field
    local isMetaMM = string.sub(name, 1, 2) == "__"
    local targetTbl, oldValue
    if isMetaMM then
        targetTbl = mt
        oldValue  = rawget(mt, name)
    else
        local idx = rawget(mt, "__index")
        if type(idx) ~= "table" then
            return false, "__index is not a table; cannot install named method"
        end
        targetTbl = idx
        oldValue  = rawget(idx, name)
    end

    local ok, err = withUnlocked(self, targetTbl, function()
        rawset(targetTbl, name, newFn)
    end)
    if not ok then
        self._stats.writesFailed = self._stats.writesFailed + 1
        return false, err
    end

    -- Record patch
    local log = self._patchLog[mt]
    if not log then log = { patches = {}, mt = mt, target = obj }; self._patchLog[mt] = log end
    log.patches[#log.patches + 1] = {
        target    = targetTbl,
        name      = name,
        oldValue  = oldValue,
        newValue  = newFn,
        isMetaMM  = isMetaMM,
        at        = os.time(),
    }
    self._cache[obj] = nil                                            -- invalidate inspect cache
    self._stats.methodsReplaced = self._stats.methodsReplaced + 1
    emit(self, "metatable.methodReplaced",
        { obj = obj, name = name, oldValue = oldValue, newValue = newFn })
    return true
end

-- ---------------------------------------------------------------------
-- Revert patches
-- ---------------------------------------------------------------------

function MetatableProbe:revertAll(obj)
    local getMt = self:_getrawmetatable()
    if not getMt then return 0 end
    local mt = (pcall(getMt, obj) and getMt(obj)) or nil
    if not mt then return 0 end
    local log = self._patchLog[mt]
    if not log then return 0 end
    local reverted = 0
    for i = #log.patches, 1, -1 do
        local p = log.patches[i]
        local ok = withUnlocked(self, p.target, function()
            rawset(p.target, p.name, p.oldValue)
        end)
        if ok then reverted = reverted + 1 end
    end
    self._patchLog[mt] = nil
    self._cache[obj] = nil
    emit(self, "metatable.allReverted", { obj = obj, count = reverted })
    return reverted
end

-- ---------------------------------------------------------------------
-- Bulk inspection
-- ---------------------------------------------------------------------

function MetatableProbe:inspectMany(objs)
    local out = {}
    for i, o in objs do out[i] = self:inspect(o) end
    return out
end

function MetatableProbe:findByClassName(name, candidates)
    local out = {}
    for _, c in candidates do
        local snap = self:inspect(c)
        if snap and snap.className == name then out[#out + 1] = snap end
    end
    return out
end

function MetatableProbe:findInstancesOf(className, candidates)
    local out = {}
    for _, c in candidates do
        local snap = self:inspect(c)
        if snap and snap.instance and snap.instance.className == className then
            out[#out + 1] = snap
        end
    end
    return out
end

function MetatableProbe:stats()
    local patched = 0; local totalPatches = 0
    for _, log in self._patchLog do
        patched = patched + 1
        totalPatches = totalPatches + #log.patches
    end
    return {
        inspected       = self._stats.inspected,
        chainsWalked    = self._stats.chainsWalked,
        methodsReplaced = self._stats.methodsReplaced,
        locksOverridden = self._stats.locksOverridden,
        writesRefused   = self._stats.writesRefused,
        writesFailed    = self._stats.writesFailed,
        patchedTables   = patched,
        totalPatches    = totalPatches,
        cacheSize       = (function()
            local n = 0; for _ in self._cache do n = n + 1 end; return n
        end)(),
    }
end

return MetatableProbe
