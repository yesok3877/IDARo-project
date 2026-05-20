--!nonstrict
-- =====================================================================
-- IDARoblox / Analysis / PatternMatcher
-- ---------------------------------------------------------------------
-- Sequence-pattern matcher over disassembly rows.
--
-- A pattern is a description of N consecutive instructions to look for.
-- Each instruction is described by an *atom* — a small predicate that
-- says "this slot must match my conditions".
--
-- Atom shape:
--   {
--     op         = "NAMECALL"     -- exact mnemonic
--                | { "A", "B" }   -- alternation
--                | "*"            -- wildcard
--                | "JUMP*"        -- prefix-glob (matches every JUMP*)
--     capture    = "name"          -- optional; bind this slot's row
--     constraint = function(captures, rows, ctx) -> bool  -- optional
--   }
--
-- A pattern:
--   {
--     id          = "namecall-call",
--     description = "method call (NAMECALL + CALL)",
--     atoms       = { atom, atom, … },
--     onMatch     = function(match, ctx) -> any   -- optional post-processing
--   }
--
-- Matching walks each PC, attempts every registered pattern starting at
-- that PC. A pattern match advances PC by each row's natural width
-- (1 or 2 for AUX-bearing ops). Inter-atom constraints fire only after
-- every atom slot has matched a row.
--
-- Result shape (the matcher returns these):
--   {
--     pattern   = <pattern>,
--     patternId = string,
--     protoId   = number,
--     startPc   = N,
--     endPc     = N,                    -- inclusive
--     rows      = { row, row, … },
--     captures  = { ["name"] = { row, pc } },
--   }
-- =====================================================================

local PatternMatcher = {}
PatternMatcher.__index = PatternMatcher

-- ---------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------

function PatternMatcher.new(opts)
    opts = opts or {}
    return setmetatable({
        _patterns = {},                                              -- id → pattern
        _enabled  = {},                                              -- id → bool
        _logger   = opts.logger,
        _stats    = {
            registered    = 0,
            patternsMatched = 0,
            scansRun        = 0,
            lastScanMs      = 0,
        },
    }, PatternMatcher)
end

-- ---------------------------------------------------------------------
-- Registration
-- ---------------------------------------------------------------------

function PatternMatcher:register(pattern)
    if type(pattern) ~= "table" or not pattern.id or not pattern.atoms then
        error("PatternMatcher.register: pattern must have id and atoms", 2)
    end
    if self._patterns[pattern.id] then
        if self._logger then
            self._logger:warn("PatternMatcher: pattern '%s' re-registered", pattern.id)
        end
    end
    self._patterns[pattern.id] = pattern
    if self._enabled[pattern.id] == nil then self._enabled[pattern.id] = true end
    self._stats.registered = self._stats.registered + 1
    return pattern
end

function PatternMatcher:registerMany(patterns)
    for _, p in patterns do self:register(p) end
end

function PatternMatcher:unregister(id)
    self._patterns[id] = nil
    self._enabled[id]  = nil
end

function PatternMatcher:setEnabled(id, enabled)
    if self._patterns[id] then self._enabled[id] = enabled and true or false end
end

function PatternMatcher:isEnabled(id)
    return self._patterns[id] ~= nil and self._enabled[id] ~= false
end

function PatternMatcher:listPatterns()
    local out = {}
    for id, p in self._patterns do
        out[#out + 1] = {
            id          = id,
            description = p.description or "",
            atomCount   = p.atoms and #p.atoms or 0,
            enabled     = self._enabled[id] ~= false,
        }
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

-- ---------------------------------------------------------------------
-- Atom evaluation
-- ---------------------------------------------------------------------

local function atomMatches(atom, row)
    if not row or not row.mnemonic then return false end
    local op = atom.op
    if op == "*" or op == nil then return true end
    if type(op) == "string" then
        if op == row.mnemonic then return true end
        -- Prefix-glob: "JUMP*" matches every mnemonic starting with "JUMP"
        if string.sub(op, -1) == "*" then
            local prefix = string.sub(op, 1, -2)
            return string.sub(row.mnemonic, 1, #prefix) == prefix
        end
        return false
    end
    if type(op) == "table" then
        for _, alt in op do
            if alt == "*" then return true end
            if alt == row.mnemonic then return true end
            if type(alt) == "string" and string.sub(alt, -1) == "*"
                and string.sub(row.mnemonic, 1, #alt - 1) == string.sub(alt, 1, -2) then
                return true
            end
        end
    end
    return false
end

-- ---------------------------------------------------------------------
-- Match attempt at a specific PC
-- ---------------------------------------------------------------------

local function tryMatch(stream, startPc, pattern, ctx)
    local pc = startPc
    local captures = {}
    local rows = {}
    for i, atom in pattern.atoms do
        local row = stream.rowByPc[pc]
        if not atomMatches(atom, row) then return nil end
        if atom.capture then
            captures[atom.capture] = { row = row, pc = pc }
        end
        rows[i] = row
        pc = pc + (row.hasAux and 2 or 1)
    end
    -- Inter-atom constraints get the whole captures map.
    for _, atom in pattern.atoms do
        if atom.constraint then
            local ok, result = pcall(atom.constraint, captures, rows, ctx)
            if not ok or result == false then return nil end
        end
    end
    return {
        pattern   = pattern,
        patternId = pattern.id,
        startPc   = startPc,
        endPc     = pc - 1,
        rows      = rows,
        captures  = captures,
    }
end

-- ---------------------------------------------------------------------
-- Per-proto match
-- ---------------------------------------------------------------------

function PatternMatcher:matchProto(stream, protoId, bytecode)
    if not stream or not stream.rows then return {} end
    local ctx = {
        stream    = stream,
        proto     = stream.proto,
        protoId   = protoId,
        bytecode  = bytecode,
    }
    local matches = {}
    for _, row in stream.rows do
        for id, pattern in self._patterns do
            if self._enabled[id] ~= false then
                local result = tryMatch(stream, row.pc, pattern, ctx)
                if result then
                    result.protoId = protoId
                    if pattern.onMatch then
                        local ok = pcall(pattern.onMatch, result, ctx)
                        if not ok and self._logger then
                            self._logger:warn(
                                "PatternMatcher: onMatch failed for pattern '%s'", id)
                        end
                    end
                    matches[#matches + 1] = result
                    self._stats.patternsMatched = self._stats.patternsMatched + 1
                end
            end
        end
    end
    return matches
end

-- ---------------------------------------------------------------------
-- Whole-bytecode scan
-- ---------------------------------------------------------------------

function PatternMatcher:scanBytecode(disassembler, bytecode, opts)
    opts = opts or {}
    if not disassembler or not bytecode then return {} end
    local allMatches = {}
    local protoCount = 0
    for _ in bytecode.protos do protoCount = protoCount + 1 end
    local done = 0
    local startedAt = os.clock()
    for protoId in bytecode.protos do
        local stream = disassembler:disassembleProto(protoId)
        if stream then
            local matches = self:matchProto(stream, protoId, bytecode)
            for _, m in matches do allMatches[#allMatches + 1] = m end
        end
        done = done + 1
        if opts.progressCb then
            pcall(opts.progressCb, done, protoCount)
        end
        -- Optional yielding for very large scripts
        if opts.yieldEvery and done % opts.yieldEvery == 0 then
            task.wait()
        end
    end
    self._stats.scansRun  = self._stats.scansRun + 1
    self._stats.lastScanMs = (os.clock() - startedAt) * 1000
    if self._logger then
        self._logger:info(
            "PatternMatcher: scan complete — %d matches across %d protos in %.0f ms",
            #allMatches, protoCount, self._stats.lastScanMs)
    end
    return allMatches
end

-- ---------------------------------------------------------------------
-- Result grouping helpers (used by PatternsView)
-- ---------------------------------------------------------------------

function PatternMatcher.groupByPattern(matches)
    local groups = {}
    for _, m in matches do
        local g = groups[m.patternId]
        if not g then
            g = { patternId = m.patternId, pattern = m.pattern, matches = {} }
            groups[m.patternId] = g
        end
        g.matches[#g.matches + 1] = m
    end
    local out = {}
    for _, g in groups do out[#out + 1] = g end
    table.sort(out, function(a, b)
        if #a.matches == #b.matches then return a.patternId < b.patternId end
        return #a.matches > #b.matches
    end)
    return out
end

function PatternMatcher.groupByProto(matches)
    local groups = {}
    for _, m in matches do
        local g = groups[m.protoId]
        if not g then g = { protoId = m.protoId, matches = {} }; groups[m.protoId] = g end
        g.matches[#g.matches + 1] = m
    end
    return groups
end

-- ---------------------------------------------------------------------
-- Stats / manifest
-- ---------------------------------------------------------------------

function PatternMatcher:stats()
    local enabled = 0
    for id in self._patterns do if self._enabled[id] ~= false then enabled = enabled + 1 end end
    return {
        registered      = self._stats.registered,
        enabled         = enabled,
        patternsMatched = self._stats.patternsMatched,
        scansRun        = self._stats.scansRun,
        lastScanMs      = self._stats.lastScanMs,
    }
end

function PatternMatcher.manifest()
    return {
        id           = "Analysis.PatternMatcher",
        dependencies = { "Analysis.Disassembler" },
        weight       = 0.4,
        serviceName  = "PatternMatcher",
        stages = {
            { id = "register", weight = 1.0, fn = function(ctx)
                ctx:report(1, "PatternMatcher ready")
            end },
        },
    }
end

return PatternMatcher
