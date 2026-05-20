--!nonstrict
-- =====================================================================
-- IDARo / UI / Views / NetworkView
-- ---------------------------------------------------------------------
-- Wireshark-for-Roblox: live log of every captured RemoteEvent /
-- RemoteFunction / Bindable* call from NetworkTracer.
--
-- Layout
--   Top  — toolbar (Install · Pause/Resume · Clear · class filter
--          chips · path search)
--   Body — left: virtualized entry list (time, dir, class, method,
--          path, args summary); right: detail pane (full args, return
--          values, traceback, action buttons)
--
-- Action buttons in the detail pane
--   * Replay (re-fire this exact call with stored args)
--   * Generate Replay Script (writes ScriptGenerator.replayRemote output
--     to the clipboard)
--   * Generate Namecall-Hook (writes ScriptGenerator.injectNamecallHook
--     scoped to this entry's class+method)
--   * Inspect Instance (writes ScriptGenerator.inspectInstance)
--
-- Update strategy: subscribes to eventBus "network.entry"; coalesces
-- updates at ~10 Hz to avoid render thrash during chatty replicators.
-- =====================================================================

local Component         = _G.IDARo.require("UI.Framework.Component")
local Element           = _G.IDARo.require("UI.Framework.Element")
local ScrollVirtualizer = _G.IDARo.require("UI.Framework.ScrollVirtualizer")

local ScriptGenerator   = _G.IDARo.require("Core.ScriptGenerator")

local e     = Element.create
local Event = Element.Event

local NetworkView = Component.extend("NetworkView")

Component.setDefaultProps(NetworkView, {
    tracer       = nil,
    onCopyResult = nil,                                              -- fn(ok, warnings) — show toast
    Size         = UDim2.fromScale(1, 1),
})

local DETAILS_W = 320
local ROW_H     = 18
local TOP_BAR_H = 30
local FOOTER_H  = 20
local REFRESH_HZ = 10                                                -- max repaints per second

local CLASS_CHIPS = {
    "RemoteEvent", "RemoteFunction", "UnreliableRemoteEvent",
    "BindableEvent", "BindableFunction",
}

-- ---------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------

function NetworkView:init(_props)
    self.state = {
        entries        = {},
        selected       = nil,
        searchText     = "",
        directionFilter = "all",                                     -- "all" | "outgoing" | "incoming"
        classFilters   = (function()
            local t = {}
            for _, c in CLASS_CHIPS do t[c] = true end
            return t
        end)(),
        lastRefreshAt  = 0,
        installStatus  = "",
    }
    self._eventConns  = {}
    self._pendingRefresh = false
end

function NetworkView:didMount()
    if self.eventBus then
        self._eventConns[#self._eventConns + 1] = self.eventBus:on(
            "network.entry", function(_entry)
                self:_scheduleRefresh()
            end)
    end
    self:_refresh()
end

function NetworkView:willUnmount()
    for _, conn in self._eventConns do
        if type(conn) == "function" then conn()
        elseif conn and conn.Disconnect then conn:Disconnect() end
    end
    self._eventConns = {}
end

function NetworkView:didUpdate(prev)
    if prev.tracer ~= self.props.tracer then self:_refresh() end
end

function NetworkView:_scheduleRefresh()
    if self._pendingRefresh then return end
    self._pendingRefresh = true
    local minGap = 1 / REFRESH_HZ
    local elapsed = os.clock() - self.state.lastRefreshAt
    local delay = math.max(0, minGap - elapsed)
    task.delay(delay, function()
        self._pendingRefresh = false
        self:_refresh()
    end)
end

function NetworkView:_refresh()
    local tracer = self.props.tracer
    if not tracer then
        if self.state.entries[1] ~= nil then self:setState({ entries = {} }) end
        return
    end
    local entries = tracer:entries()
    self:setState({ entries = entries, lastRefreshAt = os.clock() })
end

-- ---------------------------------------------------------------------
-- Filtering
-- ---------------------------------------------------------------------

function NetworkView:_filtered()
    local entries = self.state.entries
    local out = {}
    local q = self.state.searchText
    local lq = q ~= "" and string.lower(q) or nil
    for _, en in entries do
        local ok = true
        if self.state.directionFilter ~= "all"
            and en.direction ~= self.state.directionFilter then ok = false end
        if ok and not self.state.classFilters[en.kind] then ok = false end
        if ok and lq
            and not string.find(string.lower(en.path or ""), lq, 1, true)
            and not string.find(string.lower(en.method or ""), lq, 1, true) then
            ok = false
        end
        if ok then out[#out + 1] = en end
    end
    return out
end

-- ---------------------------------------------------------------------
-- Toolbar
-- ---------------------------------------------------------------------

function NetworkView:_install()
    local t = self.props.tracer
    if not t then self:setState({ installStatus = "no tracer" }); return end
    local ok, err = t:install()
    if ok then
        self:setState({ installStatus = "installed (" ..
            (t:stats().installMode or "?") .. ")" })
    else
        self:setState({ installStatus = "install failed: " .. tostring(err) })
    end
end

function NetworkView:_pauseResume()
    local t = self.props.tracer
    if not t then return end
    if t:isPaused() then t:resume() else t:pause() end
    self:setState({})                                                -- trigger rerender for button label
end

function NetworkView:_clear()
    local t = self.props.tracer
    if not t then return end
    t:clear()
    self:setState({ entries = {}, selected = nil })
end

function NetworkView:_toggleClassFilter(cls)
    local copy = {}
    for k, v in self.state.classFilters do copy[k] = v end
    copy[cls] = not copy[cls]
    self:setState({ classFilters = copy })
end

function NetworkView:_renderToolbar()
    local theme = self.theme
    local t = self.props.tracer
    local installed = t and t:stats().installed
    local paused    = t and t:isPaused()

    local function btn(label, x, w, color, onClick)
        return e("TextButton", {
            Size = UDim2.fromOffset(w, TOP_BAR_H - 6),
            Position = UDim2.fromOffset(x, 3),
            BackgroundColor3 = color,
            BorderColor3 = theme:color("border"),
            BorderSizePixel = 1,
            Text = label,
            TextColor3 = theme:color("text"),
            TextSize = 12,
            Font = Enum.Font.Code,
            AutoButtonColor = true,
            [Event.Activated] = onClick,
        })
    end

    local children = {
        btn(installed and "✓ Hooked" or "Install",
            4, 80,
            installed and theme:color("success") or theme:color("surface"),
            function() self:_install() end),
        btn(paused and "▶ Resume" or "❚❚ Pause",
            88, 80, theme:color("surface"),
            function() self:_pauseResume() end),
        btn("Clear", 172, 60, theme:color("surface"),
            function() self:_clear() end),
    }

    -- Class filter chips
    local x = 240
    for _, cls in CLASS_CHIPS do
        local on = self.state.classFilters[cls]
        children[#children + 1] = e("TextButton", {
            Size = UDim2.fromOffset(110, TOP_BAR_H - 6),
            Position = UDim2.fromOffset(x, 3),
            BackgroundColor3 = on and theme:color("accent") or theme:color("surfaceAlt"),
            BorderColor3 = theme:color("border"),
            BorderSizePixel = 1,
            Text = cls,
            TextColor3 = theme:color("text"),
            TextSize = 11,
            Font = Enum.Font.Code,
            AutoButtonColor = true,
            [Event.Activated] = function() self:_toggleClassFilter(cls) end,
        })
        x = x + 114
    end

    -- Search box
    children[#children + 1] = e("TextBox", {
        Size = UDim2.new(1, -(x + 8 + DETAILS_W), 0, TOP_BAR_H - 6),
        Position = UDim2.fromOffset(x, 3),
        BackgroundColor3 = theme:color("surfaceAlt"),
        BorderColor3 = theme:color("border"),
        BorderSizePixel = 1,
        Text = self.state.searchText,
        PlaceholderText = "Filter by path or method…",
        TextColor3 = theme:color("text"),
        PlaceholderColor3 = theme:color("textMuted"),
        TextSize = 12,
        Font = Enum.Font.Code,
        TextXAlignment = Enum.TextXAlignment.Left,
        ClearTextOnFocus = false,
        [Element.Changed.Text] = function(rbx)
            if rbx.Text == self.state.searchText then return end
            self:setState({ searchText = rbx.Text })
        end,
    }, {
        e("UIPadding", { PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6) }),
    })

    -- Install status text
    children[#children + 1] = e("TextLabel", {
        Size = UDim2.fromOffset(DETAILS_W - 8, TOP_BAR_H - 6),
        Position = UDim2.new(1, -DETAILS_W + 4, 0, 3),
        BackgroundTransparency = 1,
        Text = self.state.installStatus,
        TextColor3 = theme:color("textMuted"),
        TextSize = 11,
        Font = Enum.Font.Code,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
    })

    return e("Frame", {
        Name = "toolbar",
        Size = UDim2.new(1, 0, 0, TOP_BAR_H),
        BackgroundColor3 = theme:color("surfaceAlt"),
        BorderSizePixel = 0,
    }, children)
end

-- ---------------------------------------------------------------------
-- Entry row
-- ---------------------------------------------------------------------

function NetworkView:_renderEntryRow(en, idx)
    local theme = self.theme
    local selected = self.state.selected and self.state.selected.id == en.id
    local rowBg = selected and theme:color("primaryMuted")
        or ((idx % 2 == 0) and theme:color("backgroundAlt") or theme:color("background"))
    local dirColor = en.direction == "outgoing"
        and theme:color("accent") or theme:color("success")
    local methodColor = (en.kind == "RemoteFunction" or en.kind == "BindableFunction")
        and theme:color("warning") or theme:color("text")

    return e("Frame", {
        Name = "nrow_" .. tostring(en.id),
        Size = UDim2.new(1, 0, 0, ROW_H),
        BackgroundColor3 = rowBg,
        BorderSizePixel = 0,
        [Event.InputBegan] = function(_rbx, input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 then
                self:setState({ selected = en })
            end
        end,
    }, {
        e("TextLabel", {
            Size = UDim2.fromOffset(50, ROW_H - 2),
            Position = UDim2.fromOffset(4, 1),
            BackgroundTransparency = 1,
            Text = string.format("%.2fs", en.ts % 1000),
            TextColor3 = theme:color("textMuted"),
            TextSize = 11,
            Font = Enum.Font.Code,
            TextXAlignment = Enum.TextXAlignment.Left,
        }),
        e("TextLabel", {
            Size = UDim2.fromOffset(36, ROW_H - 2),
            Position = UDim2.fromOffset(54, 1),
            BackgroundTransparency = 1,
            Text = en.direction == "outgoing" and "→" or "←",
            TextColor3 = dirColor,
            TextSize = 12,
            Font = Enum.Font.Code,
        }),
        e("TextLabel", {
            Size = UDim2.fromOffset(90, ROW_H - 2),
            Position = UDim2.fromOffset(92, 1),
            BackgroundTransparency = 1,
            Text = en.kind or "?",
            TextColor3 = theme:color("textMuted"),
            TextSize = 11,
            Font = Enum.Font.Code,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd,
        }),
        e("TextLabel", {
            Size = UDim2.fromOffset(80, ROW_H - 2),
            Position = UDim2.fromOffset(184, 1),
            BackgroundTransparency = 1,
            Text = en.method or "?",
            TextColor3 = methodColor,
            TextSize = 12,
            Font = Enum.Font.Code,
            TextXAlignment = Enum.TextXAlignment.Left,
        }),
        e("TextLabel", {
            Size = UDim2.new(0.45, -270, 0, ROW_H - 2),
            Position = UDim2.fromOffset(268, 1),
            BackgroundTransparency = 1,
            Text = en.path or "?",
            TextColor3 = theme:color("text"),
            TextSize = 12,
            Font = Enum.Font.Code,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd,
            ClipsDescendants = true,
        }),
        e("TextLabel", {
            Size = UDim2.new(0.55, -8, 0, ROW_H - 2),
            Position = UDim2.new(0.45, 0, 0, 1),
            BackgroundTransparency = 1,
            Text = en.args or "",
            TextColor3 = theme:color("textMuted"),
            TextSize = 11,
            Font = Enum.Font.Code,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd,
            ClipsDescendants = true,
        }),
    })
end

-- ---------------------------------------------------------------------
-- Detail pane
-- ---------------------------------------------------------------------

function NetworkView:_copyScript(result)
    local ok, warnings = ScriptGenerator.copyToClipboard(result)
    if self.props.onCopyResult then
        self.props.onCopyResult(ok, warnings)
    end
end

function NetworkView:_renderDetails()
    local theme = self.theme
    local sel = self.state.selected
    if not sel then
        return e("Frame", {
            Size = UDim2.new(0, DETAILS_W, 1, -(TOP_BAR_H + FOOTER_H)),
            Position = UDim2.new(1, -DETAILS_W, 0, TOP_BAR_H),
            BackgroundColor3 = theme:color("surface"),
            BorderSizePixel = 0,
        }, {
            e("TextLabel", {
                Size = UDim2.fromScale(1, 1),
                BackgroundTransparency = 1,
                Text = "Select an entry",
                TextColor3 = theme:color("textMuted"),
                TextSize = 12,
                Font = Enum.Font.Code,
            }),
        })
    end

    local children = {}
    local y = 6
    local function line(text, color)
        children[#children + 1] = e("TextLabel", {
            Size = UDim2.new(1, -12, 0, 16),
            Position = UDim2.fromOffset(6, y),
            BackgroundTransparency = 1,
            Text = text,
            TextColor3 = color or theme:color("text"),
            TextSize = 12,
            Font = Enum.Font.Code,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd,
        })
        y = y + 18
    end
    local function multilineLabel(text, h)
        children[#children + 1] = e("TextLabel", {
            Size = UDim2.new(1, -12, 0, h),
            Position = UDim2.fromOffset(6, y),
            BackgroundColor3 = theme:color("surfaceAlt"),
            BorderSizePixel = 0,
            Text = text,
            TextColor3 = theme:color("text"),
            TextSize = 11,
            Font = Enum.Font.Code,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextYAlignment = Enum.TextYAlignment.Top,
            TextWrapped = true,
        })
        y = y + h + 4
    end

    line(string.format("#%d  %s  %s",
        sel.id, sel.direction or "?", sel.kind or "?"))
    line("Method: " .. (sel.method or "?"))
    line("Path:")
    multilineLabel(sel.path or "?", 32)
    line(string.format("Args (%d):", sel.argCount or 0))
    multilineLabel(sel.args or "", 60)
    if sel.returns then
        line("Returns:")
        multilineLabel(sel.returns, 40)
    end
    line("Traceback:")
    multilineLabel(sel.traceback or "", 80)

    local function actionBtn(label, color, onClick)
        children[#children + 1] = e("TextButton", {
            Size = UDim2.new(1, -12, 0, 22),
            Position = UDim2.fromOffset(6, y),
            BackgroundColor3 = color,
            BorderColor3 = theme:color("border"),
            BorderSizePixel = 1,
            Text = label,
            TextColor3 = theme:color("text"),
            TextSize = 12,
            Font = Enum.Font.Code,
            [Event.Activated] = onClick,
        })
        y = y + 26
    end

    actionBtn("⟳ Replay this call", theme:color("warning"), function()
        local t = self.props.tracer
        if t then
            local ok, err = t:replay(sel.id)
            if self.props.onCopyResult then
                self.props.onCopyResult(ok, ok and { "replay sent" } or { tostring(err) })
            end
        end
    end)
    actionBtn("📋 Copy Replay Script", theme:color("surface"), function()
        self:_copyScript(ScriptGenerator.replayRemote(sel))
    end)
    actionBtn("📋 Copy Namecall Hook Script", theme:color("surface"), function()
        self:_copyScript(ScriptGenerator.injectNamecallHook({
            className = sel.kind, method = sel.method,
        }))
    end)
    actionBtn("📋 Copy Inspect Script", theme:color("surface"), function()
        self:_copyScript(ScriptGenerator.inspectInstance(sel.instance))
    end)

    return e("Frame", {
        Name = "details",
        Size = UDim2.new(0, DETAILS_W, 1, -(TOP_BAR_H + FOOTER_H)),
        Position = UDim2.new(1, -DETAILS_W, 0, TOP_BAR_H),
        BackgroundColor3 = theme:color("surface"),
        BorderSizePixel = 0,
    }, {
        e("ScrollingFrame", {
            Size = UDim2.fromScale(1, 1),
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            CanvasSize = UDim2.fromOffset(0, y + 16),
            ScrollBarThickness = 6,
            ScrollBarImageColor3 = theme:color("borderStrong"),
        }, children),
    })
end

-- ---------------------------------------------------------------------
-- Render
-- ---------------------------------------------------------------------

function NetworkView:render()
    local theme = self.theme
    local filtered = self:_filtered()
    local t = self.props.tracer
    local stats = t and t:stats() or { captured = 0, ringCount = 0, ringSize = 0 }

    return e("Frame", {
        Name = "NetworkView",
        Size = self.props.Size,
        Position = self.props.Position or UDim2.fromOffset(0, 0),
        BackgroundColor3 = theme:color("surface"),
        BorderSizePixel = 0,
    }, {
        self:_renderToolbar(),
        e(ScrollVirtualizer, {
            Size = UDim2.new(1, -DETAILS_W, 1, -(TOP_BAR_H + FOOTER_H)),
            Position = UDim2.fromOffset(0, TOP_BAR_H),
            itemCount = #filtered,
            itemHeight = ROW_H,
            renderItem = function(i)
                return self:_renderEntryRow(filtered[i], i)
            end,
            stickyBottom = true,                                     -- auto-scroll to newest
        }),
        self:_renderDetails(),
        e("Frame", {
            Name = "footer",
            Size = UDim2.new(1, 0, 0, FOOTER_H),
            Position = UDim2.new(0, 0, 1, -FOOTER_H),
            BackgroundColor3 = theme:color("backgroundAlt"),
            BorderSizePixel = 0,
        }, {
            e("TextLabel", {
                Size = UDim2.fromScale(1, 1),
                BackgroundTransparency = 1,
                Text = string.format("%d captured · %d in ring (showing %d)",
                    stats.captured, stats.ringCount, #filtered),
                TextColor3 = theme:color("textMuted"),
                TextSize = 11,
                Font = Enum.Font.Code,
                TextXAlignment = Enum.TextXAlignment.Left,
            }, {
                e("UIPadding", { PaddingLeft = UDim.new(0, 8) }),
            }),
        }),
    })
end

return NetworkView
