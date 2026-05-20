--!nonstrict
-- =====================================================================
-- IDARoblox / Analysis / StringAnalyzer
-- ---------------------------------------------------------------------
-- Classifies every string in the bytecode's string table and per-proto
-- string-load instructions. For each string, produces:
--
--   {
--     id          = stringId,
--     value       = "the literal",
--     length      = N,
--     class       = "URL" | "FilePath" | "Regex" | "Base64" | "Hex" |
--                   "Identifier" | "FormatString" | "SQL" | "LuaSource" |
--                   "JSON" | "ErrorMessage" | "AssetId" | "InstancePath" |
--                   "Plain",
--     confidence  = 0..1,
--     features    = { entropy, printableRatio, alphaRatio, digitRatio,
--                     specialRatio, histogram, hasNewlines, hasNullByte, … },
--     tokens      = { … }    -- class-specific extracted tokens (e.g. URL
--                              host/path/query; instance path segments)
--   }
--
-- Per-proto roll-up: which classes appear in which protos, ranked by
-- frequency. Drives plugin annotations like "this proto talks to URLs"
-- and powers a Strings view that filters by class.
-- =====================================================================

local StringAnalyzer = {}
StringAnalyzer.__index = StringAnalyzer

-- ---------------------------------------------------------------------
-- Class registry — display strings + ordering for the UI
-- ---------------------------------------------------------------------

StringAnalyzer.Class = table.freeze({
    URL           = "URL",
    FILE_PATH     = "FilePath",
    REGEX         = "Regex",
    BASE64        = "Base64",
    HEX           = "Hex",
    IDENTIFIER    = "Identifier",
    FORMAT_STRING = "FormatString",
    SQL           = "SQL",
    LUA_SOURCE    = "LuaSource",
    JSON          = "JSON",
    ERROR_MESSAGE = "ErrorMessage",
    ASSET_ID      = "AssetId",
    INSTANCE_PATH = "InstancePath",
    PLAIN         = "Plain",
    BINARY        = "Binary",
    EMPTY         = "Empty",
})

local DISPLAY_ORDER = {
    StringAnalyzer.Class.URL,
    StringAnalyzer.Class.INSTANCE_PATH,
    StringAnalyzer.Class.ASSET_ID,
    StringAnalyzer.Class.FILE_PATH,
    StringAnalyzer.Class.SQL,
    StringAnalyzer.Class.JSON,
    StringAnalyzer.Class.LUA_SOURCE,
    StringAnalyzer.Class.REGEX,
    StringAnalyzer.Class.FORMAT_STRING,
    StringAnalyzer.Class.ERROR_MESSAGE,
    StringAnalyzer.Class.IDENTIFIER,
    StringAnalyzer.Class.BASE64,
    StringAnalyzer.Class.HEX,
    StringAnalyzer.Class.PLAIN,
    StringAnalyzer.Class.BINARY,
    StringAnalyzer.Class.EMPTY,
}

StringAnalyzer.DISPLAY_ORDER = DISPLAY_ORDER

-- ---------------------------------------------------------------------
-- Character-class helpers
-- ---------------------------------------------------------------------

local function isUpper(b) return b >= 65 and b <= 90  end
local function isLower(b) return b >= 97 and b <= 122 end
local function isAlpha(b) return isUpper(b) or isLower(b) end
local function isDigit(b) return b >= 48 and b <= 57 end
local function isAlnum(b) return isAlpha(b) or isDigit(b) end
local function isHexDigit(b)
    return isDigit(b) or (b >= 65 and b <= 70) or (b >= 97 and b <= 102)
end
local function isB64(b)
    return isAlnum(b) or b == 43 or b == 47 or b == 61                -- + / =
end
local function isPrintable(b)
    return (b >= 32 and b <= 126) or b == 9 or b == 10 or b == 13
end

-- ---------------------------------------------------------------------
-- Feature extraction
-- ---------------------------------------------------------------------

local function extractFeatures(s)
    local n = #s
    if n == 0 then return { length = 0, entropy = 0, printableRatio = 0,
                            alphaRatio = 0, digitRatio = 0, specialRatio = 0,
                            histogram = {}, hasNewlines = false,
                            hasNullByte = false, hasUpper = false,
                            hasLower = false, hasDigit = false } end
    local freq = {}
    local printable, alpha, digit, special, upper, lower = 0, 0, 0, 0, 0, 0
    local hasNewlines, hasNullByte = false, false
    for i = 1, n do
        local b = string.byte(s, i)
        freq[b] = (freq[b] or 0) + 1
        if isPrintable(b) then printable = printable + 1 end
        if isAlpha(b) then alpha = alpha + 1 end
        if isDigit(b) then digit = digit + 1 end
        if isUpper(b) then upper = upper + 1 end
        if isLower(b) then lower = lower + 1 end
        if b == 10 or b == 13 then hasNewlines = true end
        if b == 0 then hasNullByte = true end
        if not isAlnum(b) and isPrintable(b) and b ~= 32 then
            special = special + 1
        end
    end
    -- Shannon entropy
    local entropy = 0
    for _, c in freq do
        local p = c / n
        entropy = entropy - p * (math.log(p) / math.log(2))
    end
    return {
        length         = n,
        entropy        = entropy,
        printableRatio = printable / n,
        alphaRatio     = alpha / n,
        digitRatio     = digit / n,
        specialRatio   = special / n,
        histogram      = freq,
        hasNewlines    = hasNewlines,
        hasNullByte    = hasNullByte,
        hasUpper       = upper > 0,
        hasLower       = lower > 0,
        hasDigit       = digit > 0,
    }
end

-- ---------------------------------------------------------------------
-- Classifier rules
--
-- Each rule examines the string + features and returns
-- (class, confidence 0..1, tokens?) or nil. The classifier picks the
-- highest-confidence rule. Order doesn't matter — rules are independent.
-- ---------------------------------------------------------------------

local CLASSIFIERS = {}

-- URL: http(s):// or ws:// or rbxasset://
CLASSIFIERS.URL = function(s, _f)
    local scheme = string.match(s, "^([%w%+%.%-]+)://")
    if scheme then
        local host, rest = string.match(s, "^[%w%+%.%-]+://([^/]+)(/?.*)$")
        if host then
            local conf = 0.98
            if string.find(host, "%.") then conf = 0.99 end
            local path, query = rest and string.match(rest, "^(/[^?#]*)%??(.*)$")
            return StringAnalyzer.Class.URL, conf,
                { scheme = scheme, host = host, path = path or "", query = query or "" }
        end
    end
    -- rbxasset:// shorthand
    if string.sub(s, 1, 11) == "rbxasset://" then
        return StringAnalyzer.Class.URL, 0.95,
            { scheme = "rbxasset", path = string.sub(s, 12) }
    end
    return nil
end

-- Roblox AssetId: rbxassetid://<digits>, or pure digits >= 8 digits
CLASSIFIERS.AssetId = function(s, _f)
    local digits = string.match(s, "^rbxassetid://(%d+)$")
    if digits then
        return StringAnalyzer.Class.ASSET_ID, 0.99, { id = digits }
    end
    if string.match(s, "^%d+$") and #s >= 8 and #s <= 12 then
        return StringAnalyzer.Class.ASSET_ID, 0.65, { id = s }
    end
    return nil
end

-- Instance path: "game.Workspace.Foo.Bar" or "script.Parent.Foo"
CLASSIFIERS.InstancePath = function(s, _f)
    if #s < 4 or #s > 256 then return nil end
    if string.find(s, "[\n\r\t]") then return nil end
    -- Looks like a chain of Identifier (. Identifier)+
    if string.match(s, "^[%a_][%w_]*[%.:][%a_][%w_]*") then
        -- Count segments
        local segs = {}
        for seg in string.gmatch(s, "[%a_][%w_]*") do
            segs[#segs + 1] = seg
        end
        if #segs >= 2 then
            local known = { game = true, workspace = true, script = true,
                            Workspace = true, Players = true, ReplicatedStorage = true,
                            ServerScriptService = true, ServerStorage = true,
                            StarterPack = true, StarterGui = true,
                            ReplicatedFirst = true, Lighting = true,
                            CoreGui = true, StarterPlayer = true, Teams = true }
            local conf = 0.55
            if known[segs[1]] then conf = 0.92 end
            -- Reject if it actually looks like a Lua expression (operators)
            if string.find(s, "[%+%-%*/%(%)%[%]%{%}%<%>%=%~]") then
                return nil
            end
            return StringAnalyzer.Class.INSTANCE_PATH, conf, { segments = segs }
        end
    end
    return nil
end

-- File path: ends in /something.ext or starts with /, contains slash
CLASSIFIERS.FilePath = function(s, f)
    if f.length < 3 or f.length > 512 then return nil end
    if f.hasNewlines then return nil end
    local hasFwd = string.find(s, "/", 1, true)
    local hasBck = string.find(s, "\\", 1, true)
    if not hasFwd and not hasBck then return nil end
    -- If it has scheme:// it's a URL not a path
    if string.find(s, "://", 1, true) then return nil end
    -- Common file extensions
    local ext = string.match(s, "%.([%w]+)$")
    if ext and #ext >= 2 and #ext <= 6 then
        return StringAnalyzer.Class.FILE_PATH, 0.85, { ext = ext }
    end
    if hasFwd or hasBck then
        return StringAnalyzer.Class.FILE_PATH, 0.55, {}
    end
    return nil
end

-- SQL: contains SELECT / INSERT / UPDATE / DELETE / WHERE / FROM
CLASSIFIERS.SQL = function(s, _f)
    local upper = string.upper(s)
    local keywords = { "SELECT ", "INSERT INTO ", "UPDATE ", "DELETE FROM ",
                       "CREATE TABLE ", "ALTER TABLE ", "DROP TABLE " }
    local hits = 0
    for _, kw in keywords do
        if string.find(upper, kw, 1, true) then hits = hits + 1 end
    end
    if hits > 0 then
        if string.find(upper, " FROM ", 1, true) or string.find(upper, " WHERE ", 1, true) then
            return StringAnalyzer.Class.SQL, 0.95, { keywords = hits }
        end
        return StringAnalyzer.Class.SQL, 0.7, { keywords = hits }
    end
    return nil
end

-- JSON: starts with { or [, ends with } or ]
CLASSIFIERS.JSON = function(s, f)
    if f.length < 2 then return nil end
    local first = string.sub(s, 1, 1)
    local last  = string.sub(s, -1, -1)
    if (first == "{" and last == "}") or (first == "[" and last == "]") then
        -- Quick syntactic plausibility: contains ":" or "[]" / "{}"
        if string.find(s, '"', 1, true) and string.find(s, ":", 1, true) then
            return StringAnalyzer.Class.JSON, 0.9, {}
        end
        if f.length <= 4 then
            -- "{}", "[]" empty containers
            return StringAnalyzer.Class.JSON, 0.85, { empty = true }
        end
        return StringAnalyzer.Class.JSON, 0.55, {}
    end
    return nil
end

-- Lua source: contains "function" / "local" / "end" / "return" keywords
CLASSIFIERS.LuaSource = function(s, _f)
    if #s < 10 then return nil end
    local hits = 0
    if string.find(s, "function%s+[%a_]", 1, false) then hits = hits + 1 end
    if string.find(s, "local%s+[%a_]",   1, false) then hits = hits + 1 end
    if string.find(s, "%send%s",         1, false) or string.find(s, "%send$", 1, false) then hits = hits + 1 end
    if string.find(s, "return ", 1, true) then hits = hits + 1 end
    if string.find(s, "then", 1, true) and string.find(s, "if ", 1, true) then hits = hits + 1 end
    if hits >= 2 then
        return StringAnalyzer.Class.LUA_SOURCE, math.min(0.6 + hits * 0.1, 0.97), { tokens = hits }
    end
    return nil
end

-- Lua pattern / regex-like: contains "%a", "%d", "%w" character classes
-- or "(.+)", "(.-)" capture patterns
CLASSIFIERS.Regex = function(s, _f)
    if #s < 3 or #s > 256 then return nil end
    local classCount = 0
    for _ in string.gmatch(s, "%%[adlpsuwx]") do classCount = classCount + 1 end
    local hasCapture = string.find(s, "%(.+%)", 1, false) or string.find(s, "%(.-%)", 1, false)
    if classCount >= 2 or (classCount >= 1 and hasCapture) then
        return StringAnalyzer.Class.REGEX, 0.85, { classes = classCount }
    end
    -- Anchored patterns "^foo$" or "^[a-z]"
    if string.find(s, "^^", 1, false) and string.find(s, "$$", 1, false) then
        return StringAnalyzer.Class.REGEX, 0.7, {}
    end
    return nil
end

-- Format string: contains %s, %d, %x, %f, %q, %.Nf, etc.
CLASSIFIERS.FormatString = function(s, _f)
    local count = 0
    for _ in string.gmatch(s, "%%[%-%+%# ]?%d*%.?%d*[sdifqxXeEgGcb]") do
        count = count + 1
    end
    if count >= 1 and #s > 4 then
        return StringAnalyzer.Class.FORMAT_STRING, math.min(0.65 + count * 0.1, 0.95),
            { specifiers = count }
    end
    return nil
end

-- Error message: starts with the proto's name, contains ":" then text
CLASSIFIERS.ErrorMessage = function(s, _f)
    if #s < 8 or #s > 512 then return nil end
    -- Common patterns: "X:Y: error", "X expected, got Y", "invalid X"
    if string.find(s, "^attempt to", 1, false)
        or string.find(s, "^invalid ", 1, false)
        or string.find(s, " expected, got ", 1, true)
        or string.find(s, ": bad argument", 1, true)
        or string.find(s, "[Ee]rror:", 1, false) then
        return StringAnalyzer.Class.ERROR_MESSAGE, 0.9, {}
    end
    return nil
end

-- Identifier: pure [A-Za-z_][A-Za-z0-9_]*
CLASSIFIERS.Identifier = function(s, _f)
    if string.match(s, "^[%a_][%w_]*$") then
        if #s <= 64 then
            return StringAnalyzer.Class.IDENTIFIER,
                #s <= 16 and 0.85 or 0.75, {}
        end
    end
    return nil
end

-- Base64: all printable, only [A-Za-z0-9+/=], length divisible by 4 (mostly)
CLASSIFIERS.Base64 = function(s, f)
    if f.length < 8 or f.length > 16384 then return nil end
    if not f.hasUpper or not f.hasLower or not f.hasDigit then return nil end
    if f.specialRatio > 0.15 then return nil end                     -- too many specials
    -- Every byte must be a b64 char
    for i = 1, f.length do
        local b = string.byte(s, i)
        if not isB64(b) and b ~= 10 and b ~= 13 then return nil end
    end
    local conf = 0.5
    if f.length % 4 == 0 then conf = conf + 0.2 end
    if f.entropy > 5.5 then conf = conf + 0.15 end
    if f.length >= 32 then conf = conf + 0.1 end
    -- Padding '=' must only appear at the end (max 2)
    local padCount = 0
    for i = f.length, math.max(1, f.length - 2), -1 do
        if string.byte(s, i) == 61 then padCount = padCount + 1 else break end
    end
    if padCount > 0 then conf = conf + 0.05 end
    return StringAnalyzer.Class.BASE64, math.min(conf, 0.95), { padding = padCount }
end

-- Hex blob: all [0-9A-Fa-f], even length, length >= 8
CLASSIFIERS.Hex = function(s, f)
    if f.length < 8 or f.length % 2 ~= 0 then return nil end
    for i = 1, f.length do
        if not isHexDigit(string.byte(s, i)) then return nil end
    end
    local conf = 0.75
    if f.length >= 32 then conf = conf + 0.15 end
    if f.entropy > 3.5 then conf = conf + 0.05 end
    return StringAnalyzer.Class.HEX, math.min(conf, 0.97), {}
end

-- Binary (low printable ratio)
CLASSIFIERS.Binary = function(s, f)
    if f.hasNullByte or f.printableRatio < 0.5 then
        return StringAnalyzer.Class.BINARY, 0.9, {}
    end
    return nil
end

-- ---------------------------------------------------------------------
-- Top-level classify
-- ---------------------------------------------------------------------

local function classifyOne(s)
    if type(s) ~= "string" then
        return { class = StringAnalyzer.Class.EMPTY, confidence = 1, features = {} }
    end
    if s == "" then
        return { class = StringAnalyzer.Class.EMPTY, confidence = 1, features = {
            length = 0, entropy = 0, printableRatio = 0, alphaRatio = 0,
            digitRatio = 0, specialRatio = 0, histogram = {},
            hasNewlines = false, hasNullByte = false,
            hasUpper = false, hasLower = false, hasDigit = false } }
    end
    local features = extractFeatures(s)
    -- Run all classifiers, pick highest-confidence non-PLAIN/non-BINARY
    -- result. We delay binary detection so that base64 (printable) and
    -- binary blobs can both be considered.
    local best = { class = StringAnalyzer.Class.PLAIN, confidence = 0.1, tokens = {} }
    for _, fn in CLASSIFIERS do
        local class, conf, tokens = fn(s, features)
        if class and conf and conf > best.confidence then
            best = { class = class, confidence = conf, tokens = tokens or {} }
        end
    end
    -- Special demotion: if it scored highest as binary but is otherwise
    -- highly printable, prefer plain.
    if best.class == StringAnalyzer.Class.BINARY and features.printableRatio > 0.9 then
        best = { class = StringAnalyzer.Class.PLAIN, confidence = 0.5, tokens = {} }
    end
    return {
        class      = best.class,
        confidence = best.confidence,
        features   = features,
        tokens     = best.tokens,
    }
end

StringAnalyzer.classifyOne = classifyOne

-- ---------------------------------------------------------------------
-- Construction + bulk analysis
-- ---------------------------------------------------------------------

function StringAnalyzer.new(opts)
    opts = opts or {}
    return setmetatable({
        _disassembler = opts.disassembler,
        _bytecode     = opts.bytecode,
        _logger       = opts.logger,
        _byString     = {},                                          -- stringId → classification
        _byProto      = {},                                          -- protoId → { class → { stringIds } }
        _byClass      = {},                                          -- class → { stringIds }
        _stats = {
            stringsAnalyzed = 0,
            byClassCount    = {},
        },
    }, StringAnalyzer)
end

function StringAnalyzer:setBytecode(bc)
    self._bytecode = bc
    self._byString = {}
    self._byProto = {}
    self._byClass = {}
end

function StringAnalyzer:setDisassembler(d) self._disassembler = d end

function StringAnalyzer:analyseStringTable()
    if not self._bytecode or not self._bytecode.stringTable then return end
    self._byString = {}
    self._byClass = {}
    self._stats.byClassCount = {}
    for id, s in self._bytecode.stringTable do
        if type(s) == "string" then
            local rec = classifyOne(s)
            rec.id    = id
            rec.value = s
            self._byString[id] = rec
            local list = self._byClass[rec.class]
            if not list then list = {}; self._byClass[rec.class] = list end
            list[#list + 1] = id
            self._stats.byClassCount[rec.class] =
                (self._stats.byClassCount[rec.class] or 0) + 1
            self._stats.stringsAnalyzed = self._stats.stringsAnalyzed + 1
        end
    end
    if self._logger then
        local summary = {}
        for class, count in self._stats.byClassCount do
            summary[#summary + 1] = string.format("%s:%d", class, count)
        end
        table.sort(summary)
        self._logger:info("StringAnalyzer: %d strings (%s)",
            self._stats.stringsAnalyzed, table.concat(summary, ", "))
    end
end

function StringAnalyzer:analyseProtoReferences()
    -- Walks every instruction looking for LOADK/LOADKX that reference a
    -- string constant and records the proto→class mapping.
    if not self._bytecode or not self._disassembler then return end
    self._byProto = {}
    for protoId, _ in self._bytecode.protos do
        local ok, stream = pcall(function()
            return self._disassembler:disassembleProto(protoId)
        end)
        if ok and stream and stream.instructions then
            local byClass = {}
            for _, insn in stream.instructions do
                local k = insn.k or insn.K or insn.constant
                if k and k.kind == "string" and k.stringId then
                    local rec = self._byString[k.stringId]
                    if rec then
                        local list = byClass[rec.class]
                        if not list then list = {}; byClass[rec.class] = list end
                        list[#list + 1] = k.stringId
                    end
                end
            end
            self._byProto[protoId] = byClass
        end
    end
end

function StringAnalyzer:analyseAll()
    self:analyseStringTable()
    self:analyseProtoReferences()
end

-- ---------------------------------------------------------------------
-- Queries
-- ---------------------------------------------------------------------

function StringAnalyzer:get(stringId) return self._byString[stringId] end

function StringAnalyzer:byClass(class)
    local ids = self._byClass[class]
    if not ids then return {} end
    local out = table.create(#ids)
    for i, id in ids do out[i] = self._byString[id] end
    return out
end

function StringAnalyzer:protoSummary(protoId)
    local mapping = self._byProto[protoId]
    if not mapping then return {} end
    local out = {}
    for class, ids in mapping do
        out[#out + 1] = { class = class, count = #ids, stringIds = ids }
    end
    table.sort(out, function(a, b) return a.count > b.count end)
    return out
end

function StringAnalyzer:globalSummary()
    local out = {}
    for class, count in self._stats.byClassCount do
        out[#out + 1] = { class = class, count = count }
    end
    table.sort(out, function(a, b)
        -- Sort by display order then count
        local ai = 999; local bi = 999
        for i, c in DISPLAY_ORDER do
            if c == a.class then ai = i end
            if c == b.class then bi = i end
        end
        if ai == bi then return a.count > b.count end
        return ai < bi
    end)
    return out
end

function StringAnalyzer:stats() return self._stats end

return StringAnalyzer
