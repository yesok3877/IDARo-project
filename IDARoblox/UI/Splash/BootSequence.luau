--!nonstrict
-- =====================================================================
-- IDARoblox / UI / Splash / BootSequence
-- ---------------------------------------------------------------------
-- Glues the Kernel boot to the SplashScreen lifecycle.
--
-- Pattern:
--   local boot = BootSequence.new({ kernel = kernel, renderer = renderer })
--   boot:show()                          -- mount the splash
--   boot:onComplete(function() … end)    -- called when boot finishes OK
--   boot:onError(function(err) … end)    -- called on boot failure
--   boot:start()                          -- kernel:boot() on a task
--   boot:await()                          -- yielding wait for complete
--
-- The BootSequence intentionally OWNS the splash ScreenGui — callers
-- never deal with the raw Instance. Calling :hide() unmounts and
-- destroys it. Calling :destroy() also disconnects all subscriptions.
-- =====================================================================

local SplashScreen = _G.IDARo.require("UI.Splash.SplashScreen")
local Element      = _G.IDARo.require("UI.Framework.Element")
local e            = Element.create

local BootSequence = {}
BootSequence.__index = BootSequence

-- ---------------------------------------------------------------------
-- Choose the safest GUI parent we can find.
-- ---------------------------------------------------------------------

local function pickGuiParent(opts)
    if opts and opts.guiParent then return opts.guiParent end

    -- 1. Executor sandbox: gethui() (hidden, immune to many anti-cheats)
    local hui = rawget(_G or {}, "gethui") or rawget(getfenv(), "gethui")
    if type(hui) == "function" then
        local ok, container = pcall(hui)
        if ok and typeof(container) == "Instance" then return container end
    end

    -- 2. CoreGui (requires elevated permissions in plugin / executor)
    local cgOk, coreGui = pcall(function() return game:GetService("CoreGui") end)
    if cgOk and coreGui then return coreGui end

    -- 3. PlayerGui (LocalScript context)
    local players = game:GetService("Players")
    local lp = players.LocalPlayer
    if lp then
        local pgOk, pg = pcall(function() return lp:WaitForChild("PlayerGui", 5) end)
        if pgOk and pg then return pg end
    end

    error("BootSequence: cannot find a GUI parent (gethui/CoreGui/PlayerGui all unavailable)", 0)
end

-- ---------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------

function BootSequence.new(opts)
    if not opts or not opts.kernel then
        error("BootSequence.new requires opts.kernel", 2)
    end
    if not opts.renderer then
        error("BootSequence.new requires opts.renderer", 2)
    end
    local self = setmetatable({
        _kernel           = opts.kernel,
        _renderer         = opts.renderer,
        _guiName          = opts.guiName or "IDARoblox.Splash",
        _title            = opts.title or "IDARo",
        _subtitle         = opts.subtitle or "static & runtime analysis for Roblox Luau",
        _versionString    = opts.versionString or "v1.0",
        _autoFadeOnComplete = opts.autoFade ~= false,

        _guiParent        = nil,
        _screenGui        = nil,
        _rootTree         = nil,
        _started          = false,
        _completeWaiters  = {},
        _errorWaiters     = {},
        _completeListeners = {},
        _errorListeners    = {},
        _doneState        = nil,                                    -- "ok" | "error"
        _errorPayload     = nil,
        _bootThread       = nil,
    }, BootSequence)
    return self
end

-- ---------------------------------------------------------------------
-- Show / Hide
-- ---------------------------------------------------------------------

function BootSequence:show(opts)
    if self._screenGui then return end
    self._guiParent = pickGuiParent(opts)

    local sg = Instance.new("ScreenGui")
    sg.Name = self._guiName
    sg.ResetOnSpawn = false
    sg.DisplayOrder = 1000
    sg.IgnoreGuiInset = true
    pcall(function() sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling end)
    sg.Parent = self._guiParent
    self._screenGui = sg

    local element = e(SplashScreen, {
        title         = self._title,
        subtitle      = self._subtitle,
        versionString = self._versionString,
        autoFade      = self._autoFadeOnComplete,
        onHidden      = function() self:_finalizeHide() end,
    })
    self._rootTree = self._renderer:mount(element, sg)
end

function BootSequence:hide()
    if not self._screenGui then return end
    if self._rootTree then
        self._renderer:unmount(self._rootTree)
        self._rootTree = nil
    end
    pcall(function() self._screenGui:Destroy() end)
    self._screenGui = nil
end

function BootSequence:_finalizeHide()
    -- Called from SplashScreen when its fade-out completes. Tears down
    -- safely so subsequent UI can render to the same parent.
    self:hide()
end

-- ---------------------------------------------------------------------
-- Run the actual boot
-- ---------------------------------------------------------------------

function BootSequence:start()
    if self._started then return end
    self._started = true
    self._bootThread = task.spawn(function()
        local ok, err = pcall(function() self._kernel:boot() end)
        if ok then
            self._doneState = "ok"
            for _, fn in self._completeListeners do pcall(fn) end
            for _, thr in self._completeWaiters do task.spawn(thr, true) end
            self._completeWaiters = {}
        else
            self._doneState     = "error"
            self._errorPayload  = err
            for _, fn in self._errorListeners do pcall(fn, err) end
            for _, thr in self._errorWaiters do task.spawn(thr, false, err) end
            self._errorWaiters  = {}
        end
    end)
end

function BootSequence:onComplete(fn)
    if self._doneState == "ok" then task.spawn(fn) return self end
    table.insert(self._completeListeners, fn)
    return self
end

function BootSequence:onError(fn)
    if self._doneState == "error" then task.spawn(fn, self._errorPayload) return self end
    table.insert(self._errorListeners, fn)
    return self
end

-- Yielding wait. Returns (true) on success, (false, errorPayload) on failure.
function BootSequence:await()
    if self._doneState == "ok" then return true end
    if self._doneState == "error" then return false, self._errorPayload end
    local thread = coroutine.running()
    assert(thread, "BootSequence:await must be called from a coroutine")
    table.insert(self._completeWaiters, thread)
    table.insert(self._errorWaiters, thread)
    return coroutine.yield()
end

-- ---------------------------------------------------------------------
-- Convenience runner: show + start + await + return result
-- ---------------------------------------------------------------------

function BootSequence:run()
    self:show()
    self:start()
    local ok, err = self:await()
    return ok, err
end

-- ---------------------------------------------------------------------
-- Teardown
-- ---------------------------------------------------------------------

function BootSequence:destroy()
    self:hide()
    if self._bootThread and coroutine.status(self._bootThread) ~= "dead" then
        pcall(task.cancel, self._bootThread)
    end
    self._completeListeners = {}
    self._errorListeners    = {}
    self._completeWaiters   = {}
    self._errorWaiters      = {}
end

return BootSequence
