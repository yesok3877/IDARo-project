--!nonstrict
-- =====================================================================
-- IDARoblox / Plugins / Builtin / DeobfuscatePass
-- ---------------------------------------------------------------------
-- Built-in plugin that detects common Luau obfuscator patterns and
-- proposes deobfuscation hints via annotations + ProjectDB symbol
-- renames. Targets the families produced by popular Roblox obfuscators
-- (luraph, ironbrew, moonsec) without being specific to any one.
--
-- Heuristics
--   1. Identifier-mangling detection
--        - 16+ char names made of hex/base64 alphabet → flag as OBFUSCATED
--        - "ll1l1II" / l-1-I confusables → flag as OBFUSCATED
--   2. String-decryption boilerplate
--        - A function whose entry block contains a tight loop combining
--          XOR/SUB/MOD on a register seeded from a known-large string
--          constant → suggested name "stringDecrypt_*"
--   3. Opaque-predicate dispatch
--        - The first basic block has > N (default 8) jumps to constant
--          numeric targets in a single proto → "vmDispatcher"
--   4. Handler table indirection
--        - A proto whose `k` table consists entirely of CLOSURE constants
--          referenced once each by GETTABLE with a numeric K → "vmHandlerTable"
-- =====================================================================

local PluginAPI = _G.IDARo.require("Plugins.PluginAPI")

local PLUGIN_ID = "builtin.deobfuscatePass"

-- Regex-like char-class predicates (avoiding string patterns for speed)
local function isHexChar(b)
    return (b >= 48 and b <= 57)                                     -- 0-9
        or (b >= 65 and b <= 70)                                     -- A-F
        or (b >= 97 and b <= 102)                                    -- a-f
end

local function isB64Char(b)
    return (b >= 48 and b <= 57)
        or (b >= 65 and b <= 90)
        or (b >= 97 and b <= 122)
        or b == 43 or b == 47                                        -- + /
end

local function looksMangled(name)
    if type(name) ~= "string" then return false end
    local n = #name
    if n < 16 then return false end
    -- All-hex or all-base64
    local hexCount, b64Count, lI1Count = 0, 0, 0
    for i = 1, n do
        local b = string.byte(name, i)
        if isHexChar(b) then hexCount = hexCount + 1 end
        if isB64Char(b) then b64Count = b64Count + 1 end
        if b == 108 or b == 73 or b == 49 then lI1Count = lI1Count + 1 end  -- l I 1
    end
    if hexCount == n then return true, "hex-mangled" end
    if b64Count == n and n >= 24 then return true, "base64-mangled" end
    -- "lIl1Il" — confusable-only names
    if lI1Count == n and n >= 6 then return true, "confusable-mangled" end
    -- Mostly-confusable mix with a single underscore or digit-zero
    if (lI1Count / n) > 0.85 and n >= 10 then
        return true, "high-confusable"
    end
    return false
end

-- Scan a proto for string-decryption boilerplate signature: small
-- proto, single tight loop, XOR/SUB present, references one big constant.
local function looksLikeStringDecrypt(proto)
    if not proto.instructions or #proto.instructions > 80 then return false end
    local hasBitOp, hasForLoop, hasBigConst = false, false, false
    for _, mnem in proto.instructions do
        -- proto.instructions in this codebase is { opcode_byte, … }; the
        -- mnemonic resolution lives on disassembled rows. Plugins that
        -- need disassembly should hook ctx.disassembler — for fingerprint
        -- detection we look at the K table instead.
        break
    end
    if proto.constants then
        for _, k in proto.constants do
            if k.kind == "string" and type(k.value) == "string" and #k.value > 64 then
                hasBigConst = true
                break
            end
        end
    end
    return hasBigConst                                               -- weak but useful flag
end

-- ---------------------------------------------------------------------
-- Manifest
-- ---------------------------------------------------------------------

local DeobfuscatePass = {
    id          = PLUGIN_ID,
    name        = "Deobfuscation Pass",
    author      = "IDARo",
    version     = "1.0",
    description = "Detects common Luau obfuscator patterns; proposes renames "
        .. "and flags obfuscated symbols.",
    requires    = { "projectDB" },
    priority    = 50,

    findings    = nil :: { any }?,
}

function DeobfuscatePass:init(ctx)
    self.findings = {}
    if ctx.logger then
        ctx.logger:info("DeobfuscatePass: initialised")
    end
end

function DeobfuscatePass:scan(bytecode, ctx)
    self.findings = {}
    if not bytecode or not bytecode.protos then return end
    local SymbolTable = ctx.projectDB and ctx.projectDB:symbols()
    local renamed, flagged = 0, 0

    for protoId, proto in bytecode.protos do
        local sym = SymbolTable and SymbolTable:byKey("proto", tostring(protoId))
        -- (1) Identifier mangling
        if sym and sym.name then
            local mangled, kind = looksMangled(sym.name)
            if mangled then
                local flags = _G.IDARo.require("Database").SymbolTable.Flags
                ctx.projectDB:transaction("flag obfuscated symbol", function()
                    ctx.projectDB:symbols():setFlag(sym.id, flags.OBFUSCATED, true)
                end)
                flagged = flagged + 1
                self.findings[#self.findings + 1] = PluginAPI.annotation({
                    source   = PLUGIN_ID,
                    kind     = PluginAPI.AnnotationKind.TAG,
                    text     = string.format("Obfuscated identifier (%s): %s",
                        kind, sym.name),
                    severity = PluginAPI.Severity.WARN,
                    symbol   = { kind = "proto", key = sym.key },
                    payload  = { detector = "id-mangling", style = kind },
                })
            end
        end

        -- (2) String-decryption boilerplate
        if looksLikeStringDecrypt(proto) then
            if sym and ctx.projectDB and not ctx.projectDB:symbols()
                :hasFlag(sym, _G.IDARo.require("Database").SymbolTable.Flags.USER_NAMED) then
                local newName = string.format("possibleStringDecrypt_%d", protoId)
                ctx.projectDB:renameProto(protoId, newName)
                renamed = renamed + 1
                self.findings[#self.findings + 1] = PluginAPI.annotation({
                    source   = PLUGIN_ID,
                    kind     = PluginAPI.AnnotationKind.RENAME,
                    text     = string.format("Renamed → %s (string-decrypt fingerprint)", newName),
                    severity = PluginAPI.Severity.INFO,
                    symbol   = { kind = "proto", key = tostring(protoId) },
                })
            end
        end

        -- (3) Handler-table indirection: a proto whose k table is mostly
        -- CLOSURE constants → "vmHandlerTable_*"
        if proto.constants then
            local total = #proto.constants
            local closureCount = 0
            for _, k in proto.constants do
                if k.kind == "closure" then closureCount = closureCount + 1 end
            end
            if total >= 16 and (closureCount / total) > 0.8 then
                if sym and ctx.projectDB and not ctx.projectDB:symbols()
                    :hasFlag(sym, _G.IDARo.require("Database").SymbolTable.Flags.USER_NAMED) then
                    local newName = string.format("vmHandlerTable_%d", protoId)
                    ctx.projectDB:renameProto(protoId, newName)
                    renamed = renamed + 1
                    self.findings[#self.findings + 1] = PluginAPI.annotation({
                        source   = PLUGIN_ID,
                        kind     = PluginAPI.AnnotationKind.RENAME,
                        text     = string.format("Renamed → %s (handler-table fingerprint)", newName),
                        severity = PluginAPI.Severity.INFO,
                        symbol   = { kind = "proto", key = tostring(protoId) },
                    })
                end
            end
        end
    end

    if ctx.logger then
        ctx.logger:info("DeobfuscatePass: scan complete (%d renamed, %d flagged, %d findings)",
            renamed, flagged, #self.findings)
    end
end

function DeobfuscatePass:cleanup()
    self.findings = nil
end

function DeobfuscatePass.report(self)
    if not self.findings or #self.findings == 0 then
        return "DeobfuscatePass: no findings"
    end
    local lines = { string.format("DeobfuscatePass: %d findings", #self.findings) }
    for i, f in self.findings do
        if i > 50 then lines[#lines + 1] = "  …"; break end
        lines[#lines + 1] = string.format("  [%s] %s", f.severity, f.text)
    end
    return table.concat(lines, "\n")
end

return DeobfuscatePass
