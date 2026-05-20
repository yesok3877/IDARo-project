--!nonstrict
-- =====================================================================
-- IDARoblox / UI / Views / HooksView
-- ---------------------------------------------------------------------
-- Live runtime-introspection panel.
--
-- Two display modes toggled via header buttons:
--
--   "hooks"    Active hooks list: every record from
--              runtime.hooks:listAll() with an Uninstall button per row.
--              Polls runtime.hooks every 2s while visible so call counts
--              update in near-real-time.
--
--   "registry" Function-registry browser: every entry from
--              runtime.fns:entries() with a Hook button per row that
--              installs a counter hook with a sensible auto-label.
--
-- The header always shows the Scan button (re-scans scripts + functions
-- via runtime.scripts:scan() then runtime.fns:scan()) and a capability
-- warning when hookfunction is unavailable (Studio plugin sandbox,
-- some restricted executors).
--
-- Props:
--   runtime — Runtime services bundle from Runtime.new()
-- =====================================================================

local Component         = _G.IDARo.require("UI.Framework.Component")
local Element           = _G.IDARo.require("UI.Framework.Element")
local ScrollVirtualizer = _G.IDARo.require("UI.Framework.ScrollVirtualizer")
local e                 = Element.create
local Event             = Element.Event

local HooksView = Component.extend("HooksView")

Component.setDefaultProps(HooksView, {
    runtime  = nil,
    Size     = UDim2.fromScale(1, 1),
    Position = UDim2.fromOffset(0, 0),
})

local ROW_HEIGHT = 22
local HEADER_H   = 32
local FOOTER_H   = 20
local HEARTBEAT_INTERVAL = 2.0

-- ---------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------

local function truncate(s, n)
    if type(s) ~= "string" then return tostring(s) end
    n = n or 48
    if #s > n then return string.sub(s, 1, n - 1) .. "…" end
    return s
end

local function kindBadgeColor(theme, kind)
    if kind == "counter" then return theme:color("disassemblyOperand")
    elseif kind == "logger"  then return theme:color("primary")
    elseif kind == "print"   then return theme:color("syntaxKeyword")
    elseif kind == "return"  then return theme:color("danger")
    end
    return theme:color("textMuted")
end

-- ---------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------

function HooksView:init(props)
    self.state = {
        mode      = "hooks",
        hooks     = {},
        registry  = {},
        scanning  = false,
        scanInfo  = nil,
    }
    self:_pull(props)
end

function HooksView:didMount()
    self._mounted = true
    self:_pull()
    -- Periodic heartbeat to refresh call counts while hooks view is open.
    task.spawn(function()
        while self._mounted do
            task.wait(HEARTBEAT_INTERVAL)
            if self._mounted and self.state.mode == "hooks" and self.props.runtime then
                self.state.hooks = self.props.runtime.hooks:listAll()
                self:setState({})
            end
        end
    end)
end

function HooksView:willUnmount()
    self._mounted = false
end

function HooksView:_pull(props)
    props = props or self.props
    if not props.runtime then
        self.state.hooks    = {}
        self.state.registry = {}
        return
    end
    self.state.hooks    = props.runtime.hooks:listAll() or {}
    self.state.registry = props.runtime.fns:entries()  or {}
end

-- ---------------------------------------------------------------------
-- Actions
-- ---------------------------------------------------------------------

function HooksView:_runScan()
    if not self.props.runtime or self.state.scanning then return end
    self.state.scanning = true
    self:setState({})
    task.spawn(function()
        local scriptDelta = self.props.runtime.scripts:scan()
        local fnDelta     = self.props.runtime.fns:scan()
        self.state.scanInfo = {
            scripts = scriptDelta,
            fns     = fnDelta,
            at      = os.clock(),
        }
        self:_pull()
        self.state.scanning = false
        self:setState({})
    end)
end

function HooksView:_uninstall(hookId)
    if not self.props.runtime then return end
    local ok, err = self.props.runtime.hooks:uninstall(hookId)
    if not ok and self.logger then
        self.logger:warn("HooksView: uninstall failed: %s", tostring(err))
    end
    self:_pull()
    self:setState({})
end

function HooksView:_installCounter(entry)
    if not self.props.runtime or not entry or not entry.fn then return end
    local label = entry.name
        or (entry.source and ("fn@" .. truncate(entry.source, 40)))
        or string.format("fn#%d", entry.id)
    local record, err = self.props.runtime.hooks:installCounter(entry.fn, {
        label       = label,
        sourceLabel = entry.source,
    })
    if not record and self.logger then
        self.logger:warn("HooksView: hook install failed: %s", tostring(err))
    end
    self:_pull()
    -- Auto-flip to hooks mode so the user immediately sees their new hook.
    self.state.mode = "hooks"
    self:setState({})
end

function HooksView:_setMode(mode)
    self.state.mode = mode
    self:setState({})
end

-- ---------------------------------------------------------------------
-- Header rendering
-- ---------------------------------------------------------------------

function HooksView:_renderHeader()
    local theme = self.theme
    local rt   = self.props.runtime
    local caps = rt and rt.scanner:capabilities()
    local hasHookFn = caps and caps.hookfunction ~= nil

    local function modeBtn(id, label, layoutOrder)
        local active = self.state.mode == id
        return e("TextButton", {
            key              = "mode:" .. id,
            Size             = UDim2.fromOffset(140, HEADER_H - 12),
            Text             = label,
            Font             = active and Enum.Font.GothamMedium or Enum.Font.Gotham,
            TextSize         = theme:size("font.ui") - 1,
            TextColor3       = active and theme:color("text") or theme:color("textMuted"),
            BackgroundColor3 = active and theme:color("primaryMuted") or theme:color("surface"),
            BorderSizePixel  = 0,
            AutoButtonColor  = false,
            LayoutOrder      = layoutOrder,
            [Event.Activated] = function() self:_setMode(id) end,
        }, {
            e("UICorner", { CornerRadius = UDim.new(0, theme:radius("sm")) }),
        })
    end

    return e("Frame", {
        Size             = UDim2.new(1, 0, 0, HEADER_H),
        BackgroundColor3 = theme:color("surfaceAlt"),
        BorderSizePixel  = 0,
    }, {
        e("UIPadding", {
            PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8),
            PaddingTop  = UDim.new(0, 6), PaddingBottom = UDim.new(0, 6),
        }),
        e("UIListLayout", {
            FillDirection     = Enum.FillDirection.Horizontal,
            VerticalAlignment = Enum.VerticalAlignment.Center,
            SortOrder         = Enum.SortOrder.LayoutOrder,
            Padding           = UDim.new(0, 6),
        }),
        modeBtn("hooks",    string.format("Active Hooks (%d)", #self.state.hooks),    1),
        modeBtn("registry", string.format("Registry (%d)",      #self.state.registry), 2),
        -- Scan
        e("TextButton", {
            key              = "scan",
            Size             = UDim2.fromOffset(90, HEADER_H - 12),
            Text             = self.state.scanning and "scanning…" or "▶ Scan env",
            Font             = Enum.Font.GothamMedium,
            TextSize         = theme:size("font.ui") - 1,
            TextColor3       = theme:color("text"),
            BackgroundColor3 = theme:color("primary"),
            BorderSizePixel  = 0,
            AutoButtonColor  = false,
            LayoutOrder      = 3,
            [Event.Activated] = function()
                if not self.state.scanning then self:_runScan() end
            end,
        }, {
            e("UICorner", { CornerRadius = UDim.new(0, theme:radius("sm")) }),
        }),
        -- Refresh
        e("TextButton", {
            key              = "refresh",
            Size             = UDim2.fromOffset(80, HEADER_H - 12),
            Text             = "↻ Refresh",
            Font             = Enum.Font.Gotham,
            TextSize         = theme:size("font.ui") - 1,
            TextColor3       = theme:color("textMuted"),
            BackgroundColor3 = theme:color("surface"),
            BorderSizePixel  = 0,
            AutoButtonColor  = false,
            LayoutOrder      = 4,
            [Event.Activated] = function() self:_pull(); self:setState({}) end,
        }, {
            e("UICorner", { CornerRadius = UDim.new(0, theme:radius("sm")) }),
        }),
        -- Capability warning
        not hasHookFn and e("TextLabel", {
            key              = "warn",
            Size             = UDim2.fromOffset(240, HEADER_H - 12),
            Text             = "⚠ hookfunction unavailable",
            Font             = Enum.Font.GothamMedium,
            TextSize         = theme:size("font.ui") - 2,
            TextColor3       = theme:color("danger"),
            TextXAlignment   = Enum.TextXAlignment.Left,
            BackgroundTransparency = 1,
            LayoutOrder      = 5,
        }),
    })
end

-- ---------------------------------------------------------------------
-- Active-hook row
-- ---------------------------------------------------------------------

function HooksView:_renderHookRow(hook, _idx, isOdd)
    local theme = self.theme
    local bg = isOdd and theme:color("disassemblyRowOdd") or theme:color("disassemblyRowEven")
    if not hook.active then bg = theme:color("surface") end
    local kindColor = kindBadgeColor(theme, hook.kind)

    return e("Frame", {
        Size             = UDim2.new(1, 0, 1, 0),
        BackgroundColor3 = bg,
        BorderSizePixel  = 0,
    }, {
        e("TextLabel", {
            key = "id", Position = UDim2.fromOffset(8, 0),
            Size = UDim2.fromOffset(40, ROW_HEIGHT),
            Text = string.format("#%d", hook.id),
            Font = Enum.Font.RobotoMono,
            TextSize = theme:size("font.mono") - 1,
            TextColor3 = theme:color("disassemblyAddr"),
            TextXAlignment = Enum.TextXAlignment.Right,
            BackgroundTransparency = 1,
        }),
        e("TextLabel", {
            key = "kind", Position = UDim2.fromOffset(56, 0),
            Size = UDim2.fromOffset(64, ROW_HEIGHT),
            Text = "[" .. (hook.kind or "?") .. "]",
            Font = Enum.Font.RobotoMono,
            TextSize = theme:size("font.mono") - 1,
            TextColor3 = kindColor,
            TextXAlignment = Enum.TextXAlignment.Left,
            BackgroundTransparency = 1,
        }),
        e("TextLabel", {
            key = "label", Position = UDim2.fromOffset(126, 0),
            Size = UDim2.new(0.45, -130, 0, ROW_HEIGHT),
            Text = hook.label or "?",
            Font = Enum.Font.RobotoMono,
            TextSize = theme:size("font.mono"),
            TextColor3 = theme:color("text"),
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd,
            BackgroundTransparency = 1,
        }),
        e("TextLabel", {
            key = "calls", Position = UDim2.new(0.45, 0, 0, 0),
            Size = UDim2.fromOffset(70, ROW_HEIGHT),
            Text = string.format("%d×", hook.callCount or 0),
            Font = Enum.Font.RobotoMono,
            TextSize = theme:size("font.mono") - 1,
            TextColor3 = (hook.callCount or 0) > 0
                and theme:color("disassemblyOperand") or theme:color("textSubtle"),
            TextXAlignment = Enum.TextXAlignment.Right,
            BackgroundTransparency = 1,
        }),
        e("TextLabel", {
            key = "errors", Position = UDim2.new(0.45, 76, 0, 0),
            Size = UDim2.fromOffset(80, ROW_HEIGHT),
            Text = (hook.errorCount or 0) > 0
                and string.format("err: %d", hook.errorCount) or "",
            Font = Enum.Font.RobotoMono,
            TextSize = theme:size("font.mono") - 1,
            TextColor3 = theme:color("danger"),
            TextXAlignment = Enum.TextXAlignment.Left,
            BackgroundTransparency = 1,
        }),
        e("TextLabel", {
            key = "source", Position = UDim2.new(0.45, 162, 0, 0),
            Size = UDim2.new(0.55, -260, 0, ROW_HEIGHT),
            Text = truncate(hook.sourceLabel or "—", 60),
            Font = Enum.Font.RobotoMono,
            TextSize = theme:size("font.mono") - 1,
            TextColor3 = theme:color("textSubtle"),
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd,
            BackgroundTransparency = 1,
        }),
        hook.active and e("TextButton", {
            key = "uninstall",
            AnchorPoint = Vector2.new(1, 0.5),
            Position = UDim2.new(1, -6, 0.5, 0),
            Size = UDim2.fromOffset(86, ROW_HEIGHT - 4),
            Text = "✕ Uninstall",
            Font = Enum.Font.GothamMedium,
            TextSize = theme:size("font.ui") - 2,
            TextColor3 = theme:color("text"),
            BackgroundColor3 = theme:color("danger"),
            BorderSizePixel = 0,
            AutoButtonColor = false,
            [Event.Activated] = function() self:_uninstall(hook.id) end,
        }, {
            e("UICorner", { CornerRadius = UDim.new(0, theme:radius("sm")) }),
        }) or e("TextLabel", {
            key = "inactive",
            AnchorPoint = Vector2.new(1, 0.5),
            Position = UDim2.new(1, -8, 0.5, 0),
            Size = UDim2.fromOffset(86, ROW_HEIGHT - 4),
            Text = "(inactive)",
            Font = Enum.Font.Gotham,
            TextSize = theme:size("font.ui") - 2,
            TextColor3 = theme:color("textSubtle"),
            TextXAlignment = Enum.TextXAlignment.Center,
            BackgroundTransparency = 1,
        }),
    })
end

-- ---------------------------------------------------------------------
-- Registry row
-- ---------------------------------------------------------------------

function HooksView:_renderRegistryRow(entry, _idx, isOdd)
    local theme = self.theme
    local bg = isOdd and theme:color("disassemblyRowOdd") or theme:color("disassemblyRowEven")
    local kindColor = entry.kind == "lua" and theme:color("primary")
        or entry.kind == "c" and theme:color("disassemblyOperand")
        or theme:color("textMuted")

    return e("Frame", {
        Size             = UDim2.new(1, 0, 1, 0),
        BackgroundColor3 = bg,
        BorderSizePixel  = 0,
    }, {
        e("TextLabel", {
            key = "id", Position = UDim2.fromOffset(8, 0),
            Size = UDim2.fromOffset(48, ROW_HEIGHT),
            Text = string.format("#%d", entry.id),
            Font = Enum.Font.RobotoMono,
            TextSize = theme:size("font.mono") - 1,
            TextColor3 = theme:color("disassemblyAddr"),
            TextXAlignment = Enum.TextXAlignment.Right,
            BackgroundTransparency = 1,
        }),
        e("TextLabel", {
            key = "kind", Position = UDim2.fromOffset(64, 0),
            Size = UDim2.fromOffset(40, ROW_HEIGHT),
            Text = entry.kind or "?",
            Font = Enum.Font.RobotoMono,
            TextSize = theme:size("font.mono") - 1,
            TextColor3 = kindColor,
            TextXAlignment = Enum.TextXAlignment.Left,
            BackgroundTransparency = 1,
        }),
        e("TextLabel", {
            key = "name", Position = UDim2.fromOffset(112, 0),
            Size = UDim2.fromOffset(180, ROW_HEIGHT),
            Text = entry.name or "<anon>",
            Font = Enum.Font.RobotoMono,
            TextSize = theme:size("font.mono"),
            TextColor3 = entry.name and theme:color("text") or theme:color("textSubtle"),
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd,
            BackgroundTransparency = 1,
        }),
        e("TextLabel", {
            key = "source", Position = UDim2.fromOffset(298, 0),
            Size = UDim2.new(1, -382, 0, ROW_HEIGHT),
            Text = truncate(entry.source or "—", 80),
            Font = Enum.Font.RobotoMono,
            TextSize = theme:size("font.mono") - 1,
            TextColor3 = theme:color("textMuted"),
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd,
            BackgroundTransparency = 1,
        }),
        e("TextLabel", {
            key = "line",
            AnchorPoint = Vector2.new(1, 0),
            Position = UDim2.new(1, -78, 0, 0),
            Size = UDim2.fromOffset(64, ROW_HEIGHT),
            Text = entry.line and string.format(":%d", entry.line) or "",
            Font = Enum.Font.RobotoMono,
            TextSize = theme:size("font.mono") - 1,
            TextColor3 = theme:color("textSubtle"),
            TextXAlignment = Enum.TextXAlignment.Left,
            BackgroundTransparency = 1,
        }),
        e("TextButton", {
            key = "hook",
            AnchorPoint = Vector2.new(1, 0.5),
            Position = UDim2.new(1, -6, 0.5, 0),
            Size = UDim2.fromOffset(64, ROW_HEIGHT - 4),
            Text = "↪ Hook",
            Font = Enum.Font.GothamMedium,
            TextSize = theme:size("font.ui") - 2,
            TextColor3 = theme:color("text"),
            BackgroundColor3 = theme:color("primaryMuted"),
            BorderSizePixel = 0,
            AutoButtonColor = false,
            [Event.Activated] = function() self:_installCounter(entry) end,
        }, {
            e("UICorner", { CornerRadius = UDim.new(0, theme:radius("sm")) }),
        }),
    })
end

-- ---------------------------------------------------------------------
-- Footer
-- ---------------------------------------------------------------------

function HooksView:_renderFooter()
    local theme = self.theme
    if not self.props.runtime then
        return e("Frame", {
            Size = UDim2.new(1, 0, 0, FOOTER_H),
            Position = UDim2.new(0, 0, 1, -FOOTER_H),
            BackgroundColor3 = theme:color("surfaceAlt"),
            BorderSizePixel = 0,
        }, {
            e("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) }),
            e("TextLabel", {
                Text = "runtime not initialised",
                Font = Enum.Font.Gotham, TextSize = theme:size("font.ui") - 2,
                TextColor3 = theme:color("textMuted"),
                TextXAlignment = Enum.TextXAlignment.Left,
                BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1),
            }),
        })
    end
    local hookStats = self.props.runtime.hooks:stats()
    local fnStats   = self.props.runtime.fns:stats()
    local execName  = self.props.runtime.scanner:executorName() or "unknown"
    return e("Frame", {
        Size = UDim2.new(1, 0, 0, FOOTER_H),
        Position = UDim2.new(0, 0, 1, -FOOTER_H),
        BackgroundColor3 = theme:color("surfaceAlt"),
        BorderSizePixel = 0,
    }, {
        e("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) }),
        e("TextLabel", {
            Text = string.format(
                "executor: %s · %d active hooks · %d fns indexed · %d calls intercepted · %d errors",
                execName,
                hookStats.active,
                fnStats.total,
                hookStats.callsTotal,
                hookStats.errorsTotal),
            Font = Enum.Font.Gotham, TextSize = theme:size("font.ui") - 2,
            TextColor3 = theme:color("textMuted"),
            TextXAlignment = Enum.TextXAlignment.Left,
            BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1),
        }),
    })
end

-- ---------------------------------------------------------------------
-- Render
-- ---------------------------------------------------------------------

function HooksView:render()
    local theme = self.theme
    if not self.props.runtime then
        return e("Frame", {
            Size = self.props.Size, Position = self.props.Position,
            BackgroundColor3 = theme:color("background"), BorderSizePixel = 0,
        }, {
            e("TextLabel", {
                Size = UDim2.fromScale(1, 1),
                Text = "runtime not initialised\n(expected props.runtime to be set)",
                Font = Enum.Font.Gotham, TextSize = theme:size("font.ui"),
                TextColor3 = theme:color("textMuted"),
                BackgroundTransparency = 1,
            }),
        })
    end

    local items = self.state.mode == "hooks" and self.state.hooks or self.state.registry
    local renderItemFn = self.state.mode == "hooks"
        and function(item, idx, isOdd) return self:_renderHookRow(item, idx, isOdd) end
        or  function(item, idx, isOdd) return self:_renderRegistryRow(item, idx, isOdd) end

    -- Empty-state messaging
    local emptyMsg
    if #items == 0 then
        if self.state.mode == "hooks" then
            emptyMsg = "no active hooks\nuse the Registry tab to install one"
        else
            emptyMsg = "registry empty — click ▶ Scan env to discover live functions"
        end
    end

    return e("Frame", {
        Size = self.props.Size, Position = self.props.Position,
        BackgroundColor3 = theme:color("background"), BorderSizePixel = 0,
    }, {
        self:_renderHeader(),
        not emptyMsg and e(ScrollVirtualizer, {
            key = "body", Position = UDim2.fromOffset(0, HEADER_H),
            Size = UDim2.new(1, 0, 1, -(HEADER_H + FOOTER_H)),
            items = items, itemCount = #items,
            rowHeight = ROW_HEIGHT,
            overscan = 12,
            renderItem = renderItemFn,
        }),
        emptyMsg and e("TextLabel", {
            key = "empty",
            Position = UDim2.fromOffset(0, HEADER_H),
            Size = UDim2.new(1, 0, 1, -(HEADER_H + FOOTER_H)),
            Text = emptyMsg,
            Font = Enum.Font.Gotham, TextSize = theme:size("font.ui"),
            TextColor3 = theme:color("textMuted"),
            BackgroundTransparency = 1,
        }),
        self:_renderFooter(),
    })
end

return HooksView
