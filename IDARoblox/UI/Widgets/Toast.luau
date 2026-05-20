--!nonstrict
-- =====================================================================
-- IDARoblox / UI / Widgets / Toast
-- ---------------------------------------------------------------------
-- Transient notification popups. Two components:
--
--   * Toast       — single notification element (rendered by ToastHost)
--   * ToastHost   — container that owns the queue + lifecycle
--
-- Toast props
--   id            unique id
--   kind          "info" | "success" | "warn" | "error"
--   text          message body
--   actionLabel   optional button label
--   onAction      fn() — clicked
--   onDismiss     fn() — called by host when fully out
--
-- ToastHost API
--   :show({ kind, text, duration, actionLabel, onAction }) → id
--   :dismiss(id)
--   :clear()
-- =====================================================================

local Component   = _G.IDARo.require("UI.Framework.Component")
local Element     = _G.IDARo.require("UI.Framework.Element")
local TweenService = game:GetService("TweenService")
local e = Element.create
local Event = Element.Event

local KIND_COLORS = {
    info    = { bg = "toastInfoBg",    fg = "toastInfoFg",    accent = "toastInfoAccent"  },
    success = { bg = "toastSuccessBg", fg = "toastSuccessFg", accent = "toastSuccessAccent" },
    warn    = { bg = "toastWarnBg",    fg = "toastWarnFg",    accent = "toastWarnAccent" },
    error   = { bg = "toastErrorBg",   fg = "toastErrorFg",   accent = "toastErrorAccent" },
}

-- ---------------------------------------------------------------------
-- Toast (single)
-- ---------------------------------------------------------------------

local Toast = Component.extend("Toast")

Component.setDefaultProps(Toast, {
    id          = "",
    kind        = "info",
    text        = "",
    actionLabel = nil,
    onAction    = nil,
    onDismiss   = nil,
    duration    = 4,
})

function Toast:init()
    self.state = { hovering = false, opacity = 0 }
    self._timer = nil
end

function Toast:didMount()
    -- Fade in
    if self._frameRef then
        TweenService:Create(self._frameRef,
            TweenInfo.new(0.18, Enum.EasingStyle.Quad),
            { BackgroundTransparency = 0.05 }
        ):Play()
    end
    self._timer = task.delay(self.props.duration, function()
        if not self.state.hovering and self._mounted ~= false then self:_beginDismiss() end
    end)
end

function Toast:willUnmount()
    self._mounted = false
    if self._timer then task.cancel(self._timer) end
end

function Toast:_beginDismiss()
    if self._frameRef then
        local t = TweenService:Create(self._frameRef,
            TweenInfo.new(0.16, Enum.EasingStyle.Quad),
            { BackgroundTransparency = 1 })
        t.Completed:Connect(function()
            if self.props.onDismiss then self.props.onDismiss(self.props.id) end
        end)
        t:Play()
    elseif self.props.onDismiss then
        self.props.onDismiss(self.props.id)
    end
end

function Toast:render()
    local theme = self.theme
    local kindMap = KIND_COLORS[self.props.kind] or KIND_COLORS.info
    local children = {
        -- Accent strip
        e("Frame", {
            Size = UDim2.new(0, 3, 1, 0),
            BackgroundColor3 = theme:color(kindMap.accent),
            BorderSizePixel = 0,
        }),
        -- Text
        e("TextLabel", {
            Size = UDim2.new(1, -16 - (self.props.actionLabel and 90 or 0), 1, 0),
            Position = UDim2.new(0, 10, 0, 0),
            Text = self.props.text,
            Font = Enum.Font.SourceSans,
            TextSize = 14,
            TextColor3 = theme:color(kindMap.fg),
            TextXAlignment = Enum.TextXAlignment.Left,
            TextWrapped = true,
            BackgroundTransparency = 1,
        }),
    }
    if self.props.actionLabel then
        children[#children + 1] = e("TextButton", {
            Size = UDim2.new(0, 80, 0, 22),
            Position = UDim2.new(1, -86, 0.5, -11),
            Text = self.props.actionLabel,
            Font = Enum.Font.SourceSansBold,
            TextSize = 12,
            TextColor3 = theme:color(kindMap.accent),
            BackgroundColor3 = theme:color("transparent"),
            BackgroundTransparency = 0.7,
            BorderSizePixel = 0,
            [Event "Activated"] = function()
                if self.props.onAction then self.props.onAction() end
                self:_beginDismiss()
            end,
        })
    end
    return e("Frame", {
        Size = UDim2.new(1, 0, 0, 44),
        BackgroundColor3 = theme:color(kindMap.bg),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        [Element.Ref] = function(rbx) self._frameRef = rbx end,
        [Event "MouseEnter"] = function() self:setState({ hovering = true }) end,
        [Event "MouseLeave"] = function() self:setState({ hovering = false }) end,
    }, children)
end

-- ---------------------------------------------------------------------
-- ToastHost (container)
-- ---------------------------------------------------------------------

local ToastHost = Component.extend("ToastHost")

Component.setDefaultProps(ToastHost, {
    position = "bottom-right",                                       -- "top-right" | "bottom-right" | "bottom-left" | "top-left"
    maxToasts = 8,
})

function ToastHost:init()
    self.state = { toasts = {} }
    self._nextId = 1
end

function ToastHost:show(opts)
    opts = opts or {}
    local id = "toast-" .. tostring(self._nextId)
    self._nextId = self._nextId + 1
    local t = {
        id          = id,
        kind        = opts.kind or "info",
        text        = opts.text or "",
        duration    = opts.duration or 4,
        actionLabel = opts.actionLabel,
        onAction    = opts.onAction,
    }
    local list = {}
    for _, v in self.state.toasts do list[#list + 1] = v end
    list[#list + 1] = t
    -- Cap at maxToasts
    while #list > self.props.maxToasts do table.remove(list, 1) end
    self:setState({ toasts = list })
    return id
end

function ToastHost:dismiss(id)
    local list = {}
    for _, v in self.state.toasts do
        if v.id ~= id then list[#list + 1] = v end
    end
    self:setState({ toasts = list })
end

function ToastHost:clear() self:setState({ toasts = {} }) end

function ToastHost:render()
    local pos = self.props.position
    local children = { e("UIListLayout", {
        FillDirection = Enum.FillDirection.Vertical,
        SortOrder = Enum.SortOrder.LayoutOrder,
        Padding = UDim.new(0, 6),
        VerticalAlignment = (pos == "bottom-left" or pos == "bottom-right")
            and Enum.VerticalAlignment.Bottom or Enum.VerticalAlignment.Top,
    }) }
    for i, t in self.state.toasts do
        children[#children + 1] = Element.withKey(t.id, e(Toast, {
            id = t.id, kind = t.kind, text = t.text,
            duration = t.duration,
            actionLabel = t.actionLabel, onAction = t.onAction,
            onDismiss = function(id) self:dismiss(id) end,
            LayoutOrder = i,
        }))
    end

    -- Anchor in chosen corner
    local anchor = UDim2.new(1, -12, 1, -12)
    local size   = UDim2.new(0, 360, 0, 0)
    if pos == "top-right" then anchor = UDim2.new(1, -12, 0, 12)
    elseif pos == "top-left" then anchor = UDim2.new(0, 12, 0, 12)
    elseif pos == "bottom-left" then anchor = UDim2.new(0, 12, 1, -12) end

    return e("Frame", {
        Size = size,
        Position = anchor,
        AnchorPoint = (pos == "bottom-right" or pos == "top-right")
            and Vector2.new(1, (pos == "bottom-right") and 1 or 0)
            or Vector2.new(0, (pos == "bottom-left") and 1 or 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ZIndex = 4000,
    }, children)
end

return {
    Toast     = Toast,
    ToastHost = ToastHost,
}
