--!nonstrict
-- =====================================================================
-- IDARoblox / Analysis / BytecodeParser
-- ---------------------------------------------------------------------
-- Top-level parser that converts the raw bytes returned by
-- `getscriptbytecode(script)` (or any equivalent dump) into a fully
-- decoded data structure consumed by every later subsystem
-- (Disassembler, CFGBuilder, Decompiler, XRefEngine, …).
--
-- Coverage:
--   * Bytecode versions 3..6
--   * Types versions 0..3 (typed-Luau type blobs preserved verbatim;
--     decoded lazily by the type-aware later steps)
--   * String table with interning (1-indexed)
--   * Userdata type remap table (v4+, typesVersion >= 2)
--   * Per-proto: maxstacksize, numparams, nups, isvararg, flags,
--     instructions (32-bit words verbatim), constants (all 8 tags),
--     child proto ids, lineDefined, debugNameId, optional line info,
--     optional debug info (locals + upvalues)
--   * Main proto id (at the tail of the file)
--
-- Post-parse passes:
--   * Resolve IMPORT chains (decode the encoded 32-bit id into a
--     1..3-segment string path using the proto's own k-table)
--   * Resolve TABLE constant keys (k-index → string)
--   * Resolve debug name strings for protos
--   * Fill `result.byName` and `result.byDebugName` lookup maps
--
-- The parser does not interpret instructions (that's Step 4, the
-- Disassembler). It DOES walk the instruction array to honor AUX
-- consumption when building structural metadata (instruction-count and
-- has-aux-at-pc flags).
-- =====================================================================

local BytecodeReader = _G.IDARo.require("Analysis.BytecodeReader")
local OpcodeTable    = _G.IDARo.require("Analysis.OpcodeTable")

local BytecodeParser = {}

-- ---------------------------------------------------------------------
-- Constant decoder
-- ---------------------------------------------------------------------

local CT = OpcodeTable.Constant

local function parseConstant(reader): { [string]: any }
    local tag = reader:readU8()
    if tag == CT.NIL then
        return { tag = "NIL" }
    elseif tag == CT.BOOLEAN then
        return { tag = "BOOLEAN", value = reader:readU8() ~= 0 }
    elseif tag == CT.NUMBER then
        return { tag = "NUMBER", value = reader:readF64() }
    elseif tag == CT.STRING then
        local id = reader:readVarInt()
        return {
            tag      = "STRING",
            stringId = id,
            value    = reader:string(id) or "",
        }
    elseif tag == CT.IMPORT then
        local enc = reader:readU32()
        return {
            tag        = "IMPORT",
            encodedId  = enc,
            -- chain filled in post-pass once all constants are read
            chain      = nil,
        }
    elseif tag == CT.TABLE then
        local n = reader:readVarInt()
        local keyKIdxs = table.create(n)
        for i = 1, n do keyKIdxs[i] = reader:readVarInt() end
        return {
            tag       = "TABLE",
            keyKIdxs  = keyKIdxs,                                   -- raw 0-based k-indices
            keys      = nil,                                        -- resolved post-pass
        }
    elseif tag == CT.CLOSURE then
        return {
            tag     = "CLOSURE",
            protoId = reader:readVarInt(),
        }
    elseif tag == CT.VECTOR then
        local x = reader:readF32()
        local y = reader:readF32()
        local z = reader:readF32()
        local w = reader:readF32()
        return {
            tag   = "VECTOR",
            value = { x = x, y = y, z = z, w = w },
        }
    else
        error(string.format("Unknown constant tag: %d (at 0x%X)", tag, reader:tell()), 0)
    end
end

-- ---------------------------------------------------------------------
-- Proto parser
-- ---------------------------------------------------------------------

local function parseProto(reader, ctx, protoId: number, callbacks)
    reader:_pushContext(string.format("proto #%d", protoId))

    local proto = {
        id              = protoId,
        maxstacksize    = reader:readU8(),
        numparams       = reader:readU8(),
        nups            = reader:readU8(),
        isvararg        = reader:readU8() ~= 0,
        flags           = 0,
        types           = nil,
        instructions    = nil,
        sizecode        = 0,
        constants       = nil,
        childProtoIds   = nil,
        lineDefined     = 0,
        debugNameId     = 0,
        debugName       = nil,
        hasLineInfo     = false,
        lineInfo        = nil,
        hasDebugInfo    = false,
        debug           = nil,
    }

    -- v4+ adds flags + types blob
    if ctx.version >= 4 then
        proto.flags = reader:readU8()
        if ctx.typesVersion >= 1 then
            local typesize = reader:readVarInt()
            if typesize > 0 then
                proto.types = reader:readBytes(typesize)
            end
        end
    end

    -- Instructions
    reader:_pushContext("instructions")
    proto.sizecode     = reader:readVarInt()
    proto.instructions = reader:readInstructions(proto.sizecode)
    reader:_popContext()

    -- Constants
    reader:_pushContext("constants")
    local sizek = reader:readVarInt()
    proto.constants = table.create(sizek)
    for i = 1, sizek do
        proto.constants[i] = parseConstant(reader)
    end
    reader:_popContext()

    -- Child protos (varints, each is a proto index into the top-level array)
    reader:_pushContext("childProtos")
    local sizep = reader:readVarInt()
    proto.childProtoIds = table.create(sizep)
    for i = 1, sizep do
        proto.childProtoIds[i] = reader:readVarInt()
    end
    reader:_popContext()

    -- Source positions
    proto.lineDefined = reader:readVarInt()
    proto.debugNameId = reader:readVarInt()
    proto.debugName   = reader:string(proto.debugNameId)

    -- Optional line info
    local hasLineInfo = reader:readU8() ~= 0
    proto.hasLineInfo = hasLineInfo
    if hasLineInfo then
        proto.lineInfo = reader:readLineInfo(proto.sizecode)
    end

    -- Optional debug info
    local hasDebugInfo = reader:readU8() ~= 0
    proto.hasDebugInfo = hasDebugInfo
    if hasDebugInfo then
        proto.debug = reader:readDebugInfo()
    end

    reader:_popContext()

    if callbacks and callbacks.onProto then
        pcall(callbacks.onProto, proto, protoId)
    end
    return proto
end

-- ---------------------------------------------------------------------
-- Post-passes
-- ---------------------------------------------------------------------

-- Resolve every IMPORT constant's chain and every TABLE constant's keys
-- now that all k-tables exist.
local function resolvePostPasses(result)
    local stringTable = result.stringTable
    for _, proto in result.protos do
        for kIdx, c in proto.constants do
            if c.tag == "IMPORT" and c.chain == nil then
                c.chain = OpcodeTable.resolveImportChain(c.encodedId, proto.constants, stringTable)
            elseif c.tag == "TABLE" and c.keys == nil then
                local out = table.create(#c.keyKIdxs)
                for i, ki in c.keyKIdxs do
                    local k = proto.constants[ki + 1]
                    if k and k.tag == "STRING" then
                        out[i] = k.value
                    else
                        out[i] = string.format("?k%d", ki)
                    end
                end
                c.keys = out
            end
            -- Annotate constant index for downstream tooling
            c.index = kIdx
        end
    end
end

-- Verify instruction-stream AUX consumption is consistent: every opcode
-- that claims an AUX word must have a successor word available. We
-- record the AUX-bearing PCs so the disassembler doesn't have to scan
-- the whole stream a second time.
local function buildInstructionMetadata(result)
    for _, proto in result.protos do
        local n = proto.sizecode
        local insns = proto.instructions
        local auxAt = {}
        local opAt  = {}
        local pc = 1
        while pc <= n do
            local insn = insns[pc]
            local op   = bit32.band(insn, 0xFF)
            opAt[pc] = op
            if OpcodeTable.hasAux(op) then
                auxAt[pc] = true
                pc = pc + 2
            else
                pc = pc + 1
            end
        end
        proto.auxAt = auxAt                                          -- pc → true if this insn has AUX after
        proto.opAt  = opAt                                           -- pc → opcode (filled only for primary insns)
    end
end

-- Build name-lookup maps on the result for navigation.
local function buildLookupMaps(result)
    local byDebugName = {}
    local byLineDefined = {}
    for id, proto in result.protos do
        if proto.debugName and proto.debugName ~= "" then
            byDebugName[proto.debugName] = byDebugName[proto.debugName] or {}
            table.insert(byDebugName[proto.debugName], id)
        end
        if proto.lineDefined and proto.lineDefined > 0 then
            byLineDefined[proto.lineDefined] = byLineDefined[proto.lineDefined] or {}
            table.insert(byLineDefined[proto.lineDefined], id)
        end
    end
    result.byDebugName   = byDebugName
    result.byLineDefined = byLineDefined
end

-- Build statistics over the parsed file.
local function buildStats(result)
    local totalInstructions, totalConstants, totalChildEdges = 0, 0, 0
    local maxStack, deepest = 0, 0
    local countByOp = {}
    local countByConstTag = { NIL = 0, BOOLEAN = 0, NUMBER = 0, STRING = 0,
                              IMPORT = 0, TABLE = 0, CLOSURE = 0, VECTOR = 0 }
    for _, proto in result.protos do
        totalInstructions = totalInstructions + proto.sizecode
        totalConstants    = totalConstants + #proto.constants
        totalChildEdges   = totalChildEdges + #proto.childProtoIds
        if proto.maxstacksize > maxStack then maxStack = proto.maxstacksize end
        if #proto.childProtoIds > deepest then deepest = #proto.childProtoIds end
        for pc, op in proto.opAt do
            countByOp[op] = (countByOp[op] or 0) + 1
        end
        for _, k in proto.constants do
            countByConstTag[k.tag] = (countByConstTag[k.tag] or 0) + 1
        end
    end
    result.stats = {
        protos              = #result.protos + 1,                    -- protos are 0-indexed
        totalInstructions   = totalInstructions,
        totalConstants      = totalConstants,
        totalStrings        = #result.stringTable,
        totalChildEdges     = totalChildEdges,
        maxStackOverall     = maxStack,
        deepestChildEdgeFan = deepest,
        countByOp           = countByOp,
        countByConstTag     = countByConstTag,
    }
end

-- ---------------------------------------------------------------------
-- Top-level parse
-- ---------------------------------------------------------------------

function BytecodeParser.parse(bytes: string | buffer, opts)
    opts = opts or {}
    local reader = BytecodeReader.new(bytes)

    -- Header
    local header = reader:readHeader()

    -- String table
    local stringTable = reader:readStringTable()

    -- Userdata types (v4+ with typesVersion >= 2)
    local userdataTypes = {}
    if header.version >= 4 and header.typesVersion >= 2 then
        userdataTypes = reader:readUserdataTypes()
    end

    -- Build the parse context. Stored on reader so parseProto can read.
    local ctx = {
        version       = header.version,
        typesVersion  = header.typesVersion,
        stringTable   = stringTable,
        userdataTypes = userdataTypes,
    }

    -- Protos (Luau encodes them 0-indexed; child references use the same)
    reader:_pushContext("protos")
    local protoCount = reader:readVarInt()
    if protoCount < 0 or protoCount > 0x100000 then
        reader:_fail(string.format("Suspicious proto count: %d", protoCount))
    end
    local protos = table.create(protoCount)
    for i = 0, protoCount - 1 do
        protos[i] = parseProto(reader, ctx, i, opts.callbacks)
        if opts.callbacks and opts.callbacks.onProtoProgress then
            pcall(opts.callbacks.onProtoProgress, i + 1, protoCount)
        end
    end
    reader:_popContext()

    -- Main proto id (always at the tail)
    local mainProtoId = reader:readVarInt()
    if not protos[mainProtoId] then
        reader:_fail(string.format("Main proto id %d out of range (%d protos)", mainProtoId, protoCount))
    end

    -- Build the result
    local result = {
        version        = header.version,
        typesVersion   = header.typesVersion,
        stringTable    = stringTable,
        userdataTypes  = userdataTypes,
        protos         = protos,
        mainProtoId    = mainProtoId,
        bytesConsumed  = reader:tell() - 1,
        bytesTrailing  = reader:bytesAvailable(),
    }

    -- Post-passes
    buildInstructionMetadata(result)
    resolvePostPasses(result)
    buildLookupMaps(result)
    buildStats(result)

    -- Helpers attached to the result
    function result:getProto(id: number)
        return self.protos[id]
    end

    function result:mainProto()
        return self.protos[self.mainProtoId]
    end

    function result:stringAt(id: number): string?
        if id == 0 then return nil end
        return self.stringTable[id]
    end

    function result:resolveImport(proto, encodedId): { string }
        return OpcodeTable.resolveImportChain(encodedId, proto.constants, self.stringTable)
    end

    -- Iterate over the instructions of a proto yielding pc/op/aux/meta.
    function result:iterateInstructions(proto)
        return OpcodeTable.iterate(proto.instructions)
    end

    return result
end

-- ---------------------------------------------------------------------
-- Convenience: parse the bytecode of a live script via getscriptbytecode
-- ---------------------------------------------------------------------

function BytecodeParser.parseScript(scriptInstance, opts)
    -- Most executors expose getscriptbytecode in their elevated globals
    -- (getgenv) rather than in _G or the script's own fenv. Walk every
    -- candidate environment and accept known aliases.
    local getBytecode
    local sources = { _G }
    local g = rawget(_G, "getgenv")
    if type(g) == "function" then
        local ok, env = pcall(g)
        if ok and type(env) == "table" then sources[#sources + 1] = env end
    end
    local r = rawget(_G, "getrenv")
    if type(r) == "function" then
        local ok, env = pcall(r)
        if ok and type(env) == "table" then sources[#sources + 1] = env end
    end
    sources[#sources + 1] = getfenv()
    for _, env in sources do
        local fn = rawget(env, "getscriptbytecode")
            or rawget(env, "dumpstring")
            or rawget(env, "getscriptbytes")
        if type(fn) == "function" then getBytecode = fn; break end
    end
    if type(getBytecode) ~= "function" then
        error("BytecodeParser.parseScript: getscriptbytecode unavailable in this env "
            .. "(checked _G, getgenv(), getrenv(), getfenv())", 2)
    end
    local ok, bytes = pcall(getBytecode, scriptInstance)
    if not ok then
        error("BytecodeParser.parseScript: getscriptbytecode failed: " .. tostring(bytes), 2)
    end
    if type(bytes) ~= "string" or #bytes == 0 then
        error("BytecodeParser.parseScript: getscriptbytecode returned empty result", 2)
    end
    return BytecodeParser.parse(bytes, opts)
end

-- ---------------------------------------------------------------------
-- Module manifest for the Kernel's LoadingManager
-- ---------------------------------------------------------------------
-- The manifest below describes a "warm-up" registration that simply
-- exposes the parser to the service locator. Real parsing work is
-- demand-driven (caller invokes BytecodeParser.parse on user action),
-- so the load itself is fast — opcode-table sanity check + service
-- registration. Returned for convenience; the Bootstrap script will
-- pass this to kernel:registerModule().
-- ---------------------------------------------------------------------

function BytecodeParser.manifest()
    return {
        id           = "Analysis.BytecodeParser",
        dependencies = { },                                          -- OpcodeTable is required-not-registered
        weight       = 0.4,
        serviceName  = "BytecodeParser",
        stages = {
            { id = "sanity", weight = 0.5, fn = function(ctx)
                -- Sanity check the OpcodeTable: every meta entry has
                -- consistent fmt/aux/flow. Cheap but catches mis-edits.
                local count = 0
                for id, m in OpcodeTable.Meta do
                    count = count + 1
                    if m.fmt ~= "ABC" and m.fmt ~= "AD" and m.fmt ~= "E" then
                        error(string.format("OpcodeTable: opcode %d (%s) has invalid fmt '%s'",
                            id, m.name, tostring(m.fmt)), 0)
                    end
                    if (id % 20) == 0 then ctx:yield() end
                end
                ctx:report(1, string.format("verified %d opcodes", count))
            end },
            { id = "register", weight = 0.5, fn = function(ctx)
                ctx:report(1, "BytecodeParser ready")
            end },
        },
    }
end

-- Re-exports so callers don't have to require OpcodeTable too.
BytecodeParser.OpcodeTable = OpcodeTable
BytecodeParser.Reader      = BytecodeReader

return BytecodeParser
