--!nonstrict
-- =====================================================================
-- IDARoblox / Search / FuzzyMatcher
-- ---------------------------------------------------------------------
-- Subsequence + scored fuzzy matching, in the style of Sublime / VSCode
-- "command palette" and IDA's "Quick rename" jumper. Given a query, ranks
-- candidates by:
--
--   * Consecutive match bonus       (the chunkier the match, the better)
--   * Word-boundary bonus           ("getP" → "getPlayer" beats "getplayer")
--   * camelCase / underscore bonus  (matching capital after lower or '_')
--   * Case-match bonus              (exact case > case-folded)
--   * Leading-match bonus           (query starts at offset 1)
--   * Distance penalty              (gaps between matches cost points)
--
-- Returns matchPositions so the UI can highlight matched characters in
-- the candidate. Fast bailout: if the entire query isn't a subsequence
-- of the candidate, the match is rejected before scoring.
-- =====================================================================

local FuzzyMatcher = {}

local BONUS_CONSECUTIVE      = 15
local BONUS_WORD_BOUNDARY    = 25
local BONUS_CAMEL            = 15
local BONUS_LEADING          = 25
local BONUS_EXACT_CASE       = 4
local PENALTY_GAP_FIRST      = 5
local PENALTY_GAP_EXTEND     = 2
local PENALTY_UNMATCHED_TAIL = 1

-- ---------------------------------------------------------------------
-- Character classification helpers
-- ---------------------------------------------------------------------

local function isUpper(c)
    if not c then return false end
    local b = string.byte(c)
    return b >= 65 and b <= 90
end

local function isLower(c)
    if not c then return false end
    local b = string.byte(c)
    return b >= 97 and b <= 122
end

local function isAlpha(c)
    return isUpper(c) or isLower(c)
end

local function isDigit(c)
    if not c then return false end
    local b = string.byte(c)
    return b >= 48 and b <= 57
end

local function isSeparator(c)
    return c == "_" or c == " " or c == "." or c == "/" or c == "-"
        or c == ":" or c == "\t"
end

local function isWordBoundary(prev, cur)
    if prev == nil then return true end
    if isSeparator(prev) then return true end
    if isLower(prev) and isUpper(cur) then return true end           -- camelCase
    if not isAlpha(prev) and isAlpha(cur) then return true end
    if not isDigit(prev) and isDigit(cur) then return true end
    return false
end

local function lower(c)
    if not c then return c end
    if isUpper(c) then return string.char(string.byte(c) + 32) end
    return c
end

-- ---------------------------------------------------------------------
-- Subsequence test (fast bailout before scoring)
-- ---------------------------------------------------------------------

local function isSubsequence(query, candidate)
    local qLen, cLen = #query, #candidate
    if qLen == 0 then return true end
    if qLen > cLen then return false end
    local qi, ci = 1, 1
    while qi <= qLen and ci <= cLen do
        if lower(string.sub(query, qi, qi)) == lower(string.sub(candidate, ci, ci)) then
            qi = qi + 1
        end
        ci = ci + 1
    end
    return qi > qLen
end

FuzzyMatcher.isSubsequence = isSubsequence

-- ---------------------------------------------------------------------
-- Greedy scorer with position recording
--
-- For each query character we pick the earliest candidate position that
-- (a) matches case-insensitively and (b) maximizes the running score.
-- We test up to a small look-ahead window so a slightly-later position
-- with a much stronger bonus wins over a closer weak position.
-- ---------------------------------------------------------------------

local LOOKAHEAD = 4                                                  -- characters

local function scoreAtPosition(prev, candChar, queryChar, lastMatched)
    local s = 0
    if lower(candChar) ~= lower(queryChar) then return -math.huge end
    if isWordBoundary(prev, candChar)         then s = s + BONUS_WORD_BOUNDARY end
    if isLower(prev) and isUpper(candChar)    then s = s + BONUS_CAMEL end
    if candChar == queryChar                  then s = s + BONUS_EXACT_CASE end
    if lastMatched and lastMatched + 1 == "consecutive" then        -- caller signals
        s = s + BONUS_CONSECUTIVE
    end
    return s
end

function FuzzyMatcher.match(query, candidate, opts)
    if query == nil or query == "" then
        return { score = 0, positions = {}, matched = true }
    end
    if candidate == nil or candidate == "" then
        return { score = -math.huge, positions = {}, matched = false }
    end
    if not isSubsequence(query, candidate) then
        return { score = -math.huge, positions = {}, matched = false }
    end

    opts = opts or {}
    local qLen = #query
    local cLen = #candidate
    local positions = table.create(qLen)
    local totalScore = 0
    local prevMatchedAt = nil                                        -- candidate index
    local cursor = 1
    local prevChar = nil

    for qi = 1, qLen do
        local qc = string.sub(query, qi, qi)
        -- Pick best position within a lookahead window starting from cursor.
        local bestPos = nil
        local bestScore = -math.huge
        local windowEnd = math.min(cLen, cursor + LOOKAHEAD)
        for ci = cursor, windowEnd do
            local cc = string.sub(candidate, ci, ci)
            if lower(cc) == lower(qc) then
                local prevC = ci > 1 and string.sub(candidate, ci - 1, ci - 1) or nil
                local s = 0
                if isWordBoundary(prevC, cc)        then s = s + BONUS_WORD_BOUNDARY end
                if isLower(prevC) and isUpper(cc)   then s = s + BONUS_CAMEL end
                if cc == qc                         then s = s + BONUS_EXACT_CASE end
                if prevMatchedAt and ci == prevMatchedAt + 1 then
                    s = s + BONUS_CONSECUTIVE
                end
                -- Leading-match bonus only for the first query char
                if qi == 1 and ci == 1 then s = s + BONUS_LEADING end
                -- Penalty for gap from cursor (only first hop has the larger penalty)
                local gap = ci - cursor
                if gap > 0 then s = s - PENALTY_GAP_FIRST - (gap - 1) * PENALTY_GAP_EXTEND end
                if s > bestScore then
                    bestScore = s
                    bestPos = ci
                end
            end
        end
        if not bestPos then
            -- No match in the lookahead window. Fall back to a linear scan
            -- past the window (still need to match because subsequence).
            for ci = windowEnd + 1, cLen do
                local cc = string.sub(candidate, ci, ci)
                if lower(cc) == lower(qc) then
                    local prevC = ci > 1 and string.sub(candidate, ci - 1, ci - 1) or nil
                    local s = 0
                    if isWordBoundary(prevC, cc)        then s = s + BONUS_WORD_BOUNDARY end
                    if isLower(prevC) and isUpper(cc)   then s = s + BONUS_CAMEL end
                    if cc == qc                         then s = s + BONUS_EXACT_CASE end
                    local gap = ci - cursor
                    s = s - PENALTY_GAP_FIRST - (gap - 1) * PENALTY_GAP_EXTEND
                    bestPos = ci
                    bestScore = s
                    break
                end
            end
        end
        if not bestPos then
            -- Should not happen (subsequence guaranteed) — bail.
            return { score = -math.huge, positions = {}, matched = false }
        end
        positions[qi] = bestPos
        totalScore = totalScore + bestScore
        prevMatchedAt = bestPos
        cursor = bestPos + 1
        prevChar = string.sub(candidate, bestPos, bestPos)
    end

    -- Trailing characters cost something but not a lot — encourages short
    -- candidates over long ones when the score is otherwise tied.
    local tailLen = cLen - (positions[qLen] or 0)
    if tailLen > 0 then
        totalScore = totalScore - tailLen * PENALTY_UNMATCHED_TAIL
    end

    return { score = totalScore, positions = positions, matched = true }
end

-- ---------------------------------------------------------------------
-- Match many — returns sorted result list
-- ---------------------------------------------------------------------

function FuzzyMatcher.matchAll(query, candidates, opts)
    opts = opts or {}
    local keyFn = opts.key                                           -- (candidate) → string
    local limit = opts.limit
    local minScore = opts.minScore or -math.huge
    local out = {}
    for i, cand in ipairs(candidates) do
        local hay = keyFn and keyFn(cand) or cand
        if type(hay) == "string" then
            local r = FuzzyMatcher.match(query, hay, opts)
            if r.matched and r.score > minScore then
                out[#out + 1] = {
                    candidate = cand,
                    text      = hay,
                    score     = r.score,
                    positions = r.positions,
                    index     = i,
                }
            end
        end
    end
    table.sort(out, function(a, b)
        if a.score == b.score then
            -- Tiebreak: shorter wins, then original index for stability
            if #a.text == #b.text then return a.index < b.index end
            return #a.text < #b.text
        end
        return a.score > b.score
    end)
    if limit and #out > limit then
        for i = #out, limit + 1, -1 do out[i] = nil end
    end
    return out
end

-- ---------------------------------------------------------------------
-- Highlight helper: builds a span list { plain | matched, … } so a
-- view can render highlighted runs without re-computing positions.
-- ---------------------------------------------------------------------

function FuzzyMatcher.spans(text, positions)
    local out = {}
    if not positions or #positions == 0 then
        out[1] = { kind = "plain", text = text }
        return out
    end
    local i = 1
    local n = #text
    local posIdx = 1
    while i <= n do
        local nextMatch = positions[posIdx]
        if not nextMatch then
            out[#out + 1] = { kind = "plain", text = string.sub(text, i) }
            break
        end
        if i < nextMatch then
            out[#out + 1] = { kind = "plain", text = string.sub(text, i, nextMatch - 1) }
        end
        -- Collect a run of consecutive matched positions
        local runEnd = nextMatch
        while positions[posIdx + 1] == runEnd + 1 do
            runEnd = runEnd + 1
            posIdx = posIdx + 1
        end
        out[#out + 1] = { kind = "matched", text = string.sub(text, nextMatch, runEnd) }
        i = runEnd + 1
        posIdx = posIdx + 1
    end
    return out
end

return FuzzyMatcher
