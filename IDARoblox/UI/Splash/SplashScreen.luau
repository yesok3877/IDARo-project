--!nonstrict
-- =====================================================================
-- IDARoblox / UI / Splash / SplashScreen
-- ---------------------------------------------------------------------
-- The boot UI: a centered card with title, two progress bars (global +
-- current module), live module/stage labels, ETA, and a tail of recent
-- log entries.
--
-- Subscriptions installed in didMount():
--   * EventBus  loading.begin           → reset state
--   * EventBus  loading.module.begin    → set current module name
--   * EventBus  loading.module.progress → update module progress
--   * EventBus  loading.module.end      → mark module 100%
--   * EventBus  loading.module.error    → show error and freeze
--   * EventBus  loading.global.progress → update global + ETA + stage label
--   * EventBus  loading.end             → onComplete; fade out
--   * Logger    addSink                  → live log feed
--
-- All subscriptions are torn down in willUnmount().
-- =====================================================================

local Component  = _G.IDARo.require("UI.Framework.Component")
local Element    = _G.IDARo.require("UI.Framework.Element")
local ProgressBar = _G.IDARo.require("UI.Widgets.ProgressBar")
local e          = Element.create

local SplashScreen = Component.extend("SplashScreen")

local LOG_TAIL_SIZE = 8
local CARD_WIDTH    = 540
local CARD_HEIGHT   = 360

local LEVEL_NAMES = {
    [10] = "TRACE", [20] = "DEBUG", [30] = "INFO",
    [40] = "WARN",  [50] = "ERROR", [60] = "FATAL",
}

Component.setDefaultProps(SplashScreen, {
    title         = "IDARo",
    subtitle      = "static & runtime analysis for Roblox Luau",
    versionString = "v1.0",
    onComplete    = nil,
    autoFade      = true,
    fadeDuration  = 0.45,
})

-- ---------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------

function SplashScreen:init(props)
    self.state = {
        globalProgress = 0,
        moduleProgress = 0,
        currentModule  = nil,
        currentStage   = nil,
        stageLabel     = nil,
        etaSec         = -1,
        elapsedSec     = 0,
        moduleIndex    = 0,
        totalModules   = 0,
        booted         = false,
        failed         = false,
        errorMsg       = nil,
        logTail        = {},
        rootTransparency = 1.0,
        cardTransparency = 1.0,
    }
    self._subs = {}
    self._logSinkRemover = nil
    self._fadeAnim = nil
end

function SplashScreen:didMount()
    self:_subscribe()
    self:_fadeIn()
end

function SplashScreen:willUnmount()
    for _, sub in self._subs do
        if type(sub) == "table" and sub.disconnect then sub:disconnect() end
    end
    self._subs = {}
    if self._logSinkRemover then self._logSinkRemover() self._logSinkRemover = nil end
    if self._fadeAnim then self._fadeAnim:cancel() self._fadeAnim = nil end
end

-- ---------------------------------------------------------------------
-- Event subscriptions
-- ---------------------------------------------------------------------

function SplashScreen:_subscribe()
    local bus = self.eventBus
    if not bus then return end

    table.insert(self._subs, bus:on("loading.begin", function(_, payload)
        self:setState({
            totalModules   = payload and payload.totalModules or 0,
            moduleIndex    = 0,
            globalProgress = 0,
            moduleProgress = 0,
            booted         = false,
            failed         = false,
            errorMsg       = nil,
        })
    end))

    table.insert(self._subs, bus:on("loading.module.begin", function(_, payload)
        self:setState({
            currentModule  = payload.id,
            currentStage   = nil,
            stageLabel     = nil,
            moduleIndex    = payload.index or self.state.moduleIndex,
            totalModules   = payload.total  or self.state.totalModules,
            moduleProgress = 0,
        })
    end))

    table.insert(self._subs, bus:on("loading.module.progress", function(_, payload)
        if payload.id ~= self.state.currentModule then return end
        self:setState({
            moduleProgress = payload.progress or 0,
            currentStage   = payload.stageId or self.state.currentStage,
            stageLabel     = payload.label or self.state.stageLabel,
        })
    end))

    table.insert(self._subs, bus:on("loading.module.end", function(_, payload)
        if payload.id ~= self.state.currentModule then
            self:setState({ moduleProgress = 1 })
        else
            self:setState({ moduleProgress = 1 })
        end
    end))

    table.insert(self._subs, bus:on("loading.module.error", function(_, payload)
        self:setState({
            failed   = true,
            errorMsg = string.format("%s in stage '%s': %s",
                payload.id, payload.stageId or "?", tostring(payload.error)),
        })
    end))

    table.insert(self._subs, bus:on("loading.global.progress", function(_, payload)
        self:setState({
            globalProgress = payload.progress or 0,
            etaSec         = payload.etaSec or -1,
            elapsedSec     = payload.elapsedSec or 0,
            currentModule  = payload.currentModule or self.state.currentModule,
            currentStage   = payload.currentStage or self.state.currentStage,
            stageLabel     = payload.stageLabel or self.state.stageLabel,
        })
    end))

    table.insert(self._subs, bus:on("loading.end", function(_, payload)
        local fellOver = payload and payload.failed and payload.failed > 0
        self:setState({
            booted         = not fellOver,
            failed         = fellOver or false,
            globalProgress = if fellOver then self.state.globalProgress else 1,
            moduleProgress = if fellOver then self.state.moduleProgress else 1,
        })
        if not fellOver then
            if self.props.autoFade then
                task.delay(0.45, function()
                    if self._mounted then self:_fadeOut() end
                end)
            end
            if self.props.onComplete then pcall(self.props.onComplete) end
        end
    end))

    -- Log sink: append records to the tail
    if self.logger then
        self._logSinkRemover = self.logger:addSink(function(rec)
            -- Coalesce log entries on the main thread
            task.defer(function()
                if not self._mounted then return end
                local tail = table.create(LOG_TAIL_SIZE)
                local oldTail = self.state.logTail
                local start = math.max(1, #oldTail - LOG_TAIL_SIZE + 2)
                for i = start, #oldTail do tail[#tail + 1] = oldTail[i] end
                tail[#tail + 1] = rec
                self:setState({ logTail = tail })
            end)
        end)
    end
end

-- ---------------------------------------------------------------------
-- Fade
-- ---------------------------------------------------------------------

function SplashScreen:_fadeIn()
    if not self.animator then
        self:setState({ rootTransparency = 0, cardTransparency = 0 })
        return
    end
    if self._fadeAnim then self._fadeAnim:cancel() end
    local fade = self.animator:valueAnim(1, 0, self.props.fadeDuration, "easeOutCubic")
    fade:onUpdate(function(v)
        if self._mounted then
            self:setState({ rootTransparency = v * 0.10, cardTransparency = v })
        end
    end)
    self._fadeAnim = fade
end

function SplashScreen:_fadeOut()
    if not self.animator then
        if self.props.onComplete then pcall(self.props.onComplete) end
        return
    end
    if self._fadeAnim then self._fadeAnim:cancel() end
    local fade = self.animator:valueAnim(0, 1, self.props.fadeDuration, "easeInCubic")
    fade:onUpdate(function(v)
        if self._mounted then
            self:setState({ rootTransparency = v * 0.10 + (1 - 0.10) * v, cardTransparency = v })
        end
    end)
    fade:onComplete(function()
        if self.props.onHidden then pcall(self.props.onHidden) end
    end)
    self._fadeAnim = fade
end

-- ---------------------------------------------------------------------
-- Render helpers
-- ---------------------------------------------------------------------

local function formatEta(sec: number): string
    if sec < 0 then return "—" end
    if sec < 1 then return string.format("%.0f ms", sec * 1000) end
    if sec < 60 then return string.format("%.1f s", sec) end
    local m = math.floor(sec / 60)
    local s = sec - m * 60
    return string.format("%dm %.0fs", m, s)
end

local function formatElapsed(sec: number): string
    if sec < 60 then return string.format("%.1fs", sec) end
    local m = math.floor(sec / 60)
    return string.format("%dm %.0fs", m, sec - m * 60)
end

function SplashScreen:_renderLogTail()
    local theme = self.theme
    local lines = {}
    for i, rec in self.state.logTail do
        local levelColor = theme:color("textMuted")
        if rec.level == 40 then levelColor = theme:color("warning")
        elseif rec.level >= 50 then levelColor = theme:color("danger")
        elseif rec.level == 30 then levelColor = theme:color("textMuted")
        elseif rec.level <= 20 then levelColor = theme:color("textSubtle")
        end
        local levelText = LEVEL_NAMES[rec.level] or "?"
        lines[i] = e("Frame", {
            key              = "log:" .. i,
            Size             = UDim2.new(1, 0, 0, 14),
            BackgroundTransparency = 1,
            LayoutOrder      = i,
        }, {
            e("TextLabel", {
                key              = "level",
                Size             = UDim2.fromOffset(46, 14),
                Position         = UDim2.fromOffset(0, 0),
                Text             = levelText,
                Font             = Enum.Font.RobotoMono,
                TextSize         = 11,
                TextColor3       = levelColor,
                TextXAlignment   = Enum.TextXAlignment.Left,
                BackgroundTransparency = 1,
            }),
            e("TextLabel", {
                key              = "tag",
                Size             = UDim2.fromOffset(170, 14),
                Position         = UDim2.fromOffset(50, 0),
                Text             = rec.tag,
                Font             = Enum.Font.RobotoMono,
                TextSize         = 11,
                TextColor3       = theme:color("textSubtle"),
                TextXAlignment   = Enum.TextXAlignment.Left,
                TextTruncate     = Enum.TextTruncate.AtEnd,
                BackgroundTransparency = 1,
            }),
            e("TextLabel", {
                key              = "msg",
                Size             = UDim2.new(1, -230, 0, 14),
                Position         = UDim2.fromOffset(226, 0),
                Text             = rec.message,
                Font             = Enum.Font.RobotoMono,
                TextSize         = 11,
                TextColor3       = theme:color("textMuted"),
                TextXAlignment   = Enum.TextXAlignment.Left,
                TextTruncate     = Enum.TextTruncate.AtEnd,
                BackgroundTransparency = 1,
            }),
        })
    end
    return e("Frame", {
        Size              = UDim2.new(1, 0, 0, LOG_TAIL_SIZE * 14),
        BackgroundTransparency = 1,
    }, {
        e("UIListLayout", {
            FillDirection = Enum.FillDirection.Vertical,
            SortOrder     = Enum.SortOrder.LayoutOrder,
            Padding       = UDim.new(0, 0),
        }),
        Element.fragment(lines),
    })
end

-- ---------------------------------------------------------------------
-- Render
-- ---------------------------------------------------------------------

function SplashScreen:render()
    local theme = self.theme
    local rootTrans = self.state.rootTransparency

    local moduleLine = self.state.currentModule or "preparing…"
    local stageLine  = self.state.stageLabel
        or self.state.currentStage
        or (if self.state.totalModules > 0
            then string.format("module %d of %d", self.state.moduleIndex, self.state.totalModules)
            else "")

    local etaText
    if self.state.failed then
        etaText = "failed"
    elseif self.state.booted then
        etaText = string.format("ready in %s", formatElapsed(self.state.elapsedSec))
    else
        etaText = string.format("ETA %s · elapsed %s",
            formatEta(self.state.etaSec), formatElapsed(self.state.elapsedSec))
    end

    -- Outer dimmer + centered card
    return e("Frame", {
        key                    = "splash.root",
        Size                   = UDim2.fromScale(1, 1),
        BackgroundColor3       = theme:color("background"),
        BackgroundTransparency = rootTrans,
        BorderSizePixel        = 0,
        ZIndex                 = 100,
    }, {
        -- Centered card
        e("Frame", {
            key                    = "splash.card",
            AnchorPoint            = Vector2.new(0.5, 0.5),
            Position               = UDim2.fromScale(0.5, 0.5),
            Size                   = UDim2.fromOffset(CARD_WIDTH, CARD_HEIGHT),
            BackgroundColor3       = theme:color("surface"),
            BackgroundTransparency = self.state.cardTransparency,
            BorderSizePixel        = 0,
            ZIndex                 = 101,
        }, {
            e("UICorner", { CornerRadius = UDim.new(0, theme:radius("lg")) }),
            e("UIStroke", {
                Color = theme:color("border"),
                Thickness = 1,
                Transparency = self.state.cardTransparency,
            }),
            e("UIPadding", {
                PaddingTop    = UDim.new(0, theme:spacing("xl")),
                PaddingBottom = UDim.new(0, theme:spacing("xl")),
                PaddingLeft   = UDim.new(0, theme:spacing("xl")),
                PaddingRight  = UDim.new(0, theme:spacing("xl")),
            }),

            -- Header (title + version)
            e("TextLabel", {
                key            = "title",
                Size           = UDim2.new(1, 0, 0, 32),
                Text           = self.props.title,
                Font           = Enum.Font.GothamBold,
                TextSize       = 26,
                TextColor3     = theme:color("text"),
                TextXAlignment = Enum.TextXAlignment.Left,
                BackgroundTransparency = 1,
                ZIndex         = 102,
            }),
            e("TextLabel", {
                key            = "version",
                AnchorPoint    = Vector2.new(1, 0),
                Position       = UDim2.new(1, 0, 0, 6),
                Size           = UDim2.fromOffset(120, 18),
                Text           = self.props.versionString,
                Font           = Enum.Font.RobotoMono,
                TextSize       = 12,
                TextColor3     = theme:color("textSubtle"),
                TextXAlignment = Enum.TextXAlignment.Right,
                BackgroundTransparency = 1,
                ZIndex         = 102,
            }),
            e("TextLabel", {
                key            = "subtitle",
                Position       = UDim2.fromOffset(0, 32),
                Size           = UDim2.new(1, 0, 0, 16),
                Text           = self.props.subtitle,
                Font           = Enum.Font.Gotham,
                TextSize       = 12,
                TextColor3     = theme:color("textMuted"),
                TextXAlignment = Enum.TextXAlignment.Left,
                BackgroundTransparency = 1,
                ZIndex         = 102,
            }),

            -- Global progress
            e("Frame", {
                key                    = "globalLabel",
                Position               = UDim2.fromOffset(0, 70),
                Size                   = UDim2.new(1, 0, 0, 16),
                BackgroundTransparency = 1,
                ZIndex                 = 102,
            }, {
                e("TextLabel", {
                    Size           = UDim2.new(1, -160, 1, 0),
                    Text           = "loading",
                    Font           = Enum.Font.GothamMedium,
                    TextSize       = 11,
                    TextColor3     = theme:color("textMuted"),
                    TextXAlignment = Enum.TextXAlignment.Left,
                    BackgroundTransparency = 1,
                }),
                e("TextLabel", {
                    AnchorPoint    = Vector2.new(1, 0),
                    Position       = UDim2.new(1, 0, 0, 0),
                    Size           = UDim2.fromOffset(160, 16),
                    Text           = etaText,
                    Font           = Enum.Font.RobotoMono,
                    TextSize       = 11,
                    TextColor3     = if self.state.failed then theme:color("danger") else theme:color("textSubtle"),
                    TextXAlignment = Enum.TextXAlignment.Right,
                    BackgroundTransparency = 1,
                }),
            }),
            e(ProgressBar, {
                key             = "globalBar",
                Position        = UDim2.fromOffset(0, 90),
                Size            = UDim2.new(1, 0, 0, 14),
                value           = self.state.globalProgress,
                showPercent     = true,
                rounded         = true,
                height          = 14,
                striped         = not self.state.booted and not self.state.failed,
                animateDuration = 0.25,
            }),

            -- Current module
            e("TextLabel", {
                key            = "moduleName",
                Position       = UDim2.fromOffset(0, 124),
                Size           = UDim2.new(1, 0, 0, 16),
                Text           = moduleLine,
                Font           = Enum.Font.GothamMedium,
                TextSize       = 13,
                TextColor3     = theme:color("text"),
                TextXAlignment = Enum.TextXAlignment.Left,
                BackgroundTransparency = 1,
                ZIndex         = 102,
            }),
            e("TextLabel", {
                key            = "stageLabel",
                Position       = UDim2.fromOffset(0, 142),
                Size           = UDim2.new(1, 0, 0, 14),
                Text           = stageLine,
                Font           = Enum.Font.RobotoMono,
                TextSize       = 11,
                TextColor3     = theme:color("textMuted"),
                TextXAlignment = Enum.TextXAlignment.Left,
                TextTruncate   = Enum.TextTruncate.AtEnd,
                BackgroundTransparency = 1,
                ZIndex         = 102,
            }),
            e(ProgressBar, {
                key             = "moduleBar",
                Position        = UDim2.fromOffset(0, 162),
                Size            = UDim2.new(1, 0, 0, 10),
                value           = self.state.moduleProgress,
                color           = "primary",
                rounded         = true,
                height          = 10,
                animateDuration = 0.18,
            }),

            -- Divider above log
            e("Frame", {
                key              = "logDivider",
                Position         = UDim2.fromOffset(0, 184),
                Size             = UDim2.new(1, 0, 0, 1),
                BackgroundColor3 = theme:color("divider"),
                BorderSizePixel  = 0,
                ZIndex           = 102,
            }),

            -- Log tail
            e("Frame", {
                key                    = "logFrame",
                Position               = UDim2.fromOffset(0, 192),
                Size                   = UDim2.new(1, 0, 0, LOG_TAIL_SIZE * 14 + 4),
                BackgroundTransparency = 1,
                ClipsDescendants       = true,
                ZIndex                 = 102,
            }, { self:_renderLogTail() }),

            -- Failure overlay
            self.state.failed and e("Frame", {
                key                    = "failOverlay",
                AnchorPoint            = Vector2.new(0, 1),
                Position               = UDim2.new(0, 0, 1, 0),
                Size                   = UDim2.new(1, 0, 0, 36),
                BackgroundColor3       = theme:color("danger"),
                BackgroundTransparency = 0.8,
                BorderSizePixel        = 0,
                ZIndex                 = 110,
            }, {
                e("UICorner", { CornerRadius = UDim.new(0, theme:radius("md")) }),
                e("TextLabel", {
                    Size           = UDim2.fromScale(1, 1),
                    Text           = self.state.errorMsg or "loading failed",
                    Font           = Enum.Font.GothamMedium,
                    TextSize       = 12,
                    TextColor3     = theme:color("text"),
                    BackgroundTransparency = 1,
                    TextTruncate   = Enum.TextTruncate.AtEnd,
                }),
            }),
        }),
    })
end

return SplashScreen
