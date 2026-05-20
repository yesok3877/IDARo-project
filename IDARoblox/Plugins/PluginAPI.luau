--!nonstrict
-- =====================================================================
-- IDARoblox / Plugins / PluginAPI
-- ---------------------------------------------------------------------
-- The contract surface that plugin authors program against. Plugins
-- `require` this module to access manifest validation helpers,
-- canonical Annotation / Severity / Hook constants, and to declare
-- the services they expect.
--
-- Plugin manifest schema
--   {
--     id              = "myplugin",         REQUIRED, unique string
--     name            = "My Cool Plugin",
--     author          = "...",
--     version         = "1.0.0",
--     description     = "...",
--     dependencies    = { "another-plugin-id" },
--
--     -- Lifecycle hooks (all optional; called with `self`)
--     init            = function(self, ctx) … end,
--     onBytecodeLoad  = function(self, bytecode, ctx) … end,
--     scan            = function(self, bytecode, ctx) … end,
--     onRow           = function(self, row, proto, ctx) -> annotation?
--     cleanup         = function(self, ctx) … end,
--
--     -- Pattern-matcher integration (auto-registered)
--     patterns        = { { id, description, atoms = {...}, onMatch }, … }
--
--     -- Declared service requirements (for the loader to validate)
--     requires        = { "logger", "matcher", "projectDB", "bytecode", … },
--   }
--
-- Annotation shape (what onRow / scan return)
--   {
--     source   = "myplugin",      -- usually the plugin id
--     kind     = "rename" | "comment" | "warn" | "tag" | "highlight",
--     text     = "the human-visible string",
--     severity = "info" | "warn" | "error",
--     symbol   = optional symbol-table reference { kind, key }
--     address  = optional { protoId, pc } if attached to a site
--     payload  = arbitrary plugin-specific data
--   }
-- =====================================================================

local PluginAPI = {}

PluginAPI.Severity = table.freeze({
    INFO  = "info",
    WARN  = "warn",
    ERROR = "error",
})

PluginAPI.AnnotationKind = table.freeze({
    RENAME    = "rename",
    COMMENT   = "comment",
    WARN      = "warn",
    TAG       = "tag",
    HIGHLIGHT = "highlight",
    REPORT    = "report",
})

PluginAPI.Hook = table.freeze({
    INIT             = "init",
    ON_BYTECODE_LOAD = "onBytecodeLoad",
    SCAN             = "scan",
    ON_ROW           = "onRow",
    CLEANUP          = "cleanup",
})

-- Services plugins may declare under `requires`. The loader validates
-- presence at registration time and rejects plugins missing critical
-- dependencies.
PluginAPI.Service = table.freeze({
    LOGGER     = "logger",
    EVENT_BUS  = "eventBus",
    MATCHER    = "matcher",
    PROJECT_DB = "projectDB",
    BYTECODE   = "bytecode",
    RUNTIME    = "runtime",
    SEARCH     = "search",
})

-- ---------------------------------------------------------------------
-- Constructors for plugin-emitted records
-- ---------------------------------------------------------------------

function PluginAPI.annotation(opts)
    if type(opts) ~= "table" then
        error("PluginAPI.annotation: opts table expected", 2)
    end
    if type(opts.source) ~= "string" or opts.source == "" then
        error("PluginAPI.annotation: source required", 2)
    end
    if type(opts.text) ~= "string" then
        error("PluginAPI.annotation: text must be a string", 2)
    end
    local kind = opts.kind or PluginAPI.AnnotationKind.COMMENT
    return {
        source   = opts.source,
        kind     = kind,
        text     = opts.text,
        severity = opts.severity or PluginAPI.Severity.INFO,
        symbol   = opts.symbol,
        address  = opts.address,
        payload  = opts.payload,
    }
end

function PluginAPI.report(opts)
    -- A "report" annotation aggregates multiple findings for the
    -- plugin-manager view to show a summary block.
    local a = PluginAPI.annotation({
        source   = opts.source,
        text     = opts.title or "report",
        kind     = PluginAPI.AnnotationKind.REPORT,
        severity = opts.severity,
    })
    a.findings = opts.findings or {}                                 -- array of annotation
    return a
end

-- ---------------------------------------------------------------------
-- Manifest validation
-- ---------------------------------------------------------------------

local VALID_MANIFEST_FIELDS = {
    id           = "string",
    name         = "string",
    author       = "string",
    version      = "string",
    description  = "string",
    dependencies = "table",
    init             = "function",
    onBytecodeLoad   = "function",
    scan             = "function",
    onRow            = "function",
    cleanup          = "function",
    patterns         = "table",
    requires         = "table",
    enabledByDefault = "boolean",
    priority         = "number",
}

function PluginAPI.validateManifest(manifest)
    if type(manifest) ~= "table" then
        return false, "manifest must be a table"
    end
    if type(manifest.id) ~= "string" or manifest.id == "" then
        return false, "manifest.id must be a non-empty string"
    end
    for key, val in manifest do
        local expected = VALID_MANIFEST_FIELDS[key]
        if expected and type(val) ~= expected then
            return false, string.format(
                "manifest.%s expected %s, got %s", key, expected, type(val))
        end
    end
    if manifest.patterns then
        for i, p in manifest.patterns do
            if type(p) ~= "table" then
                return false, string.format("patterns[%d] not a table", i)
            end
            if type(p.atoms) ~= "table" and type(p.onMatch) ~= "function" then
                return false, string.format(
                    "patterns[%d] needs atoms or onMatch", i)
            end
        end
    end
    return true
end

-- ---------------------------------------------------------------------
-- Service-requirements check
-- ---------------------------------------------------------------------

function PluginAPI.validateRequires(manifest, available)
    if not manifest.requires then return true end
    for _, key in manifest.requires do
        if not available[key] then
            return false, string.format("plugin '%s' missing service: %s",
                manifest.id, key)
        end
    end
    return true
end

-- ---------------------------------------------------------------------
-- Sandbox helpers (for the loader to wrap callbacks)
-- ---------------------------------------------------------------------

function PluginAPI.makeProtectedCall(logger)
    return function(fn, ...)
        local args = table.pack(...)
        local results = table.pack(pcall(fn, table.unpack(args, 1, args.n)))
        if results[1] then
            return true, table.unpack(results, 2, results.n)
        end
        if logger then logger:warn("Plugin error: %s", tostring(results[2])) end
        return false, results[2]
    end
end

-- ---------------------------------------------------------------------
-- ContextBuilder — produces a plugin-friendly ctx object for callbacks
-- ---------------------------------------------------------------------

function PluginAPI.buildContext(services, extras)
    extras = extras or {}
    local ctx = {
        logger    = services.logger,
        eventBus  = services.eventBus,
        matcher   = services.matcher,
        projectDB = services.projectDB,
        runtime   = services.runtime,
        bytecode  = services.bytecode,
        search    = services.search,
    }
    for k, v in extras do ctx[k] = v end
    return ctx
end

return PluginAPI
