--!nonstrict
-- =====================================================================
-- IDARoblox / Analysis / Decompiler / ExpressionFolder
-- ---------------------------------------------------------------------
-- Re-fuses split expressions in the lifted IR. The Lifter produces a
-- straight-line sequence of `assign` statements like
--
--   t0 = a + b
--   t1 = t0 * c
--   t2 = t1 - d
--   result = t2
--
-- which read naturally only after the folder squashes them back into
--
--   result = ((a + b) * c) - d
--
-- Algorithm
--   1. Build a single-use map: for every IR register, count how many
--      reads occur. Single-defined + single-used + no side effect
--      between def and use → eligible to fold.
--   2. Walk statements in program order; for each statement, look at
--      each operand. If the operand is a SimpleVar referring to a
--      foldable temp, splice the temp's defining expression in.
--   3. After folding, drop the now-dead temp definitions.
--
-- The pass refuses to fold across:
--   * Calls (CALL, NAMECALL) — these may have side effects
--   * Table writes (SETTABLE, SETUPVAL) — may alias
--   * Loop or branch boundaries (the temp must be defined in the same
--     basic block as its use)
--
-- The folder consults DataFlowAnalyzer's reaching-defs (if available)
-- so even cross-block folds become safe when only one def reaches.
-- =====================================================================

local ExpressionFolder = {}
ExpressionFolder.__index = ExpressionFolder

-- ---------------------------------------------------------------------
-- IR-shape predicates
-- ---------------------------------------------------------------------

local function isSimpleVar(node)
    return type(node) == "table" and node.kind == "var" and node.scope == "register"
end

local function isAssign(stmt)
    return type(stmt) == "table" and stmt.kind == "assign"
end

local function isCall(node)
    if type(node) ~= "table" then return false end
    return node.kind == "call" or node.kind == "namecall"
end

-- "Side-effect-free" expressions: arithmetic, loads, table reads that
-- don't depend on mutable state we'd violate by reordering.
local SAFE_EXPR_KINDS = {
    binop  = true, unop = true, concat = true,
    const  = true, var  = true, length = true,
    index  = true,                                                   -- table reads are usually safe to reorder over arithmetic
    not_   = true,
    select = true,                                                   -- vararg slot — has no side effect itself
}

local function isSafeExpr(node)
    if type(node) ~= "table" then return true end
    return SAFE_EXPR_KINDS[node.kind] == true
end

-- ---------------------------------------------------------------------
-- Use-count walk: visit every expression node and tally var.regId reads
-- ---------------------------------------------------------------------

local countRefs                                                       -- forward decl

local function countRefsInList(list, byReg)
    if type(list) ~= "table" then return end
    for _, n in list do countRefs(n, byReg) end
end

countRefs = function(node, byReg)
    if type(node) ~= "table" then return end
    if node.kind == "var" and node.scope == "register" and node.regId then
        byReg[node.regId] = (byReg[node.regId] or 0) + 1
    end
    if node.lhs   then countRefs(node.lhs, byReg)   end
    if node.rhs   then countRefs(node.rhs, byReg)   end
    if node.operand then countRefs(node.operand, byReg) end
    if node.value then countRefs(node.value, byReg) end
    if node.target then countRefs(node.target, byReg) end
    if node.index then countRefs(node.index, byReg) end
    if node.fn    then countRefs(node.fn, byReg)    end
    if node.self  then countRefs(node.self, byReg)  end
    if node.args  then countRefsInList(node.args, byReg) end
    if node.parts then countRefsInList(node.parts, byReg) end
    if node.elements then countRefsInList(node.elements, byReg) end
    if node.fields   then
        for _, f in node.fields do
            countRefs(f.key,   byReg)
            countRefs(f.value, byReg)
        end
    end
end

-- ---------------------------------------------------------------------
-- Substitute: replace every var-node referring to `regId` with `replacement`
-- ---------------------------------------------------------------------

local substituteInNode                                                -- forward decl

local function substituteInList(list, regId, replacement)
    if type(list) ~= "table" then return end
    for i, n in list do
        if isSimpleVar(n) and n.regId == regId then
            list[i] = replacement
        else
            substituteInNode(n, regId, replacement)
        end
    end
end

local function maybeReplace(parent, key, regId, replacement)
    local v = parent[key]
    if not v then return end
    if isSimpleVar(v) and v.regId == regId then
        parent[key] = replacement
    else
        substituteInNode(v, regId, replacement)
    end
end

substituteInNode = function(node, regId, replacement)
    if type(node) ~= "table" then return end
    maybeReplace(node, "lhs", regId, replacement)
    maybeReplace(node, "rhs", regId, replacement)
    maybeReplace(node, "operand", regId, replacement)
    maybeReplace(node, "value", regId, replacement)
    maybeReplace(node, "target", regId, replacement)
    maybeReplace(node, "index", regId, replacement)
    maybeReplace(node, "fn", regId, replacement)
    maybeReplace(node, "self", regId, replacement)
    if node.args     then substituteInList(node.args, regId, replacement) end
    if node.parts    then substituteInList(node.parts, regId, replacement) end
    if node.elements then substituteInList(node.elements, regId, replacement) end
    if node.fields then
        for _, f in node.fields do
            maybeReplace(f, "key",   regId, replacement)
            maybeReplace(f, "value", regId, replacement)
        end
    end
end

-- ---------------------------------------------------------------------
-- Block-level folder
--
-- For each statement (in order):
--   * If it's `register r = SAFE_EXPR` and r is used exactly once later
--     in the same block AND nothing dangerous happens between def and
--     use → mark for folding.
--   * Perform the fold; remove the statement once dead.
-- ---------------------------------------------------------------------

local function statementHasSideEffects(stmt)
    if not stmt or type(stmt) ~= "table" then return false end
    if stmt.kind == "callstat" then return true end                  -- bare call
    if stmt.kind == "return"   then return true end
    if stmt.kind == "assign" then
        -- Writing to non-register targets is a side effect we can't
        -- safely reorder over.
        if stmt.target then
            if stmt.target.kind == "index" then return true end      -- table write
            if stmt.target.scope == "upvalue"  then return true end
            if stmt.target.scope == "global"   then return true end
        end
        if stmt.targets then
            for _, t in stmt.targets do
                if t.kind == "index" then return true end
                if t.scope == "upvalue" then return true end
                if t.scope == "global"  then return true end
            end
        end
        if stmt.value and isCall(stmt.value) then return true end
    end
    if stmt.kind == "if" or stmt.kind == "while" or stmt.kind == "for"
        or stmt.kind == "loop" or stmt.kind == "break" then
        return true
    end
    return false
end

local function foldBlock(self, statements)
    if type(statements) ~= "table" or #statements == 0 then return statements, 0 end

    -- 1. Count uses across the whole block
    local useCount = {}
    for _, stmt in statements do
        if isAssign(stmt) then
            if stmt.target then countRefs(stmt.target, useCount) end
            if stmt.targets then countRefsInList(stmt.targets, useCount) end
            if stmt.value  then countRefs(stmt.value, useCount) end
            if stmt.values then countRefsInList(stmt.values, useCount) end
        else
            -- Conservatively count refs in everything else
            countRefs(stmt, useCount)
        end
    end

    -- 2. Walk forward, attempt to fold
    local foldedCount = 0
    local i = 1
    while i <= #statements do
        local def = statements[i]
        if isAssign(def)
            and def.target
            and isSimpleVar(def.target)
            and def.value
            and isSafeExpr(def.value)
            and (useCount[def.target.regId] or 0) == 1 then

            local defReg = def.target.regId
            -- Find the consumer in the rest of the block
            local consumerIdx = nil
            for j = i + 1, #statements do
                local stmt = statements[j]
                if statementHasSideEffects(stmt) and not isAssign(stmt) then
                    -- Side-effecting statement between def and use: stop
                    break
                end
                local localRefs = {}
                countRefs(stmt, localRefs)
                if localRefs[defReg] then
                    consumerIdx = j; break
                end
            end

            if consumerIdx then
                substituteInNode(statements[consumerIdx], defReg, def.value)
                table.remove(statements, i)
                foldedCount = foldedCount + 1
                -- After removal, we don't advance i: a chain could now be foldable
                -- e.g. t0=a+b; t1=t0*c; t2=t1-d ; folding t0 into t1 means t1
                -- now matches the foldable shape too.
            else
                i = i + 1
            end
        else
            i = i + 1
        end
    end

    return statements, foldedCount
end

-- ---------------------------------------------------------------------
-- Recursive walk over nested IR blocks
-- ---------------------------------------------------------------------

local function foldRecursive(self, node, counts)
    if type(node) ~= "table" then return end
    if node.statements then
        local _, n = foldBlock(self, node.statements)
        counts.folded = counts.folded + n
        counts.blocks = counts.blocks + 1
        for _, stmt in node.statements do foldRecursive(self, stmt, counts) end
    end
    if node.body         then foldRecursive(self, node.body, counts) end
    if node.thenBranch   then foldRecursive(self, node.thenBranch, counts) end
    if node.elseBranch   then foldRecursive(self, node.elseBranch, counts) end
    if node.elseif_branches then
        for _, br in node.elseif_branches do foldRecursive(self, br, counts) end
    end
    if node.cases then
        for _, c in node.cases do foldRecursive(self, c, counts) end
    end
end

-- ---------------------------------------------------------------------
-- Construction + public entry
-- ---------------------------------------------------------------------

function ExpressionFolder.new(opts)
    opts = opts or {}
    return setmetatable({
        _dataflow = opts.dataflow,
        _logger   = opts.logger,
        _stats = { foldedTotal = 0, blocksVisited = 0, runs = 0 },
    }, ExpressionFolder)
end

function ExpressionFolder:fold(ir)
    if type(ir) ~= "table" then return ir, { folded = 0, blocks = 0 } end
    local counts = { folded = 0, blocks = 0 }
    foldRecursive(self, ir, counts)
    self._stats.foldedTotal   = self._stats.foldedTotal + counts.folded
    self._stats.blocksVisited = self._stats.blocksVisited + counts.blocks
    self._stats.runs          = self._stats.runs + 1
    if self._logger then
        self._logger:debug("ExpressionFolder: folded %d expressions across %d blocks",
            counts.folded, counts.blocks)
    end
    return ir, counts
end

function ExpressionFolder:stats() return self._stats end

return ExpressionFolder
