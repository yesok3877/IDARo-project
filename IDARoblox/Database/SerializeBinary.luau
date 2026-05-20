--!nonstrict
-- =====================================================================
-- IDARoblox / Database / SerializeBinary
-- ---------------------------------------------------------------------
-- Compact tag-based binary serializer with string interning. Designed
-- to be the on-disk format for ProjectDB snapshots.
--
-- Goals
--   * Small: integer shortcuts for 0/1/-1, varint everywhere a length or
--     id appears, U8 / U16 / U32 width selection by magnitude, string
--     interning for any string appearing 2+ times.
--   * Self-describing: every value carries a 1-byte type tag, malformed
--     input fails loud rather than silently misinterpreting.
--   * Deterministic: encode of the same structure yields the same bytes
--     (intern table iteration order is fixed by appearance order).
--   * Round-trip safe: every nil / boolean / number / string / array /
--     map / nested combination of those roundtrips byte-exactly.
--
-- Wire format
--   MAGIC                   "IDARBLX-DB-V1\0"   (14 bytes, NUL-terminated)
--   VERSION                 u8                  (currently 1)
--   FLAGS                   u32 LE              (reserved, must be 0)
--   INTERN_COUNT            varint
--   INTERN_TABLE            INTERN_COUNT × [varint len, bytes]
--   PAYLOAD                 tagged value
--
-- Tag table
--   0x00 NIL
--   0x01 FALSE
--   0x02 TRUE
--   0x03 ZERO              (numeric 0)
--   0x04 ONE               (numeric 1)
--   0x05 NEG_ONE           (numeric -1)
--   0x10 U8                + u8
--   0x11 U16               + u16 LE
--   0x12 U32               + u32 LE
--   0x13 UVARINT           + varint            (general unsigned)
--   0x14 NEG_UVARINT       + varint            (general negative; value = -varint)
--   0x15 F64               + 8 bytes IEEE754 LE
--   0x20 STR_EMPTY
--   0x21 STR_INLINE_SHORT  + u8 len + bytes    (len < 256, non-interned)
--   0x22 STR_INLINE_LONG   + varint len + bytes (len >= 256, non-interned)
--   0x23 STR_INTERNED      + varint intern_id  (1-based id into intern table)
--   0x30 BYTES_SHORT       + u8 len + bytes    (binary blob, may include NULs)
--   0x31 BYTES_LONG        + varint len + bytes
--   0x40 ARRAY_EMPTY
--   0x41 ARRAY             + varint count + count values
--   0x50 MAP_EMPTY
--   0x51 MAP               + varint count + count (key, value) pairs
-- =====================================================================

local BinaryStream = _G.IDARo.require("Core.BinaryStream")

local SerializeBinary = {}

local MAGIC          = "IDARBLX-DB-V1\0"                             -- 14 bytes
local FORMAT_VERSION = 1
local MAX_DEPTH      = 128

local TAG = table.freeze({
    NIL              = 0x00,
    FALSE            = 0x01,
    TRUE             = 0x02,
    ZERO             = 0x03,
    ONE              = 0x04,
    NEG_ONE          = 0x05,
    U8               = 0x10,
    U16              = 0x11,
    U32              = 0x12,
    UVARINT          = 0x13,
    NEG_UVARINT      = 0x14,
    F64              = 0x15,
    STR_EMPTY        = 0x20,
    STR_INLINE_SHORT = 0x21,
    STR_INLINE_LONG  = 0x22,
    STR_INTERNED     = 0x23,
    BYTES_SHORT      = 0x30,
    BYTES_LONG       = 0x31,
    ARRAY_EMPTY      = 0x40,
    ARRAY            = 0x41,
    MAP_EMPTY        = 0x50,
    MAP              = 0x51,
})

SerializeBinary.MAGIC           = MAGIC
SerializeBinary.FORMAT_VERSION  = FORMAT_VERSION
SerializeBinary.TAG             = TAG

-- ---------------------------------------------------------------------
-- Marker for explicit binary blobs (so callers can distinguish a raw
-- byte string from a text string when the bytes contain NULs / non-UTF-8)
-- ---------------------------------------------------------------------

local BYTES_MARKER = newproxy(true)
do
    local mt = getmetatable(BYTES_MARKER)
    mt.__tostring = function() return "<SerializeBinary.Bytes>" end
end

function SerializeBinary.wrapBytes(data)
    if type(data) ~= "string" then
        error("SerializeBinary.wrapBytes: expected string, got " .. type(data), 2)
    end
    return { __bytes = BYTES_MARKER, data = data }
end

local function isBytesBlob(v)
    return type(v) == "table" and v.__bytes == BYTES_MARKER and type(v.data) == "string"
end

SerializeBinary.isBytesBlob = isBytesBlob

-- ---------------------------------------------------------------------
-- Pre-pass: build intern table
-- ---------------------------------------------------------------------

local function collectStrings(value, freq, depth, seen)
    if depth > MAX_DEPTH then
        error(string.format("SerializeBinary.encode: depth limit %d exceeded", MAX_DEPTH), 3)
    end
    local t = type(value)
    if t == "string" then
        freq[value] = (freq[value] or 0) + 1
    elseif t == "table" then
        if isBytesBlob(value) then return end                        -- raw blob; skip
        if seen[value] then
            error("SerializeBinary.encode: cycle detected in input table", 3)
        end
        seen[value] = true
        for k, v in pairs(value) do
            if type(k) == "string" then freq[k] = (freq[k] or 0) + 1 end
            collectStrings(v, freq, depth + 1, seen)
        end
        seen[value] = nil
    end
end

-- Strings interned when they appear at least twice AND are longer than
-- 3 bytes (intern-ref encoding is ~2 bytes; below that breakeven, inline
-- is cheaper).
local function buildInternTable(freq)
    local internToId = {}
    local idToIntern = {}
    -- Stable ordering: by descending frequency, then by string for ties.
    -- This makes deterministic output even if `pairs` order varies across runs.
    local candidates = {}
    for s, c in pairs(freq) do
        if c >= 2 and #s > 3 then
            candidates[#candidates + 1] = { s = s, c = c }
        end
    end
    table.sort(candidates, function(a, b)
        if a.c == b.c then return a.s < b.s end
        return a.c > b.c
    end)
    for _, entry in candidates do
        local id = #idToIntern + 1
        internToId[entry.s] = id
        idToIntern[id]      = entry.s
    end
    return internToId, idToIntern
end

-- ---------------------------------------------------------------------
-- Encoder
-- ---------------------------------------------------------------------

local function writeString(stream, s, internToId)
    if s == "" then stream:writeU8(TAG.STR_EMPTY); return end
    local id = internToId[s]
    if id then
        stream:writeU8(TAG.STR_INTERNED)
        stream:writeVarInt(id)
    elseif #s < 256 then
        stream:writeU8(TAG.STR_INLINE_SHORT)
        stream:writeU8(#s)
        stream:writeBytes(s)
    else
        stream:writeU8(TAG.STR_INLINE_LONG)
        stream:writeVarInt(#s)
        stream:writeBytes(s)
    end
end

local function writeNumber(stream, n)
    if n == 0     then stream:writeU8(TAG.ZERO);    return end
    if n == 1     then stream:writeU8(TAG.ONE);     return end
    if n == -1    then stream:writeU8(TAG.NEG_ONE); return end
    if n ~= n or n == math.huge or n == -math.huge or math.floor(n) ~= n then
        stream:writeU8(TAG.F64); stream:writeF64(n); return
    end
    local neg = n < 0
    local v = neg and -n or n
    if not neg then
        if v <= 0xFF then
            stream:writeU8(TAG.U8); stream:writeU8(v)
        elseif v <= 0xFFFF then
            stream:writeU8(TAG.U16); stream:writeU16(v)
        elseif v <= 0xFFFFFFFF then
            stream:writeU8(TAG.U32); stream:writeU32(v)
        else
            stream:writeU8(TAG.UVARINT); stream:writeVarInt(v)
        end
    else
        stream:writeU8(TAG.NEG_UVARINT); stream:writeVarInt(v)
    end
end

local function writeBytesBlob(stream, data)
    if #data < 256 then
        stream:writeU8(TAG.BYTES_SHORT); stream:writeU8(#data); stream:writeBytes(data)
    else
        stream:writeU8(TAG.BYTES_LONG); stream:writeVarInt(#data); stream:writeBytes(data)
    end
end

local encodeValue                                                    -- forward decl
local function encodeTable(stream, t, internToId)
    if isBytesBlob(t) then writeBytesBlob(stream, t.data); return end

    local n = #t
    local isArrayLike = n > 0
    local keyCount = 0
    for k in pairs(t) do
        keyCount = keyCount + 1
        if isArrayLike then
            if type(k) ~= "number" or k < 1 or k > n or math.floor(k) ~= k then
                isArrayLike = false
            end
        end
    end

    if isArrayLike and keyCount == n then
        if n == 0 then stream:writeU8(TAG.ARRAY_EMPTY); return end
        stream:writeU8(TAG.ARRAY); stream:writeVarInt(n)
        for i = 1, n do encodeValue(stream, t[i], internToId) end
    else
        if keyCount == 0 then stream:writeU8(TAG.MAP_EMPTY); return end
        stream:writeU8(TAG.MAP); stream:writeVarInt(keyCount)
        -- Deterministic key ordering for map values too: numeric first then strings.
        local numericKeys, stringKeys = {}, {}
        for k in pairs(t) do
            if type(k) == "number" then numericKeys[#numericKeys + 1] = k
            elseif type(k) == "string" then stringKeys[#stringKeys + 1] = k end
        end
        table.sort(numericKeys)
        table.sort(stringKeys)
        local emitted = 0
        for _, k in numericKeys do
            encodeValue(stream, k, internToId); encodeValue(stream, t[k], internToId)
            emitted = emitted + 1
        end
        for _, k in stringKeys do
            encodeValue(stream, k, internToId); encodeValue(stream, t[k], internToId)
            emitted = emitted + 1
        end
        -- Any other key types (booleans, tables-as-keys) are not supported.
        if emitted ~= keyCount then
            error(string.format(
                "SerializeBinary.encode: unsupported key type in map (emitted %d / %d)",
                emitted, keyCount), 3)
        end
    end
end

encodeValue = function(stream, value, internToId)
    local t = type(value)
    if value == nil then stream:writeU8(TAG.NIL)
    elseif t == "boolean" then stream:writeU8(value and TAG.TRUE or TAG.FALSE)
    elseif t == "number" then writeNumber(stream, value)
    elseif t == "string" then writeString(stream, value, internToId)
    elseif t == "table"  then encodeTable(stream, value, internToId)
    else error("SerializeBinary.encode: cannot encode type " .. t, 3) end
end

function SerializeBinary.encode(value)
    local freq = {}
    collectStrings(value, freq, 0, {})
    local internToId, idToIntern = buildInternTable(freq)

    local stream = BinaryStream.writer()
    stream:writeBytes(MAGIC)
    stream:writeU8(FORMAT_VERSION)
    stream:writeU32(0)
    stream:writeVarInt(#idToIntern)
    for i = 1, #idToIntern do
        local s = idToIntern[i]
        stream:writeVarInt(#s)
        stream:writeBytes(s)
    end
    encodeValue(stream, value, internToId)
    return stream:toString()
end

-- ---------------------------------------------------------------------
-- Decoder
-- ---------------------------------------------------------------------

local decodeValue                                                    -- forward decl

local function readArray(stream, interns, depth)
    local n = stream:readVarInt()
    if n < 0 or n > 0x10000000 then
        error("SerializeBinary.decode: implausible array length " .. n, 3)
    end
    local arr = table.create(n)
    for i = 1, n do arr[i] = decodeValue(stream, interns, depth + 1) end
    return arr
end

local function readMap(stream, interns, depth)
    local n = stream:readVarInt()
    if n < 0 or n > 0x10000000 then
        error("SerializeBinary.decode: implausible map length " .. n, 3)
    end
    local m = {}
    for _ = 1, n do
        local k = decodeValue(stream, interns, depth + 1)
        local v = decodeValue(stream, interns, depth + 1)
        m[k] = v
    end
    return m
end

decodeValue = function(stream, interns, depth)
    if depth > MAX_DEPTH then
        error(string.format(
            "SerializeBinary.decode: depth limit %d exceeded at pos %d",
            MAX_DEPTH, stream:position()), 3)
    end
    local tag = stream:readU8()
    if     tag == TAG.NIL              then return nil
    elseif tag == TAG.FALSE            then return false
    elseif tag == TAG.TRUE             then return true
    elseif tag == TAG.ZERO             then return 0
    elseif tag == TAG.ONE              then return 1
    elseif tag == TAG.NEG_ONE          then return -1
    elseif tag == TAG.U8               then return stream:readU8()
    elseif tag == TAG.U16              then return stream:readU16()
    elseif tag == TAG.U32              then return stream:readU32()
    elseif tag == TAG.UVARINT          then return stream:readVarInt()
    elseif tag == TAG.NEG_UVARINT      then return -stream:readVarInt()
    elseif tag == TAG.F64              then return stream:readF64()
    elseif tag == TAG.STR_EMPTY        then return ""
    elseif tag == TAG.STR_INLINE_SHORT then return stream:readBytes(stream:readU8())
    elseif tag == TAG.STR_INLINE_LONG  then return stream:readBytes(stream:readVarInt())
    elseif tag == TAG.STR_INTERNED     then
        local id = stream:readVarInt()
        local s = interns[id]
        if not s then
            error(string.format(
                "SerializeBinary.decode: invalid intern ref %d at pos %d",
                id, stream:position()), 3)
        end
        return s
    elseif tag == TAG.BYTES_SHORT      then return stream:readBytes(stream:readU8())
    elseif tag == TAG.BYTES_LONG       then return stream:readBytes(stream:readVarInt())
    elseif tag == TAG.ARRAY_EMPTY      then return {}
    elseif tag == TAG.ARRAY            then return readArray(stream, interns, depth)
    elseif tag == TAG.MAP_EMPTY        then return {}
    elseif tag == TAG.MAP              then return readMap(stream, interns, depth)
    end
    error(string.format(
        "SerializeBinary.decode: unknown tag 0x%02X at pos %d", tag, stream:position()), 3)
end

function SerializeBinary.decode(data)
    if type(data) ~= "string" then
        return nil, "decode expects a string"
    end
    if #data < #MAGIC + 1 + 4 + 1 then
        return nil, "data too short for header"
    end
    local stream = BinaryStream.new(data)
    local magic  = stream:readBytes(#MAGIC)
    if magic ~= MAGIC then
        return nil, string.format("invalid magic header (got %q)",
            string.sub(magic, 1, math.min(16, #magic)))
    end
    local version = stream:readU8()
    if version > FORMAT_VERSION then
        return nil, string.format("format version too new: %d (max %d)", version, FORMAT_VERSION)
    end
    local _flags = stream:readU32()                                  -- reserved
    local internCount = stream:readVarInt()
    if internCount < 0 or internCount > 0x100000 then
        return nil, "implausible intern count " .. internCount
    end
    local interns = table.create(internCount)
    for i = 1, internCount do
        local len = stream:readVarInt()
        if len < 0 or len > 0x1000000 then
            return nil, "implausible intern string length " .. len
        end
        interns[i] = stream:readBytes(len)
    end
    local ok, value = pcall(decodeValue, stream, interns, 0)
    if not ok then return nil, tostring(value) end
    return value, nil
end

-- ---------------------------------------------------------------------
-- Diagnostics
-- ---------------------------------------------------------------------

function SerializeBinary.inspect(data)
    -- Returns header info without fully decoding payload. Useful for
    -- showing "file format version" / "size" in UI.
    if type(data) ~= "string" or #data < #MAGIC + 5 then
        return nil, "data too short"
    end
    local stream = BinaryStream.new(data)
    local magic  = stream:readBytes(#MAGIC)
    if magic ~= MAGIC then return nil, "invalid magic" end
    local version = stream:readU8()
    local flags   = stream:readU32()
    local internCount = stream:readVarInt()
    return {
        magic       = magic,
        version     = version,
        flags       = flags,
        internCount = internCount,
        totalBytes  = #data,
    }
end

return SerializeBinary
