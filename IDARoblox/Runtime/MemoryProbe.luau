--!nonstrict
-- =====================================================================
-- IDARoblox / Runtime / MemoryProbe
-- ---------------------------------------------------------------------
-- Raw memory access wrapped behind a typed read/write API. Only
-- functional when the executor exposes the corresponding primitives.
-- Capability detection at construction; every read/write fails cleanly
-- with a descriptive error when unavailable.
--
-- Primitives consulted (any subset may be present):
--   readinteger, writeinteger
--   readbyte, writebyte, readu16, writeu16, readu32, writeu32, readu64
--   readfloat, writefloat, readdouble, writedouble
--   readstring, writestring
--   readmemory, writememory
--   getluastate, getfunctionaddress, getfunctionhash
--
-- The MemoryProbe NEVER calls these without:
--   * capability check at boot
--   * address bounds check against any user-registered Region
--   * pcall around every primitive
--
-- Region API
--   probe:defineRegion("script_bytecode", base, size, { readonly = true })
--   probe:readInRegion("script_bytecode", offset, "u32")
--
-- Functions
--   probe:functionPointer(fn) → number address (if getfunctionaddress
--   exists), else nil.
-- =====================================================================

local MemoryProbe = {}
MemoryProbe.__index = MemoryProbe

-- Type sizes for the bounds calculation
local TYPE_SIZE = {
    u8 = 1, i8 = 1,
    u16 = 2, i16 = 2,
    u32 = 4, i32 = 4,
    u64 = 8, i64 = 8,
    f32 = 4, f64 = 8,
}

-- ---------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------

function MemoryProbe.new(opts)
    opts = opts or {}
    local self = setmetatable({
        _scanner  = opts.scanner,
        _logger   = opts.logger,
        _eventBus = opts.eventBus,
        _regions  = {},                                              -- name → { base, size, readonly }
        _caps     = nil,
        _stats = {
            reads        = 0,
            writes       = 0,
            readsFailed  = 0,
            writesFailed = 0,
            writesRefused = 0,
            regionsDefined = 0,
        },
    }, MemoryProbe)
    self:_detectCapabilities()
    return self
end

function MemoryProbe:setScanner(s) self._scanner = s; self:_detectCapabilities() end

local function fetch(scanner, name)
    if scanner and type(scanner.getRaw) == "function" then
        return scanner:getRaw(name)
    end
    return getfenv(0)[name]
end

function MemoryProbe:_detectCapabilities()
    local s = self._scanner
    local caps = {
        readbyte       = fetch(s, "readbyte"),
        writebyte      = fetch(s, "writebyte"),
        readu16        = fetch(s, "readu16"),
        writeu16       = fetch(s, "writeu16"),
        readu32        = fetch(s, "readu32"),
        writeu32       = fetch(s, "writeu32"),
        readu64        = fetch(s, "readu64"),                        -- often missing
        readinteger    = fetch(s, "readinteger"),
        writeinteger   = fetch(s, "writeinteger"),
        readfloat      = fetch(s, "readfloat"),
        writefloat     = fetch(s, "writefloat"),
        readdouble     = fetch(s, "readdouble"),
        writedouble    = fetch(s, "writedouble"),
        readstring     = fetch(s, "readstring"),
        writestring    = fetch(s, "writestring"),
        readmemory     = fetch(s, "readmemory"),
        writememory    = fetch(s, "writememory"),
        getluastate    = fetch(s, "getluastate"),
        getfunctionaddress = fetch(s, "getfunctionaddress"),
        getfunctionhash    = fetch(s, "getfunctionhash"),
    }
    self._caps = caps
    if self._logger then
        local n = 0
        for _, v in pairs(caps) do if v then n = n + 1 end end
        self._logger:info("MemoryProbe: %d raw-memory capabilities detected", n)
    end
end

function MemoryProbe:capabilities() return self._caps end

-- ---------------------------------------------------------------------
-- Region API
-- ---------------------------------------------------------------------

function MemoryProbe:defineRegion(name, base, size, opts)
    opts = opts or {}
    if type(base) ~= "number" or type(size) ~= "number" or size <= 0 then
        return false, "base + size must be positive numbers"
    end
    if self._regions[name] then
        return false, "region already defined: " .. name
    end
    self._regions[name] = {
        name     = name,
        base     = base,
        size     = size,
        readonly = opts.readonly == true,
        label    = opts.label or name,
        definedAt = os.time(),
    }
    self._stats.regionsDefined = self._stats.regionsDefined + 1
    return true
end

function MemoryProbe:undefineRegion(name)
    if self._regions[name] then
        self._regions[name] = nil
        return true
    end
    return false, "no such region"
end

function MemoryProbe:listRegions()
    local out = {}
    for _, r in self._regions do out[#out + 1] = r end
    table.sort(out, function(a, b) return a.base < b.base end)
    return out
end

local function regionContaining(self, addr, len)
    for _, r in self._regions do
        if addr >= r.base and (addr + len) <= (r.base + r.size) then
            return r
        end
    end
    return nil
end

-- ---------------------------------------------------------------------
-- Read helpers
-- ---------------------------------------------------------------------

local function read(self, kind, addr)
    local sz = TYPE_SIZE[kind]
    if not sz then return nil, "unsupported kind: " .. tostring(kind) end
    -- If the caller has any regions defined, enforce bounds. Otherwise
    -- allow free-form addressing (executor sandbox should still kill
    -- bad pointers).
    if next(self._regions) ~= nil then
        if not regionContaining(self, addr, sz) then
            self._stats.readsFailed = self._stats.readsFailed + 1
            return nil, string.format(
                "address %s+%d not in any defined region", tostring(addr), sz)
        end
    end
    local caps = self._caps
    local primitive
    if kind == "u8" or kind == "i8" then primitive = caps.readbyte
    elseif kind == "u16" or kind == "i16" then primitive = caps.readu16
    elseif kind == "u32" or kind == "i32" then primitive = caps.readu32
    elseif kind == "u64" or kind == "i64" then primitive = caps.readu64 or caps.readinteger
    elseif kind == "f32" then primitive = caps.readfloat
    elseif kind == "f64" then primitive = caps.readdouble
    end
    if not primitive then
        self._stats.readsFailed = self._stats.readsFailed + 1
        return nil, "no primitive for " .. kind
    end
    local ok, val = pcall(primitive, addr)
    if not ok then
        self._stats.readsFailed = self._stats.readsFailed + 1
        return nil, "read failed: " .. tostring(val)
    end
    self._stats.reads = self._stats.reads + 1
    return val
end

function MemoryProbe:readU8(addr)   return read(self, "u8", addr)  end
function MemoryProbe:readI8(addr)   return read(self, "i8", addr)  end
function MemoryProbe:readU16(addr)  return read(self, "u16", addr) end
function MemoryProbe:readU32(addr)  return read(self, "u32", addr) end
function MemoryProbe:readU64(addr)  return read(self, "u64", addr) end
function MemoryProbe:readF32(addr)  return read(self, "f32", addr) end
function MemoryProbe:readF64(addr)  return read(self, "f64", addr) end

function MemoryProbe:readBytes(addr, len)
    if next(self._regions) ~= nil then
        if not regionContaining(self, addr, len) then
            self._stats.readsFailed = self._stats.readsFailed + 1
            return nil, "address out of any region"
        end
    end
    local primitive = self._caps.readmemory or self._caps.readstring
    if not primitive then
        self._stats.readsFailed = self._stats.readsFailed + 1
        return nil, "no readmemory / readstring primitive"
    end
    local ok, data = pcall(primitive, addr, len)
    if not ok then
        self._stats.readsFailed = self._stats.readsFailed + 1
        return nil, "readBytes failed: " .. tostring(data)
    end
    self._stats.reads = self._stats.reads + 1
    return data
end

function MemoryProbe:readCString(addr, maxLen)
    maxLen = maxLen or 4096
    local primitive = self._caps.readstring or self._caps.readmemory
    if primitive == self._caps.readstring and primitive then
        -- Some executors' readstring stops at the NUL
        local ok, data = pcall(primitive, addr, maxLen)
        if ok and type(data) == "string" then
            local nul = string.find(data, "\0", 1, true)
            if nul then return string.sub(data, 1, nul - 1) end
            return data
        end
    end
    -- Byte-wise fallback
    local out = {}
    for i = 0, maxLen - 1 do
        local b = self:readU8(addr + i)
        if not b or b == 0 then break end
        out[#out + 1] = string.char(b)
    end
    return table.concat(out)
end

-- ---------------------------------------------------------------------
-- Write helpers
-- ---------------------------------------------------------------------

local function write(self, kind, addr, value)
    local sz = TYPE_SIZE[kind]
    if not sz then return false, "unsupported kind: " .. tostring(kind) end
    if next(self._regions) ~= nil then
        local r = regionContaining(self, addr, sz)
        if not r then
            self._stats.writesRefused = self._stats.writesRefused + 1
            return false, "address out of any region"
        end
        if r.readonly then
            self._stats.writesRefused = self._stats.writesRefused + 1
            return false, "region '" .. r.name .. "' is readonly"
        end
    end
    local caps = self._caps
    local primitive
    if kind == "u8" or kind == "i8" then primitive = caps.writebyte
    elseif kind == "u16" or kind == "i16" then primitive = caps.writeu16
    elseif kind == "u32" or kind == "i32" then primitive = caps.writeu32
    elseif kind == "u64" or kind == "i64" then primitive = caps.writeinteger
    elseif kind == "f32" then primitive = caps.writefloat
    elseif kind == "f64" then primitive = caps.writedouble
    end
    if not primitive then
        self._stats.writesFailed = self._stats.writesFailed + 1
        return false, "no primitive for " .. kind
    end
    local ok, err = pcall(primitive, addr, value)
    if not ok then
        self._stats.writesFailed = self._stats.writesFailed + 1
        return false, "write failed: " .. tostring(err)
    end
    self._stats.writes = self._stats.writes + 1
    return true
end

function MemoryProbe:writeU8(addr, v)   return write(self, "u8", addr, v)  end
function MemoryProbe:writeU16(addr, v)  return write(self, "u16", addr, v) end
function MemoryProbe:writeU32(addr, v)  return write(self, "u32", addr, v) end
function MemoryProbe:writeU64(addr, v)  return write(self, "u64", addr, v) end
function MemoryProbe:writeF32(addr, v)  return write(self, "f32", addr, v) end
function MemoryProbe:writeF64(addr, v)  return write(self, "f64", addr, v) end

function MemoryProbe:writeBytes(addr, data)
    if next(self._regions) ~= nil then
        local r = regionContaining(self, addr, #data)
        if not r then
            self._stats.writesRefused = self._stats.writesRefused + 1
            return false, "address out of any region"
        end
        if r.readonly then
            self._stats.writesRefused = self._stats.writesRefused + 1
            return false, "region '" .. r.name .. "' is readonly"
        end
    end
    local primitive = self._caps.writememory or self._caps.writestring
    if not primitive then
        self._stats.writesFailed = self._stats.writesFailed + 1
        return false, "no writememory / writestring primitive"
    end
    local ok, err = pcall(primitive, addr, data)
    if not ok then
        self._stats.writesFailed = self._stats.writesFailed + 1
        return false, "writeBytes failed: " .. tostring(err)
    end
    self._stats.writes = self._stats.writes + 1
    return true
end

-- ---------------------------------------------------------------------
-- Function pointer
-- ---------------------------------------------------------------------

function MemoryProbe:functionPointer(fn)
    if type(fn) ~= "function" then return nil, "fn must be function" end
    local p = self._caps.getfunctionaddress
    if not p then return nil, "getfunctionaddress unavailable" end
    local ok, addr = pcall(p, fn)
    if not ok then return nil, "getfunctionaddress failed: " .. tostring(addr) end
    return addr
end

function MemoryProbe:functionHash(fn)
    local p = self._caps.getfunctionhash
    if not p then return nil, "getfunctionhash unavailable" end
    local ok, h = pcall(p, fn)
    if not ok then return nil, "getfunctionhash failed: " .. tostring(h) end
    return h
end

function MemoryProbe:luaState()
    local p = self._caps.getluastate
    if not p then return nil, "getluastate unavailable" end
    local ok, s = pcall(p)
    if not ok then return nil, "getluastate failed: " .. tostring(s) end
    return s
end

-- ---------------------------------------------------------------------
-- Pattern scan within a region
-- ---------------------------------------------------------------------

-- pattern: array of { byte = N | nil (wildcard) }
function MemoryProbe:scan(regionName, pattern, opts)
    opts = opts or {}
    local maxMatches = opts.maxMatches or math.huge
    local region = self._regions[regionName]
    if not region then return nil, "no such region: " .. tostring(regionName) end
    if not self._caps.readmemory then return nil, "readmemory unavailable" end
    if type(pattern) ~= "table" or #pattern == 0 then
        return nil, "pattern must be non-empty array of {byte} entries"
    end
    local matches = {}
    local plen = #pattern
    local chunkSize = math.min(region.size, 65536)
    local pos = 0
    while pos + plen <= region.size do
        local readLen = math.min(chunkSize, region.size - pos)
        local ok, chunk = pcall(self._caps.readmemory, region.base + pos, readLen)
        if not ok then return nil, "chunk read failed: " .. tostring(chunk) end
        if type(chunk) == "string" then
            local maxOffset = #chunk - plen
            for i = 0, maxOffset do
                local matched = true
                for j = 1, plen do
                    local p = pattern[j]
                    if p.byte ~= nil then
                        if string.byte(chunk, i + j) ~= p.byte then
                            matched = false; break
                        end
                    end
                end
                if matched then
                    matches[#matches + 1] = region.base + pos + i
                    if #matches >= maxMatches then return matches end
                end
            end
        end
        pos = pos + readLen
        if task and task.wait and (pos / chunkSize) % 8 == 0 then task.wait() end
    end
    return matches
end

function MemoryProbe:stats()
    return {
        reads          = self._stats.reads,
        writes         = self._stats.writes,
        readsFailed    = self._stats.readsFailed,
        writesFailed   = self._stats.writesFailed,
        writesRefused  = self._stats.writesRefused,
        regionsDefined = self._stats.regionsDefined,
        regionCount    = (function()
            local n = 0; for _ in self._regions do n = n + 1 end; return n
        end)(),
        capabilities = (function()
            local out = {}
            for k, v in self._caps do if v then out[#out + 1] = k end end
            table.sort(out)
            return out
        end)(),
    }
end

return MemoryProbe
