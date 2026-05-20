--!nonstrict
-- =====================================================================
-- IDARoblox / Core / Base64
-- ---------------------------------------------------------------------
-- Minimal RFC 4648 base64 encoder + decoder.
--
-- Used by SessionManager to wrap raw bytecode into a text-safe payload
-- that survives transport through writefile / setclipboard / etc.
--
-- API:
--   Base64.encode(s)   → string  (always text, with = padding)
--   Base64.decode(s)   → string  (any whitespace tolerated; case-sensitive)
--   Base64.isBase64(s) → bool    (cheap heuristic)
-- =====================================================================

local Base64 = {}

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local CHAR_TO_VAL = {}
do
    for i = 1, #ALPHABET do
        CHAR_TO_VAL[string.byte(ALPHABET, i)] = i - 1
    end
end

local VAL_TO_CHAR = {}
for i = 0, 63 do
    VAL_TO_CHAR[i] = string.sub(ALPHABET, i + 1, i + 1)
end

-- ---------------------------------------------------------------------
-- Encode
-- ---------------------------------------------------------------------

function Base64.encode(data)
    if type(data) ~= "string" then
        error("Base64.encode: expected string, got " .. type(data), 2)
    end
    if data == "" then return "" end

    local n = #data
    local out = table.create(math.ceil(n / 3) * 4)
    local outIdx = 0

    local i = 1
    -- Full triples
    while i + 2 <= n do
        local a, b, c = string.byte(data, i, i + 2)
        local n1 = bit32.rshift(a, 2)
        local n2 = bit32.bor(bit32.lshift(bit32.band(a, 0x3), 4), bit32.rshift(b, 4))
        local n3 = bit32.bor(bit32.lshift(bit32.band(b, 0xF), 2), bit32.rshift(c, 6))
        local n4 = bit32.band(c, 0x3F)
        out[outIdx + 1] = VAL_TO_CHAR[n1]
        out[outIdx + 2] = VAL_TO_CHAR[n2]
        out[outIdx + 3] = VAL_TO_CHAR[n3]
        out[outIdx + 4] = VAL_TO_CHAR[n4]
        outIdx = outIdx + 4
        i = i + 3
    end

    -- Trailing 1 or 2 bytes
    local remaining = n - i + 1
    if remaining == 1 then
        local a = string.byte(data, i)
        local n1 = bit32.rshift(a, 2)
        local n2 = bit32.lshift(bit32.band(a, 0x3), 4)
        out[outIdx + 1] = VAL_TO_CHAR[n1]
        out[outIdx + 2] = VAL_TO_CHAR[n2]
        out[outIdx + 3] = "="
        out[outIdx + 4] = "="
    elseif remaining == 2 then
        local a, b = string.byte(data, i, i + 1)
        local n1 = bit32.rshift(a, 2)
        local n2 = bit32.bor(bit32.lshift(bit32.band(a, 0x3), 4), bit32.rshift(b, 4))
        local n3 = bit32.lshift(bit32.band(b, 0xF), 2)
        out[outIdx + 1] = VAL_TO_CHAR[n1]
        out[outIdx + 2] = VAL_TO_CHAR[n2]
        out[outIdx + 3] = VAL_TO_CHAR[n3]
        out[outIdx + 4] = "="
    end

    return table.concat(out)
end

-- ---------------------------------------------------------------------
-- Decode
-- ---------------------------------------------------------------------

local function nextBase64Val(data, idx, n)
    -- Returns the next base64 value (0..63), 64 for '=' padding,
    -- or nil at end-of-input. Skips whitespace.
    while idx <= n do
        local b = string.byte(data, idx)
        if b == 0x20 or b == 0x09 or b == 0x0A or b == 0x0D then
            idx = idx + 1
        elseif b == 0x3D then                                        -- '='
            return 64, idx + 1
        else
            local v = CHAR_TO_VAL[b]
            if v == nil then
                error("Base64.decode: invalid character at offset " .. idx, 3)
            end
            return v, idx + 1
        end
    end
    return nil, idx
end

function Base64.decode(data)
    if type(data) ~= "string" then
        error("Base64.decode: expected string, got " .. type(data), 2)
    end
    if data == "" then return "" end

    local n = #data
    local out = table.create(math.floor(n * 3 / 4) + 4)
    local outIdx = 0
    local idx = 1

    while true do
        local v1; v1, idx = nextBase64Val(data, idx, n)
        if v1 == nil then break end
        local v2; v2, idx = nextBase64Val(data, idx, n)
        local v3; v3, idx = nextBase64Val(data, idx, n)
        local v4; v4, idx = nextBase64Val(data, idx, n)
        if v2 == nil or v3 == nil or v4 == nil then
            error("Base64.decode: truncated input", 2)
        end

        -- v1 v2 are always real (non-padding) for a valid block
        if v1 == 64 or v2 == 64 then
            error("Base64.decode: padding in wrong position", 2)
        end

        local a = bit32.bor(bit32.lshift(v1, 2), bit32.rshift(v2, 4))
        out[outIdx + 1] = string.char(a)
        outIdx = outIdx + 1

        if v3 ~= 64 then
            local b = bit32.bor(bit32.lshift(bit32.band(v2, 0xF), 4), bit32.rshift(v3, 2))
            out[outIdx + 1] = string.char(b)
            outIdx = outIdx + 1
            if v4 ~= 64 then
                local c = bit32.bor(bit32.lshift(bit32.band(v3, 0x3), 6), v4)
                out[outIdx + 1] = string.char(c)
                outIdx = outIdx + 1
            end
        end
    end

    return table.concat(out)
end

-- ---------------------------------------------------------------------
-- Heuristic check
-- ---------------------------------------------------------------------

function Base64.isBase64(s)
    if type(s) ~= "string" or s == "" then return false end
    -- Strip whitespace for cheap inspection
    if not string.match(s, "^[%s%w%+/=]+$") then return false end
    -- Stripped length must be a multiple of 4
    local stripped = string.gsub(s, "[%s]", "")
    return #stripped % 4 == 0
end

return Base64
