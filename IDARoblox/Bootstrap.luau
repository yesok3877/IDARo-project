--!nonstrict
-- =====================================================================
-- IDARo / Bootstrap (executor entry, per-file HTTP loader)
-- ---------------------------------------------------------------------
-- Deployment model
--   The entire IDARoblox/ directory lives on a GitHub repo. The user
--   runs:
--
--     loadstring(game:HttpGet(
--         "https://raw.githubusercontent.com/<owner>/<repo>/<branch>/"
--         .. "IDARoblox/Bootstrap.luau"))()
--
--   This file is the FIRST and ONLY file fetched directly. After the
--   loader at the top of this file installs `_G.IDARo.require`, every
--   subsequent module is HTTP-fetched on demand from the same repo.
--
-- Loader semantics
--   * Module names are dotted ("Database.SymbolTable").
--   * Resolution order:
--       (1) <BASE_URL>/<path-with-slashes>.luau
--       (2) <BASE_URL>/<path-with-slashes>/init.luau    (fallback)
--   * Results are cached so the second require is free.
--   * Circular requires are detected and reported as an error.
--   * Failed fetches throw with the URL that was tried.
--
-- Configuration
--   Set `_G.IDARo_REPO_URL` BEFORE running this loadstring to point at
--   your fork:
--
--     _G.IDARo_REPO_URL =
--         "https://raw.githubusercontent.com/myname/myrepo/main/IDARoblox"
--     loadstring(game:HttpGet(_G.IDARo_REPO_URL .. "/Bootstrap.luau"))()
--
--   Otherwise the default URL below is used.
--
-- Idempotency: re-running the loader in the same session tears down
-- the previous mount before building a fresh one.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Default repo URL — override by setting _G.IDARo_REPO_URL before this
-- script runs. The base URL must point at the directory that contains
-- this Bootstrap.luau, not at Bootstrap.luau itself.
-- ---------------------------------------------------------------------

local DEFAULT_REPO_URL =
    "https://raw.githubusercontent.com/IDARo/IDARo/main/IDARoblox"

local BASE_URL = rawget(_G, "IDARo_REPO_URL") or DEFAULT_REPO_URL
-- Strip any trailing slash to keep URL construction predictable.
if string.sub(BASE_URL, -1) == "/" then
    BASE_URL = string.sub(BASE_URL, 1, -2)
end

-- ---------------------------------------------------------------------
-- HTTP fetch helper. Roblox's game:HttpGet returns the body as a
-- string. A 404 typically comes back as the literal text "404: Not
-- Found" or an HTML error page; we treat any response that doesn't
-- start with "--" (the Luau comment marker) or look like Lua source as
-- a miss so the loader can try the next candidate URL.
-- ---------------------------------------------------------------------

local function looksLikeLuau(body)
    if type(body) ~= "string" or #body == 0 then return false end
    -- Strip up to a few hundred bytes of leading whitespace before
    -- making the judgment.
    local head = string.sub(body, 1, 256)
    if string.find(head, "<!DOCTYPE", 1, true)
        or string.find(head, "<html",   1, true)
        or string.find(head, "<Html",   1, true) then
        return false
    end
    if string.find(head, "^404") or string.find(head, "^Not Found") then
        return false
    end
    return true
end

local function httpGet(url)
    local ok, body = pcall(function() return game:HttpGet(url, true) end)
    if not ok then
        -- Roblox HttpGet errors come through as Lua errors; treat as a
        -- miss but stash the message for the eventual report.
        return nil, tostring(body)
    end
    if not looksLikeLuau(body) then
        return nil, "non-luau response"
    end
    return body, nil
end

-- ---------------------------------------------------------------------
-- Module cache + require implementation
-- ---------------------------------------------------------------------

-- If we're being re-run inside the same executor session, blow away
-- any cached modules from the previous run so a fresh fetch happens.
do
    local prev = rawget(_G, "IDARo")
    if type(prev) == "table" then
        if type(prev.modules) == "table" then
            for k in pairs(prev.modules) do prev.modules[k] = nil end
        end
        if type(prev._loading) == "table" then
            for k in pairs(prev._loading) do prev._loading[k] = nil end
        end
    end
end

local _modules = {}
local _loading = {}

local function fetchAndLoad(path)
    local slashed = string.gsub(path, "%.", "/")
    local candidates = {
        BASE_URL .. "/" .. slashed .. ".luau",
        BASE_URL .. "/" .. slashed .. "/init.luau",
    }
    local lastErr
    for _, url in ipairs(candidates) do
        local body, err = httpGet(url)
        if body then
            local chunk, loadErr = loadstring(body, "@IDARo/" .. path)
            if not chunk then
                error("IDARo: parse error in '" .. path .. "': "
                    .. tostring(loadErr) .. "  (url: " .. url .. ")", 2)
            end
            local ok, result = pcall(chunk)
            if not ok then
                error("IDARo: runtime error in '" .. path .. "': "
                    .. tostring(result) .. "  (url: " .. url .. ")", 2)
            end
            return result, url
        else
            lastErr = err
        end
    end
    error("IDARo: could not fetch module '" .. path .. "': "
        .. tostring(lastErr) .. "  (tried .luau and /init.luau under "
        .. BASE_URL .. ")", 2)
end

local function _require(path)
    if type(path) ~= "string" then
        error("IDARo.require: expected string path, got " .. typeof(path), 2)
    end
    if _modules[path] ~= nil then
        local cached = _modules[path]
        if cached == "__nil__" then return nil end
        return cached
    end
    if _loading[path] then
        error("IDARo: circular require detected for '" .. path .. "'", 2)
    end
    _loading[path] = true
    local ok, result = pcall(fetchAndLoad, path)
    _loading[path] = nil
    if not ok then
        error(tostring(result), 2)
    end
    if result == nil then
        _modules[path] = "__nil__"
    else
        _modules[path] = result
    end
    return result
end

local IDARo = {
    require   = _require,
    modules   = _modules,
    _loading  = _loading,
    baseUrl   = BASE_URL,
    version   = "1.0.0",
    -- Diagnostics
    cached    = function() local out = {} for k in pairs(_modules) do
        out[#out + 1] = k end table.sort(out) return out end,
    clear     = function() for k in pairs(_modules) do _modules[k] = nil end end,
}
_G.IDARo = IDARo

-- ---------------------------------------------------------------------
-- Tear-down previous mount (if any). The state-stash below lets a
-- second invocation in the same session clean up cleanly.
-- ---------------------------------------------------------------------

local _existing = rawget(_G, "_IDARo_state")
if _existing then
    pcall(function()
        if _existing.screenGui then _existing.screenGui:Destroy() end
        if _existing.runtime and _existing.runtime.network then
            _existing.runtime.network:pause()
        end
        if _existing.scheduler and _existing.scheduler.shutdown then
            _existing.scheduler:shutdown()
        end
    end)
    rawset(_G, "_IDARo_state", nil)
end

-- ---------------------------------------------------------------------
-- Locate / create a ScreenGui parent.
-- ---------------------------------------------------------------------

local function findScreenGuiParent()
    local gethui = rawget(_G, "gethui") or rawget(getfenv(0), "gethui")
    if type(gethui) == "function" then
        local ok, res = pcall(gethui)
        if ok and res then return res, "gethui" end
    end
    local ok, cg = pcall(function() return game:GetService("CoreGui") end)
    if ok and cg then return cg, "CoreGui" end
    local lp = game:GetService("Players").LocalPlayer
    if lp and lp:FindFirstChildOfClass("PlayerGui") then
        return lp:FindFirstChildOfClass("PlayerGui"), "PlayerGui"
    end
    return nil, "none"
end

local PROJECT_NAME    = "IDARo"
local PROJECT_VERSION = "1.0.0"
local STORAGE_ROOT    = "IDARo"

local guiParent, guiHost = findScreenGuiParent()
if not guiParent then
    error("IDARo: no suitable GUI parent (need CoreGui / PlayerGui)", 0)
end

local screenGui = Instance.new("ScreenGui")
screenGui.Name           = PROJECT_NAME
screenGui.ResetOnSpawn   = false
screenGui.IgnoreGuiInset = true
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.DisplayOrder   = 1_000_000
do
    local protect = rawget(_G, "protectgui")
        or (rawget(_G, "syn") and _G.syn.protect_gui)
    if type(protect) == "function" then pcall(protect, screenGui) end
end
screenGui.Parent = guiParent

-- ---------------------------------------------------------------------
-- Pull in the rest of the project. Each of these triggers a single
-- HTTP fetch the first time it's mentioned (cached thereafter).
-- ---------------------------------------------------------------------

local Core     = _G.IDARo.require("Core")
local UI       = _G.IDARo.require("UI")
local Analysis = _G.IDARo.require("Analysis")
local Runtime  = _G.IDARo.require("Runtime")
local Database = _G.IDARo.require("Database")
local Plugins  = _G.IDARo.require("Plugins")
local Search   = _G.IDARo.require("Search")

-- ---------------------------------------------------------------------
-- Core bootstrap
-- ---------------------------------------------------------------------

local kernel = Core.bootstrap({
    loggerLevel = Core.Logger.Level.DEBUG,
    ringSize    = 4096,
    budgetMs    = 5,
    failFast    = false,
})

local log = kernel:logger()
log:info("%s %s starting (gui host: %s)", PROJECT_NAME, PROJECT_VERSION, guiHost)
log:info("loader base url: %s", BASE_URL)

-- ---------------------------------------------------------------------
-- UI bootstrap
-- ---------------------------------------------------------------------

local renderer, services = UI.bootstrap(kernel, { theme = "dark" })

-- ---------------------------------------------------------------------
-- Runtime construction
-- ---------------------------------------------------------------------

local runtime = Runtime.new({
    logger          = log,
    eventBus        = kernel:eventBus(),
    parser          = Analysis.BytecodeParser,
    networkRingSize = 4096,
    includeTables   = true,
})

-- ---------------------------------------------------------------------
-- ProjectDB (the IDA "IDB")
-- ---------------------------------------------------------------------

local projectDB = Database.ProjectDB.new({
    logger   = log,
    eventBus = kernel:eventBus(),
})

-- ---------------------------------------------------------------------
-- Plugins + built-ins
-- ---------------------------------------------------------------------

local pluginLoader = Plugins.PluginLoader.new({
    logger    = log,
    eventBus  = kernel:eventBus(),
    projectDB = projectDB,
    runtime   = runtime,
})

if type(Plugins.registerBuiltins) == "function" then
    local ok, registered, errors = pcall(Plugins.registerBuiltins, pluginLoader)
    if ok then
        if type(errors) == "table" and #errors > 0 then
            for _, info in ipairs(errors) do
                log:warn("plugin '%s' failed to register: %s",
                    tostring(info.id or "?"), tostring(info.err))
            end
        end
        if type(registered) == "table" then
            log:info("registered %d built-in plugins", #registered)
        end
    else
        log:warn("Plugins.registerBuiltins errored: %s", tostring(registered))
    end
end

-- ---------------------------------------------------------------------
-- Search engine
-- ---------------------------------------------------------------------

local searchEngine = Search and Search.SearchEngine and Search.SearchEngine.new({
    logger   = log,
    eventBus = kernel:eventBus(),
})

-- ---------------------------------------------------------------------
-- Mount workspace
-- ---------------------------------------------------------------------

local workspaceRef
local workspaceSG = screenGui

renderer:mount(
    UI.Element.create(UI.Workspace, {
        kernel        = kernel,
        services      = services,
        runtime       = runtime,
        projectDB     = projectDB,
        pluginLoader  = pluginLoader,
        searchEngine  = searchEngine,
        storageRoot   = STORAGE_ROOT,
        title         = PROJECT_NAME,
        onLoadRequest = function()
            log:info("Open requested; pass a script via Bootstrap return value :loadScript(s).")
            if workspaceRef then
                workspaceRef:setStatusText(
                    "Open: programmatic only at this step (call :loadScript()).")
            end
        end,
        -- File → Open Script…
        -- In executor environments there's no file picker, so this drives
        -- a placeholder status message + offers the public API path.
        onOpenScript = function()
            if workspaceRef then
                workspaceRef:setStatusText(
                    "Open Script: call _G._IDARo:loadScript(scriptInstance) from console.")
            end
            log:info("Open Script invoked. Use _G._IDARo:loadScript(<Script>) from the console.")
        end,
        -- File → Reload
        -- Re-fetch Bootstrap from the loader URL and re-execute. We do
        -- this by clearing the module cache and re-running the top-level
        -- _G.IDARo.require("Bootstrap") — the user's outer loadstring
        -- can then call back into a fresh workspace.
        onReload = function()
            log:info("Reload requested. Clearing module cache.")
            if _G.IDARo and _G.IDARo._moduleCache then
                table.clear(_G.IDARo._moduleCache)
            end
            if workspaceRef then
                workspaceRef:setStatusText("Reload: module cache cleared. Re-run Bootstrap to apply.")
            end
        end,
        -- File → Quit
        -- Tear down the renderer + remove the ScreenGui, fully unmount.
        onQuit = function()
            log:info("Quit requested. Unmounting IDARo.")
            pcall(function() renderer:unmount() end)
            pcall(function() if screenGui then screenGui:Destroy() end end)
            if _G.IDARo then
                _G.IDARo._mounted = false
            end
        end,
        onMount = function(component) workspaceRef = component end,
    }),
    workspaceSG)

-- ---------------------------------------------------------------------
-- Self-bytecode smoke test
-- ---------------------------------------------------------------------

local getbc do
    -- Wave (and most modern executors) expose getscriptbytecode in the
    -- elevated globals returned by getgenv(), not in _G or the script's
    -- own fenv. We resolve from every plausible location.
    local sources = { _G }
    local g = rawget(_G, "getgenv")
    if type(g) == "function" then
        local ok, env = pcall(g)
        if ok and type(env) == "table" then sources[#sources + 1] = env end
    end
    local r = rawget(_G, "getrenv")
    if type(r) == "function" then
        local ok, env = pcall(r)
        if ok and type(env) == "table" then sources[#sources + 1] = env end
    end
    sources[#sources + 1] = getfenv(0)
    for _, env in sources do
        local fn = rawget(env, "getscriptbytecode")
            or rawget(env, "dumpstring")                            -- Krnl alias
            or rawget(env, "getscriptbytes")                        -- Synapse v3 alias
        if type(fn) == "function" then getbc = fn; break end
    end
end
if type(getbc) == "function" then
    task.defer(function()
        local ok, bytes = pcall(getbc, script)
        if ok and type(bytes) == "string" and #bytes > 0 then
            local pOk, parsed = pcall(Analysis.BytecodeParser.parse, bytes)
            if pOk and workspaceRef then
                workspaceRef:setBytecode(parsed)
                workspaceRef:setStatusText(string.format(
                    "loaded self-bytecode: %d protos, %d insn, %d str",
                    parsed.stats.protos, parsed.stats.totalInstructions,
                    parsed.stats.totalStrings))
            elseif not pOk then
                log:warn("BytecodeParser failed on self: %s", tostring(parsed))
            end
        end
    end)
end

-- ---------------------------------------------------------------------
-- Auto-install NetworkTracer
-- ---------------------------------------------------------------------

if runtime.network then
    task.defer(function()
        local ok, err = runtime.network:install()
        if not ok then log:warn("NetworkTracer install: %s", tostring(err)) end
    end)
end

-- ---------------------------------------------------------------------
-- Stash live state for re-run cleanup
-- ---------------------------------------------------------------------

local state = {
    kernel       = kernel,
    renderer     = renderer,
    services     = services,
    runtime      = runtime,
    projectDB    = projectDB,
    pluginLoader = pluginLoader,
    searchEngine = searchEngine,
    screenGui    = screenGui,
    workspaceRef = function() return workspaceRef end,
    workspaceSG  = function() return workspaceSG end,
    version      = PROJECT_VERSION,
}
rawset(_G, "_IDARo_state", state)

-- ---------------------------------------------------------------------
-- Public API: _G._IDARo
-- The simplest possible interface for testing. From any executor
-- console you can do:
--   _G._IDARo:loadScript(workspace.SomeLocalScript)
--   _G._IDARo:loadBytes(getscriptbytecode(someScript))
--   _G._IDARo:focus()              — bring the UI to front
--   _G._IDARo:unload()             — tear down the workspace
-- ---------------------------------------------------------------------

local publicAPI = {}

function publicAPI:loadScript(scriptInstance)
    if not scriptInstance then
        log:warn("_IDARo:loadScript called with nil — pass a LocalScript/ModuleScript/Script Instance")
        return false
    end
    local ws = workspaceRef
    if not ws then
        log:warn("_IDARo:loadScript: workspace not mounted yet")
        return false
    end
    local ok, err = pcall(function() ws:loadScript(scriptInstance) end)
    if not ok then
        log:error("_IDARo:loadScript failed: %s", tostring(err))
        return false
    end
    return true
end

function publicAPI:loadBytes(bytes, label)
    if type(bytes) ~= "string" or #bytes == 0 then
        log:warn("_IDARo:loadBytes expects a non-empty bytecode string")
        return false
    end
    local ws = workspaceRef
    if not ws then
        log:warn("_IDARo:loadBytes: workspace not mounted yet")
        return false
    end
    local BytecodeParser = _G.IDARo.require("Analysis.BytecodeParser")
    local ok, parsed = pcall(BytecodeParser.parse, bytes)
    if not ok then
        log:error("_IDARo:loadBytes: parser failed: %s", tostring(parsed))
        if ws then ws:setStatusText("loadBytes: parser failed") end
        return false
    end
    ws:setBytecode(parsed, bytes)
    if label and ws.setStatusText then
        ws:setStatusText(string.format("Loaded %s (%d protos)", label, parsed.stats.protos))
    end
    return true
end

function publicAPI:focus()
    if screenGui then
        pcall(function() screenGui.Enabled = true end)
    end
end

function publicAPI:unload()
    pcall(function() renderer:unmount() end)
    pcall(function() if screenGui then screenGui:Destroy() end end)
    rawset(_G, "_IDARo", nil)
end

function publicAPI:workspace()
    return workspaceRef
end

function publicAPI:version()
    return PROJECT_VERSION
end

rawset(_G, "_IDARo", publicAPI)

log:info("%s ready (%d modules cached so far).",
    PROJECT_NAME, #_G.IDARo.cached())

return state
