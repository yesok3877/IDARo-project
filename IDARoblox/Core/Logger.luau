--!nonstrict
-- =====================================================================
-- IDARoblox / Core / Logger
-- ---------------------------------------------------------------------
-- Structured logger with:
--   * Numeric levels (TRACE/DEBUG/INFO/WARN/ERROR/FATAL)
--   * Per-tag level filtering — a single tree-shaped tag namespace
--     ("Analysis.BytecodeParser") with inheritance
--   * Ring-buffered in-memory history (configurable size)
--   * Pluggable sinks (console, ring, custom — e.g. the OutputView)
--   * Lazy-format closures: `log:trace(function() return expensive() end)`
--     never invokes the function unless the level is enabled
--   * Sub-loggers (`log:child("Sub")`) inherit level and sinks
--   * Snapshot/dump for crash reports
-- =====================================================================

local Logger = {}
Logger.__index = Logger

Logger.Level = {
    TRACE = 10,
    DEBUG = 20,
    INFO  = 30,
    WARN  = 40,
    ERROR = 50,
    FATAL = 60,
    OFF   = 1000,
}

local LEVEL_NAMES = {
    [10] = "TRACE", [20] = "DEBUG", [30] = "INFO",
    [40] = "WARN",  [50] = "ERROR", [60] = "FATAL",
}

local LEVEL_COLORS = {                                              -- ANSI for executors with stdout
    [10] = "\27[90m",   -- bright black
    [20] = "\27[36m",   -- cyan
    [30] = "\27[37m",   -- white
    [40] = "\27[33m",   -- yellow
    [50] = "\27[31m",   -- red
    [60] = "\27[35m",   -- magenta
}
local ANSI_RESET = "\27[0m"

-- ---------------------------------------------------------------------
-- Sink: console
-- ---------------------------------------------------------------------

local function defaultConsoleSink(record)
    local color = LEVEL_COLORS[record.level] or ""
    local line = string.format(
        "%s[%s] [%-5s] [%s]%s %s",
        color, record.timeStr, LEVEL_NAMES[record.level] or "?",
        record.tag, ANSI_RESET, record.message
    )
    -- Roblox: print is the most universal; warn for >= WARN
    if record.level >= Logger.Level.WARN then
        warn(line)
    else
        print(line)
    end
end

-- ---------------------------------------------------------------------
-- Ring buffer
-- ---------------------------------------------------------------------

local function newRing(size)
    return {
        size    = size,
        items   = table.create(size),
        head    = 0,                                                -- next write index (0-indexed)
        count   = 0,
        seq     = 0,                                                -- monotonic write counter
    }
end

local function ringPush(ring, item)
    ring.seq = ring.seq + 1
    item.seq = ring.seq
    ring.head = (ring.head % ring.size) + 1
    ring.items[ring.head] = item
    if ring.count < ring.size then ring.count = ring.count + 1 end
end

local function ringSnapshot(ring)
    local out = table.create(ring.count)
    if ring.count == 0 then return out end
    if ring.count < ring.size then
        for i = 1, ring.count do out[i] = ring.items[i] end
    else
        local idx = ring.head
        for i = 1, ring.size do
            idx = (idx % ring.size) + 1
            out[i] = ring.items[idx]
        end
    end
    return out
end

-- ---------------------------------------------------------------------
-- Manager singleton (one per project)
-- ---------------------------------------------------------------------

local Manager = {}
Manager.__index = Manager

function Manager.new(opts)
    opts = opts or {}
    local self = setmetatable({
        _tagLevels    = {},                                         -- exact tag → min level
        _defaultLevel = opts.defaultLevel or Logger.Level.INFO,
        _sinks        = table.create(4),
        _ring         = newRing(opts.ringSize or 1024),
        _formatter    = opts.formatter or string.format,
        _enabled      = true,
        _start        = os.clock(),
    }, Manager)
    -- Default sinks: console + ring
    table.insert(self._sinks, defaultConsoleSink)
    table.insert(self._sinks, function(rec) ringPush(self._ring, rec) end)
    if opts.sinks then
        for _, s in opts.sinks do table.insert(self._sinks, s) end
    end
    return self
end

function Manager:setLevel(tag: string?, level: number)
    if tag == nil or tag == "*" then
        self._defaultLevel = level
    else
        self._tagLevels[tag] = level
    end
end

-- Resolve effective level via dot-path inheritance:
-- "A.B.C" walks "A.B.C" → "A.B" → "A" → default
function Manager:effectiveLevel(tag: string): number
    local explicit = self._tagLevels[tag]
    if explicit then return explicit end
    local s = tag
    while true do
        local dot = string.find(s, "%.[^%.]*$")
        if not dot then break end
        s = string.sub(s, 1, dot - 1)
        explicit = self._tagLevels[s]
        if explicit then return explicit end
    end
    return self._defaultLevel
end

function Manager:addSink(sink)
    table.insert(self._sinks, sink)
    return function()
        for i, s in self._sinks do if s == sink then table.remove(self._sinks, i) return end end
    end
end

function Manager:disable() self._enabled = false end
function Manager:enable()  self._enabled = true  end

function Manager:_dispatch(tag, level, message, fields)
    if not self._enabled then return end
    if level < self:effectiveLevel(tag) then return end
    local now = os.clock() - self._start
    local timeStr = string.format("%9.3f", now)
    local rec = {
        time     = now,
        timeStr  = timeStr,
        level    = level,
        tag      = tag,
        message  = message,
        fields   = fields,
    }
    for _, sink in self._sinks do
        local ok, err = pcall(sink, rec)
        if not ok then
            -- Avoid recursion; print directly
            print(string.format("[Logger] sink error: %s", tostring(err)))
        end
    end
end

function Manager:snapshot(): { any }
    return ringSnapshot(self._ring)
end

function Manager:dumpString(): string
    local lines = {}
    for _, rec in self:snapshot() do
        lines[#lines + 1] = string.format("[%s] [%-5s] [%s] %s",
            rec.timeStr, LEVEL_NAMES[rec.level] or "?", rec.tag, rec.message)
    end
    return table.concat(lines, "\n")
end

-- ---------------------------------------------------------------------
-- Logger instance (a view bound to a tag)
-- ---------------------------------------------------------------------

function Logger.new(opts): any
    -- Top-level Logger doubles as the manager; sub-loggers are bound to tags.
    local mgr = Manager.new(opts)
    local self = setmetatable({
        _manager = mgr,
        _tag     = (opts and opts.tag) or "IDARo",
    }, Logger)
    return self
end

function Logger:child(suffix: string)
    local newTag = if self._tag == "" then suffix else (self._tag .. "." .. suffix)
    return setmetatable({ _manager = self._manager, _tag = newTag }, Logger)
end

function Logger:setLevel(level: number, tag: string?)
    self._manager:setLevel(tag or self._tag, level)
end

function Logger:addSink(sink) return self._manager:addSink(sink) end
function Logger:snapshot()    return self._manager:snapshot() end
function Logger:dumpString()  return self._manager:dumpString() end
function Logger:disable()     self._manager:disable() end
function Logger:enable()      self._manager:enable()  end

-- ---------------------------------------------------------------------
-- Logging methods — each supports either (msg, ...) printf-style OR a
-- single function that returns the message (lazy formatting).
-- ---------------------------------------------------------------------

local function emit(self, level, first, ...)
    if level < self._manager:effectiveLevel(self._tag) then return end
    local msg
    if type(first) == "function" then
        local ok, r = pcall(first)
        msg = if ok then tostring(r) else string.format("<format error: %s>", tostring(r))
    elseif select("#", ...) > 0 then
        local ok, r = pcall(string.format, first, ...)
        msg = if ok then r else tostring(first)
    else
        msg = tostring(first)
    end
    self._manager:_dispatch(self._tag, level, msg, nil)
end

function Logger:trace(first, ...) emit(self, Logger.Level.TRACE, first, ...) end
function Logger:debug(first, ...) emit(self, Logger.Level.DEBUG, first, ...) end
function Logger:info(first, ...)  emit(self, Logger.Level.INFO,  first, ...) end
function Logger:warn(first, ...)  emit(self, Logger.Level.WARN,  first, ...) end
function Logger:error(first, ...) emit(self, Logger.Level.ERROR, first, ...) end
function Logger:fatal(first, ...) emit(self, Logger.Level.FATAL, first, ...) end

function Logger:log(level, first, ...) emit(self, level, first, ...) end

-- Structured logging: fields table is preserved on the record.
function Logger:structured(level, message, fields)
    if level < self._manager:effectiveLevel(self._tag) then return end
    self._manager:_dispatch(self._tag, level, message, fields)
end

function Logger:isLevel(level: number): boolean
    return level >= self._manager:effectiveLevel(self._tag)
end

-- Assert helper that logs FATAL before erroring.
function Logger:assert(cond, msg, ...)
    if cond then return cond end
    local m = if select("#", ...) > 0 then string.format(msg, ...) else tostring(msg)
    emit(self, Logger.Level.FATAL, m)
    error(m, 2)
end

-- ---------------------------------------------------------------------
-- Scope timing helper — `local s = log:scope("parse"); ... s:done()`
-- ---------------------------------------------------------------------

local Scope = {}
Scope.__index = Scope

function Logger:scope(label: string, level: number?)
    return setmetatable({
        _logger = self,
        _label  = label,
        _level  = level or Logger.Level.DEBUG,
        _start  = os.clock(),
        _done   = false,
    }, Scope)
end

function Scope:done(extra: string?)
    if self._done then return end
    self._done = true
    local ms = (os.clock() - self._start) * 1000
    local msg = if extra
        then string.format("%s: %.3f ms (%s)", self._label, ms, extra)
        else string.format("%s: %.3f ms", self._label, ms)
    emit(self._logger, self._level, msg)
end

function Scope:cancel() self._done = true end

return Logger
