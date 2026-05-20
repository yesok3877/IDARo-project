--!nonstrict
-- =====================================================================
-- IDARoblox / Search / SearchEngine
-- ---------------------------------------------------------------------
-- Unified query over every searchable surface in a project:
--
--   * protos       — symbols of kind "proto" (debug names, user renames)
--   * symbols      — all SymbolTable entries regardless of kind
--   * strings      — bytecode string table entries
--   * mnemonics    — disassembly opcodes ("CALL", "GETIMPORT", …)
--   * operands     — operand text from disassembled instructions
--   * comments     — CommentStore text
--   * bookmarks    — BookmarkStore labels
--   * imports      — resolved GETIMPORT chains
--
-- Three match modes:
--   PLAIN   — case-insensitive substring (fastest)
--   REGEX   — Lua pattern via RegexCache
--   FUZZY   — scored fuzzy match via FuzzyMatcher (best for incremental)
--
-- Results are SearchHit records:
--   { source, text, kind, score, positions, address = {protoId, pc},
--     payload (source-specific extra), ref (symbol id / comment id / etc.) }
--
-- The engine is *pull*-based: each query iterates sources lazily and
-- caps at opts.limit. Sources can be disabled via opts.sources.
-- =====================================================================

local RegexCache   = _G.IDARo.require("Search.RegexCache")
local FuzzyMatcher = _G.IDARo.require("Search.FuzzyMatcher")

local SearchEngine = {}
SearchEngine.__index = SearchEngine

SearchEngine.Mode = table.freeze({
    PLAIN = "plain",
    REGEX = "regex",
    FUZZY = "fuzzy",
})

SearchEngine.Source = table.freeze({
    PROTOS    = "protos",
    SYMBOLS   = "symbols",
    STRINGS   = "strings",
    MNEMONICS = "mnemonics",
    OPERANDS  = "operands",
    COMMENTS  = "comments",
    BOOKMARKS = "bookmarks",
    IMPORTS   = "imports",
})

-- All sources, in deterministic display order
local ALL_SOURCES = {
    SearchEngine.Source.PROTOS,
    SearchEngine.Source.SYMBOLS,
    SearchEngine.Source.STRINGS,
    SearchEngine.Source.MNEMONICS,
    SearchEngine.Source.OPERANDS,
    SearchEngine.Source.COMMENTS,
    SearchEngine.Source.BOOKMARKS,
    SearchEngine.Source.IMPORTS,
}

-- ---------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------

function SearchEngine.new(opts)
    opts = opts or {}
    return setmetatable({
        _projectDB    = opts.projectDB,                              -- Database.ProjectDB
        _disassembler = opts.disassembler,
        _xrefIndex    = opts.xrefIndex,
        _bytecode     = opts.bytecode,
        _regexCache   = opts.regexCache or RegexCache.new({}),
        _logger       = opts.logger,
        _stats = {
            queries        = 0,
            totalCandidates = 0,
            totalHits      = 0,
        },
    }, SearchEngine)
end

-- The wiring around the engine may change as bytecode reloads; allow
-- the workspace to re-point sources without reconstructing.
function SearchEngine:setBytecode(bytecode)    self._bytecode    = bytecode end
function SearchEngine:setDisassembler(d)       self._disassembler = d end
function SearchEngine:setXRefIndex(x)          self._xrefIndex   = x end
function SearchEngine:setProjectDB(db)         self._projectDB   = db end

-- ---------------------------------------------------------------------
-- Matcher
-- ---------------------------------------------------------------------

-- Returns (matched, score, positions). For PLAIN/REGEX, the score is a
-- coarse rank (-position, so earlier matches rank higher); for FUZZY it
-- comes from FuzzyMatcher.
function SearchEngine:_buildMatcher(query, opts)
    if query == nil or query == "" then return nil end
    local mode = opts.mode or SearchEngine.Mode.PLAIN
    if mode == SearchEngine.Mode.PLAIN then
        local needle = string.lower(query)
        return function(text)
            if type(text) ~= "string" or text == "" then return false end
            local s = string.find(string.lower(text), needle, 1, true)
            if not s then return false end
            -- Position-based score: earlier wins.
            -- Build positions for highlighting
            local positions = table.create(#query)
            for i = 1, #query do positions[i] = s + i - 1 end
            return true, -s, positions
        end
    elseif mode == SearchEngine.Mode.REGEX then
        local cache = self._regexCache
        return function(text)
            if type(text) ~= "string" or text == "" then return false end
            local s, e = cache:find(text, query, 1, { caseInsensitive = opts.caseInsensitive ~= false })
            if not s then return false end
            local positions = table.create(e - s + 1)
            for i = s, e do positions[#positions + 1] = i end
            return true, -s, positions
        end
    elseif mode == SearchEngine.Mode.FUZZY then
        return function(text)
            if type(text) ~= "string" or text == "" then return false end
            local r = FuzzyMatcher.match(query, text)
            if not r.matched then return false end
            return true, r.score, r.positions
        end
    end
    error("SearchEngine: unknown mode " .. tostring(mode), 2)
end

-- ---------------------------------------------------------------------
-- Source iterators
--
-- Each returns a coroutine-like iterator producing SearchHit candidates
-- as { text, kind, address, payload, ref }. The engine itself runs the
-- matcher over text and assembles final hits.
-- ---------------------------------------------------------------------

local function emitHit(out, hit, score, positions, limit)
    hit.score     = score
    hit.positions = positions
    out[#out + 1] = hit
    if limit and #out >= limit then return true end
    return false
end

function SearchEngine:_searchProtos(matcher, out, limit)
    if not self._projectDB then return end
    local SymbolTableMod = self._projectDB:symbols()
    local protos = SymbolTableMod:allOfKind("proto")
    for _, sym in protos do
        local ok, score, positions = matcher(sym.name or "")
        if ok then
            local hit = {
                source  = SearchEngine.Source.PROTOS,
                text    = sym.name or "",
                kind    = sym.kind,
                address = { protoId = tonumber(sym.key), pc = nil },
                payload = sym,
                ref     = sym.id,
            }
            if emitHit(out, hit, score, positions, limit) then return end
        end
    end
end

function SearchEngine:_searchSymbols(matcher, out, limit)
    if not self._projectDB then return end
    local symbols = self._projectDB:symbols():all()
    for _, sym in symbols do
        if sym.name and sym.name ~= "" then
            local ok, score, positions = matcher(sym.name)
            if ok then
                local addr = nil
                if sym.kind == "proto" then
                    addr = { protoId = tonumber(sym.key) }
                elseif sym.kind == "register" then
                    -- key like "protoId:pc:reg"
                    local p, c = string.match(sym.key, "^(%d+):(%d+):")
                    if p and c then addr = { protoId = tonumber(p), pc = tonumber(c) } end
                end
                local hit = {
                    source  = SearchEngine.Source.SYMBOLS,
                    text    = sym.name,
                    kind    = sym.kind,
                    address = addr,
                    payload = sym,
                    ref     = sym.id,
                }
                if emitHit(out, hit, score, positions, limit) then return end
            end
        end
    end
end

function SearchEngine:_searchStrings(matcher, out, limit)
    if not self._bytecode or not self._bytecode.stringTable then return end
    for id, s in self._bytecode.stringTable do
        if type(s) == "string" and s ~= "" then
            local ok, score, positions = matcher(s)
            if ok then
                local hit = {
                    source  = SearchEngine.Source.STRINGS,
                    text    = s,
                    kind    = "string",
                    address = nil,
                    payload = { stringId = id, value = s },
                    ref     = id,
                }
                if emitHit(out, hit, score, positions, limit) then return end
            end
        end
    end
end

function SearchEngine:_searchMnemonics(matcher, out, limit)
    if not self._disassembler or not self._bytecode then return end
    for protoId, _ in self._bytecode.protos do
        local ok2, stream = pcall(function()
            return self._disassembler:disassembleProto(protoId)
        end)
        if ok2 and stream and stream.instructions then
            for i, insn in stream.instructions do
                local mnem = insn.mnemonic or ""
                local m, score, positions = matcher(mnem)
                if m then
                    local hit = {
                        source  = SearchEngine.Source.MNEMONICS,
                        text    = mnem,
                        kind    = "instruction",
                        address = { protoId = protoId, pc = insn.pc or i },
                        payload = insn,
                        ref     = nil,
                    }
                    if emitHit(out, hit, score, positions, limit) then return end
                end
            end
        end
    end
end

function SearchEngine:_searchOperands(matcher, out, limit)
    if not self._disassembler or not self._bytecode then return end
    for protoId, _ in self._bytecode.protos do
        local ok2, stream = pcall(function()
            return self._disassembler:disassembleProto(protoId)
        end)
        if ok2 and stream and stream.instructions then
            for i, insn in stream.instructions do
                local optext = insn.operandText or insn.operands or ""
                if type(optext) == "table" then optext = table.concat(optext, ", ") end
                if type(optext) == "string" and optext ~= "" then
                    local m, score, positions = matcher(optext)
                    if m then
                        local hit = {
                            source  = SearchEngine.Source.OPERANDS,
                            text    = optext,
                            kind    = "operand",
                            address = { protoId = protoId, pc = insn.pc or i },
                            payload = insn,
                            ref     = nil,
                        }
                        if emitHit(out, hit, score, positions, limit) then return end
                    end
                end
            end
        end
    end
end

function SearchEngine:_searchComments(matcher, out, limit)
    if not self._projectDB then return end
    local comments = self._projectDB:comments():all()
    for _, c in comments do
        local ok, score, positions = matcher(c.text or "")
        if ok then
            local hit = {
                source  = SearchEngine.Source.COMMENTS,
                text    = c.text,
                kind    = c.kind,
                address = { protoId = c.protoId, pc = c.pc },
                payload = c,
                ref     = c.id,
            }
            if emitHit(out, hit, score, positions, limit) then return end
        end
    end
end

function SearchEngine:_searchBookmarks(matcher, out, limit)
    if not self._projectDB then return end
    local bookmarks = self._projectDB:bookmarks():all()
    for _, bm in bookmarks do
        local ok, score, positions = matcher(bm.label or "")
        if ok then
            local hit = {
                source  = SearchEngine.Source.BOOKMARKS,
                text    = bm.label,
                kind    = "bookmark",
                address = { protoId = bm.protoId, pc = bm.pc },
                payload = bm,
                ref     = bm.id,
            }
            if emitHit(out, hit, score, positions, limit) then return end
        end
    end
end

function SearchEngine:_searchImports(matcher, out, limit)
    -- Imports come from the disassembler's resolved GETIMPORT chains.
    if not self._disassembler or not self._bytecode then return end
    for protoId, _ in self._bytecode.protos do
        local ok2, stream = pcall(function()
            return self._disassembler:disassembleProto(protoId)
        end)
        if ok2 and stream and stream.imports then
            for _, imp in stream.imports do
                local label = imp.label or imp.path or tostring(imp)
                if type(label) == "string" and label ~= "" then
                    local m, score, positions = matcher(label)
                    if m then
                        local hit = {
                            source  = SearchEngine.Source.IMPORTS,
                            text    = label,
                            kind    = "import",
                            address = { protoId = protoId, pc = imp.pc },
                            payload = imp,
                            ref     = nil,
                        }
                        if emitHit(out, hit, score, positions, limit) then return end
                    end
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------
-- Public query
-- ---------------------------------------------------------------------

function SearchEngine:query(text, opts)
    opts = opts or {}
    self._stats.queries = self._stats.queries + 1
    if text == nil or text == "" then return {} end
    local matcher = self:_buildMatcher(text, opts)
    if not matcher then return {} end

    local limit = opts.limit or 500
    local out = {}

    local sources = opts.sources or ALL_SOURCES
    local enabled = {}
    for _, s in sources do enabled[s] = true end

    if enabled[SearchEngine.Source.PROTOS]    then self:_searchProtos(matcher, out, limit)    end
    if #out >= limit then return self:_finalize(out, opts) end
    if enabled[SearchEngine.Source.SYMBOLS]   then self:_searchSymbols(matcher, out, limit)   end
    if #out >= limit then return self:_finalize(out, opts) end
    if enabled[SearchEngine.Source.STRINGS]   then self:_searchStrings(matcher, out, limit)   end
    if #out >= limit then return self:_finalize(out, opts) end
    if enabled[SearchEngine.Source.MNEMONICS] then self:_searchMnemonics(matcher, out, limit) end
    if #out >= limit then return self:_finalize(out, opts) end
    if enabled[SearchEngine.Source.OPERANDS]  then self:_searchOperands(matcher, out, limit)  end
    if #out >= limit then return self:_finalize(out, opts) end
    if enabled[SearchEngine.Source.COMMENTS]  then self:_searchComments(matcher, out, limit)  end
    if #out >= limit then return self:_finalize(out, opts) end
    if enabled[SearchEngine.Source.BOOKMARKS] then self:_searchBookmarks(matcher, out, limit) end
    if #out >= limit then return self:_finalize(out, opts) end
    if enabled[SearchEngine.Source.IMPORTS]   then self:_searchImports(matcher, out, limit)   end

    return self:_finalize(out, opts)
end

function SearchEngine:_finalize(out, opts)
    self._stats.totalHits = self._stats.totalHits + #out
    -- Sort by score descending (already mostly stable since iteration order is fixed)
    table.sort(out, function(a, b)
        if a.score == b.score then
            -- Tiebreak: shorter text first
            return #(a.text or "") < #(b.text or "")
        end
        return (a.score or -math.huge) > (b.score or -math.huge)
    end)
    return out
end

-- ---------------------------------------------------------------------
-- Group results by source (for tabbed display)
-- ---------------------------------------------------------------------

function SearchEngine.groupBySource(hits)
    local groups = {}
    for _, hit in hits do
        local src = hit.source or "unknown"
        local g = groups[src]
        if not g then g = {}; groups[src] = g end
        g[#g + 1] = hit
    end
    return groups
end

-- ---------------------------------------------------------------------
-- Diagnostics
-- ---------------------------------------------------------------------

function SearchEngine:stats()
    return {
        queries          = self._stats.queries,
        totalCandidates  = self._stats.totalCandidates,
        totalHits        = self._stats.totalHits,
        regexCacheStats  = self._regexCache:stats(),
    }
end

function SearchEngine:clearCaches()
    self._regexCache:clear()
end

return SearchEngine
