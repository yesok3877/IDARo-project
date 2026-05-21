--!nonstrict
-- =====================================================================
-- IDARoblox / UI / init
-- ---------------------------------------------------------------------
-- One-call UI bootstrap. After Core.bootstrap(), pass the resulting
-- Kernel to UI.bootstrap(kernel) and you get back a fully-wired
-- Renderer ready to mount elements.
--
--   local Core   = require(path.to.IDARoblox.Core)
--   local UI     = require(path.to.IDARoblox.UI)
--   local kernel = Core.bootstrap({ … })
--   local renderer, services = UI.bootstrap(kernel, { theme = "dark" })
--
--   -- Register your modules, then run the splash + boot.
--   local boot = UI.BootSequence.new({ kernel = kernel, renderer = renderer })
--   boot:show()
--   boot:start()
--   boot:onComplete(function() … hand off to workspace … end)
-- =====================================================================

local Framework = script.Framework
local Widgets   = script.Widgets
local Splash    = script.Splash
local Views     = script.Views

local ThemeEngine       = _G.IDARo.require("UI.Framework.ThemeEngine")
local FontMetrics       = _G.IDARo.require("UI.Framework.FontMetrics")
local Animator          = _G.IDARo.require("UI.Framework.Animator")
local Element           = _G.IDARo.require("UI.Framework.Element")
local Component         = _G.IDARo.require("UI.Framework.Component")
local Renderer          = _G.IDARo.require("UI.Framework.Renderer")
local LayoutEngine      = _G.IDARo.require("UI.Framework.LayoutEngine")
local ScrollVirtualizer = _G.IDARo.require("UI.Framework.ScrollVirtualizer")
local InputRouter       = _G.IDARo.require("UI.Framework.InputRouter")
local Camera            = _G.IDARo.require("UI.Framework.Camera")
local SugiyamaLayout    = _G.IDARo.require("UI.Framework.SugiyamaLayout")

local ProgressBar       = _G.IDARo.require("UI.Widgets.ProgressBar")
local Menu              = _G.IDARo.require("UI.Widgets.Menu")
local Toolbar           = _G.IDARo.require("UI.Widgets.Toolbar")
local StatusBar         = _G.IDARo.require("UI.Widgets.StatusBar")

local ProtoTreeView     = _G.IDARo.require("UI.Views.ProtoTreeView")
local DisassemblyView   = _G.IDARo.require("UI.Views.DisassemblyView")
local OutputView        = _G.IDARo.require("UI.Views.OutputView")
local GraphView         = _G.IDARo.require("UI.Views.GraphView")
local StringsView       = _G.IDARo.require("UI.Views.StringsView")
local NamesView         = _G.IDARo.require("UI.Views.NamesView")
local XRefView          = _G.IDARo.require("UI.Views.XRefView")
local PseudocodeView    = _G.IDARo.require("UI.Views.PseudocodeView")
local SearchView        = _G.IDARo.require("UI.Views.SearchView")
local HexView           = _G.IDARo.require("UI.Views.HexView")
local ConstantsView     = _G.IDARo.require("UI.Views.ConstantsView")
local ImportsView       = _G.IDARo.require("UI.Views.ImportsView")
local PatternsView      = _G.IDARo.require("UI.Views.PatternsView")
local HooksView         = _G.IDARo.require("UI.Views.HooksView")

local SplashScreen      = _G.IDARo.require("UI.Splash.SplashScreen")
local BootSequence      = _G.IDARo.require("UI.Splash.BootSequence")

local Workspace         = _G.IDARo.require("UI.Workspace")

local UI = {}

-- ---------------------------------------------------------------------
-- Re-exports
-- ---------------------------------------------------------------------

UI.ThemeEngine        = ThemeEngine
UI.FontMetrics        = FontMetrics
UI.Animator           = Animator
UI.Element            = Element
UI.Component          = Component
UI.Renderer           = Renderer
UI.LayoutEngine       = LayoutEngine
UI.ScrollVirtualizer  = ScrollVirtualizer
UI.InputRouter        = InputRouter
UI.Camera             = Camera
UI.SugiyamaLayout     = SugiyamaLayout

UI.Splitter           = LayoutEngine.Splitter
UI.TabGroup           = LayoutEngine.TabGroup
UI.Panel              = LayoutEngine.Panel

UI.ProgressBar        = ProgressBar
UI.Menu               = Menu
UI.Toolbar            = Toolbar
UI.StatusBar          = StatusBar

UI.ProtoTreeView      = ProtoTreeView
UI.DisassemblyView    = DisassemblyView
UI.OutputView         = OutputView
UI.GraphView          = GraphView
UI.StringsView        = StringsView
UI.NamesView          = NamesView
UI.XRefView           = XRefView
UI.PseudocodeView     = PseudocodeView
UI.SearchView         = SearchView
UI.HexView            = HexView
UI.ConstantsView      = ConstantsView
UI.ImportsView        = ImportsView
UI.PatternsView       = PatternsView
UI.HooksView          = HooksView

UI.SplashScreen       = SplashScreen
UI.BootSequence       = BootSequence
UI.Workspace          = Workspace

-- Convenience: alias the Element factory so callers can write `UI.e(...)`
UI.e         = Element.create
UI.fragment  = Element.fragment
UI.Event     = Element.Event
UI.Changed   = Element.Changed
UI.Ref       = Element.Ref
UI.Children  = Element.Children

-- ---------------------------------------------------------------------
-- bootstrap(kernel, opts) → (renderer, services)
-- ---------------------------------------------------------------------

function UI.bootstrap(kernel, opts)
    if not kernel or type(kernel.eventBus) ~= "function" then
        error("UI.bootstrap requires a Core kernel (from Core.bootstrap())", 2)
    end
    opts = opts or {}

    local logger      = kernel:logger() and kernel:logger():child("UI") or nil
    local eventBus    = kernel:eventBus()

    local theme = ThemeEngine.new({
        eventBus = eventBus,
        theme    = opts.theme or "dark",
        presets  = opts.themePresets,
    })

    local animator = Animator.new({
        useRender      = opts.animatorUseRender == true,
        springTension  = opts.springTension,
        springDamping  = opts.springDamping,
    })

    local fontMetrics = FontMetrics.new({
        cacheCap = opts.fontCacheCap,
        tabWidth = opts.tabWidth,
    })

    local router = InputRouter.new({
        logger = logger,
    })

    local services = {
        theme       = theme,
        animator    = animator,
        fontMetrics = fontMetrics,
        router      = router,
        eventBus    = eventBus,
        logger      = logger,
        kernel      = kernel,
    }

    local renderer = Renderer.new(services)

    -- Register as services so non-UI modules can reach them too.
    kernel:register("Theme",        theme)
    kernel:register("Animator",     animator)
    kernel:register("FontMetrics",  fontMetrics)
    kernel:register("Renderer",     renderer)
    kernel:register("InputRouter",  router)

    if logger then logger:debug("UI bootstrap complete (theme=%s)", theme:name()) end
    return renderer, services, theme, animator, fontMetrics, router
end

-- ---------------------------------------------------------------------
-- mountInScreenGui(renderer, element, opts) → (tree, screenGui)
-- ---------------------------------------------------------------------
-- Convenience: create a ScreenGui under gethui()/CoreGui/PlayerGui, then
-- mount the supplied element into it. Returns both for later teardown.
-- ---------------------------------------------------------------------

local function pickGuiParent(opts)
    if opts and opts.parent then return opts.parent end
    local hui = rawget(_G or {}, "gethui") or rawget(getfenv(), "gethui")
    if type(hui) == "function" then
        local ok, c = pcall(hui)
        if ok and typeof(c) == "Instance" then return c end
    end
    local cg = pcall(function() return game:GetService("CoreGui") end)
    if cg then return game:GetService("CoreGui") end
    local Players = game:GetService("Players")
    local lp = Players.LocalPlayer
    if lp then return lp:WaitForChild("PlayerGui") end
    error("UI.mountInScreenGui: no GUI parent available", 2)
end

function UI.mountInScreenGui(renderer, element, opts)
    opts = opts or {}
    local parent = pickGuiParent(opts)
    local sg = Instance.new("ScreenGui")
    sg.Name = opts.name or "IDARo"
    sg.ResetOnSpawn = false
    sg.IgnoreGuiInset = true
    sg.DisplayOrder = opts.displayOrder or 100
    pcall(function() sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling end)
    sg.Parent = parent
    local tree = renderer:mount(element, sg)
    return tree, sg
end

-- ---------------------------------------------------------------------
-- runSelfTest — minimal sanity check
-- ---------------------------------------------------------------------

function UI.runSelfTest(kernel, renderer, services)
    local logger = services.logger
    local passes, fails = 0, 0
    local function check(name, ok, info)
        if ok then passes = passes + 1
            if logger then logger:debug("UI self-test pass: %s", name) end
        else fails = fails + 1
            if logger then logger:error("UI self-test FAIL: %s — %s", name, tostring(info)) end
        end
    end

    -- Theme tokens resolve
    check("Theme.color('text') is Color3", typeof(services.theme:color("text")) == "Color3")
    check("Theme.size('font.ui') > 0", services.theme:size("font.ui") > 0)

    -- Element creation
    local frame = Element.create("Frame", { Size = UDim2.fromOffset(10, 10) })
    check("Element host kind", Element.isHost(frame))

    -- Mount/unmount round-trip
    local sg = Instance.new("ScreenGui")
    sg.Name = "UI.SelfTest"
    sg.Parent = game:GetService("ReplicatedStorage") or game
    local tree = renderer:mount(Element.create("Frame", { Size = UDim2.fromOffset(20, 20) }), sg)
    check("Mount produced Instance", typeof(tree.instance) == "Instance" and tree.instance.Parent == sg)
    renderer:unmount(tree)
    check("Unmount cleared instance", tree.instance == nil)
    sg:Destroy()

    -- Animator value tween produces final value
    local done = false
    local last = 0
    local anim = services.animator:valueAnim(0, 1, 0.05, "linear")
    anim:onUpdate(function(v) last = v end)
    anim:onComplete(function() done = true end)
    local start = os.clock()
    while not done and (os.clock() - start) < 0.5 do task.wait() end
    check("Animator tween settled", done and math.abs(last - 1) < 1e-3, last)

    if logger then logger:info("UI self-test: %d pass, %d fail", passes, fails) end
    return passes, fails
end

return UI
