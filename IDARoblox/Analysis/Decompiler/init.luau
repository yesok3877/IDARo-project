--!nonstrict
-- =====================================================================
-- IDARoblox / Analysis / Decompiler
-- ---------------------------------------------------------------------
-- Top-level orchestrator. Wires Lifter → StructureRecovery → Emitter.
--
-- Pipeline per proto:
--   1. Get disassembled InstructionStream from the Disassembler.
--   2. Get the CFG from the CFGBuilder.
--   3. Lifter.liftProto(stream, bytecode) → linear lifted IR.
--   4. StructureRecovery.recoverProto(cfg, lifted.stmts) → structured IR.
--   5. Emitter.emitFunction(lifted, structured) → text.
--
-- The Lifter accepts a `childIRs` parameter so that NEWCLOSURE /
-- DUPCLOSURE instructions can embed already-lifted children. To honor
-- that contract we decompile bottom-up: post-order over the proto tree
-- (rooted at mainProtoId, with children given by proto.childProtoIds),
-- so by the time we lift a parent every closure it might create has
-- already been lifted and is in the cache.
--
-- Public API:
--   local d = Decompiler.new(disassembler, cfgBuilder, parsedBytecode, opts)
--   local result = d:decompileProto(protoId)         -- { lifted, structured, text }
--   local mapping = d:decompileAll(progressCb)        -- protoId → result
--   local text   = d:decompileToText(protoId, opts)   -- shortcut
-- =====================================================================

local Lifter             = _G.IDARo.require("Analysis.Decompiler.Lifter")
local StructureRecovery  = _G.IDARo.require("Analysis.Decompiler.StructureRecovery")
local Emitter            = _G.IDARo.require("Analysis.Decompiler.Emitter")
local IR                 = _G.IDARo.require("Analysis.Decompiler.IR")

local Decompiler = {}
Decompiler.__index = Decompiler

Decompiler.Lifter           = Lifter
Decompiler.StructureRecovery = StructureRecovery
Decompiler.Emitter          = Emitter
Decompiler.IR               = IR

-- ---------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------

function Decompiler.new(disassembler, cfgBuilder, parsedBytecode, opts)
    if not disassembler then error("Decompiler.new: disassembler required", 2) end
    if not cfgBuilder then error("Decompiler.new: cfgBuilder required", 2) end
    if not parsedBytecode then error("Decompiler.new: parsedBytecode required", 2) end
    return setmetatable({
        _disasm   = disassembler,
        _cfg      = cfgBuilder,
        _bc       = parsedBytecode,
        _opts     = opts or {},
        _cache    = {},                                              -- protoId → result
        _logger   = opts and opts.logger,
    }, Decompiler)
end

-- ---------------------------------------------------------------------
-- Per-proto decompilation
-- ---------------------------------------------------------------------

local function decompileSingle(self, protoId, childIRs)
    if self._cache[protoId] then return self._cache[protoId] end
    local stream = self._disasm:disassembleProto(protoId)
    local cfg    = self._cfg:cfgForProto(protoId)

    local lifted = Lifter.liftProto(stream, self._bc, {
        childIRs = childIRs,
    })
    local structured = StructureRecovery.recoverProto(cfg, lifted.stmts)
    -- The lifter result needs a `body` field for the parent's
    -- liftClosure to consume.
    lifted.body = structured.body

    local result = {
        protoId    = protoId,
        lifted     = lifted,
        structured = structured,
        text       = nil,                                            -- emitted on demand
        stream     = stream,
        cfg        = cfg,
    }
    self._cache[protoId] = result
    return result
end

-- Post-order traversal of the proto tree: visit every child of `protoId`
-- before `protoId` itself. Cycles in proto trees aren't legal but we
-- protect against them anyway.
local function postOrderLift(self, protoId, visited, order)
    if visited[protoId] then return end
    visited[protoId] = true
    local proto = self._bc.protos[protoId]
    if proto and proto.childProtoIds then
        for _, childId in proto.childProtoIds do
            postOrderLift(self, childId, visited, order)
        end
    end
    order[#order + 1] = protoId
end

function Decompiler:decompileProto(protoId)
    if self._cache[protoId] then return self._cache[protoId] end

    -- Bottom-up: walk the subtree under `protoId` in post-order, lifting
    -- each in turn so closures can embed their children's bodies.
    local order   = {}
    local visited = {}
    postOrderLift(self, protoId, visited, order)

    local childIRs = {}                                              -- protoId → lifted (for the Lifter)
    for _, id in order do
        local result = decompileSingle(self, id, childIRs)
        childIRs[id] = result.lifted
    end

    return self._cache[protoId]
end

function Decompiler:decompileAll(progressCb)
    -- Start from the main proto, but make sure we catch any orphan
    -- protos (defensive).
    local mainId = self._bc.mainProtoId
    self:decompileProto(mainId)
    local i, total = 0, 0
    for _ in self._bc.protos do total = total + 1 end
    for id in self._bc.protos do
        if not self._cache[id] then self:decompileProto(id) end
        i = i + 1
        if progressCb then pcall(progressCb, i, total) end
    end
    return self._cache
end

-- ---------------------------------------------------------------------
-- Text output
-- ---------------------------------------------------------------------

function Decompiler:decompileToText(protoId, emitOpts)
    local res = self:decompileProto(protoId)
    if res.text then return res.text end
    local opts = emitOpts or {}
    opts.declarationStyle = opts.declarationStyle or "named"
    opts.functionName     = opts.functionName     or res.lifted.debugName
    opts.indent           = opts.indent           or "    "
    res.text = Emitter.emitFunction(res.lifted, res.structured, opts)
    return res.text
end

function Decompiler:invalidate(protoId)
    if protoId then self._cache[protoId] = nil
    else self._cache = {} end
end

function Decompiler:cacheSize()
    local n = 0
    for _ in self._cache do n = n + 1 end
    return n
end

-- ---------------------------------------------------------------------
-- Manifest
-- ---------------------------------------------------------------------

function Decompiler.manifest()
    return {
        id           = "Analysis.Decompiler",
        dependencies = { "Analysis.CFGBuilder" },
        weight       = 0.8,
        serviceName  = "Decompiler",
        stages = {
            { id = "register", weight = 1.0, fn = function(ctx)
                ctx:report(1, "Decompiler ready")
            end },
        },
    }
end

return Decompiler
