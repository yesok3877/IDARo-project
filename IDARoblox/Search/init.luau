--!nonstrict
-- =====================================================================
-- IDARoblox / Search
-- ---------------------------------------------------------------------
-- Aggregate exports for the unified search subsystem.
-- =====================================================================

local SearchEngine = _G.IDARo.require("Search.SearchEngine")
local RegexCache   = _G.IDARo.require("Search.RegexCache")
local FuzzyMatcher = _G.IDARo.require("Search.FuzzyMatcher")

return {
    SearchEngine = SearchEngine,
    RegexCache   = RegexCache,
    FuzzyMatcher = FuzzyMatcher,
}
