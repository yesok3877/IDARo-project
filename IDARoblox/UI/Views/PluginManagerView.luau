--!nonstrict
-- =====================================================================
-- IDARoblox / UI / Views / PluginManagerView
-- ---------------------------------------------------------------------
-- UI for managing the running PluginLoader. Two-pane layout:
--
--   Left  — sortable list of every registered plugin:
--             id · name · priority · status badge · enable toggle
--           Status badges:  ACTIVE / DISABLED / ERROR
--   Right — inspector for the selected plugin:
--             * Manifest summary  (id, name, author, version, description,
--               dependencies, requires, priority)
--             * Lifecycle stats   (call counts per hook, total errors,
--               last error message)
--             * Action buttons    (Trigger Scan, Run, Unregister, Reset
--               Error Count). For DumpAll specifically the inspector
--               offers a Run-with-options form.
--
-- A toolbar at the top exposes: Register Builtins, Scan All (re-fires
-- onBytecodeLoad+scan on every enabled plugin), and a global search
-- filter.
--
-- The view listens for plugin.* eventBus events and refreshes itself.
-- =====================================================================

local Component         = _G.IDARo.require("UI.Framework.Component")
local Element           = _G.IDARo.require("UI.Framework.Element")
local ScrollVirtualizer = _G.IDARo.require("UI.Framework.ScrollVirtualizer")

local Plugins = _G.IDARo.require("Plugins")
local PluginAPI = Plugins.PluginAPI

local e     = Element.create
local Event = Element.Event

local PluginManagerView = Component.extend("PluginManagerView")

Component.setDefaultProps(PluginManagerView, {
    loader       = nil,                                              -- PluginLoader instance
    bytecode     = nil,
    onTriggerScan = nil,
    Size         = UDim2.fromScale(1, 1),
})

local LIST_W   = 280
local ROW_H    = 22
local HEADER_H = 28
local FOOTER_H = 20
local TOP_BAR_H = 30

-- ---------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------

function PluginManagerView:init(_props)
    self.state = {
        plugins        = {},
        searchText     = "",
        sortKey        = "priority",
        sortDir        = "asc",
        selectedId     = nil,
        filteredCache  = nil,
        actionStatus   = "",
    }
    self._eventConns = {}
end

function PluginManagerView:didMount()
    self:_refresh()
    if self.eventBus then
        local function refresh() self:_refresh() end
        for _, evt in {
            "plugin.registered", "plugin.unregistered",
            "plugin.enabled", "plugin.disabled", "plugin.error",
        } do
            self._eventConns[#self._eventConns + 1] = self.eventBus:on(evt, refresh)
        end
    end
end

function PluginManagerView:willUnmount()
    for _, conn in self._eventConns do
        if type(conn) == "function" then conn()                       -- some EventBus return unsubscribe fn
        elseif conn and conn.Disconnect then conn:Disconnect() end
    end
    self._eventConns = {}
end

function PluginManagerView:didUpdate(prev)
    if prev.loader ~= self.props.loader then self:_refresh() end
end

-- ---------------------------------------------------------------------
-- Refresh from loader
-- ---------------------------------------------------------------------

function PluginManagerView:_refresh()
    local loader = self.props.loader
    if not loader then self:setState({ plugins = {}, filteredCache = nil }); return end
    local list = loader:list()
    local out = {}
    for _, record in list do
        local stats = loader:pluginStats(record.manifest.id)
        out[#out + 1] = {
            id          = record.manifest.id,
            name        = record.manifest.name or record.manifest.id,
            author      = record.manifest.author,
            version     = record.manifest.version,
            description = record.manifest.description,
            dependencies = record.manifest.dependencies,
            requires    = record.manifest.requires,
            priority    = record.priority,
            enabled     = record.enabled,
            stats       = stats,
            record      = record,
        }
    end
    self:setState({ plugins = out, filteredCache = nil })
end

-- ---------------------------------------------------------------------
-- Filter + sort
-- ---------------------------------------------------------------------

function PluginManagerView:_filtered()
    if self.state.filteredCache then return self.state.filteredCache end
    local q = self.state.searchText
    local lq = q ~= "" and string.lower(q) or nil
    local out = {}
    for _, p in self.state.plugins do
        local hay = (p.id or "") .. " " .. (p.name or "")
        if not lq or string.find(string.lower(hay), lq, 1, true) then
            out[#out + 1] = p
        end
    end
    table.sort(out, function(a, b)
        local av, bv = a[self.state.sortKey], b[self.state.sortKey]
        if av == bv then return tostring(a.id) < tostring(b.id) end
        if av == nil then return false end
        if bv == nil then return true end
        if self.state.sortDir == "asc" then return av < bv end
        return av > bv
    end)
    self.state.filteredCache = out
    return out
end

-- ---------------------------------------------------------------------
-- Actions
-- ---------------------------------------------------------------------

function PluginManagerView:_registerBuiltins()
    if not self.props.loader then return end
    local registered, errors = Plugins.registerBuiltins(self.props.loader)
    local msg = string.format("registered %d, errors %d", #registered, #errors)
    self:setState({ actionStatus = msg })
    self:_refresh()
end

function PluginManagerView:_scanAll()
    local loader = self.props.loader
    local bc = self.props.bytecode
    if not loader or not bc then
        self:setState({ actionStatus = "no loader or bytecode" })
        return
    end
    local ok, err = pcall(function() loader:onBytecodeLoaded(bc) end)
    if ok then
        self:setState({ actionStatus = "scan-all complete" })
        if self.props.onTriggerScan then self.props.onTriggerScan() end
    else
        self:setState({ actionStatus = "scan-all failed: " .. tostring(err) })
    end
    self:_refresh()
end

function PluginManagerView:_toggleEnabled(p)
    if not self.props.loader then return end
    pcall(function()
        self.props.loader:setEnabled(p.id, not p.enabled)
    end)
    self:_refresh()
end

function PluginManagerView:_unregister(p)
    if not self.props.loader then return end
    local ok, err = pcall(function() self.props.loader:unregister(p.id) end)
    if not ok then
        self:setState({ actionStatus = "unregister failed: " .. tostring(err) })
    else
        self:setState({ actionStatus = "unregistered " .. p.id })
        if self.state.selectedId == p.id then
            self:setState({ selectedId = nil })
        end
    end
    self:_refresh()
end

function PluginManagerView:_runDumpAll(p)
    -- Fire eventBus signal that DumpAll listens for
    if self.eventBus then
        self.eventBus:emit("plugin.dumpAll.run", {
            directory = "dumps",
        })
        self:setState({ actionStatus = "dispatched dumpAll trigger" })
    else
        self:setState({ actionStatus = "no eventBus available" })
    end
end

-- ---------------------------------------------------------------------
-- Top bar
-- ---------------------------------------------------------------------

function PluginManagerView:_renderTopBar()
    local theme = self.theme
    return e("Frame", {
        Name = "topbar",
        Size = UDim2.new(1, 0, 0, TOP_BAR_H),
        BackgroundColor3 = theme:color("surfaceAlt"),
        BorderSizePixel = 0,
    }, {
        e("TextButton", {
            Size = UDim2.fromOffset(120, TOP_BAR_H - 6),
            Position = UDim2.fromOffset(4, 3),
            BackgroundColor3 = theme:color("surface"),
            BorderColor3 = theme:color("border"),
            BorderSizePixel = 1,
            Text = "Register Builtins",
            TextColor3 = theme:color("text"),
            TextSize = 12,
            Font = Enum.Font.Code,
            [Event.Activated] = function() self:_registerBuiltins() end,
        }),
        e("TextButton", {
            Size = UDim2.fromOffset(80, TOP_BAR_H - 6),
            Position = UDim2.fromOffset(128, 3),
            BackgroundColor3 = theme:color("surface"),
            BorderColor3 = theme:color("border"),
            BorderSizePixel = 1,
            Text = "Scan All",
            TextColor3 = theme:color("text"),
            TextSize = 12,
            Font = Enum.Font.Code,
            [Event.Activated] = function() self:_scanAll() end,
        }),
        e("TextBox", {
            Size = UDim2.new(0, LIST_W - 220, 0, TOP_BAR_H - 6),
            Position = UDim2.fromOffset(216, 3),
            BackgroundColor3 = theme:color("surfaceAlt"),
            BorderColor3 = theme:color("border"),
            BorderSizePixel = 1,
            Text = self.state.searchText,
            PlaceholderText = "Filter plugins…",
            TextColor3 = theme:color("text"),
            PlaceholderColor3 = theme:color("textMuted"),
            TextSize = 12,
            Font = Enum.Font.Code,
            ClearTextOnFocus = false,
            [Element.Changed.Text] = function(rbx)
                if rbx.Text == self.state.searchText then return end
                self:setState({ searchText = rbx.Text, filteredCache = nil })
            end,
        }, {
            e("UIPadding", { PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6) }),
        }),
        e("TextLabel", {
            Size = UDim2.new(1, -(LIST_W + 8), 0, TOP_BAR_H - 6),
            Position = UDim2.fromOffset(LIST_W + 4, 3),
            BackgroundTransparency = 1,
            Text = self.state.actionStatus,
            TextColor3 = theme:color("textMuted"),
            TextSize = 12,
            Font = Enum.Font.Code,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd,
        }),
    })
end

-- ---------------------------------------------------------------------
-- Status badge
-- ---------------------------------------------------------------------

local function statusOf(p)
    if not p.enabled then
        if p.stats and (p.stats.errors or 0) > 0 then return "AUTODIS", "error" end
        return "DIS", "dim"
    end
    if p.stats and (p.stats.errors or 0) > 0 then return "WARN", "warn" end
    return "OK", "ok"
end

function PluginManagerView:_renderPluginRow(p, idx)
    local theme = self.theme
    local selected = self.state.selectedId == p.id
    local rowBg = selected and theme:color("primaryMuted")
        or ((idx % 2 == 0) and theme:color("backgroundAlt") or theme:color("background"))
    local badgeText, badgeKind = statusOf(p)
    local badgeColor =
        badgeKind == "ok"    and theme:color("success")    or
        badgeKind == "warn"  and theme:color("warning")  or
        badgeKind == "error" and theme:color("danger") or
        theme:color("surfaceAlt")

    return e("Frame", {
        Name = "prow_" .. tostring(idx),
        Size = UDim2.new(1, 0, 0, ROW_H),
        BackgroundColor3 = rowBg,
        BorderSizePixel = 0,
        [Event.InputBegan] = function(_rbx, input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 then
                self:setState({ selectedId = p.id })
            end
        end,
    }, {
        e("Frame", {
            Size = UDim2.fromOffset(8, ROW_H),
            BackgroundColor3 = p.enabled and theme:color("success") or theme:color("textMuted"),
            BorderSizePixel = 0,
        }),
        e("TextLabel", {
            Size = UDim2.new(1, -110, 0, ROW_H - 4),
            Position = UDim2.fromOffset(12, 2),
            BackgroundTransparency = 1,
            Text = p.name or p.id,
            TextColor3 = theme:color("text"),
            TextSize = 12,
            Font = Enum.Font.Code,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd,
            ClipsDescendants = true,
        }),
        e("TextLabel", {
            Size = UDim2.fromOffset(48, ROW_H - 4),
            Position = UDim2.new(1, -100, 0, 2),
            BackgroundColor3 = badgeColor,
            BorderSizePixel = 0,
            Text = badgeText,
            TextColor3 = theme:color("text"),
            TextSize = 11,
            Font = Enum.Font.Code,
        }),
        e("TextButton", {
            Size = UDim2.fromOffset(46, ROW_H - 6),
            Position = UDim2.new(1, -52, 0, 3),
            BackgroundColor3 = p.enabled and theme:color("surface") or theme:color("surfaceAlt"),
            BorderColor3 = theme:color("border"),
            BorderSizePixel = 1,
            Text = p.enabled and "On" or "Off",
            TextColor3 = theme:color("text"),
            TextSize = 11,
            Font = Enum.Font.Code,
            [Event.Activated] = function() self:_toggleEnabled(p) end,
        }),
    })
end

-- ---------------------------------------------------------------------
-- Inspector
-- ---------------------------------------------------------------------

function PluginManagerView:_renderInspector()
    local theme = self.theme
    local sel = nil
    for _, p in self.state.plugins do
        if p.id == self.state.selectedId then sel = p; break end
    end
    if not sel then
        return e("Frame", {
            Name = "inspector",
            Size = UDim2.new(1, -LIST_W, 1, -(TOP_BAR_H + FOOTER_H)),
            Position = UDim2.fromOffset(LIST_W, TOP_BAR_H),
            BackgroundColor3 = theme:color("surface"),
            BorderSizePixel = 0,
        }, {
            e("TextLabel", {
                Size = UDim2.fromScale(1, 1),
                BackgroundTransparency = 1,
                Text = "Select a plugin to inspect",
                TextColor3 = theme:color("textMuted"),
                TextSize = 12,
                Font = Enum.Font.Code,
            }),
        })
    end

    local children = {}
    local y = 6
    local function row(label, value, color)
        children[#children + 1] = e("TextLabel", {
            Size = UDim2.fromOffset(100, 16),
            Position = UDim2.fromOffset(8, y),
            BackgroundTransparency = 1,
            Text = label,
            TextColor3 = theme:color("textMuted"),
            TextSize = 12,
            Font = Enum.Font.Code,
            TextXAlignment = Enum.TextXAlignment.Left,
        })
        children[#children + 1] = e("TextLabel", {
            Size = UDim2.new(1, -116, 0, 16),
            Position = UDim2.fromOffset(108, y),
            BackgroundTransparency = 1,
            Text = tostring(value or ""),
            TextColor3 = color or theme:color("text"),
            TextSize = 12,
            Font = Enum.Font.Code,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd,
            TextWrapped = false,
        })
        y = y + 18
    end

    row("ID:", sel.id)
    row("Name:", sel.name)
    row("Author:", sel.author or "—")
    row("Version:", sel.version or "—")
    row("Priority:", tostring(sel.priority or 100))
    row("Enabled:", sel.enabled and "yes" or "no",
        sel.enabled and theme:color("success") or theme:color("textMuted"))
    if sel.dependencies and #sel.dependencies > 0 then
        row("Depends:", table.concat(sel.dependencies, ", "))
    end
    if sel.requires and #sel.requires > 0 then
        row("Requires:", table.concat(sel.requires, ", "))
    end
    y = y + 6
    if sel.description then
        children[#children + 1] = e("TextLabel", {
            Size = UDim2.new(1, -16, 0, 60),
            Position = UDim2.fromOffset(8, y),
            BackgroundTransparency = 1,
            Text = sel.description,
            TextColor3 = theme:color("text"),
            TextSize = 12,
            Font = Enum.Font.Code,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextYAlignment = Enum.TextYAlignment.Top,
            TextWrapped = true,
        })
        y = y + 64
    end

    -- Lifecycle stats
    children[#children + 1] = e("TextLabel", {
        Size = UDim2.new(1, -16, 0, 16),
        Position = UDim2.fromOffset(8, y),
        BackgroundTransparency = 1,
        Text = "── Lifecycle stats ──",
        TextColor3 = theme:color("textMuted"),
        TextSize = 11,
        Font = Enum.Font.Code,
        TextXAlignment = Enum.TextXAlignment.Left,
    })
    y = y + 18
    local stats = sel.stats or {}
    row("Errors:", tostring(stats.errors or 0),
        (stats.errors or 0) > 0 and theme:color("danger") or theme:color("text"))
    if stats.lastError then
        children[#children + 1] = e("TextLabel", {
            Size = UDim2.new(1, -16, 0, 32),
            Position = UDim2.fromOffset(8, y),
            BackgroundTransparency = 1,
            Text = "Last error: " .. tostring(stats.lastError),
            TextColor3 = theme:color("danger"),
            TextSize = 11,
            Font = Enum.Font.Code,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextYAlignment = Enum.TextYAlignment.Top,
            TextWrapped = true,
        })
        y = y + 36
    end
    if stats.calls then
        for hook, count in stats.calls do
            row(hook .. ":", tostring(count) .. " calls")
        end
    end

    -- Action buttons
    y = y + 6
    children[#children + 1] = e("TextLabel", {
        Size = UDim2.new(1, -16, 0, 16),
        Position = UDim2.fromOffset(8, y),
        BackgroundTransparency = 1,
        Text = "── Actions ──",
        TextColor3 = theme:color("textMuted"),
        TextSize = 11,
        Font = Enum.Font.Code,
        TextXAlignment = Enum.TextXAlignment.Left,
    })
    y = y + 20

    local function actionBtn(label, x, onClick, color)
        children[#children + 1] = e("TextButton", {
            Size = UDim2.fromOffset(100, 22),
            Position = UDim2.fromOffset(x, y),
            BackgroundColor3 = color or theme:color("surface"),
            BorderColor3 = theme:color("border"),
            BorderSizePixel = 1,
            Text = label,
            TextColor3 = theme:color("text"),
            TextSize = 12,
            Font = Enum.Font.Code,
            [Event.Activated] = onClick,
        })
    end

    actionBtn("Scan", 8, function() self:_scanAll() end)
    actionBtn(sel.enabled and "Disable" or "Enable", 112,
        function() self:_toggleEnabled(sel) end)
    actionBtn("Unregister", 216,
        function() self:_unregister(sel) end, theme:color("danger"))
    y = y + 26

    if sel.id == "builtin.dumpAll" then
        actionBtn("Run DumpAll", 8, function() self:_runDumpAll(sel) end,
            theme:color("warning"))
        y = y + 26
    end

    return e("Frame", {
        Name = "inspector",
        Size = UDim2.new(1, -LIST_W, 1, -(TOP_BAR_H + FOOTER_H)),
        Position = UDim2.fromOffset(LIST_W, TOP_BAR_H),
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

function PluginManagerView:render()
    local theme = self.theme
    local list = self:_filtered()
    local enabledCount = 0
    local errorCount = 0
    for _, p in self.state.plugins do
        if p.enabled then enabledCount = enabledCount + 1 end
        if p.stats and (p.stats.errors or 0) > 0 then
            errorCount = errorCount + 1
        end
    end

    return e("Frame", {
        Name = "PluginManagerView",
        Size = self.props.Size,
        Position = self.props.Position or UDim2.fromOffset(0, 0),
        BackgroundColor3 = theme:color("surface"),
        BorderSizePixel = 0,
    }, {
        self:_renderTopBar(),
        e(ScrollVirtualizer, {
            Size = UDim2.new(0, LIST_W, 1, -(TOP_BAR_H + FOOTER_H)),
            Position = UDim2.fromOffset(0, TOP_BAR_H),
            itemCount = #list,
            itemHeight = ROW_H,
            renderItem = function(i)
                return self:_renderPluginRow(list[i], i)
            end,
        }),
        self:_renderInspector(),
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
                Text = string.format("%d plugins · %d enabled · %d with errors",
                    #self.state.plugins, enabledCount, errorCount),
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

return PluginManagerView
