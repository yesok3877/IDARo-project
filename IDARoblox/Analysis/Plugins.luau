--!nonstrict
-- =====================================================================
-- IDARoblox / Analysis / Plugins  (compatibility shim)
-- ---------------------------------------------------------------------
-- The plugin host originally lived under Analysis/. It has since moved
-- to its own top-level directory (`/Plugins/`) with a proper split
-- between PluginAPI (contract) and PluginLoader (host). This file is
-- kept as a thin re-export so existing call sites in Workspace and
-- elsewhere keep working without churn.
--
-- Behavior:
--   * .new(opts)            → constructs a Plugins.PluginLoader
--   * .registerBuiltins(l)  → registers every built-in plugin
--   * .PluginAPI / .PluginLoader → the underlying modules
--
-- New code should `require(IDARoblox.Plugins)` directly.
-- =====================================================================

local Plugins = _G.IDARo.require("Plugins")

local Compat = {}
Compat.PluginAPI    = Plugins.PluginAPI
Compat.PluginLoader = Plugins.PluginLoader
Compat.Builtin      = Plugins.Builtin

function Compat.new(opts)
    return Plugins.PluginLoader.new(opts)
end

function Compat.registerBuiltins(loader, opts)
    return Plugins.registerBuiltins(loader, opts)
end

return Compat
