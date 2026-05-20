--!nonstrict
-- =====================================================================
-- IDARoblox / UI / Widgets / ProgressBar
-- ---------------------------------------------------------------------
-- The loading-bar widget.
--
-- Modes:
--   * Determinate    — value in [0,1], smoothly eased on each change.
--                      Mutates the fill Instance directly through a ref
--                      so 60 fps prop updates from LoadingManager don't
--                      thrash the reconciler.
--   * Indeterminate  — value=nil; a 30%-wide marcher slides 0→1 and
--                      loops, always visible motion.
--   * Multi-segment  — `segments = {{weight,color}, ...}` paints the
--                      track in coloured regions; the fill clips to
--                      `value`, so colour transitions match phases.
--
-- Optional decorations:
--   * showPercent      — inline percentage label, monospace, RHS
--   * label            — left-aligned text inside the bar
--   * eta              — seconds; shown as a tooltip on hover
--   * striped          — diagonal animated stripes (parser-running cue)
--   * rounded          — corner radius via UICorner
--   * height           — pixel height override (default from theme)
-- =====================================================================

local Component = _G.IDARo.require("UI.Framework.Component")
local Element   = _G.IDARo.require("UI.Framework.Element")
local e         = Element.create

local ProgressBar = Component.extend("ProgressBar")

Component.setDefaultProps(ProgressBar, {
    value              = 0,                                         -- nil → indeterminate
    label              = nil,
    color              = "barFill",
    backgroundColor    = "barTrack",
    successColor       = "barFillSuccess",
    indeterminateColor = "barIndeterminate",
    segments           = nil,
    showPercent        = false,
    showLabel          = true,
    showEta            = false,
    eta                = nil,
    height             = nil,
    rounded            = true,
    striped            = false,
    indeterminate      = false,
    animateDuration    = 0.20,
    animateEasing      = "easeOutCubic",
    completeOnFull     = true,                                      -- swap to successColor at value=1
    Size               = UDim2.new(1, 0, 0, 0),
    Position           = UDim2.fromOffset(0, 0),
    LayoutOrder        = 0,
})

-- ---------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------

function ProgressBar:init(props)
    local startVal = props.value or 0
    self.state = {
        displayedValue = startVal,
        hover          = false,
    }
    self._fillRef     = nil
    self._stripesRef  = nil
    self._currentAnim = nil
    self._indetAnim   = nil
    self._stripesAnim = nil
    self._indetPos    = -0.30
end

function ProgressBar:didMount()
    if self:_isIndeterminate() then
        self:_startIndeterminate()
    else
        self:_writeFill(self.props.value or 0)
    end
    if self.props.striped then
        self:_startStripes()
    end
end

function ProgressBar:didUpdate(prevProps)
    local wasIndet = (prevProps.value == nil) or prevProps.indeterminate
    local nowIndet = self:_isIndeterminate()
    if nowIndet and not wasIndet then
        self:_cancelDeterminate()
        self:_startIndeterminate()
    elseif (not nowIndet) and wasIndet then
        self:_stopIndeterminate()
        self:_animateTo(self.props.value or 0)
    elseif not nowIndet then
        if prevProps.value ~= self.props.value then
            self:_animateTo(self.props.value or 0)
        end
    end
    if self.props.striped and not self._stripesAnim then
        self:_startStripes()
    elseif (not self.props.striped) and self._stripesAnim then
        self._stripesAnim:cancel()
        self._stripesAnim = nil
    end
end

function ProgressBar:willUnmount()
    if self._currentAnim then self._currentAnim:cancel() self._currentAnim = nil end
    if self._indetAnim   then self._indetAnim:cancel()   self._indetAnim = nil   end
    if self._stripesAnim then self._stripesAnim:cancel() self._stripesAnim = nil end
end

-- ---------------------------------------------------------------------
-- Mode detection
-- ---------------------------------------------------------------------

function ProgressBar:_isIndeterminate(): boolean
    return self.props.indeterminate or self.props.value == nil
end

-- ---------------------------------------------------------------------
-- Direct fill mutation (avoids triggering re-render every frame)
-- ---------------------------------------------------------------------

function ProgressBar:_writeFill(v: number)
    if not self._fillRef then return end
    if v < 0 then v = 0 elseif v > 1 then v = 1 end
    self.state.displayedValue = v
    local ok = pcall(function()
        self._fillRef.Size = UDim2.new(v, 0, 1, 0)
    end)
    if not ok then self._fillRef = nil end
    -- Swap color at 100%
    if self.props.completeOnFull and v >= 0.999 and self._fillRef then
        pcall(function()
            self._fillRef.BackgroundColor3 = self.theme:color(self.props.successColor)
        end)
    elseif self._fillRef and v < 0.999 then
        pcall(function()
            self._fillRef.BackgroundColor3 = self.theme:color(self.props.color)
        end)
    end
end

function ProgressBar:_animateTo(target: number)
    if not self.animator then
        self:_writeFill(target)
        return
    end
    if self._currentAnim then self._currentAnim:cancel() end
    if not self.props.animate then
        self:_writeFill(target)
        return
    end
    local from = self.state.displayedValue
    if math.abs(from - target) < 0.0005 then
        self:_writeFill(target)
        return
    end
    self._currentAnim = self.animator:valueAnim(from, target,
        self.props.animateDuration, self.props.animateEasing)
    self._currentAnim:onUpdate(function(v) self:_writeFill(v) end)
    self._currentAnim:onComplete(function() self._currentAnim = nil end)
end

function ProgressBar:_cancelDeterminate()
    if self._currentAnim then self._currentAnim:cancel() self._currentAnim = nil end
end

-- ---------------------------------------------------------------------
-- Indeterminate marcher
-- ---------------------------------------------------------------------

function ProgressBar:_startIndeterminate()
    if self._indetAnim or not self.animator then return end
    -- Cycle: pos from -0.30 → 1.00 over ~1.1s
    local function loop()
        if self._mounted ~= true then return end
        self._indetAnim = self.animator:valueAnim(-0.30, 1.00, 1.10, "easeInOutCubic")
        self._indetAnim:onUpdate(function(pos)
            if self._fillRef then
                pcall(function()
                    self._fillRef.Position = UDim2.new(pos, 0, 0, 0)
                    self._fillRef.Size     = UDim2.new(0.30, 0, 1, 0)
                    self._fillRef.BackgroundColor3 = self.theme:color(self.props.indeterminateColor)
                end)
            end
        end)
        self._indetAnim:onComplete(function()
            self._indetAnim = nil
            if self:_isIndeterminate() and self._mounted then loop() end
        end)
    end
    loop()
end

function ProgressBar:_stopIndeterminate()
    if self._indetAnim then self._indetAnim:cancel() self._indetAnim = nil end
    if self._fillRef then
        pcall(function()
            self._fillRef.Position = UDim2.fromOffset(0, 0)
            self._fillRef.BackgroundColor3 = self.theme:color(self.props.color)
        end)
    end
end

-- ---------------------------------------------------------------------
-- Striped animation (a UIGradient cycling Offset for moving stripes)
-- ---------------------------------------------------------------------

function ProgressBar:_startStripes()
    if self._stripesAnim or not self.animator then return end
    local function loop()
        if not self._mounted then return end
        self._stripesAnim = self.animator:valueAnim(0, 1, 0.8, "linear")
        self._stripesAnim:onUpdate(function(t)
            if self._stripesRef then
                pcall(function() self._stripesRef.Offset = Vector2.new(t, 0) end)
            end
        end)
        self._stripesAnim:onComplete(function()
            self._stripesAnim = nil
            if self.props.striped and self._mounted then loop() end
        end)
    end
    loop()
end

-- ---------------------------------------------------------------------
-- Render
-- ---------------------------------------------------------------------

local function buildSegmentBackdrop(theme, segments, height)
    -- Returns an array of child Frames painting the track in segment colors.
    if not segments or #segments == 0 then return {} end
    local total = 0
    for _, s in segments do total = total + (s.weight or 1) end
    if total <= 0 then return {} end
    local out, cursor = {}, 0
    for i, s in segments do
        local w = (s.weight or 1) / total
        out[i] = e("Frame", {
            key              = "seg:" .. i,
            Size             = UDim2.new(w, 0, 1, 0),
            Position         = UDim2.new(cursor, 0, 0, 0),
            BackgroundColor3 = theme:color(s.color or "barFill"),
            BackgroundTransparency = 0.55,
            BorderSizePixel  = 0,
        })
        cursor = cursor + w
    end
    return out
end

function ProgressBar:render()
    local theme = self.theme
    local height = self.props.height or theme:size("bar.height")
    local rounded = self.props.rounded
    local indet = self:_isIndeterminate()
    local pctText = ""
    if self.props.showPercent and not indet then
        pctText = string.format("%3d%%", math.floor((self.props.value or 0) * 100 + 0.5))
    elseif indet then
        pctText = ""
    end

    local size = self.props.Size
    if size.Y.Offset == 0 and size.Y.Scale == 0 then
        size = UDim2.new(size.X.Scale, size.X.Offset, 0, height)
    end

    -- Children of the outer container
    local outerChildren = {}

    -- Track
    outerChildren[#outerChildren + 1] = e("Frame", {
        key              = "track",
        Size             = UDim2.fromScale(1, 1),
        BackgroundColor3 = theme:color(self.props.backgroundColor),
        BorderSizePixel  = 0,
    }, {
        rounded and e("UICorner", { CornerRadius = UDim.new(0, math.floor(height / 2)) }),
        e("UIStroke", {
            Color = theme:color("border"),
            Thickness = 1,
            Transparency = 0.5,
            ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
        }),
    })

    -- Segment backdrop (if any) — sits between track and fill
    if self.props.segments then
        outerChildren[#outerChildren + 1] = e("Frame", {
            key              = "segments",
            Size             = UDim2.fromScale(1, 1),
            BackgroundTransparency = 1,
            ClipsDescendants = true,
        }, {
            rounded and e("UICorner", { CornerRadius = UDim.new(0, math.floor(height / 2)) }),
            Element.fragment(buildSegmentBackdrop(theme, self.props.segments, height)),
        })
    end

    -- Fill
    outerChildren[#outerChildren + 1] = e("Frame", {
        key              = "fill",
        Size             = UDim2.new(self.state.displayedValue, 0, 1, 0),
        Position         = UDim2.fromOffset(0, 0),
        BackgroundColor3 = if indet
            then theme:color(self.props.indeterminateColor)
            else theme:color(self.props.color),
        BorderSizePixel  = 0,
        ZIndex           = 2,
        [Element.Ref]    = function(inst) self._fillRef = inst end,
    }, {
        rounded and e("UICorner", { CornerRadius = UDim.new(0, math.floor(height / 2)) }),
        self.props.striped and e("UIGradient", {
            Rotation = 45,
            Transparency = NumberSequence.new({
                NumberSequenceKeypoint.new(0.0, 0.0),
                NumberSequenceKeypoint.new(0.45, 0.0),
                NumberSequenceKeypoint.new(0.45, 0.35),
                NumberSequenceKeypoint.new(0.55, 0.35),
                NumberSequenceKeypoint.new(0.55, 0.0),
                NumberSequenceKeypoint.new(1.0, 0.0),
            }),
            Offset = Vector2.new(0, 0),
            [Element.Ref] = function(inst) self._stripesRef = inst end,
        }),
    })

    -- Optional inline label + percent overlay
    local hasOverlay = (self.props.showLabel and self.props.label)
        or self.props.showPercent
    if hasOverlay then
        local overlayChildren = {}
        if self.props.label and self.props.showLabel then
            overlayChildren[#overlayChildren + 1] = e("TextLabel", {
                key              = "label",
                AnchorPoint      = Vector2.new(0, 0.5),
                Position         = UDim2.new(0, theme:spacing("sm"), 0.5, 0),
                Size             = UDim2.new(1, -theme:spacing("xxl"), 1, 0),
                Text             = self.props.label,
                Font             = Enum.Font.GothamMedium,
                TextSize         = math.max(10, height - 4),
                TextColor3       = theme:color("text"),
                TextXAlignment   = Enum.TextXAlignment.Left,
                BackgroundTransparency = 1,
                TextTruncate     = Enum.TextTruncate.AtEnd,
                ZIndex           = 5,
            })
        end
        if self.props.showPercent and pctText ~= "" then
            overlayChildren[#overlayChildren + 1] = e("TextLabel", {
                key              = "pct",
                AnchorPoint      = Vector2.new(1, 0.5),
                Position         = UDim2.new(1, -theme:spacing("sm"), 0.5, 0),
                Size             = UDim2.new(0, 48, 1, 0),
                Text             = pctText,
                Font             = Enum.Font.RobotoMono,
                TextSize         = math.max(10, height - 4),
                TextColor3       = theme:color("textMuted"),
                TextXAlignment   = Enum.TextXAlignment.Right,
                BackgroundTransparency = 1,
                ZIndex           = 5,
            })
        end
        outerChildren[#outerChildren + 1] = e("Frame", {
            key              = "overlay",
            Size             = UDim2.fromScale(1, 1),
            BackgroundTransparency = 1,
            ZIndex           = 4,
        }, overlayChildren)
    end

    return e("Frame", {
        Size              = size,
        Position          = self.props.Position,
        LayoutOrder       = self.props.LayoutOrder,
        BackgroundTransparency = 1,
        BorderSizePixel   = 0,
        ClipsDescendants  = true,
        [Element.Event.MouseEnter] = function()
            if self.state.hover then return end
            task.defer(function()
                if self.state and not self.state.hover then
                    self:setState({ hover = true })
                end
            end)
        end,
        [Element.Event.MouseLeave] = function()
            if not self.state.hover then return end
            task.defer(function()
                if self.state and self.state.hover then
                    self:setState({ hover = false })
                end
            end)
        end,
    }, outerChildren)
end

return ProgressBar
