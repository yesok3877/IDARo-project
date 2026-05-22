--!nonstrict
-- =====================================================================
-- IDARoblox / Analysis / BytecodeReader
-- ---------------------------------------------------------------------
-- Specialized reader for Luau bytecode. Wraps Core.BinaryStream and adds
-- the format-specific decoders the parser needs:
--
--   reader:readHeader()        → { version, typesVersion }
--   reader:readStringTable()   → array of strings, 1-indexed
--   reader:readUserdataTypes() → array (v4+ typed-Luau type remap)
--   reader:readInstructions(n) → array of 32-bit instructions
--   reader:readLineInfo(n)     → function pc → line, lazily computed
--   reader:readDebugInfo(strs) → { locals = {...}, upvalues = {...} }
--   reader:readVarInt()        → unsigned LEB128
--   reader:readString(strs)    → looks up an interned string by id
--
-- All methods raise with a contextful error including the byte position
-- when they encounter malformed data.
-- =====================================================================

local BinaryStream = _G.IDARo.require("Core.BinaryStream")
local OpcodeTable  = _G.IDARo.require("Analysis.OpcodeTable")

local BytecodeReader = {}
BytecodeReader.__index = BytecodeReader

-- ---------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------

function BytecodeReader.new(bytes: string | buffer)
    local stream = BinaryStream.new(bytes)
    local self = setmetatable({
        _stream     = stream,
        _strings    = nil,                                          -- filled by readStringTable
        _strCount   = 0,
        _userdataTypes = {},
        _version    = 0,
        _typesVersion = 0,
        _context    = {},                                           -- stack of error-context labels
    }, BytecodeReader)
    return self
end

function BytecodeReader:bytesAvailable(): number
    return self._stream:remaining()
end

function BytecodeReader:tell(): number
    return self._stream:position()
end

-- ---------------------------------------------------------------------
-- Error helpers
-- ---------------------------------------------------------------------

function BytecodeReader:_pushContext(label: string)
    table.insert(self._context, label)
end

function BytecodeReader:_popContext()
    table.remove(self._context)
end

function BytecodeReader:_fail(msg: string): never
    local where = ""
    if #self._context > 0 then where = " [" .. table.concat(self._context, " > ") .. "]" end
    error(string.format("BytecodeReader@0x%X%s: %s", self._stream:position(), where, msg), 0)
end

local function withContext(self, label, fn, ...)
    self:_pushContext(label)
    local results = table.pack(pcall(fn, ...))
    self:_popContext()
    if not results[1] then error(results[2], 0) end
    return table.unpack(results, 2, results.n)
end

-- ---------------------------------------------------------------------
-- Primitive forwarders
-- ---------------------------------------------------------------------

function BytecodeReader:readU8()    return self._stream:readU8() end
function BytecodeReader:readU16()   return self._stream:readU16() end
function BytecodeReader:readU32()   return self._stream:readU32() end
function BytecodeReader:readI8()    return self._stream:readI8() end
function BytecodeReader:readI16()   return self._stream:readI16() end
function BytecodeReader:readI32()   return self._stream:readI32() end
function BytecodeReader:readF32()   return self._stream:readF32() end
function BytecodeReader:readF64()   return self._stream:readF64() end
function BytecodeReader:readVarInt(): number return self._stream:readVarInt() end
function BytecodeReader:readBytes(n: number): string return self._stream:readBytes(n) end

-- ---------------------------------------------------------------------
-- Header
-- ---------------------------------------------------------------------

function BytecodeReader:readHeader(): { version: number, typesVersion: number }
    local version = self._stream:readU8()

    -- Luau encodes "deserialization error" as version=0 followed by the
    -- error message text. Surface that distinctly so the parser can
    -- propagate it cleanly.
    if version == 0 then
        local rest = self._stream:remaining()
        local msg = self._stream:readBytes(rest)
        error("Luau bytecode error: " .. msg, 0)
    end

    if version < OpcodeTable.LBC_VERSION_MIN or version > OpcodeTable.LBC_VERSION_MAX then
        -- Hex-dump the first 32 bytes so the caller can see what was
        -- actually returned. Some executors wrap the bytecode in a
        -- header (length prefix, encryption marker, etc.) and the
        -- first byte we read isn't the real version.
        local total = (self._stream.length and self._stream:length()) or 0
        local snapshot
        local saveOk = pcall(function()
            self._stream:seek(1)
            local n = math.min(32, total)
            local bytes = self._stream:readBytes(n)
            local hexParts = {}
            for i = 1, #bytes do
                hexParts[i] = string.format("%02X", string.byte(bytes, i))
            end
            snapshot = table.concat(hexParts, " ")
        end)
        self:_fail(string.format(
            "Unsupported bytecode version %d (supported %d..%d). "
            .. "First %d bytes: %s%s",
            version, OpcodeTable.LBC_VERSION_MIN, OpcodeTable.LBC_VERSION_MAX,
            math.min(32, total),
            (saveOk and snapshot) or "<unavailable>",
            (total > 32) and " ..." or ""))
    end

    local typesVersion = 0
    if version >= 4 then
        typesVersion = self._stream:readU8()
        if typesVersion < OpcodeTable.LBC_TYPE_VERSION_MIN
            or typesVersion > OpcodeTable.LBC_TYPE_VERSION_MAX then
            self:_fail(string.format(
                "Unsupported types version %d (supported %d..%d)",
                typesVersion, OpcodeTable.LBC_TYPE_VERSION_MIN, OpcodeTable.LBC_TYPE_VERSION_MAX))
        end
    end

    self._version = version
    self._typesVersion = typesVersion
    return { version = version, typesVersion = typesVersion }
end

function BytecodeReader:version(): number      return self._version end
function BytecodeReader:typesVersion(): number return self._typesVersion end

-- ---------------------------------------------------------------------
-- String table (interned)
-- ---------------------------------------------------------------------
-- Format:
--   varint  count
--   for each:
--     varint  length
--     bytes   raw string bytes (no null terminator)
-- ---------------------------------------------------------------------

function BytecodeReader:readStringTable(): { string }
    self:_pushContext("strings")
    local count = self._stream:readVarInt()
    if count < 0 or count > 0x10000000 then
        self:_fail(string.format("Suspicious string-table count: %d", count))
    end
    local strings = table.create(count)
    for i = 1, count do
        local len = self._stream:readVarInt()
        if len < 0 or len > self._stream:remaining() then
            self:_fail(string.format("String %d has invalid length %d (remaining %d)",
                i, len, self._stream:remaining()))
        end
        strings[i] = if len == 0 then "" else self._stream:readBytes(len)
    end
    self._strings  = strings
    self._strCount = count
    self:_popContext()
    return strings
end

function BytecodeReader:string(id: number): string?
    if id == 0 then return nil end                                  -- 0 is reserved for "no string"
    if not self._strings then self:_fail("string requested before string table read") end
    local s = self._strings[id]
    if s == nil then self:_fail(string.format("string id %d out of range (have %d)", id, self._strCount)) end
    return s
end

-- ---------------------------------------------------------------------
-- Userdata type remap (typesVersion >= 1, present in v4+ bytecode)
-- ---------------------------------------------------------------------
-- Format:
--   while next byte != 0:
--     userdata_type_tag (u8)
--     name_string_id    (varint)
--   terminator: u8 0
-- Returns a map of typeTag → name.
-- ---------------------------------------------------------------------

function BytecodeReader:readUserdataTypes(): { [number]: string }
    if self._typesVersion < 2 then return {} end
    self:_pushContext("userdataTypes")
    local out = {}
    while true do
        local tag = self._stream:readU8()
        if tag == 0 then break end
        local nameId = self._stream:readVarInt()
        out[tag] = self:string(nameId)
    end
    self._userdataTypes = out
    self:_popContext()
    return out
end

-- ---------------------------------------------------------------------
-- Instructions
-- ---------------------------------------------------------------------

function BytecodeReader:readInstructions(sizecode: number): { number }
    if sizecode < 0 or sizecode > 0x1000000 then
        self:_fail(string.format("Suspicious sizecode: %d", sizecode))
    end
    local arr = table.create(sizecode)
    for i = 1, sizecode do
        arr[i] = self._stream:readU32()
    end
    return arr
end

-- ---------------------------------------------------------------------
-- Line info (compressed)
-- ---------------------------------------------------------------------
-- Two-tier scheme matching Luau's compiler:
--
--   1. linegaplog2   (uint8)
--   2. lineinfo[i]   (uint8 each, delta-coded, length=sizecode)
--      The "absolute" offset within its block, computed incrementally.
--   3. abslineinfo[k] (int32 each, count=ceil(sizecode / 2^linegaplog2))
--      The absolute base line at the start of each block.
--
--   line(pc) = abslineinfo[pc >> linegaplog2] + lineinfo[pc]
--
-- Returns a `lookup(pc) -> line` function plus the raw arrays for any
-- consumer (StringsView, decompiler) that wants to scan them.
-- ---------------------------------------------------------------------

function BytecodeReader:readLineInfo(sizecode: number)
    self:_pushContext("lineInfo")
    local linegaplog2 = self._stream:readU8()
    if linegaplog2 > 24 then
        self:_fail(string.format("Insane linegaplog2: %d", linegaplog2))
    end
    local intervalShift = linegaplog2
    local intervals = math.floor((sizecode - 1) / 2^intervalShift) + 1
    if sizecode == 0 then intervals = 0 end

    -- Per-instruction delta-coded uint8 — accumulate as we go.
    local lineinfo = table.create(sizecode)
    local lastOffset = 0
    for i = 1, sizecode do
        local delta = self._stream:readU8()
        lastOffset = (lastOffset + delta) % 256                     -- uint8 wraparound is intentional
        lineinfo[i] = lastOffset
    end

    -- Per-interval delta-coded int32 absolute bases.
    local abslineinfo = table.create(intervals)
    local lastLine = 0
    for i = 1, intervals do
        local delta = self._stream:readI32()
        lastLine = lastLine + delta
        abslineinfo[i] = lastLine
    end
    self:_popContext()

    -- Closure that resolves PC (1-based) → line number.
    local function lookup(pc: number): number
        if pc < 1 or pc > sizecode then return -1 end
        local block = math.floor((pc - 1) / 2^intervalShift) + 1
        local base = abslineinfo[block] or 0
        local off  = lineinfo[pc] or 0
        return base + off
    end
    return {
        linegaplog2 = linegaplog2,
        lineinfo    = lineinfo,
        abslineinfo = abslineinfo,
        lookup      = lookup,
    }
end

-- ---------------------------------------------------------------------
-- Debug info: locals + upvalues + (typed Luau) types
-- ---------------------------------------------------------------------
-- Format:
--   varint nLocals
--     for each:
--       varint  nameStringId
--       varint  startpc
--       varint  endpc
--       u8      reg
--   varint nUpvalues
--     for each:
--       varint  nameStringId
-- ---------------------------------------------------------------------

function BytecodeReader:readDebugInfo()
    self:_pushContext("debug")
    local stream = self._stream

    local nLocals = stream:readVarInt()
    local locals = table.create(nLocals)
    for i = 1, nLocals do
        local nameId  = stream:readVarInt()
        local startpc = stream:readVarInt()
        local endpc   = stream:readVarInt()
        local reg     = stream:readU8()
        locals[i] = {
            nameId   = nameId,
            name     = self:string(nameId) or string.format("local_%d", i),
            startpc  = startpc,
            endpc    = endpc,
            reg      = reg,
        }
    end

    local nUpvalues = stream:readVarInt()
    local upvalues = table.create(nUpvalues)
    for i = 1, nUpvalues do
        local nameId = stream:readVarInt()
        upvalues[i] = {
            nameId = nameId,
            name   = self:string(nameId) or string.format("upval_%d", i - 1),
        }
    end

    self:_popContext()
    return { locals = locals, upvalues = upvalues }
end

return BytecodeReader
