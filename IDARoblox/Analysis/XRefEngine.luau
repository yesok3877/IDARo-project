--!nonstrict
-- =====================================================================
-- IDARoblox / Analysis / XRefEngine
-- ---------------------------------------------------------------------
-- Cross-reference index. Walks every proto's instruction stream and
-- inverts the structured `references` lists the Disassembler emits on
-- each row, producing query-friendly lookup tables.
--
-- For each kind of reference we maintain a separate map:
--
--   byGlobal      [name]            → { Site, … }    mode = "read" | "write"
--   byField       [name]            → { Site, … }    mode = "read" | "write"
--   byMethod      [name]            → { Site, … }    (NAMECALL only)
--   byString      [value]           → { Site, … }    (every K-string + every
--                                                     global/field/method/import
--                                                     part — finds *every* use)
--   byImport      [chainKey]        → { Site, … }    chainKey = "game.Players"
--   byClosure     [protoId]         → { Site, … }    (NEWCLOSURE/DUPCLOSURE
--                                                     instructions that create
--                                                     a closure for this proto)
--   byBuiltin     [name]            → { Site, … }    (fastcall builtin name)
--   byUpval       ["pId:idx"]       → { Site, … }
--   byBranchTarget["pId:pc"]        → { Site, … }    (jump-source side)
--   sitesByProto  [protoId]         → { Site, … }    (every site in this proto)
--
-- The `Site` record:
--   {
--       siteId    = unique integer,
--       protoId   = number,
--       pc        = number,
--       refKind   = "global" | "field" | "method" | "string" | "import"
--                 | "closure" | "builtin" | "upval" | "branch",
--       targetKey = string  -- the bucket key in the corresponding index
--       mode      = "read" | "write" | "call" | "branch" | nil,
--       refData   = <the original ref table from the Disassembler row>,
--   }
--
-- A reference can land in MULTIPLE buckets — for example a `global` ref
-- to "Players" registers as both a site in `byGlobal.Players` and a site
-- in `byString.Players`. That way "find all uses of the string Players"
-- catches globals, fields, methods, import-chain parts, AND raw K-string
-- loads in one query.
--
-- Aggregates:
--   topGlobals(n) / topFields(n) / topMethods(n) / topStrings(n) / topImports(n)
--   closuresList() / builtinsList()
--
-- All sorted by descending site count for "most-referenced X" panels.
-- =====================================================================

local XRefEngine = {}
XRefEngine.__index = XRefEngine

-- ---------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------

local function ensureList(tbl, key)
    local v = tbl[key]
    if not v then v = {}; tbl[key] = v end
    return v
end

local function chainKey(chain)
    if type(chain) == "string" then return chain end
    if type(chain) ~= "table" then return tostring(chain) end
    return table.concat(chain, ".")
end

-- ---------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------

function XRefEngine.new(disassembler, parsedBytecode, opts)
    if not disassembler then error("XRefEngine.new: disassembler required", 2) end
    if not parsedBytecode then error("XRefEngine.new: parsedBytecode required", 2) end
    return setmetatable({
        _disasm   = disassembler,
        _bc       = parsedBytecode,
        _opts     = opts or {},
        _index    = nil,
        _logger   = opts and opts.logger,
    }, XRefEngine)
end

-- ---------------------------------------------------------------------
-- Build pipeline
-- ---------------------------------------------------------------------

local function newIndex(parsedBytecode)
    return {
        bytecode        = parsedBytecode,
        sites           = {},                                        -- flat, 1-indexed
        byGlobal        = {},
        byField         = {},
        byMethod        = {},
        byString        = {},
        byImport        = {},
        byClosure       = {},
        byBuiltin       = {},
        byUpval         = {},
        byBranchTarget  = {},
        sitesByProto    = {},
        stats           = {
            totalSites      = 0,
            uniqueGlobals   = 0,
            uniqueFields    = 0,
            uniqueMethods   = 0,
            uniqueStrings   = 0,
            uniqueImports   = 0,
            uniqueBuiltins  = 0,
            uniqueClosures  = 0,
            callSiteCount   = 0,
            branchSiteCount = 0,
        },
    }
end

-- Walk a single proto, classify each ref, and append to the appropriate
-- bucket(s). Each ref can contribute to multiple buckets.
local function processProto(self, index, protoId)
    local stream = self._disasm:disassembleProto(protoId)
    if not stream then return 0 end

    local protoSites = ensureList(index.sitesByProto, protoId)
    local addedThisProto = 0

    local function pushSite(refKind, targetKey, bucketTable, ref, row, mode)
        if not bucketTable or not targetKey then return end
        index.stats.totalSites = index.stats.totalSites + 1
        local site = {
            siteId    = index.stats.totalSites,
            protoId   = protoId,
            pc        = row.pc,
            refKind   = refKind,
            targetKey = targetKey,
            mode      = mode,
            refData   = ref,
        }
        index.sites[site.siteId] = site
        local bucket = ensureList(bucketTable, targetKey)
        bucket[#bucket + 1] = site
        protoSites[#protoSites + 1] = site
        addedThisProto = addedThisProto + 1
        return site
    end

    -- ALSO index a string-mention so finding "Players" returns globals + fields + etc.
    local function indexString(value, ref, row, sourceRefKind)
        if type(value) ~= "string" or value == "" then return end
        pushSite("string", value, index.byString, ref, row, sourceRefKind)
    end

    for _, row in stream.rows do
        local refs = row.references
        if not refs then continue end
        for _, ref in refs do
            local kind = ref.kind
            if kind == "global" then
                pushSite("global", ref.name, index.byGlobal, ref, row, ref.mode)
                indexString(ref.name, ref, row, "global")
            elseif kind == "field" then
                pushSite("field", ref.name, index.byField, ref, row, ref.mode)
                indexString(ref.name, ref, row, "field")
            elseif kind == "namecall" then
                pushSite("method", ref.method, index.byMethod, ref, row, "call")
                indexString(ref.method, ref, row, "method")
            elseif kind == "import" then
                local key = chainKey(ref.chain)
                if key and key ~= "" then
                    pushSite("import", key, index.byImport, ref, row, "read")
                    if type(ref.chain) == "table" then
                        for _, part in ref.chain do
                            indexString(part, ref, row, "import-part")
                        end
                    end
                end
            elseif kind == "k" then
                -- We index k-string references; numeric / bool / nil / table
                -- constants aren't included because there's no useful inverted
                -- key for them (the value-by-K-index lookup is already O(1)).
                if ref.tag == "STRING" then
                    local proto = self._bc.protos[protoId]
                    local kEntry = proto and proto.constants[ref.kidx + 1]
                    local val = kEntry and kEntry.value
                    if val then indexString(val, ref, row, "k-string") end
                end
            elseif kind == "closure" then
                pushSite("closure", tostring(ref.protoId), index.byClosure, ref, row, "create")
            elseif kind == "fastcall_builtin" then
                pushSite("builtin", ref.name, index.byBuiltin, ref, row, "call")
            elseif kind == "upval" then
                local key = string.format("%d:%d", protoId, ref.index)
                pushSite("upval", key, index.byUpval, ref, row, ref.mode)
                if ref.name then indexString(ref.name, ref, row, "upval-name") end
            elseif kind == "branch" then
                if ref.target then
                    local key = string.format("%d:%d", protoId, ref.target)
                    pushSite("branch", key, index.byBranchTarget, ref, row, "branch")
                    index.stats.branchSiteCount = index.stats.branchSiteCount + 1
                end
            elseif kind == "call" then
                -- Direct CALL sites have no static target (the function is in
                -- a register). Counted for stats; no inverted index — the
                -- decompiler in step 8 will resolve via data-flow if it can.
                index.stats.callSiteCount = index.stats.callSiteCount + 1
            end
        end
    end

    return addedThisProto
end

-- ---------------------------------------------------------------------
-- Finalize: compute unique-key counts after building
-- ---------------------------------------------------------------------

local function countKeys(tbl)
    local n = 0
    for _ in tbl do n = n + 1 end
    return n
end

local function finalizeStats(index)
    index.stats.uniqueGlobals  = countKeys(index.byGlobal)
    index.stats.uniqueFields   = countKeys(index.byField)
    index.stats.uniqueMethods  = countKeys(index.byMethod)
    index.stats.uniqueStrings  = countKeys(index.byString)
    index.stats.uniqueImports  = countKeys(index.byImport)
    index.stats.uniqueBuiltins = countKeys(index.byBuiltin)
    index.stats.uniqueClosures = countKeys(index.byClosure)
end

-- ---------------------------------------------------------------------
-- Attach helper methods on the result object so callers can ergonomically
-- ask the index for queries without going through engine.
-- ---------------------------------------------------------------------

local function attachHelpers(index)
    function index:sitesForGlobal(name)
        return self.byGlobal[name] or {}
    end
    function index:sitesForField(name)
        return self.byField[name] or {}
    end
    function index:sitesForMethod(name)
        return self.byMethod[name] or {}
    end
    function index:sitesForString(value)
        return self.byString[value] or {}
    end
    function index:sitesForImport(chain)
        return self.byImport[chainKey(chain)] or {}
    end
    function index:sitesForClosure(protoId)
        return self.byClosure[tostring(protoId)] or {}
    end
    function index:sitesForBuiltin(name)
        return self.byBuiltin[name] or {}
    end
    function index:sitesForUpval(protoId, upvalIdx)
        return self.byUpval[string.format("%d:%d", protoId, upvalIdx)] or {}
    end
    function index:sitesForBranchTarget(protoId, pc)
        return self.byBranchTarget[string.format("%d:%d", protoId, pc)] or {}
    end
    function index:sitesInProto(protoId)
        return self.sitesByProto[protoId] or {}
    end

    -- Top-N sorted descending by site count. Returns
    -- { { name, count, sites }, … }
    local function topN(bucket, n)
        local list = {}
        for name, sites in bucket do
            list[#list + 1] = { name = name, count = #sites, sites = sites }
        end
        table.sort(list, function(a, b)
            if a.count == b.count then return a.name < b.name end
            return a.count > b.count
        end)
        if n and n > 0 and #list > n then
            for i = n + 1, #list do list[i] = nil end
        end
        return list
    end

    function index:topGlobals(n) return topN(self.byGlobal, n) end
    function index:topFields(n)  return topN(self.byField,  n) end
    function index:topMethods(n) return topN(self.byMethod, n) end
    function index:topStrings(n) return topN(self.byString, n) end
    function index:topImports(n) return topN(self.byImport, n) end
    function index:topBuiltins(n) return topN(self.byBuiltin, n) end

    -- Closures (creators) listed by protoId. Each entry holds the proto's
    -- debugName when present so the Names view can render at-a-glance.
    function index:closuresList()
        local out = {}
        for protoIdStr, sites in self.byClosure do
            local protoId = tonumber(protoIdStr)
            local proto = self.bytecode.protos[protoId]
            out[#out + 1] = {
                protoId   = protoId,
                count     = #sites,
                sites     = sites,
                debugName = proto and proto.debugName,
            }
        end
        table.sort(out, function(a, b)
            if a.count == b.count then return (a.debugName or "") < (b.debugName or "") end
            return a.count > b.count
        end)
        return out
    end

    -- An iterator over named functions: every proto that has a debugName.
    -- Combined here because the Names view will want to see every named
    -- function plus how many times it gets instantiated as a closure.
    function index:namedProtos()
        local out = {}
        for id, proto in self.bytecode.protos do
            if proto.debugName and proto.debugName ~= "" then
                out[#out + 1] = {
                    protoId   = id,
                    debugName = proto.debugName,
                    sizecode  = proto.sizecode or 0,
                    numparams = proto.numparams or 0,
                    closureCount = #(self.byClosure[tostring(id)] or {}),
                }
            end
        end
        table.sort(out, function(a, b)
            return (a.debugName or "") < (b.debugName or "")
        end)
        return out
    end

    -- Per-string aggregate: { stringId, value, length, refCount }, sorted
    -- by raw stringId order (the strings panel will let the user re-sort
    -- by other columns at the view layer).
    function index:stringsList()
        local out = {}
        local stringTable = self.bytecode.stringTable or {}
        for id, value in stringTable do
            local sites = self.byString[value]
            out[#out + 1] = {
                stringId = id,
                value    = value,
                length   = #value,
                refCount = sites and #sites or 0,
                sites    = sites or {},
            }
        end
        return out
    end

    return index
end

-- ---------------------------------------------------------------------
-- Public build entry point
-- ---------------------------------------------------------------------

function XRefEngine.run(disassembler, parsedBytecode, opts)
    opts = opts or {}
    local engine = XRefEngine.new(disassembler, parsedBytecode, opts)
    return XRefEngine._instanceBuild(engine, opts.progressCb)
end
-- Back-compat: some callers pre-date the rename. Route XRefEngine.build
-- (when called with the static signature: first arg is a disassembler,
-- not an engine) to the new static name. If first arg looks like an
-- engine (has _disasm), we treat it as the colon-call.
function XRefEngine.build(...)
    local args = { ... }
    local first = args[1]
    -- Engine instances always have _disasm; a raw disassembler doesn't.
    if type(first) == "table" and rawget(first, "_disasm") ~= nil then
        -- Instance method call: engine:build(progressCb)
        return XRefEngine._instanceBuild(first, args[2])
    end
    -- Static call: XRefEngine.run-style with (disassembler, parsedBytecode, opts)
    return XRefEngine.run(args[1], args[2], args[3])
end

function XRefEngine._instanceBuild(self, progressCb)
    local index = newIndex(self._bc)
    local protoCount = self._bc.stats and self._bc.stats.protos or 0
    if protoCount == 0 then
        -- protos is indexed table from 0; count via iteration
        for _ in self._bc.protos do protoCount = protoCount + 1 end
    end
    local done = 0
    for protoId in self._bc.protos do
        processProto(self, index, protoId)
        done = done + 1
        if progressCb then pcall(progressCb, done, protoCount) end
    end
    finalizeStats(index)
    attachHelpers(index)
    self._index = index
    if self._logger then
        self._logger:info(
            "XRefEngine: indexed %d sites — %d globals, %d fields, %d methods, %d strings, %d imports",
            index.stats.totalSites, index.stats.uniqueGlobals,
            index.stats.uniqueFields, index.stats.uniqueMethods,
            index.stats.uniqueStrings, index.stats.uniqueImports)
    end
    return index
end
-- Public instance-method alias for engine:build(progressCb).
function XRefEngine:build_instance(progressCb)
    return XRefEngine._instanceBuild(self, progressCb)
end

function XRefEngine:index() return self._index end

-- ---------------------------------------------------------------------
-- Manifest
-- ---------------------------------------------------------------------

function XRefEngine.manifest()
    return {
        id           = "Analysis.XRefEngine",
        dependencies = { "Analysis.Disassembler" },
        weight       = 0.5,
        serviceName  = "XRefEngine",
        stages = {
            { id = "register", weight = 1.0, fn = function(ctx)
                ctx:report(1, "XRefEngine ready")
            end },
        },
    }
end

return XRefEngine
