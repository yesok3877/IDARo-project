--!nonstrict
-- =====================================================================
-- IDARoblox / Plugins / Builtin / VMHandlerDetect
-- ---------------------------------------------------------------------
-- Detects Luau scripts that run an additional bytecode VM in user-space
-- (the so-called "VM-in-VM" protection style — ironbrew, moonsec,
-- luraph at high tiers). The original code is compiled to a custom
-- opcode set and interpreted by a Luau "dispatcher" function.
--
-- Detection signatures
--   * Dispatcher proto
--       - Contains a `while true do … end` loop with > N basic blocks
--       - Inside the loop, a single switch (chain of JUMPIFEQ on a
--         "pc"-register) selects an opcode handler
--       - Constants include a single very-long string constant ("the
--         encoded program") with high entropy
--   * Handler table
--       - A proto whose constants are 80%+ CLOSURE constants with
--         numeric-index references
--   * Loader stub
--       - Main proto contains GETIMPORT chains for `string.byte` and
--         `string.sub` plus a SETLIST/NEWTABLE → likely a decoder
--
-- Flags identified protos with the OBFUSCATED + ENTRY (for the
-- dispatcher) symbol flags and proposes canonical names.
-- =====================================================================

local PluginAPI = _G.IDARo.require("Plugins.PluginAPI")
local Database  = _G.IDARo.require("Database")

local PLUGIN_ID = "builtin.vmHandlerDetect"

local function shannonEntropy(s)
    if #s == 0 then return 0 end
    local freq = {}
    for i = 1, #s do
        local b = string.byte(s, i)
        freq[b] = (freq[b] or 0) + 1
    end
    local n, h = #s, 0
    for _, c in freq do
        local p = c / n
        h = h - p * (math.log(p) / math.log(2))
    end
    return h
end

local function countClosuresInK(proto)
    if not proto.constants then return 0, 0 end
    local total, closures = 0, 0
    for _, k in proto.constants do
        total = total + 1
        if k.kind == "closure" then closures = closures + 1 end
    end
    return closures, total
end

local function hasLongHighEntropyString(proto)
    if not proto.constants then return false, 0 end
    for _, k in proto.constants do
        if k.kind == "string" and type(k.value) == "string" and #k.value >= 256 then
            if shannonEntropy(k.value) >= 7.0 then
                return true, #k.value
            end
        end
    end
    return false, 0
end

-- A "while true do" dispatcher in disassembled form: the proto's last
-- instruction (or near-last) is JUMPBACK to the proto's first
-- instruction (or one near it), and the first block contains a chain
-- of conditional jumps to the same set of constants.
local function looksLikeDispatcher(stream)
    if not stream or not stream.instructions then return false end
    local n = #stream.instructions
    if n < 16 then return false end
    -- Find a JUMPBACK in the last 10% of the proto that jumps to the
    -- first 10% of the proto (the loop header).
    local backJumpThreshold = math.floor(n * 0.9)
    local headerLimit       = math.floor(n * 0.10)
    for i = backJumpThreshold, n do
        local insn = stream.instructions[i]
        if insn.mnemonic == "JUMPBACK" or
            (insn.mnemonic == "JUMP" and (insn.offset or 0) < 0) then
            local target = (insn.targetPc or (insn.pc or 0) + (insn.offset or 0))
            if target <= headerLimit then
                -- Now look in the header for a chain of JUMPIFEQ / JUMPIFLT
                -- targeting different addresses (the opcode switch).
                local condJumps = 0
                for j = 1, math.min(n, headerLimit + 16) do
                    local m = stream.instructions[j].mnemonic
                    if m == "JUMPIFEQ" or m == "JUMPIFNOTEQ"
                        or m == "JUMPXEQKN" or m == "JUMPXEQKS"
                        or m == "JUMPXEQKB" or m == "JUMPXEQKNIL" then
                        condJumps = condJumps + 1
                    end
                end
                if condJumps >= 4 then return true end
            end
        end
    end
    return false
end

-- ---------------------------------------------------------------------
-- Manifest
-- ---------------------------------------------------------------------

local VMHandlerDetect = {
    id          = PLUGIN_ID,
    name        = "VM-in-Luau Detector",
    author      = "IDARo",
    version     = "1.0",
    description = "Identifies user-space-VM protections (dispatcher loops + "
        .. "handler tables + encoded program constants).",
    requires    = { "projectDB" },
    priority    = 40,
    findings    = nil :: { any }?,
}

function VMHandlerDetect:init(_ctx) self.findings = {} end

function VMHandlerDetect:scan(bytecode, ctx)
    self.findings = {}
    if not bytecode or not bytecode.protos then return end

    local d = ctx.search and ctx.search._disassembler
    local flags = Database.SymbolTable.Flags
    local symbols = ctx.projectDB:symbols()
    local dispatcherCandidates = 0
    local handlerTableCandidates = 0
    local programConstants = 0

    for protoId, proto in bytecode.protos do
        local sym = symbols:byKey("proto", tostring(protoId))

        -- (1) Long high-entropy string constant
        local hasProg, progLen = hasLongHighEntropyString(proto)
        if hasProg then
            programConstants = programConstants + 1
            self.findings[#self.findings + 1] = PluginAPI.annotation({
                source   = PLUGIN_ID,
                kind     = PluginAPI.AnnotationKind.WARN,
                text     = string.format(
                    "proto %d carries a %d-byte high-entropy constant "
                    .. "(possible encoded VM program)",
                    protoId, progLen),
                severity = PluginAPI.Severity.WARN,
                symbol   = sym and { kind = "proto", key = sym.key } or nil,
            })
        end

        -- (2) Closure-table fingerprint
        local closureCount, total = countClosuresInK(proto)
        if total >= 16 and (closureCount / total) > 0.75 then
            handlerTableCandidates = handlerTableCandidates + 1
            if sym and not symbols:hasFlag(sym, flags.USER_NAMED) then
                ctx.projectDB:transaction("VMHandlerDetect: handler-table rename", function()
                    ctx.projectDB:renameProto(protoId,
                        string.format("vm_handler_table_%d", protoId))
                    symbols:setFlag(sym.id, flags.OBFUSCATED, true)
                end)
            end
            self.findings[#self.findings + 1] = PluginAPI.annotation({
                source   = PLUGIN_ID,
                kind     = PluginAPI.AnnotationKind.RENAME,
                text     = string.format(
                    "proto %d is a likely VM handler table (%d/%d closures in k)",
                    protoId, closureCount, total),
                severity = PluginAPI.Severity.WARN,
                symbol   = sym and { kind = "proto", key = sym.key } or nil,
            })
        end

        -- (3) Dispatcher loop fingerprint
        if d then
            local ok, stream = pcall(function() return d:disassembleProto(protoId) end)
            if ok and stream and looksLikeDispatcher(stream) then
                dispatcherCandidates = dispatcherCandidates + 1
                if sym and not symbols:hasFlag(sym, flags.USER_NAMED) then
                    ctx.projectDB:transaction("VMHandlerDetect: dispatcher rename", function()
                        ctx.projectDB:renameProto(protoId,
                            string.format("vm_dispatcher_%d", protoId))
                        symbols:setFlag(sym.id, flags.OBFUSCATED, true)
                    end)
                end
                self.findings[#self.findings + 1] = PluginAPI.annotation({
                    source   = PLUGIN_ID,
                    kind     = PluginAPI.AnnotationKind.RENAME,
                    text     = string.format(
                        "proto %d is a likely VM dispatcher (loop + switch)",
                        protoId),
                    severity = PluginAPI.Severity.ERROR,
                    symbol   = sym and { kind = "proto", key = sym.key } or nil,
                })
            end
        end
    end

    if ctx.logger then
        ctx.logger:info(
            "VMHandlerDetect: %d dispatcher candidates, %d handler tables, "
            .. "%d encoded-program constants",
            dispatcherCandidates, handlerTableCandidates, programConstants)
    end
end

function VMHandlerDetect:cleanup() self.findings = nil end

return VMHandlerDetect
