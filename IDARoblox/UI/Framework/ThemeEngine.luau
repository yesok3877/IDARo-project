--!nonstrict
-- =====================================================================
-- IDARoblox / UI / Framework / ThemeEngine
-- ---------------------------------------------------------------------
-- Token-based theme system. Components read tokens via:
--   theme:color("surface")        -> Color3
--   theme:font("mono")            -> Font
--   theme:size("font.mono")       -> number
--   theme:spacing("md")           -> number
--   theme:radius("md")            -> number
--
-- Themes can be swapped at runtime; the engine emits "theme.changed" on
-- the EventBus (if one is provided), which Components subscribe to in
-- their didMount() to trigger re-render.
-- =====================================================================

local ThemeEngine = {}
ThemeEngine.__index = ThemeEngine

local function rgb(r, g, b) return Color3.fromRGB(r, g, b) end
local function mkFont(name, weight, style)
    if Font and Font.fromEnum then
        local ok, f = pcall(function()
            return Font.new(name, weight or Enum.FontWeight.Regular, style or Enum.FontStyle.Normal)
        end)
        if ok and f then return f end
    end
    return name                                                     -- fallback for old engines
end

-- ---------------------------------------------------------------------
-- Dark preset — calibrated for IDA Pro feel (deep navy/charcoal +
-- desaturated accent palette).
-- ---------------------------------------------------------------------

local DARK = {
    name = "dark",
    colors = {
        -- Surfaces
        background       = rgb(13, 16, 22),
        backgroundAlt    = rgb(17, 21, 28),
        surface          = rgb(22, 28, 38),
        surfaceAlt       = rgb(28, 35, 47),
        surfaceHover     = rgb(34, 42, 56),
        surfaceActive    = rgb(40, 50, 67),
        overlay          = rgb(0, 0, 0),
        -- Borders / separators
        border           = rgb(38, 46, 60),
        borderStrong     = rgb(58, 68, 86),
        divider          = rgb(28, 34, 44),
        -- Text
        text             = rgb(220, 226, 235),
        textMuted        = rgb(150, 160, 175),
        textSubtle       = rgb(105, 115, 130),
        textDisabled     = rgb(70, 78, 90),
        textInverse      = rgb(20, 20, 20),
        -- Accents (IDA-ish palette)
        primary          = rgb(94, 162, 224),                       -- selection blue
        primaryHover     = rgb(126, 184, 236),
        primaryPressed   = rgb(64, 132, 196),
        primaryMuted     = rgb(50, 96, 138),
        textOnPrimary    = rgb(245, 250, 255),
        accent           = rgb(176, 142, 232),                      -- violet
        success          = rgb(102, 187, 138),
        warning          = rgb(232, 178, 76),
        danger           = rgb(228, 90, 90),
        info             = rgb(102, 178, 222),
        -- Code syntax (used by the future PseudocodeView)
        syntaxBg         = rgb(14, 18, 24),
        syntaxKeyword    = rgb(202, 136, 215),
        syntaxString     = rgb(166, 200, 122),
        syntaxNumber     = rgb(232, 178, 76),
        syntaxComment    = rgb(100, 115, 130),
        syntaxOperator   = rgb(180, 190, 200),
        syntaxIdentifier = rgb(220, 226, 235),
        syntaxFunction   = rgb(126, 184, 236),
        syntaxLabel      = rgb(228, 154, 92),
        -- Disassembly hilites
        addrColor        = rgb(120, 130, 145),
        mnemonicColor    = rgb(220, 226, 235),
        registerColor    = rgb(232, 178, 76),
        constantColor    = rgb(166, 200, 122),
        jumpTarget       = rgb(94, 162, 224),
        -- DisassemblyView semantic tokens (mapped to a small palette so the
        -- listing reads at a glance: address bar / mnemonic / operands /
        -- comments / branch labels / row stripe).
        disassemblyAddr     = rgb(120, 130, 145),
        disassemblyMnem     = rgb(220, 226, 235),
        disassemblyOperand  = rgb(196, 204, 218),
        disassemblyComment  = rgb(110, 124, 140),
        disassemblyLabel    = rgb(228, 154, 92),
        disassemblyRowOdd   = rgb(13, 16, 22),
        disassemblyRowEven  = rgb(16, 20, 27),
        -- Progress bar palette
        barTrack         = rgb(28, 34, 44),
        barFill          = rgb(94, 162, 224),
        barFillSuccess   = rgb(102, 187, 138),
        barFillWarning   = rgb(232, 178, 76),
        barIndeterminate = rgb(126, 184, 236),
    },
    fonts = {
        ui         = mkFont("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Medium),
        uiBold     = mkFont("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Bold),
        uiLight    = mkFont("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Regular),
        mono       = mkFont("rbxasset://fonts/families/RobotoMono.json", Enum.FontWeight.Regular),
        monoBold   = mkFont("rbxasset://fonts/families/RobotoMono.json", Enum.FontWeight.Bold),
        title      = mkFont("rbxasset://fonts/families/Inconsolata.json", Enum.FontWeight.Bold),
    },
    sizes = {
        ["font.ui"]      = 13,
        ["font.uiSmall"] = 11,
        ["font.uiTitle"] = 16,
        ["font.uiHero"]  = 28,
        ["font.mono"]    = 12,
        ["font.code"]    = 13,
        ["row.height"]   = 18,
        ["bar.height"]   = 10,
        ["bar.heightLg"] = 14,
        ["icon.sm"]      = 12,
        ["icon.md"]      = 16,
        ["icon.lg"]      = 20,
        ["tabBar"]       = 28,
        ["statusBar"]    = 22,
        ["menuBar"]      = 24,
        ["toolbar"]      = 32,
        ["splitter"]     = 4,
    },
    spacing = {
        none = 0, xxs = 2, xs = 4, sm = 6, md = 8, lg = 12, xl = 16, xxl = 24, hero = 48,
    },
    radius = {
        none = 0, sm = 3, md = 5, lg = 8, xl = 12, pill = 999,
    },
    transitions = {
        fast = 0.10,
        med  = 0.18,
        slow = 0.32,
    },
    transparency = {
        scrim = 0.55,
        ghost = 0.85,
        ghostStrong = 0.65,
        tooltip = 0.05,
    },
}

-- ---------------------------------------------------------------------
-- Light preset (kept for completeness; less polish, intended for use in
-- screenshot-style exports rather than the main editor surface)
-- ---------------------------------------------------------------------

local LIGHT = table.clone(DARK)
LIGHT.name = "light"
LIGHT.colors = {
    background       = rgb(244, 246, 250),
    backgroundAlt    = rgb(238, 240, 244),
    surface          = rgb(255, 255, 255),
    surfaceAlt       = rgb(248, 249, 252),
    surfaceHover     = rgb(238, 242, 248),
    surfaceActive    = rgb(220, 230, 244),
    overlay          = rgb(255, 255, 255),
    border           = rgb(220, 226, 235),
    borderStrong     = rgb(190, 198, 212),
    divider          = rgb(228, 232, 240),
    text             = rgb(28, 34, 42),
    textMuted        = rgb(90, 100, 115),
    textSubtle       = rgb(140, 150, 165),
    textDisabled     = rgb(180, 188, 200),
    textInverse      = rgb(245, 248, 252),
    primary          = rgb(48, 110, 198),
    primaryHover     = rgb(40, 96, 180),
    primaryPressed   = rgb(34, 84, 162),
    primaryMuted     = rgb(180, 210, 242),
    textOnPrimary    = rgb(252, 253, 255),
    accent           = rgb(132, 90, 196),
    success          = rgb(64, 152, 96),
    warning          = rgb(200, 134, 40),
    danger           = rgb(196, 56, 56),
    info             = rgb(68, 142, 196),
    syntaxBg         = rgb(252, 253, 255),
    syntaxKeyword    = rgb(132, 60, 168),
    syntaxString     = rgb(70, 130, 64),
    syntaxNumber     = rgb(178, 110, 28),
    syntaxComment    = rgb(140, 148, 162),
    syntaxOperator   = rgb(60, 70, 85),
    syntaxIdentifier = rgb(28, 34, 42),
    syntaxFunction   = rgb(40, 96, 180),
    syntaxLabel      = rgb(180, 96, 30),
    addrColor        = rgb(120, 130, 145),
    mnemonicColor    = rgb(28, 34, 42),
    registerColor    = rgb(178, 110, 28),
    constantColor    = rgb(70, 130, 64),
    jumpTarget       = rgb(48, 110, 198),
    disassemblyAddr     = rgb(140, 150, 165),
    disassemblyMnem     = rgb(28, 34, 42),
    disassemblyOperand  = rgb(46, 54, 68),
    disassemblyComment  = rgb(150, 156, 170),
    disassemblyLabel    = rgb(180, 96, 30),
    disassemblyRowOdd   = rgb(252, 253, 255),
    disassemblyRowEven  = rgb(246, 248, 252),
    barTrack         = rgb(228, 232, 240),
    barFill          = rgb(48, 110, 198),
    barFillSuccess   = rgb(64, 152, 96),
    barFillWarning   = rgb(200, 134, 40),
    barIndeterminate = rgb(80, 142, 222),
}

local MAGENTA = rgb(255, 0, 255)  -- fallback for missing colors so issues stand out

-- ---------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------

function ThemeEngine.new(opts)
    opts = opts or {}
    local presets = { dark = DARK, light = LIGHT }
    if opts.presets then
        for k, v in opts.presets do presets[k] = v end
    end
    local startName = opts.theme or "dark"
    local self = setmetatable({
        _presets  = presets,
        _name     = startName,
        _current  = presets[startName] or DARK,
        _bus      = opts.eventBus,
        _overrides = {},                                            -- runtime per-token overrides
    }, ThemeEngine)
    return self
end

-- ---------------------------------------------------------------------
-- Token accessors (always return *something*; never raise)
-- ---------------------------------------------------------------------

function ThemeEngine:color(key: string): Color3
    local override = self._overrides[key]
    if typeof(override) == "Color3" then return override end
    local v = self._current.colors[key]
    if typeof(v) == "Color3" then return v end
    return MAGENTA
end

function ThemeEngine:font(key: string)
    return self._current.fonts[key] or self._current.fonts.ui
end

function ThemeEngine:size(key: string): number
    return self._current.sizes[key] or 14
end

function ThemeEngine:spacing(key: string): number
    return self._current.spacing[key] or 8
end

function ThemeEngine:radius(key: string): number
    return self._current.radius[key] or 4
end

function ThemeEngine:transition(key: string): number
    return self._current.transitions[key] or 0.18
end

function ThemeEngine:transparency(key: string): number
    return self._current.transparency[key] or 0
end

function ThemeEngine:name(): string return self._name end

-- ---------------------------------------------------------------------
-- Mutations
-- ---------------------------------------------------------------------

function ThemeEngine:setTheme(name: string)
    local preset = self._presets[name]
    if not preset then
        error("ThemeEngine: unknown theme '" .. name .. "'", 2)
    end
    if name == self._name then return end
    self._name = name
    self._current = preset
    if self._bus then
        self._bus:emit("theme.changed", { name = name })
    end
end

function ThemeEngine:override(token: string, value)
    self._overrides[token] = value
    if self._bus then self._bus:emit("theme.changed", { token = token, override = true }) end
end

function ThemeEngine:clearOverrides()
    self._overrides = {}
    if self._bus then self._bus:emit("theme.changed", { resetOverrides = true }) end
end

-- ---------------------------------------------------------------------
-- Convenience builders (used by widgets)
-- ---------------------------------------------------------------------

function ThemeEngine:colorScheme(): { background: Color3, surface: Color3, text: Color3 }
    return {
        background = self:color("background"),
        surface    = self:color("surface"),
        text       = self:color("text"),
    }
end

-- Mix two colors. amount=0 → a, amount=1 → b. Used for hover states etc.
function ThemeEngine.mix(a: Color3, b: Color3, amount: number): Color3
    if amount <= 0 then return a end
    if amount >= 1 then return b end
    return Color3.new(
        a.R + (b.R - a.R) * amount,
        a.G + (b.G - a.G) * amount,
        a.B + (b.B - a.B) * amount
    )
end

function ThemeEngine:lighten(color: Color3, amount: number): Color3
    return ThemeEngine.mix(color, Color3.new(1, 1, 1), amount)
end

function ThemeEngine:darken(color: Color3, amount: number): Color3
    return ThemeEngine.mix(color, Color3.new(0, 0, 0), amount)
end

return ThemeEngine
