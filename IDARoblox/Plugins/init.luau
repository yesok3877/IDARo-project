--!nonstrict
-- =====================================================================
-- IDARoblox / Plugins
-- ---------------------------------------------------------------------
-- Aggregate exports for the plugin subsystem. Re-exports PluginAPI and
-- PluginLoader, and lists every built-in plugin in `Builtin`. Callers
-- typically:
--
--   local Plugins = require(IDARoblox.Plugins)
--   local loader  = Plugins.PluginLoader.new({ matcher = m, … })
--   Plugins.registerBuiltins(loader)
-- =====================================================================

local PluginAPI    = _G.IDARo.require("Plugins.PluginAPI")
local PluginLoader = _G.IDARo.require("Plugins.PluginLoader")

local DeobfuscatePass  = _G.IDARo.require("Plugins.Builtin.DeobfuscatePass")
local ConstFolder      = _G.IDARo.require("Plugins.Builtin.ConstFolder")
local StringDeXOR      = _G.IDARo.require("Plugins.Builtin.StringDeXOR")
local VMHandlerDetect  = _G.IDARo.require("Plugins.Builtin.VMHandlerDetect")
local DumpAll          = _G.IDARo.require("Plugins.Builtin.DumpAll")

local Plugins = {}

Plugins.PluginAPI    = PluginAPI
Plugins.PluginLoader = PluginLoader
Plugins.Builtin = {
    DeobfuscatePass  = DeobfuscatePass,
    ConstFolder      = ConstFolder,
    StringDeXOR      = StringDeXOR,
    VMHandlerDetect  = VMHandlerDetect,
    DumpAll          = DumpAll,
}

-- The display order, also the load order. Lower priority numbers run
-- earlier in scan phase (so VMHandlerDetect runs before DeobfuscatePass
-- and tags structural protos first; then DeobfuscatePass refines names).
local BUILTIN_LOAD_ORDER = {
    VMHandlerDetect,
    DeobfuscatePass,
    StringDeXOR,
    ConstFolder,
    DumpAll,
}

function Plugins.registerBuiltins(loader, opts)
    opts = opts or {}
    local skip = {}
    if opts.skip then for _, id in opts.skip do skip[id] = true end end
    local registered, errors = {}, {}
    for _, manifest in BUILTIN_LOAD_ORDER do
        if not skip[manifest.id] then
            local rec, err = loader:register(manifest)
            if rec then
                registered[#registered + 1] = manifest.id
            else
                errors[#errors + 1] = { id = manifest.id, err = err }
            end
        end
    end
    return registered, errors
end

return Plugins
