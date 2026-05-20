--!nonstrict
-- =====================================================================
-- IDARoblox / Plugins / Builtin / DumpAll
-- ---------------------------------------------------------------------
-- Mass-extract every script-bytecode payload the executor can see. Walks
-- the live environment via ctx.runtime.scripts (ScriptRegistry) and
-- dumps each accessible script to disk under `IDARoblox/dumps/`.
--
-- Output structure
--   IDARoblox/dumps/<sanitized-name>__<shortHash>.luac
--   IDARoblox/dumps/manifest.txt   ← one line per dump
--
-- The plugin doesn't run automatically on bytecode load — it exposes a
-- manual `:run()` entry point and a "dumpAll" command via the eventBus
-- so the UI can trigger it from the Plugin Manager.
-- =====================================================================

local PluginAPI = _G.IDARo.require("Plugins.PluginAPI")

local PLUGIN_ID = "builtin.dumpAll"

local function fnvHash32(s)
    -- 32-bit FNV-1a — fast non-cryptographic checksum suitable for
    -- file-naming. Stays within Lua double precision.
    local h = 2166136261                                              -- offset basis
    local prime = 16777619
    for i = 1, #s do
        h = bit32.bxor(h, string.byte(s, i))
        h = (h * prime) % 4294967296
    end
    return h
end

local function shortHash(s)
    return string.format("%08X", fnvHash32(s))
end

local function sanitize(name)
    if type(name) ~= "string" then return "anon" end
    local out = name:gsub("[^%w_%-%.]", "_")
    if #out > 64 then out = string.sub(out, 1, 64) end
    if out == "" then out = "anon" end
    return out
end

-- ---------------------------------------------------------------------
-- Dump core
-- ---------------------------------------------------------------------

local function dumpOneScript(script, getBytecode, storage, dir)
    local ok, bytes = pcall(getBytecode, script)
    if not ok or type(bytes) ~= "string" or #bytes == 0 then
        return nil, "getscriptbytecode returned: " .. tostring(bytes)
    end
    local fullName = nil
    pcall(function() fullName = script:GetFullName() end)
    local safe = sanitize(fullName or script.Name or "anon")
    local hash = shortHash(bytes)
    local filename = dir .. "/" .. safe .. "__" .. hash .. ".luac"
    if storage and storage.write then
        local wok, werr = storage:write(filename, bytes)
        if not wok then return nil, "write failed: " .. tostring(werr) end
    end
    return { filename = filename, size = #bytes, hash = hash, fullName = fullName }, nil
end

-- ---------------------------------------------------------------------
-- Manifest
-- ---------------------------------------------------------------------

local DumpAll = {
    id          = PLUGIN_ID,
    name        = "Mass Script Dumper",
    author      = "IDARo",
    version     = "1.0",
    description = "Walks the live environment and dumps every accessible "
        .. "Luau script to disk for later analysis.",
    requires    = { "runtime" },
    priority    = 200,                                               -- run after scanners
    enabledByDefault = false,                                        -- manual trigger
    _storage    = nil,
    _logger     = nil,
}

function DumpAll:init(ctx)
    self._logger = ctx.logger
    -- Storage may come either via ctx or via a workspace passthrough.
    -- We accept a storage either way.
    self._storage = ctx.storage
end

-- Public entry — called by UI / eventBus / direct call.
function DumpAll:run(ctx, opts)
    opts = opts or {}
    local runtime = ctx.runtime
    if not runtime or not runtime.scripts then
        return nil, "runtime.scripts unavailable"
    end
    local storage = opts.storage or self._storage or ctx.storage
    if not storage or not storage.write then
        return nil, "no writable storage backend"
    end
    if not storage:available() then
        return nil, "writefile unavailable in this executor"
    end
    local dir = opts.directory or "dumps"

    -- Resolve getscriptbytecode at runtime via the env scanner if available.
    local getBytecode = opts.getscriptbytecode
    if not getBytecode then
        local scanner = runtime.scanner
        if scanner and scanner.getRaw then
            getBytecode = scanner:getRaw("getscriptbytecode")
        end
        if not getBytecode then getBytecode = getfenv(0).getscriptbytecode end
    end
    if type(getBytecode) ~= "function" then
        return nil, "getscriptbytecode not available"
    end

    local scripts = runtime.scripts:enumerate()
    local results = { dumped = {}, failed = {}, manifest = {} }
    local total = (scripts.loadedModules and #scripts.loadedModules or 0)
                + (scripts.runningScripts and #scripts.runningScripts or 0)
                + (scripts.gameScripts and #scripts.gameScripts or 0)
    if self._logger then
        self._logger:info("DumpAll: starting (%d candidate scripts)", total)
    end

    local seen = {}
    local function process(list, sourceLabel)
        if not list then return end
        for _, s in list do
            if not seen[s] then
                seen[s] = true
                local rec, err = dumpOneScript(s, getBytecode, storage, dir)
                if rec then
                    rec.source = sourceLabel
                    results.dumped[#results.dumped + 1] = rec
                    results.manifest[#results.manifest + 1] = string.format(
                        "%s\t%s\t%d\t%s",
                        rec.hash, sourceLabel, rec.size, rec.fullName or "?")
                else
                    results.failed[#results.failed + 1] = { script = s, err = err }
                end
            end
        end
    end

    process(scripts.loadedModules,  "loadedModules")
    process(scripts.runningScripts, "runningScripts")
    process(scripts.gameScripts,    "gameScripts")
    process(scripts.allScripts,     "allScripts")

    -- Write the manifest
    if #results.manifest > 0 then
        storage:write(dir .. "/manifest.txt", table.concat(results.manifest, "\n"))
    end

    if self._logger then
        self._logger:info("DumpAll: %d dumped, %d failed",
            #results.dumped, #results.failed)
    end

    return results
end

-- Listen for an event-driven trigger so the Plugin Manager view can
-- fire "plugin.dumpAll.run" via the eventBus.
function DumpAll:onBytecodeLoad(_bc, ctx)
    if ctx.eventBus and not self._eventHooked then
        self._eventHooked = true
        ctx.eventBus:on("plugin.dumpAll.run", function(opts)
            self:run(ctx, opts or {})
        end)
    end
end

function DumpAll:cleanup() self._storage = nil; self._logger = nil end

return DumpAll
