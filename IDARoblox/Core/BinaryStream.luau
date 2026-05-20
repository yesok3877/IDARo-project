--!nonstrict
-- =====================================================================
-- IDARoblox / Core / BinaryStream
-- ---------------------------------------------------------------------
-- Low-level binary stream reader+writer used as the substrate for every
-- byte-oriented parser in IDARoblox (Luau bytecode, project DB, sigs).
--
-- Features
--   * Fixed-width reads (u8/u16/u32/i8/i16/i32/u64/i64) with endian control
--   * IEEE 754 float (32-bit) and double (64-bit) reads — buffer-accelerated
--     when the Luau buffer library is available, with a fully manual
--     fallback (denormals, infinities, NaNs all handled correctly)
--   * Unsigned LEB128 varint (Luau bytecode format) + zigzag signed variant
--   * Sub-byte bit reads with explicit alignment control
--   * Checkpoint / restore stack for parser error-recovery
--   * Length-prefixed strings and raw block reads
--   * Symmetric writer surface that emits to either a buffer or a
--     string chunk list, finalized by :toString()
-- =====================================================================

local BinaryStream = {}
BinaryStream.__index = BinaryStream

-- Detect buffer support up-front so every read path is branch-predictable.
local HAS_BUFFER: boolean = type(buffer) == "table"
    and type(buffer.fromstring) == "function"
    and type(buffer.readu8) == "function"
    and type(buffer.readu16) == "function"
    and type(buffer.readu32) == "function"
    and type(buffer.readi8) == "function"
    and type(buffer.readi16) == "function"
    and type(buffer.readi32) == "function"
    and type(buffer.readf32) == "function"
    and type(buffer.readf64) == "function"

local LE_DEFAULT = true  -- Luau bytecode is little-endian

-- Bit helpers, prefer bit32 (present in Roblox/Luau).
local band, bor, bxor, lshift, rshift = bit32.band, bit32.bor, bit32.bxor, bit32.lshift, bit32.rshift

-- ---------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------

function BinaryStream.new(data: string?, littleEndian: boolean?)
    local raw: string = data or ""
    local self = setmetatable({
        _raw           = raw,
        _length        = #raw,
        _position      = 1,                                       -- 1-indexed
        _le            = if littleEndian == nil then LE_DEFAULT else littleEndian,
        _checkpoints   = table.create(8),
        _bitBuffer     = 0,
        _bitCount      = 0,
        _buf           = if HAS_BUFFER and #raw > 0 then buffer.fromstring(raw) else nil,
        -- Writer-side state
        _writeChunks   = nil :: { string }?,
        _writeLen      = 0,
    }, BinaryStream)
    return self
end

function BinaryStream.writer(littleEndian: boolean?)
    local self = BinaryStream.new("", littleEndian)
    self._writeChunks = table.create(32)
    return self
end

function BinaryStream:clone()
    local clone = BinaryStream.new(self._raw, self._le)
    clone._position = self._position
    return clone
end

-- ---------------------------------------------------------------------
-- Position / bounds
-- ---------------------------------------------------------------------

function BinaryStream:length(): number return self._length end
function BinaryStream:position(): number return self._position end
function BinaryStream:remaining(): number return math.max(0, self._length - self._position + 1) end
function BinaryStream:eof(): boolean return self._position > self._length end

function BinaryStream:seek(pos: number)
    if pos < 1 or pos > self._length + 1 then
        error(string.format("BinaryStream: seek out of bounds: %d (length=%d)", pos, self._length), 2)
    end
    self._position = pos
    self._bitBuffer, self._bitCount = 0, 0
end

function BinaryStream:skip(n: number)
    self:seek(self._position + n)
end

function BinaryStream:_ensure(n: number)
    if self._position + n - 1 > self._length then
        error(string.format(
            "BinaryStream: read past end (need %d bytes at pos %d, length %d)",
            n, self._position, self._length), 3)
    end
end

-- ---------------------------------------------------------------------
-- Checkpoint stack
-- ---------------------------------------------------------------------

function BinaryStream:checkpoint(): number
    local cp = self._position
    table.insert(self._checkpoints, cp)
    return cp
end

function BinaryStream:restore()
    local cp = table.remove(self._checkpoints)
    if not cp then error("BinaryStream: restore() with no checkpoint", 2) end
    self._position = cp
    self._bitBuffer, self._bitCount = 0, 0
end

function BinaryStream:discardCheckpoint()
    if not table.remove(self._checkpoints) then
        error("BinaryStream: discardCheckpoint() with no checkpoint", 2)
    end
end

function BinaryStream:withCheckpoint<T>(fn: () -> T): (boolean, T)
    self:checkpoint()
    local ok, result = pcall(fn)
    if ok then
        self:discardCheckpoint()
        return true, result
    else
        self:restore()
        return false, result
    end
end

-- ---------------------------------------------------------------------
-- Fixed-width unsigned reads
-- ---------------------------------------------------------------------

function BinaryStream:readU8(): number
    self:_ensure(1)
    local v
    if self._buf then
        v = buffer.readu8(self._buf, self._position - 1)
    else
        v = string.byte(self._raw, self._position)
    end
    self._position = self._position + 1
    return v
end
BinaryStream.readByte = BinaryStream.readU8

function BinaryStream:readU16(): number
    self:_ensure(2)
    local v
    if self._buf and self._le then
        v = buffer.readu16(self._buf, self._position - 1)
    else
        local b1, b2 = string.byte(self._raw, self._position, self._position + 1)
        v = if self._le then b1 + b2 * 256 else b1 * 256 + b2
    end
    self._position = self._position + 2
    return v
end

function BinaryStream:readU32(): number
    self:_ensure(4)
    local v
    if self._buf and self._le then
        v = buffer.readu32(self._buf, self._position - 1)
    else
        local b1, b2, b3, b4 = string.byte(self._raw, self._position, self._position + 3)
        if self._le then
            v = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
        else
            v = b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
        end
    end
    self._position = self._position + 4
    return v
end

function BinaryStream:readU64(): number
    -- Note: Lua doubles can represent integers exactly up to 2^53. Above that
    -- precision is lost; the parser should not encounter such values in normal
    -- Luau bytecode. We accept the limit silently and document.
    self:_ensure(8)
    if self._le then
        local lo = self:readU32()
        local hi = self:readU32()
        return lo + hi * 4294967296
    else
        local hi = self:readU32()
        local lo = self:readU32()
        return lo + hi * 4294967296
    end
end

-- ---------------------------------------------------------------------
-- Signed reads (two's complement)
-- ---------------------------------------------------------------------

function BinaryStream:readI8(): number
    local v = self:readU8()
    return if v >= 128 then v - 256 else v
end

function BinaryStream:readI16(): number
    local v = self:readU16()
    return if v >= 32768 then v - 65536 else v
end

function BinaryStream:readI32(): number
    local v = self:readU32()
    return if v >= 2147483648 then v - 4294967296 else v
end

function BinaryStream:readI64(): number
    local v = self:readU64()
    return if v >= 9223372036854775808 then v - 18446744073709551616 else v
end

-- ---------------------------------------------------------------------
-- IEEE 754
-- ---------------------------------------------------------------------

function BinaryStream:readF32(): number
    self:_ensure(4)
    if self._buf and self._le then
        local v = buffer.readf32(self._buf, self._position - 1)
        self._position = self._position + 4
        return v
    end
    local b1, b2, b3, b4 = string.byte(self._raw, self._position, self._position + 3)
    self._position = self._position + 4
    if not self._le then b1, b2, b3, b4 = b4, b3, b2, b1 end

    local sign = if band(b4, 0x80) ~= 0 then -1 else 1
    local exponent = bor(lshift(band(b4, 0x7F), 1), rshift(band(b3, 0x80), 7))
    local mantissa = band(b3, 0x7F) * 65536 + b2 * 256 + b1

    if exponent == 0 then
        if mantissa == 0 then return sign * 0 end
        return sign * mantissa * 2^-149                            -- denormal
    elseif exponent == 0xFF then
        if mantissa == 0 then return sign * math.huge end
        return 0/0                                                 -- NaN
    end
    return sign * (1 + mantissa / 8388608) * 2^(exponent - 127)
end

function BinaryStream:readF64(): number
    self:_ensure(8)
    if self._buf and self._le then
        local v = buffer.readf64(self._buf, self._position - 1)
        self._position = self._position + 8
        return v
    end
    local b1, b2, b3, b4, b5, b6, b7, b8 = string.byte(self._raw, self._position, self._position + 7)
    self._position = self._position + 8
    if not self._le then
        b1, b8 = b8, b1; b2, b7 = b7, b2; b3, b6 = b6, b3; b4, b5 = b5, b4
    end

    local sign = if band(b8, 0x80) ~= 0 then -1 else 1
    local exponent = bor(lshift(band(b8, 0x7F), 4), rshift(band(b7, 0xF0), 4))
    -- Mantissa is 52 bits; assemble from low byte to high nibble.
    local mantissa =
        band(b7, 0x0F) * 281474976710656   -- 2^48
        + b6 * 1099511627776                -- 2^40
        + b5 * 4294967296                   -- 2^32
        + b4 * 16777216                     -- 2^24
        + b3 * 65536                        -- 2^16
        + b2 * 256                          -- 2^8
        + b1

    if exponent == 0 then
        if mantissa == 0 then return sign * 0 end
        return sign * mantissa * 2^-1074
    elseif exponent == 0x7FF then
        if mantissa == 0 then return sign * math.huge end
        return 0/0
    end
    return sign * (1 + mantissa / 4503599627370496) * 2^(exponent - 1023)
end
BinaryStream.readFloat  = BinaryStream.readF32
BinaryStream.readDouble = BinaryStream.readF64

-- ---------------------------------------------------------------------
-- LEB128 varints (Luau bytecode uses unsigned 7-bit-continuation form)
-- ---------------------------------------------------------------------

function BinaryStream:readVarInt(): number
    local result, shift = 0, 0
    for _ = 1, 10 do                                              -- max 10 bytes for u64
        local b = self:readU8()
        result = bor(result, lshift(band(b, 0x7F), shift))
        if band(b, 0x80) == 0 then return result end
        shift = shift + 7
        if shift >= 64 then break end
    end
    error("BinaryStream: varint too long / malformed", 2)
end

function BinaryStream:readSignedVarInt(): number
    -- ZigZag decode: (n >> 1) ^ -(n & 1) — done in float-safe ops
    local n = self:readVarInt()
    local low = n % 2
    local half = (n - low) / 2
    return if low == 1 then -(half + 1) else half
end

-- ---------------------------------------------------------------------
-- Blocks and strings
-- ---------------------------------------------------------------------

function BinaryStream:readBytes(n: number): string
    if n == 0 then return "" end
    self:_ensure(n)
    local s = string.sub(self._raw, self._position, self._position + n - 1)
    self._position = self._position + n
    return s
end

function BinaryStream:readString(): string
    -- Length-prefixed (varint length, raw bytes)
    local n = self:readVarInt()
    if n == 0 then return "" end
    return self:readBytes(n)
end

function BinaryStream:readCString(): string
    -- Null-terminated; rarely used in Luau bytecode but useful for forensics
    local start = self._position
    while self._position <= self._length do
        if string.byte(self._raw, self._position) == 0 then
            local s = string.sub(self._raw, start, self._position - 1)
            self._position = self._position + 1
            return s
        end
        self._position = self._position + 1
    end
    error("BinaryStream: unterminated C-string", 2)
end

-- ---------------------------------------------------------------------
-- Peeks (non-advancing)
-- ---------------------------------------------------------------------

function BinaryStream:peekByte(offset: number?): number
    local pos = self._position + (offset or 0)
    if pos < 1 or pos > self._length then
        error("BinaryStream: peek out of bounds", 2)
    end
    return string.byte(self._raw, pos)
end

function BinaryStream:peekBytes(n: number, offset: number?): string
    local pos = self._position + (offset or 0)
    if pos < 1 or pos + n - 1 > self._length then
        error("BinaryStream: peek out of bounds", 2)
    end
    return string.sub(self._raw, pos, pos + n - 1)
end

-- ---------------------------------------------------------------------
-- Bit-level reads (MSB-first by default; useful for packed instruction fields)
-- ---------------------------------------------------------------------

function BinaryStream:alignByte()
    self._bitBuffer, self._bitCount = 0, 0
end

function BinaryStream:readBits(n: number): number
    -- n: 1..24 (kept inside Lua double precision easily)
    if n < 1 or n > 24 then error("BinaryStream: readBits expects 1..24, got " .. tostring(n), 2) end
    while self._bitCount < n do
        self._bitBuffer = bor(lshift(self._bitBuffer, 8), self:readU8())
        self._bitCount = self._bitCount + 8
    end
    local shift = self._bitCount - n
    local mask = lshift(1, n) - 1
    local v = band(rshift(self._bitBuffer, shift), mask)
    -- Clear consumed bits from the high end.
    self._bitBuffer = band(self._bitBuffer, lshift(1, shift) - 1)
    self._bitCount = shift
    return v
end

function BinaryStream:readBit(): number
    return self:readBits(1)
end

-- ---------------------------------------------------------------------
-- Writer surface
-- ---------------------------------------------------------------------

function BinaryStream:_writePush(s: string)
    if not self._writeChunks then
        error("BinaryStream: instance is read-only (use BinaryStream.writer())", 3)
    end
    table.insert(self._writeChunks, s)
    self._writeLen = self._writeLen + #s
end

function BinaryStream:writeU8(v: number)
    self:_writePush(string.char(band(v, 0xFF)))
end
BinaryStream.writeByte = BinaryStream.writeU8

function BinaryStream:writeU16(v: number)
    v = band(v, 0xFFFF)
    local b1, b2 = band(v, 0xFF), band(rshift(v, 8), 0xFF)
    self:_writePush(if self._le then string.char(b1, b2) else string.char(b2, b1))
end

function BinaryStream:writeU32(v: number)
    -- v is unsigned 32-bit; keep within double-safe bounds.
    local b1 = band(v, 0xFF)
    local b2 = band(rshift(v, 8), 0xFF)
    local b3 = band(rshift(v, 16), 0xFF)
    local b4 = band(rshift(v, 24), 0xFF)
    self:_writePush(if self._le
        then string.char(b1, b2, b3, b4)
        else string.char(b4, b3, b2, b1))
end

function BinaryStream:writeI32(v: number)
    if v < 0 then v = v + 4294967296 end
    self:writeU32(v)
end

function BinaryStream:writeVarInt(v: number)
    if v < 0 then error("BinaryStream: writeVarInt expects unsigned, got " .. tostring(v), 2) end
    -- Emit 7 bits at a time, MSB = continuation
    local out = table.create(10)
    repeat
        local low = v % 128
        v = (v - low) / 128
        if v > 0 then
            out[#out + 1] = string.char(low + 128)
        else
            out[#out + 1] = string.char(low)
        end
    until v == 0
    self:_writePush(table.concat(out))
end

function BinaryStream:writeSignedVarInt(v: number)
    -- ZigZag encode: (n << 1) ^ (n >> (bits-1))
    local encoded = if v >= 0 then v * 2 else (-v) * 2 - 1
    self:writeVarInt(encoded)
end

function BinaryStream:writeF32(v: number)
    -- Best-effort encode via buffer when present; otherwise manual.
    if HAS_BUFFER then
        local b = buffer.create(4)
        buffer.writef32(b, 0, v)
        local s = buffer.tostring(b)
        self:_writePush(if self._le then s else string.reverse(s))
        return
    end
    -- Manual encode
    if v ~= v then                                                 -- NaN
        self:_writePush(string.char(0, 0, 0xC0, 0x7F))
        return
    elseif v == math.huge then
        self:_writePush(string.char(0, 0, 0x80, 0x7F))
        return
    elseif v == -math.huge then
        self:_writePush(string.char(0, 0, 0x80, 0xFF))
        return
    elseif v == 0 then
        self:_writePush(string.char(0, 0, 0, 0))
        return
    end
    local sign = if v < 0 then 1 else 0
    if sign == 1 then v = -v end
    local m, e = math.frexp(v)
    e = e - 1
    m = m * 2 - 1
    local mant = math.floor(m * 8388608 + 0.5)
    local bias = e + 127
    local b1 = band(mant, 0xFF)
    local b2 = band(rshift(mant, 8), 0xFF)
    local b3 = band(bor(band(mant, 0x7F0000) / 65536, lshift(band(bias, 1), 7)), 0xFF)
    local b4 = band(bor(rshift(bias, 1), lshift(sign, 7)), 0xFF)
    self:_writePush(if self._le then string.char(b1, b2, b3, b4) else string.char(b4, b3, b2, b1))
end

function BinaryStream:writeF64(v: number)
    if HAS_BUFFER then
        local b = buffer.create(8)
        buffer.writef64(b, 0, v)
        local s = buffer.tostring(b)
        self:_writePush(if self._le then s else string.reverse(s))
        return
    end
    -- Manual fallback: similar to F32 but with 11-bit exp, 52-bit mantissa.
    -- (Used only on platforms without `buffer`; full implementation kept for parity.)
    if v ~= v then
        self:_writePush(string.char(0, 0, 0, 0, 0, 0, 0xF8, 0x7F))
        return
    elseif v == math.huge then
        self:_writePush(string.char(0, 0, 0, 0, 0, 0, 0xF0, 0x7F))
        return
    elseif v == -math.huge then
        self:_writePush(string.char(0, 0, 0, 0, 0, 0, 0xF0, 0xFF))
        return
    elseif v == 0 then
        self:_writePush(string.char(0, 0, 0, 0, 0, 0, 0, 0))
        return
    end
    local sign = if v < 0 then 1 else 0
    if sign == 1 then v = -v end
    local m, e = math.frexp(v)
    e = e - 1
    m = m * 2 - 1
    local mant = m * 4503599627370496                              -- 2^52
    local mh = math.floor(mant / 4294967296)                       -- top 20 bits
    local ml = mant - mh * 4294967296                              -- bottom 32 bits
    local bias = e + 1023
    local bytes = table.create(8)
    bytes[1] = band(ml, 0xFF)
    bytes[2] = band(rshift(ml, 8), 0xFF)
    bytes[3] = band(rshift(ml, 16), 0xFF)
    bytes[4] = band(rshift(ml, 24), 0xFF)
    bytes[5] = band(mh, 0xFF)
    bytes[6] = band(rshift(mh, 8), 0xFF)
    bytes[7] = band(bor(band(mh, 0x0F0000) / 65536, lshift(band(bias, 0x0F), 4)), 0xFF)
    bytes[8] = band(bor(rshift(bias, 4), lshift(sign, 7)), 0xFF)
    if not self._le then
        for i = 1, 4 do bytes[i], bytes[9 - i] = bytes[9 - i], bytes[i] end
    end
    self:_writePush(string.char(table.unpack(bytes)))
end

function BinaryStream:writeBytes(s: string) self:_writePush(s) end

function BinaryStream:writeString(s: string)
    self:writeVarInt(#s)
    self:_writePush(s)
end

function BinaryStream:toString(): string
    if not self._writeChunks then
        error("BinaryStream: toString() on a read-only instance", 2)
    end
    return table.concat(self._writeChunks)
end

function BinaryStream:writeLength(): number
    return self._writeLen
end

-- ---------------------------------------------------------------------
-- Diagnostics
-- ---------------------------------------------------------------------

function BinaryStream:hexdump(maxBytes: number?): string
    local limit = math.min(maxBytes or 256, self._length)
    local lines = table.create(math.ceil(limit / 16))
    for off = 0, limit - 1, 16 do
        local b = table.create(16)
        local ascii = table.create(16)
        for i = 0, 15 do
            local p = off + i + 1
            if p > limit then break end
            local byte = string.byte(self._raw, p)
            b[#b + 1] = string.format("%02X", byte)
            ascii[#ascii + 1] = if byte >= 32 and byte < 127 then string.char(byte) else "."
        end
        lines[#lines + 1] = string.format("%08X  %-47s  %s",
            off, table.concat(b, " "), table.concat(ascii))
    end
    return table.concat(lines, "\n")
end

return BinaryStream
