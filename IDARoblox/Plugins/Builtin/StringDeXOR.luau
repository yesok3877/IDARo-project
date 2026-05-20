--!nonstrict
-- =====================================================================
-- IDARoblox / Plugins / Builtin / StringDeXOR
-- ---------------------------------------------------------------------
-- Detects probable XOR-encoded plaintext among the bytecode's string
-- constants and attempts to recover the underlying text. The decoder
-- tries single-byte, 2-byte, and 4-byte rotating XOR keys and accepts
-- a decode when the result:
--   1. Contains > N printable ASCII bytes (> 90% by default)
--   2. Matches at least one "tell" — a substring from a hand-curated
--      list of words common in Roblox scripts ("function", "local",
--      "game", "Workspace", "GetService", etc).
--
-- Successful decodes get attached as ProjectDB comments to the proto/pc
-- sites that loaded the constant (located via the disassembler).
-- =====================================================================

local PluginAPI = _G.IDARo.require("Plugins.PluginAPI")

local PLUGIN_ID = "builtin.stringDeXOR"

-- Words whose presence strongly suggests a successful decode.
local TELLS = {
    "function", "local", "return", "end", "then", "do ", "while ", "for ",
    "game", "Workspace", "Players", "LocalPlayer", "GetService", "FindFirst",
    "script.Parent", "loadstring", "require", "Instance.new", "WaitForChild",
    "Vector3", "CFrame", "TweenService", "RunService", "ReplicatedStorage",
}

-- Lowercased tells for case-insensitive matching
local LOWER_TELLS = {}
for i, t in TELLS do LOWER_TELLS[i] = string.lower(t) end

local MIN_LENGTH       = 8
local PRINTABLE_RATIO  = 0.90
local MAX_KEY_BYTES    = 4
local MAX_PER_STRING_KEYS = 16384                                   -- safety cap

-- ---------------------------------------------------------------------
-- Heuristic helpers
-- ---------------------------------------------------------------------

local function printableRatio(s)
    if #s == 0 then return 0 end
    local printable = 0
    for i = 1, #s do
        local b = string.byte(s, i)
        if b >= 32 and b <= 126 then printable = printable + 1
        elseif b == 9 or b == 10 or b == 13 then printable = printable + 1 end
    end
    return printable / #s
end

local function isSuspicious(s)
    if #s < MIN_LENGTH then return false end
    local pr = printableRatio(s)
    if pr > 0.85 then return false end                               -- already plaintext
    return pr < 0.5                                                   -- mostly non-printable
end

local function entropyByte(s)
    -- Simple byte-frequency entropy: 0 means all same byte, 8 = uniform
    local freq = {}
    for i = 1, #s do
        local b = string.byte(s, i)
        freq[b] = (freq[b] or 0) + 1
    end
    local n = #s
    local h = 0
    for _, c in freq do
        local p = c / n
        h = h - p * (math.log(p) / math.log(2))
    end
    return h
end

local function xorWithKey(s, keyBytes)
    local out = table.create(#s)
    local kn = #keyBytes
    for i = 1, #s do
        local b = string.byte(s, i)
        local k = keyBytes[((i - 1) % kn) + 1]
        out[i] = string.char(bit32.bxor(b, k))
    end
    return table.concat(out)
end

local function containsTell(decoded)
    local lower = string.lower(decoded)
    for _, t in LOWER_TELLS do
        if string.find(lower, t, 1, true) then return t end
    end
    return nil
end

-- Try every 1-byte key. If that fails, try 2-byte and 4-byte but with
-- a budget so we don't burn cycles on long strings.
local function tryDecode(s)
    -- Single byte
    for k = 1, 255 do
        local decoded = xorWithKey(s, { k })
        if printableRatio(decoded) >= PRINTABLE_RATIO then
            local tell = containsTell(decoded)
            if tell then return decoded, { k }, tell end
        end
    end
    -- 2-byte (only if string is short enough that we have budget)
    if #s <= 256 then
        for k1 = 1, 255 do
            for k2 = 0, 255 do
                local decoded = xorWithKey(s, { k1, k2 })
                if printableRatio(decoded) >= PRINTABLE_RATIO then
                    local tell = containsTell(decoded)
                    if tell then return decoded, { k1, k2 }, tell end
                end
            end
        end
    end
    -- 4-byte: only attempt a sampling of plausible keys
    if #s <= 128 then
        -- Common keys: ASCII strings of length 4, common XOR cookies
        local candidates = { 0x5A,0xA5,0xDE,0xAD,0xBE,0xEF,0xCA,0xFE,0xBA,0xBE,
                              0x13,0x37,0xC0,0xDE,0xFA,0xCE,0x42,0x69 }
        for _, k1 in candidates do
            for _, k2 in candidates do
                for _, k3 in candidates do
                    for _, k4 in candidates do
                        local decoded = xorWithKey(s, { k1, k2, k3, k4 })
                        if printableRatio(decoded) >= PRINTABLE_RATIO then
                            local tell = containsTell(decoded)
                            if tell then
                                return decoded, { k1, k2, k3, k4 }, tell
                            end
                        end
                    end
                end
            end
        end
    end
    return nil
end

local function formatKey(k)
    local parts = {}
    for _, b in k do parts[#parts + 1] = string.format("%02X", b) end
    return "0x" .. table.concat(parts)
end

-- ---------------------------------------------------------------------
-- Manifest
-- ---------------------------------------------------------------------

local StringDeXOR = {
    id          = PLUGIN_ID,
    name        = "String XOR Decoder",
    author      = "IDARo",
    version     = "1.0",
    description = "Detects XOR-encoded strings in the constant table and "
        .. "attempts plaintext recovery (1-, 2-, and 4-byte keys).",
    requires    = {},
    priority    = 70,
    findings    = nil :: { any }?,
    _byString   = nil,
}

function StringDeXOR:init(_ctx)
    self.findings = {}
    self._byString = {}
end

function StringDeXOR:onBytecodeLoad(bytecode, ctx)
    self.findings = {}
    self._byString = {}
    if not bytecode or not bytecode.stringTable then return end
    local decodedCount = 0

    for stringId, s in bytecode.stringTable do
        if type(s) == "string" and isSuspicious(s) then
            -- Cheap entropy filter — very high entropy is unlikely XOR plaintext
            if entropyByte(s) < 7.5 then
                local decoded, key, tell = tryDecode(s)
                if decoded then
                    decodedCount = decodedCount + 1
                    self._byString[stringId] = { decoded = decoded, key = key, tell = tell }
                    self.findings[#self.findings + 1] = PluginAPI.annotation({
                        source   = PLUGIN_ID,
                        kind     = PluginAPI.AnnotationKind.COMMENT,
                        text     = string.format("XOR-decoded (key %s, tell '%s'): %s",
                            formatKey(key), tell,
                            #decoded > 80 and (string.sub(decoded, 1, 77) .. "…") or decoded),
                        severity = PluginAPI.Severity.INFO,
                        payload  = { stringId = stringId, decoded = decoded, key = key },
                    })
                end
            end
        end
    end

    if ctx.logger then
        ctx.logger:info("StringDeXOR: decoded %d of %d candidate strings",
            decodedCount, #bytecode.stringTable)
    end

    -- Attach decoded strings as ProjectDB comments on every LOADK that
    -- references one of them. The disassembler reports k-references on
    -- its decoded rows.
    local d = ctx.search and ctx.search._disassembler
    if d and ctx.projectDB then
        ctx.projectDB:transaction("StringDeXOR: attach comments", function()
            for protoId, _ in bytecode.protos do
                local ok, stream = pcall(function() return d:disassembleProto(protoId) end)
                if ok and stream and stream.instructions then
                    for _, insn in stream.instructions do
                        local k = insn.k or insn.constant or insn.K
                        if k and k.kind == "string" and k.stringId then
                            local rec = self._byString[k.stringId]
                            if rec then
                                ctx.projectDB:comments():add(
                                    protoId, insn.pc or 0,
                                    string.format("(decoded) %s", rec.decoded),
                                    { kind = "repeatable" })
                            end
                        end
                    end
                end
            end
        end)
    end
end

function StringDeXOR:cleanup()
    self.findings = nil
    self._byString = nil
end

return StringDeXOR
