--!nonstrict
-- =====================================================================
-- IDARoblox / Analysis / init
-- ---------------------------------------------------------------------
-- Re-exports the three Step-3 modules and offers a comprehensive
-- self-test that round-trips a hand-crafted bytecode blob through the
-- parser. This is the canonical "is the parser correct?" gate; later
-- steps depend on its output.
-- =====================================================================

local OpcodeTable       = _G.IDARo.require("Analysis.OpcodeTable")
local BytecodeReader    = _G.IDARo.require("Analysis.BytecodeReader")
local BytecodeParser    = _G.IDARo.require("Analysis.BytecodeParser")
local Disassembler      = _G.IDARo.require("Analysis.Disassembler")
local CFGBuilder        = _G.IDARo.require("Analysis.CFGBuilder")
local DataFlowAnalyzer  = _G.IDARo.require("Analysis.DataFlowAnalyzer")
local XRefEngine        = _G.IDARo.require("Analysis.XRefEngine")
local Decompiler        = _G.IDARo.require("Analysis.Decompiler")
local PatternMatcher    = _G.IDARo.require("Analysis.PatternMatcher")
local Heuristics        = _G.IDARo.require("Analysis.Heuristics")
local Plugins           = _G.IDARo.require("Analysis.Plugins")
local BinaryStream      = _G.IDARo.require("Core.BinaryStream")

local Analysis = {}

Analysis.OpcodeTable        = OpcodeTable
Analysis.BytecodeReader     = BytecodeReader
Analysis.BytecodeParser     = BytecodeParser
Analysis.Disassembler       = Disassembler
Analysis.CFGBuilder         = CFGBuilder
Analysis.DataFlowAnalyzer   = DataFlowAnalyzer
Analysis.XRefEngine         = XRefEngine
Analysis.Decompiler         = Decompiler
Analysis.PatternMatcher     = PatternMatcher
Analysis.Heuristics         = Heuristics
Analysis.Plugins            = Plugins

-- ---------------------------------------------------------------------
-- Hand-crafted bytecode generator (for the self-test)
-- ---------------------------------------------------------------------

local Op = OpcodeTable.Op
local C  = OpcodeTable.Constant

local function packABC(op, a, b, c)
    return bit32.bor(
        bit32.band(op, 0xFF),
        bit32.lshift(bit32.band(a or 0, 0xFF), 8),
        bit32.lshift(bit32.band(b or 0, 0xFF), 16),
        bit32.lshift(bit32.band(c or 0, 0xFF), 24)
    )
end

local function packAD(op, a, d)
    -- D is signed 16-bit; truncate to 16 bits via bitand 0xFFFF
    return bit32.bor(
        bit32.band(op, 0xFF),
        bit32.lshift(bit32.band(a or 0, 0xFF), 8),
        bit32.lshift(bit32.band(d or 0, 0xFFFF), 16)
    )
end

local function buildTestBytecode()
    local w = BinaryStream.writer()

    -- Header
    w:writeU8(6)                                                    -- bytecode version 6
    w:writeU8(0)                                                    -- types version 0 (untyped)

    -- String table: 2 strings
    w:writeVarInt(2)
    w:writeVarInt(3); w:writeBytes("foo")
    w:writeVarInt(5); w:writeBytes("hello")

    -- Userdata types (none — only present when typesVersion >= 2)
    -- (skipped since typesVersion == 0)

    -- Protos: 1 proto
    w:writeVarInt(1)

    -- Proto 0
    w:writeU8(2)                                                    -- maxstacksize
    w:writeU8(0)                                                    -- numparams
    w:writeU8(0)                                                    -- nups
    w:writeU8(0)                                                    -- isvararg
    w:writeU8(0)                                                    -- flags (v4+)
    w:writeVarInt(0)                                                -- types size (no blob)

    -- Instructions: 3 instructions
    --   LOADK R0 K(1)         ; R0 = K[1] = "foo"  (STRING constant)
    --   LOADN R1 42           ; R1 = 42
    --   RETURN R0 3           ; return R0, R1 (B=count+1=3)
    w:writeVarInt(3)
    w:writeU32(packAD(Op.LOADK,  0, 1))                             -- K idx 1 = "foo" (1-based in my model)
    w:writeU32(packAD(Op.LOADN,  1, 42))
    w:writeU32(packABC(Op.RETURN, 0, 3, 0))

    -- Constants: 2 (NIL, STRING(id=1))
    -- We need a STRING constant at k-index 1 (1-based) for LOADK above
    -- to reference. LOADK's D is the 0-based k-index, so we write the
    -- STRING constant FIRST (k-index 0) and a NIL at k-index 1 so the
    -- instruction "LOADK R0 K(1)" sees… wait, the instruction encodes
    -- LOADK R0 K(0) actually, since k-index in instruction is 0-based.
    -- We already wrote packAD(LOADK, 0, 1) — meaning D=1, so it
    -- references k[1] (0-based) = the SECOND constant.
    -- Layout: [0]=NIL, [1]=STRING("foo")
    w:writeVarInt(2)
    w:writeU8(C.NIL)                                                -- k[0] = nil
    w:writeU8(C.STRING); w:writeVarInt(1)                           -- k[1] = STRING id 1 → "foo"

    -- Child protos: none
    w:writeVarInt(0)

    -- Line info / debug name
    w:writeVarInt(0)                                                -- lineDefined
    w:writeVarInt(2)                                                -- debugNameId → "hello"

    -- Optional line info
    w:writeU8(1)                                                    -- present
    w:writeU8(0)                                                    -- linegaplog2 = 0
    -- per-instruction delta bytes (sizecode = 3)
    w:writeU8(0); w:writeU8(0); w:writeU8(0)
    -- abslineinfo intervals = floor((3-1)/1)+1 = 3 → 3 int32s
    w:writeI32(10); w:writeI32(0); w:writeI32(0)

    -- Optional debug info
    w:writeU8(0)                                                    -- absent

    -- Main proto id
    w:writeVarInt(0)

    return w:toString()
end

-- ---------------------------------------------------------------------
-- Self-test
-- ---------------------------------------------------------------------

function Analysis.runSelfTest(kernel)
    local logger = kernel and kernel:logger() or nil
    local passes, fails = 0, 0
    local function check(name, ok, info)
        if ok then
            passes = passes + 1
            if logger then logger:debug("Analysis self-test pass: %s", name) end
        else
            fails = fails + 1
            local msg = string.format("Analysis self-test FAIL: %s — %s", name, tostring(info))
            if logger then logger:error("%s", msg) else print(msg) end
        end
    end

    -- ---------- OpcodeTable structural checks ----------

    do
        local count = 0
        for _, m in OpcodeTable.Meta do count = count + 1 end
        check("OpcodeTable has >= 83 opcodes", count >= 83, count)

        -- Specific opcode encodings
        local insn = packABC(Op.MOVE, 5, 7, 0)
        local op, a, b, c = OpcodeTable.decodeABC(insn)
        check("decodeABC", op == Op.MOVE and a == 5 and b == 7 and c == 0)

        local insn2 = packAD(Op.JUMP, 0, -10)
        local op2, a2, d2 = OpcodeTable.decodeAD(insn2)
        check("decodeAD signed D", op2 == Op.JUMP and d2 == -10)

        local insn3 = bit32.bor(Op.JUMPX, bit32.lshift(bit32.band(0xFFFFF0, 0xFFFFFF), 8))
        local op3, e3 = OpcodeTable.decodeE(insn3)
        -- 0xFFFFF0 as signed 24-bit = -16
        check("decodeE signed E", op3 == Op.JUMPX and e3 == -16, e3)

        -- Predicates
        check("isUncondJump(JUMP)", OpcodeTable.isUnconditionalJump(Op.JUMP))
        check("isCondJump(JUMPIF)", OpcodeTable.isConditionalJump(Op.JUMPIF))
        check("isReturn(RETURN)", OpcodeTable.isReturn(Op.RETURN))
        check("hasAux(NAMECALL)",  OpcodeTable.hasAux(Op.NAMECALL))
        check("hasAux(MOVE)==false", not OpcodeTable.hasAux(Op.MOVE))
    end

    -- ---------- Hand-crafted parse end-to-end ----------

    do
        local bytes = buildTestBytecode()
        check("test bytecode non-empty", #bytes > 0, #bytes)

        local ok, result = pcall(BytecodeParser.parse, bytes)
        check("parse OK", ok, result)
        if not ok then
            if logger then logger:error("parse aborted self-test: %s", tostring(result)) end
            return passes, fails
        end

        check("version = 6", result.version == 6, result.version)
        check("typesVersion = 0", result.typesVersion == 0)
        check("stringTable has 2", #result.stringTable == 2)
        check("string[1]='foo'", result.stringTable[1] == "foo")
        check("string[2]='hello'", result.stringTable[2] == "hello")
        check("protos = 1", #result.protos + 1 == 1, #result.protos)
        check("mainProto = 0", result.mainProtoId == 0)

        local main = result:mainProto()
        check("mainProto.sizecode = 3", main.sizecode == 3, main.sizecode)
        check("mainProto.maxstacksize = 2", main.maxstacksize == 2)
        check("mainProto.constants 2", #main.constants == 2)
        check("k[1] = NIL", main.constants[1].tag == "NIL")
        check("k[2] = STRING 'foo'", main.constants[2].tag == "STRING"
            and main.constants[2].value == "foo")
        check("debugName = 'hello'", main.debugName == "hello")

        check("hasLineInfo", main.hasLineInfo)
        check("lineInfo lookup pc=1 → 10", main.lineInfo.lookup(1) == 10,
            main.lineInfo.lookup(1))

        -- Verify instruction-iteration honors AUX consumption.
        local seen = 0
        for pc, insn, aux, m in result:iterateInstructions(main) do
            seen = seen + 1
        end
        check("iterateInstructions visits 3", seen == 3, seen)

        -- Stats
        check("stats.protos = 1", result.stats.protos == 1)
        check("stats.totalInstructions = 3", result.stats.totalInstructions == 3)
        check("stats.totalConstants = 2", result.stats.totalConstants == 2)

        -- ---------- Disassembler round-trip on same bytecode ----------

        local disasm = Disassembler.new(result, { useDebugNames = false })
        local stream = disasm:disassembleProto(0)
        check("Disassembler.stream has 3 rows", #stream.rows == 3, #stream.rows)

        local r1, r2, r3 = stream.rows[1], stream.rows[2], stream.rows[3]
        check("row1 mnemonic = LOADK",  r1.mnemonic == "LOADK",  r1.mnemonic)
        check("row2 mnemonic = LOADN",  r2.mnemonic == "LOADN",  r2.mnemonic)
        check("row3 mnemonic = RETURN", r3.mnemonic == "RETURN", r3.mnemonic)
        check("row1 address = 0x0000",  r1.address == 0, r1.address)
        check("row2 address = 0x0004",  r2.address == 4, r2.address)
        check("row3 address = 0x0008",  r3.address == 8, r3.address)
        check("row1 has line 10",       r1.line == 10, r1.line)

        -- LOADK K-resolution comment includes "foo"
        local row1Comments = table.concat(r1.comments or {}, " ")
        check("LOADK comment shows 'foo'", row1Comments:find("foo") ~= nil, row1Comments)

        -- LOADN operand shows literal 42
        check("LOADN operand has '42'", (r2.operandText or ""):find("42") ~= nil, r2.operandText)

        -- RETURN registers a structured return reference
        local hasReturnRef = false
        for _, ref in r3.references or {} do
            if ref.kind == "return" then hasReturnRef = true; break end
        end
        check("RETURN has return reference", hasReturnRef)

        -- Stream rendering produces non-empty multi-line text
        local rendered = disasm:formatProto(0)
        check("formatProto non-empty", #rendered > 0, #rendered)
        check("formatProto includes 'LOADK'", rendered:find("LOADK") ~= nil)
        check("formatProto includes proto header", rendered:find("proto%[0%]") ~= nil)

        -- formatLine on one row
        local oneLine = disasm:formatLine(r2)
        check("formatLine has '0x0004'", oneLine:find("0x0004") ~= nil, oneLine)
        check("formatLine has 'LOADN'", oneLine:find("LOADN") ~= nil)
    end

    -- ---------- Disassembler formatters smoke-test ----------

    do
        -- Construct a synthetic proto with one of every flow-control opcode
        -- and verify each row gets a sensible operandText (non-empty).
        local proto = {
            id           = 0,
            maxstacksize = 4,
            numparams    = 0,
            nups         = 0,
            isvararg     = false,
            flags        = 0,
            lineDefined  = 0,
            debugNameId  = 0,
            debugName    = nil,
            sizecode     = 0,
            instructions = {},
            constants    = {
                { tag = "NIL", index = 1 },
                { tag = "STRING", value = "hello", stringId = 1, index = 2 },
                { tag = "NUMBER", value = 3.14, index = 3 },
            },
            childProtoIds = {},
            hasLineInfo  = false,
            lineInfo     = nil,
            hasDebugInfo = false,
            debug        = nil,
        }
        -- Helper for ABC pack
        local function abc(op, a, b, c)
            return bit32.bor(bit32.band(op, 0xFF),
                bit32.lshift(bit32.band(a or 0, 0xFF), 8),
                bit32.lshift(bit32.band(b or 0, 0xFF), 16),
                bit32.lshift(bit32.band(c or 0, 0xFF), 24))
        end
        local function ad(op, a, d)
            return bit32.bor(bit32.band(op, 0xFF),
                bit32.lshift(bit32.band(a or 0, 0xFF), 8),
                bit32.lshift(bit32.band(d or 0, 0xFFFF), 16))
        end

        local Op = OpcodeTable.Op
        local insns = proto.instructions
        local function push(insn) insns[#insns + 1] = insn end

        push(abc(Op.MOVE, 0, 1, 0))                                  -- MOVE
        push(ad(Op.LOADN, 1, -5))                                    -- LOADN with negative D
        push(abc(Op.ADD, 2, 0, 1))                                   -- ADD
        push(abc(Op.NEWTABLE, 3, 2, 0)); push(8)                     -- NEWTABLE + AUX
        push(abc(Op.GETTABLEKS, 0, 3, 0)); push(1)                   -- GETTABLEKS + AUX K idx
        push(abc(Op.NAMECALL, 0, 3, 0));   push(1)                   -- NAMECALL + AUX K idx (method "hello")
        push(abc(Op.CALL, 0, 1, 1))                                  -- CALL R0, 0 args, 0 rets
        push(ad(Op.JUMP, 0, 1))                                      -- JUMP +1 → target = pc+1+1 = pc=13
        push(abc(Op.RETURN, 0, 1, 0))                                -- pc=12: skipped by JUMP
        push(abc(Op.RETURN, 0, 1, 0))                                -- pc=13: JUMP lands here

        proto.sizecode = #insns
        -- Build auxAt / opAt to match what BytecodeParser does
        proto.auxAt = {}
        proto.opAt  = {}
        do
            local pc = 1
            while pc <= proto.sizecode do
                local insn = insns[pc]
                local op = bit32.band(insn, 0xFF)
                proto.opAt[pc] = op
                if OpcodeTable.hasAux(op) then
                    proto.auxAt[pc] = true
                    pc = pc + 2
                else
                    pc = pc + 1
                end
            end
        end

        -- Fake parsed-bytecode envelope
        local fakeBC = {
            version       = 6,
            typesVersion  = 0,
            stringTable   = { "hello" },
            protos        = { [0] = proto },
            mainProtoId   = 0,
        }

        local disasm = Disassembler.new(fakeBC)
        local stream = disasm:disassembleProto(0)

        -- Every row should have non-empty operandText except NOP
        local missing = 0
        for _, row in stream.rows do
            if row.mnemonic ~= "NOP" and (not row.operandText or row.operandText == "") then
                missing = missing + 1
            end
        end
        check("every non-NOP row has operandText", missing == 0, missing)

        -- JUMP should have produced a label and a branch reference
        local jumpRow
        for _, row in stream.rows do
            if row.mnemonic == "JUMP" then jumpRow = row; break end
        end
        check("JUMP row exists", jumpRow ~= nil)
        if jumpRow then
            local hasBranch = false
            for _, ref in jumpRow.references or {} do
                if ref.kind == "branch" then hasBranch = true; break end
            end
            check("JUMP has branch reference", hasBranch)
            check("JUMP target has a label", next(stream.labels) ~= nil)
        end

        -- NAMECALL should resolve method name
        local ncRow
        for _, row in stream.rows do
            if row.mnemonic == "NAMECALL" then ncRow = row; break end
        end
        check("NAMECALL resolved method", ncRow and (table.concat(ncRow.comments or {}, " ")):find("hello") ~= nil,
            ncRow and ncRow.comments)

        -- formatAll should run without error
        local ok2, text = pcall(disasm.formatProto, disasm, 0)
        check("formatProto runs on synthetic proto", ok2 and #text > 0, text)
    end

    -- ---------- Import-id decoding ----------

    do
        -- count=2, id0=4, id1=7 → encoded
        local enc = bit32.bor(
            bit32.lshift(2, 30),
            bit32.lshift(4, 20),
            bit32.lshift(7, 10),
            0)
        local count, i0, i1, i2 = OpcodeTable.decodeImportId(enc)
        check("decodeImportId count", count == 2)
        check("decodeImportId id0",  i0 == 4)
        check("decodeImportId id1",  i1 == 7)
        check("decodeImportId id2",  i2 == 0)

        -- Full resolution: build a tiny synthetic proto.
        local stringTable = { "game", "Players" }
        local protoConsts = {
            { tag = "STRING", value = "game",    stringId = 1, index = 1 },
            { tag = "STRING", value = "Players", stringId = 2, index = 2 },
            { tag = "IMPORT", encodedId = enc, index = 3 },
        }
        -- count=2, k-indices 4 and 7 are wrong for this proto. Re-pack with
        -- the right indices (0 and 1) so we hit the strings.
        local enc2 = bit32.bor(
            bit32.lshift(2, 30),
            bit32.lshift(0, 20),
            bit32.lshift(1, 10),
            0)
        local chain = OpcodeTable.resolveImportChain(enc2, protoConsts, stringTable)
        check("resolveImportChain length", #chain == 2, #chain)
        check("resolveImportChain[1]", chain[1] == "game")
        check("resolveImportChain[2]", chain[2] == "Players")
    end

    -- ---------- CFGBuilder + DataFlowAnalyzer ----------

    do
        -- Build a small but interesting proto:
        --
        --   pc=1   LOADN R0, 0           ; counter
        --   pc=2   LOADN R1, 10          ; limit
        --   pc=3:                        ← header
        --   pc=3   JUMPIFLT R0, R1, +6 → pc=10 (body); fall to pc=4 (exit)
        --   pc=5   AUX
        --   pc=6   RETURN R0, 1          ; exit
        --   pc=7   LOADN R2, 1
        --   pc=8   ADD R0, R0, R2
        --   pc=9   JUMPBACK -8 → pc=3   ; back edge (loop)
        --
        -- Layout above re-numbered because JUMPIFLT consumes an AUX:
        --
        --   pc=1   LOADN
        --   pc=2   LOADN
        --   pc=3   JUMPIFLT (header)
        --   pc=4   AUX
        --   pc=5   RETURN
        --   pc=6   LOADN
        --   pc=7   ADD
        --   pc=8   JUMPBACK
        --
        -- Expected blocks:
        --   B1  pc 1..2  (entry)        falls into B2
        --   B2  pc 3..5  (header)       fall to B3 (exit-return), branch to B4 (body)
        --   B3  pc 5..5  (return)       → synthetic exit
        --   B4  pc 6..8  (body)         back edge to B2 (header)
        --
        -- Note: the leader algorithm will pick:
        --   leaders = {1, 3, 6} since pc=3 is target of JUMPBACK (back),
        --                       pc=6 is target of JUMPIFLT,
        --                       pc=5 is the instruction after RETURN (terminator)
        --   But pc=5 IS the AUX of JUMPIFLT — there's no row at pc=4.
        --   The leader-after-terminator picks RETURN's next pc which is 6,
        --   already a leader. The post-AUX of JUMPIFLT is pc=5 (RETURN).
        --   So leaders = {1, 3, 5, 6} → 4 blocks.

        local Op = OpcodeTable.Op
        local function abc(op, a, b, c)
            return bit32.bor(bit32.band(op, 0xFF),
                bit32.lshift(bit32.band(a or 0, 0xFF), 8),
                bit32.lshift(bit32.band(b or 0, 0xFF), 16),
                bit32.lshift(bit32.band(c or 0, 0xFF), 24))
        end
        local function ad(op, a, d)
            return bit32.bor(bit32.band(op, 0xFF),
                bit32.lshift(bit32.band(a or 0, 0xFF), 8),
                bit32.lshift(bit32.band(d or 0, 0xFFFF), 16))
        end

        local insns = {}
        local function push(x) insns[#insns + 1] = x end

        push(ad(Op.LOADN, 0, 0))                                     -- pc=1
        push(ad(Op.LOADN, 1, 10))                                    -- pc=2
        -- JUMPIFLT (AD+AUX). Target = pc + 2 + D.
        -- We want target = pc=6 (body start), so D = 6 - 3 - 2 = 1.
        push(ad(Op.JUMPIFLT, 0, 1))                                  -- pc=3
        push(1)                                                       -- pc=4 AUX = reg 1
        push(abc(Op.RETURN, 0, 1, 0))                                 -- pc=5
        push(ad(Op.LOADN, 2, 1))                                     -- pc=6
        push(abc(Op.ADD, 0, 0, 2))                                    -- pc=7
        -- JUMPBACK. Target = pc + 1 + D. We want target = 3.
        -- D = 3 - 8 - 1 = -6. 16-bit signed encoding = 0xFFFA.
        push(ad(Op.JUMPBACK, 0, bit32.band(-6 % 0x10000, 0xFFFF)))    -- pc=8

        local proto = {
            id           = 0,
            maxstacksize = 4,
            numparams    = 0,
            nups         = 0,
            isvararg     = false,
            flags        = 0,
            lineDefined  = 0,
            debugName    = "loop_proto",
            sizecode     = #insns,
            instructions = insns,
            constants    = {},
            childProtoIds = {},
            hasLineInfo  = false,
            lineInfo     = nil,
            hasDebugInfo = false,
            debug        = nil,
        }
        -- Build opAt / auxAt the same way BytecodeParser does
        proto.auxAt = {}; proto.opAt = {}
        do
            local pc = 1
            while pc <= proto.sizecode do
                local insn = insns[pc]
                local op = bit32.band(insn, 0xFF)
                proto.opAt[pc] = op
                if OpcodeTable.hasAux(op) then
                    proto.auxAt[pc] = true
                    pc = pc + 2
                else
                    pc = pc + 1
                end
            end
        end

        local fakeBC = {
            version       = 6,
            typesVersion  = 0,
            stringTable   = {},
            protos        = { [0] = proto },
            mainProtoId   = 0,
            stats         = { protos = 1, totalInstructions = #insns,
                              totalConstants = 0, totalStrings = 0 },
        }

        local disasm = Disassembler.new(fakeBC)
        local cfgb   = CFGBuilder.new(disasm)
        local cfg    = cfgb:cfgForProto(0)

        check("CFG built", cfg ~= nil)
        check("CFG has >= 3 blocks", cfg.stats.blockCount >= 3, cfg.stats.blockCount)
        check("CFG has back edges", cfg.stats.backEdgeCount >= 1, cfg.stats.backEdgeCount)
        check("CFG detected at least one loop", cfg.stats.loopCount >= 1, cfg.stats.loopCount)
        check("loop header marked", (function()
            for _, b in cfg.blocks do
                if b.isLoopHeader then return true end
            end
            return false
        end)())
        check("entry block has no predecessors", #cfg.blocks[1].predecessors == 0,
            #cfg.blocks[1].predecessors)
        check("entry idom = entry (self)", cfg.idom[1] == 1)

        -- Every non-entry reachable block must have an idom assigned.
        local missingIdom = 0
        for blkId in cfg.blocks do
            if blkId ~= 1 and cfg.idom[blkId] == nil then missingIdom = missingIdom + 1 end
        end
        check("all reachable blocks have idom", missingIdom == 0, missingIdom)

        -- Reverse-postorder is non-empty and starts at entry.
        check("RPO starts at entry", cfg.reversePostOrder[1] == 1)
        check("RPO covers all blocks",
            #cfg.reversePostOrder == cfg.stats.blockCount,
            #cfg.reversePostOrder, cfg.stats.blockCount)

        -- ---- DataFlowAnalyzer ----
        local dfaMgr = DataFlowAnalyzer.new(cfgb)
        local dfa = dfaMgr:analyze(0)
        check("DFA built", dfa ~= nil)
        check("DFA defs at pc=1 includes R0",
            dfa:defsAt(1)[0] == true)
        check("DFA uses at pc=8 (JUMPBACK) is empty",
            next(dfa:usesAt(8)) == nil)
        check("DFA: ADD pc=7 defs R0, uses R0+R2",
            dfa:defsAt(7)[0] == true
            and dfa:usesAt(7)[0] == true
            and dfa:usesAt(7)[2] == true)

        -- LiveIn[entry] should be empty (no register read before being defined).
        check("LiveIn[entry] empty",
            next(dfa.liveIn[1] or {}) == nil)

        -- LiveOut of the entry block must include R0 and R1 (they are
        -- defined in entry and consumed by the header's compare).
        local liveOutEntry = dfa.liveOut[1] or {}
        check("LiveOut[entry] has R0", liveOutEntry[0] == true, liveOutEntry)
        check("LiveOut[entry] has R1", liveOutEntry[1] == true, liveOutEntry)

        -- Register interval check
        local r0 = dfa:registerInterval(0)
        check("R0 interval covers full proto", r0 and r0.first == 1 and r0.last >= 7,
            r0 and r0.first, r0 and r0.last)

        -- Convergence sanity
        check("liveness iterations small", dfa.iterations <= 32, dfa.iterations)
    end

    -- ---------- XRefEngine ----------

    do
        -- Build a small proto that contains an IMPORT chain, a NAMECALL,
        -- a GETGLOBAL, and a few k-string references so the engine has
        -- something to bucket.
        --
        --   pc=1   GETIMPORT R0, K(2)              ; import "game.Players"
        --   pc=2   AUX (encoded id)
        --   pc=3   GETTABLEKS R1, R0, K(3)         ; field "LocalPlayer"
        --   pc=4   AUX (kidx = 3 for "LocalPlayer")
        --   pc=5   NAMECALL R0, R1, K(4)           ; method "WaitForChild"
        --   pc=6   AUX (kidx = 4 for "WaitForChild")
        --   pc=7   GETGLOBAL R2, K(5)              ; global "warn"
        --   pc=8   AUX (kidx = 5 for "warn")
        --   pc=9   LOADK R3, K(3)                  ; k-string "LocalPlayer" again
        --   pc=10  RETURN R0, 1
        --
        -- That gives us:
        --   1 import     → "game.Players"
        --   1 field      → "LocalPlayer"
        --   1 namecall   → "WaitForChild"
        --   1 global     → "warn"
        --   k-string sites: "game", "Players", "LocalPlayer" (3×),
        --                   "WaitForChild", "warn"

        local Op = OpcodeTable.Op
        local function abc(op, a, b, c)
            return bit32.bor(bit32.band(op, 0xFF),
                bit32.lshift(bit32.band(a or 0, 0xFF), 8),
                bit32.lshift(bit32.band(b or 0, 0xFF), 16),
                bit32.lshift(bit32.band(c or 0, 0xFF), 24))
        end
        local function ad(op, a, d)
            return bit32.bor(bit32.band(op, 0xFF),
                bit32.lshift(bit32.band(a or 0, 0xFF), 8),
                bit32.lshift(bit32.band(d or 0, 0xFFFF), 16))
        end

        -- IMPORT chain "game.Players" packed: count=2, parts at k-idx 0 and 1.
        local importEncoded = bit32.bor(
            bit32.lshift(2, 30),      -- count
            bit32.lshift(0, 20),      -- part1 → k[0] = "game"
            bit32.lshift(1, 10),      -- part2 → k[1] = "Players"
            0)

        local constants = {
            { tag = "STRING",  value = "game",          stringId = 1, index = 1 },
            { tag = "STRING",  value = "Players",       stringId = 2, index = 2 },
            { tag = "IMPORT",  encodedId = importEncoded,
                chain = { "game", "Players" },                          index = 3 },
            { tag = "STRING",  value = "LocalPlayer",   stringId = 3, index = 4 },
            { tag = "STRING",  value = "WaitForChild",  stringId = 4, index = 5 },
            { tag = "STRING",  value = "warn",          stringId = 5, index = 6 },
        }

        local insns = {}
        local function push(x) insns[#insns + 1] = x end

        push(ad(Op.GETIMPORT, 0, 2));                push(importEncoded)
        push(abc(Op.GETTABLEKS, 1, 0, 0));           push(3)            -- kidx=3 → "LocalPlayer"
        push(abc(Op.NAMECALL, 0, 1, 0));             push(4)            -- kidx=4 → "WaitForChild"
        push(abc(Op.GETGLOBAL, 2, 0, 0));            push(5)            -- kidx=5 → "warn"
        push(ad(Op.LOADK, 3, 3))                                        -- LOADK R3, K(3)  → "LocalPlayer"
        push(abc(Op.RETURN, 0, 1, 0))

        local proto = {
            id           = 0,
            maxstacksize = 4,
            numparams    = 0,
            nups         = 0,
            isvararg     = false,
            flags        = 0,
            lineDefined  = 0,
            debugName    = "xref_demo",
            sizecode     = #insns,
            instructions = insns,
            constants    = constants,
            childProtoIds = {},
            hasLineInfo  = false,
            lineInfo     = nil,
            hasDebugInfo = false,
            debug        = nil,
        }
        proto.auxAt = {}; proto.opAt = {}
        do
            local pc = 1
            while pc <= proto.sizecode do
                local insn = insns[pc]
                local op = bit32.band(insn, 0xFF)
                proto.opAt[pc] = op
                if OpcodeTable.hasAux(op) then
                    proto.auxAt[pc] = true; pc = pc + 2
                else
                    pc = pc + 1
                end
            end
        end

        local fakeBC = {
            version       = 6,
            typesVersion  = 0,
            stringTable   = { "game", "Players", "LocalPlayer", "WaitForChild", "warn" },
            protos        = { [0] = proto },
            mainProtoId   = 0,
            stats         = { protos = 1, totalInstructions = #insns,
                              totalConstants = #constants,
                              totalStrings = 5 },
        }

        local disasm = Disassembler.new(fakeBC)
        disasm:disassembleProto(0)                                      -- ensure cached
        local index = XRefEngine.build(disasm, fakeBC)

        check("XRef built", index ~= nil)
        check("XRef has >0 sites", index.stats.totalSites > 0, index.stats.totalSites)

        -- Globals: "warn" should appear once with read mode.
        local warnSites = index:sitesForGlobal("warn")
        check("byGlobal['warn'] exists",
            #warnSites == 1, #warnSites)
        check("warn site mode = read",
            warnSites[1] and warnSites[1].mode == "read")

        -- Fields: "LocalPlayer" appears once.
        local fldSites = index:sitesForField("LocalPlayer")
        check("byField['LocalPlayer'] exists",
            #fldSites == 1, #fldSites)

        -- Methods: "WaitForChild" appears once.
        local mthSites = index:sitesForMethod("WaitForChild")
        check("byMethod['WaitForChild'] exists",
            #mthSites == 1, #mthSites)

        -- Import chain.
        local impSites = index:sitesForImport({ "game", "Players" })
        check("byImport['game.Players'] exists",
            #impSites == 1, #impSites)
        local impSitesStr = index:sitesForImport("game.Players")
        check("byImport accepts string key",
            #impSitesStr == 1, #impSitesStr)

        -- Strings: "LocalPlayer" must be hit at least 2× (once from the
        -- GETTABLEKS field ref, once from the LOADK). Same logic for
        -- "WaitForChild" (namecall + nothing else, so 1×). "Players" is
        -- hit by the import part scan.
        local locSites = index:sitesForString("LocalPlayer")
        check("byString['LocalPlayer'] ≥ 2",
            #locSites >= 2, #locSites)
        local playersSites = index:sitesForString("Players")
        check("byString['Players'] ≥ 1",
            #playersSites >= 1, #playersSites)
        local gameSites = index:sitesForString("game")
        check("byString['game'] ≥ 1",
            #gameSites >= 1, #gameSites)
        local warnStringSites = index:sitesForString("warn")
        check("byString['warn'] catches global-name use",
            #warnStringSites >= 1, #warnStringSites)

        -- Stats sanity.
        check("uniqueGlobals = 1",  index.stats.uniqueGlobals == 1, index.stats.uniqueGlobals)
        check("uniqueFields = 1",   index.stats.uniqueFields == 1,  index.stats.uniqueFields)
        check("uniqueMethods = 1",  index.stats.uniqueMethods == 1, index.stats.uniqueMethods)
        check("uniqueImports = 1",  index.stats.uniqueImports == 1, index.stats.uniqueImports)
        check("uniqueStrings ≥ 5",  index.stats.uniqueStrings >= 5, index.stats.uniqueStrings)

        -- sitesInProto returns every site for proto 0.
        local protoSites = index:sitesInProto(0)
        check("sitesInProto matches totalSites",
            #protoSites == index.stats.totalSites,
            #protoSites, index.stats.totalSites)

        -- topStrings is sorted descending by count.
        local top = index:topStrings(5)
        check("topStrings returns rows", #top > 0, #top)
        if #top >= 2 then
            check("topStrings descending",
                top[1].count >= top[2].count,
                top[1].count, top[2].count)
        end

        -- Named protos list picks up "xref_demo".
        local named = index:namedProtos()
        check("namedProtos contains 'xref_demo'",
            (function()
                for _, n in named do
                    if n.debugName == "xref_demo" then return true end
                end
                return false
            end)())
    end

    -- ---------- Decompiler (lift→structure→emit pipeline smoke-test) ----------

    do
        -- Reuse the loop proto from the CFG test pattern:
        --   pc=1   LOADN R0, 0
        --   pc=2   LOADN R1, 10
        --   pc=3   JUMPIFLT R0 < R1 → pc=6
        --   pc=4   AUX = R1
        --   pc=5   RETURN R0, 1
        --   pc=6   LOADN R2, 1
        --   pc=7   ADD R0, R0, R2
        --   pc=8   JUMPBACK → pc=3
        --
        -- Expected decompiled output is roughly:
        --   function loop_proto()
        --       R0 = 0
        --       R1 = 10
        --       while R0 < R1 do
        --           R2 = 1
        --           R0 = R0 + R2
        --       end
        --       return R0
        --   end
        -- (The lifter's first pass uses raw R0/R1/R2 names because there's
        -- no debug info on this synthetic proto; that's expected.)

        local Op = OpcodeTable.Op
        local function abc(op, a, b, c)
            return bit32.bor(bit32.band(op, 0xFF),
                bit32.lshift(bit32.band(a or 0, 0xFF), 8),
                bit32.lshift(bit32.band(b or 0, 0xFF), 16),
                bit32.lshift(bit32.band(c or 0, 0xFF), 24))
        end
        local function ad(op, a, d)
            return bit32.bor(bit32.band(op, 0xFF),
                bit32.lshift(bit32.band(a or 0, 0xFF), 8),
                bit32.lshift(bit32.band(d or 0, 0xFFFF), 16))
        end

        local insns = {}
        local function push(x) insns[#insns + 1] = x end
        push(ad(Op.LOADN, 0, 0))
        push(ad(Op.LOADN, 1, 10))
        push(ad(Op.JUMPIFLT, 0, 1));            push(1)
        push(abc(Op.RETURN, 0, 1, 0))
        push(ad(Op.LOADN, 2, 1))
        push(abc(Op.ADD, 0, 0, 2))
        push(ad(Op.JUMPBACK, 0, bit32.band(-6 % 0x10000, 0xFFFF)))

        local proto = {
            id           = 0,
            maxstacksize = 4,
            numparams    = 0,
            nups         = 0,
            isvararg     = false,
            flags        = 0,
            lineDefined  = 0,
            debugName    = "loop_proto",
            sizecode     = #insns,
            instructions = insns,
            constants    = {},
            childProtoIds = {},
            hasLineInfo  = false,
            lineInfo     = nil,
            hasDebugInfo = false,
            debug        = nil,
        }
        proto.auxAt = {}; proto.opAt = {}
        do
            local pc = 1
            while pc <= proto.sizecode do
                local insn = insns[pc]
                local op = bit32.band(insn, 0xFF)
                proto.opAt[pc] = op
                if OpcodeTable.hasAux(op) then
                    proto.auxAt[pc] = true; pc = pc + 2
                else
                    pc = pc + 1
                end
            end
        end

        local fakeBC = {
            version       = 6,
            typesVersion  = 0,
            stringTable   = {},
            protos        = { [0] = proto },
            mainProtoId   = 0,
            stats         = { protos = 1, totalInstructions = #insns,
                              totalConstants = 0, totalStrings = 0 },
        }
        local disasm = Disassembler.new(fakeBC)
        local cfgb   = CFGBuilder.new(disasm)
        local decomp = Decompiler.new(disasm, cfgb, fakeBC)

        local result = decomp:decompileProto(0)
        check("Decompiler.decompileProto returns", result ~= nil)
        check("decompile has lifted", result and result.lifted)
        check("decompile has structured", result and result.structured)
        check("structured body is block", result and result.structured
            and result.structured.body and result.structured.body.kind == "block")
        check("structured stats.ifCount + while ≥ 1",
            result and (result.structured.stats.ifCount
                + result.structured.stats.whileCount
                + result.structured.stats.forNumCount) >= 1,
            result and result.structured.stats)

        local text = decomp:decompileToText(0)
        check("decompile text non-empty", text and #text > 0)
        check("decompile text contains 'function loop_proto'",
            text and text:find("function loop_proto") ~= nil, text and text:sub(1, 80))
        check("decompile text contains 'return'",
            text and text:find("return") ~= nil)
        check("decompile text contains 'end'",
            text and text:find("end") ~= nil)
    end

    -- ---------- PatternMatcher + Heuristics + Plugins ----------

    do
        -- Reuse the XRef demo proto from earlier in the file: it has a
        -- NAMECALL+CALL pair plus a GETIMPORT — perfect for testing the
        -- method-call pattern and the GetService heuristic.

        local Op = OpcodeTable.Op
        local function abc(op, a, b, c)
            return bit32.bor(bit32.band(op, 0xFF),
                bit32.lshift(bit32.band(a or 0, 0xFF), 8),
                bit32.lshift(bit32.band(b or 0, 0xFF), 16),
                bit32.lshift(bit32.band(c or 0, 0xFF), 24))
        end
        local function ad(op, a, d)
            return bit32.bor(bit32.band(op, 0xFF),
                bit32.lshift(bit32.band(a or 0, 0xFF), 8),
                bit32.lshift(bit32.band(d or 0, 0xFFFF), 16))
        end

        -- 6 instructions: NAMECALL R0, R1, K(0)="WaitForChild"
        --                 AUX = 0
        --                 CALL R0, 2, 1     ; calls R0(R1) → R0
        --                 AUX (unused but encoded)  -- NAMECALL is hasAux, CALL not really
        --                 RETURN R0, 1
        -- Actually CALL doesn't have AUX. NAMECALL has AUX (the K-index).
        -- Layout:
        --   pc=1 NAMECALL    (hasAux)
        --   pc=2 AUX
        --   pc=3 CALL
        --   pc=4 RETURN
        local constants = {
            { tag = "STRING", value = "WaitForChild", stringId = 1, index = 1 },
        }
        local insns = {
            abc(Op.NAMECALL, 0, 1, 0),  0,           -- pc=1, AUX=0 (kidx → "WaitForChild")
            abc(Op.CALL,     0, 2, 1),               -- pc=3 (after AUX skip), calls R0(R1)
            abc(Op.RETURN,   0, 1, 0),               -- pc=4
        }

        local proto = {
            id = 0, maxstacksize = 4, numparams = 0, nups = 0, isvararg = false,
            flags = 0, lineDefined = 0, debugName = "pattern_demo",
            sizecode = #insns,
            instructions = insns,
            constants = constants,
            childProtoIds = {},
            hasLineInfo = false, hasDebugInfo = false,
        }
        proto.auxAt = {}; proto.opAt = {}
        do
            local pc = 1
            while pc <= proto.sizecode do
                local insn = insns[pc]
                local op = bit32.band(insn, 0xFF)
                proto.opAt[pc] = op
                if OpcodeTable.hasAux(op) then proto.auxAt[pc] = true; pc = pc + 2
                else pc = pc + 1 end
            end
        end

        local fakeBC = {
            version = 6, typesVersion = 0,
            stringTable = { "WaitForChild" },
            protos = { [0] = proto },
            mainProtoId = 0,
            stats = { protos = 1, totalInstructions = #insns,
                      totalConstants = 1, totalStrings = 1 },
        }
        local disasm = Disassembler.new(fakeBC)
        disasm:disassembleProto(0)

        -- PatternMatcher with built-in heuristics
        local matcher = PatternMatcher.new()
        check("matcher constructed", matcher ~= nil)
        Heuristics.registerAll(matcher)
        local mstats = matcher:stats()
        check("matcher has > 0 patterns registered", mstats.registered > 0, mstats.registered)

        -- Scan should find the method-call pattern + the WaitForChild heuristic.
        local matches = matcher:scanBytecode(disasm, fakeBC)
        check("scanBytecode returns matches", type(matches) == "table" and #matches > 0,
            #matches)
        -- We expect at least: calls.method-call AND roblox.WaitForChild
        local foundMethodCall = false
        local foundWaitForChild = false
        for _, m in matches do
            if m.patternId == "calls.method-call"   then foundMethodCall   = true end
            if m.patternId == "roblox.WaitForChild" then foundWaitForChild = true end
        end
        check("method-call pattern detected",   foundMethodCall)
        check("WaitForChild heuristic detected", foundWaitForChild)

        -- Group helpers
        local groups = PatternMatcher.groupByPattern(matches)
        check("groupByPattern non-empty", #groups > 0, #groups)

        -- ---------- Plugins ----------

        local plugins = Plugins.new({ matcher = matcher })
        local hooksFired = { init = 0, scan = 0, row = 0 }
        local samplePlugin = {
            id = "self-test.sample",
            name = "Self-Test Sample",
            description = "Counts how many times each hook fires.",
            init = function(self, services)
                self.services = services
                hooksFired.init = hooksFired.init + 1
            end,
            scan = function(self, bytecode)
                hooksFired.scan = hooksFired.scan + 1
            end,
            onRow = function(self, row, proto)
                hooksFired.row = hooksFired.row + 1
                if row.mnemonic == "NAMECALL" then return "self-test annotation" end
                return nil
            end,
            patterns = {
                { id = "always-return",
                  description = "self-test: every RETURN",
                  atoms = { { op = "RETURN", capture = "ret" } } },
            },
        }

        local record, err = plugins:register(samplePlugin)
        check("plugin registered", record ~= nil, err)
        check("plugin init fired",  hooksFired.init == 1, hooksFired.init)

        -- Re-scan with the plugin's pattern registered should now also
        -- match the RETURN instruction.
        local matches2 = matcher:scanBytecode(disasm, fakeBC)
        local foundPluginPattern = false
        for _, m in matches2 do
            if m.patternId == "self-test.sample.always-return" then
                foundPluginPattern = true; break
            end
        end
        check("plugin pattern matched after re-scan", foundPluginPattern)

        -- onBytecodeLoaded fires the scan hook
        plugins:onBytecodeLoaded(fakeBC)
        check("plugin scan hook fired", hooksFired.scan == 1, hooksFired.scan)

        -- annotateRow on a NAMECALL row
        local stream = disasm:disassembleProto(0)
        local ncRow = stream and stream.rowByPc[1]
        if ncRow then
            local ann = plugins:annotateRow(ncRow, proto)
            check("annotateRow returns annotation for NAMECALL",
                ann ~= nil and ann[1] and ann[1].source == "self-test.sample",
                ann and ann[1] and ann[1].source)
        end
        check("plugin row hook fired", hooksFired.row > 0, hooksFired.row)

        -- list / stats
        local pluginList = plugins:list()
        check("plugins:list has the sample", #pluginList >= 1, #pluginList)
        local pluginStats = plugins:stats()
        check("plugins stats", pluginStats.total >= 1 and pluginStats.enabled >= 1,
            pluginStats.total, pluginStats.enabled)

        -- Disable + verify hooks no longer fire
        plugins:setEnabled("self-test.sample", false)
        local prevRow = hooksFired.row
        plugins:annotateRow(ncRow, proto)
        check("disabled plugin doesn't fire onRow",
            hooksFired.row == prevRow, hooksFired.row, prevRow)
        plugins:setEnabled("self-test.sample", true)

        -- Unregister cleanup
        plugins:unregister("self-test.sample")
        local listAfter = plugins:list()
        check("plugin unregistered", #listAfter == 0, #listAfter)
    end

    if logger then logger:info("Analysis self-test: %d pass, %d fail", passes, fails) end
    return passes, fails
end

return Analysis
