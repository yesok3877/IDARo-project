--!nonstrict
-- =====================================================================
-- IDARo / UI / Views / ConsoleView
-- ---------------------------------------------------------------------
-- Built-in console for capturing every log line, plugin error, and
-- uncaught exception the system produces. Designed so the user can hit
-- "Copy All" and paste the entire buffer into a bug report.
--
-- Sources captured
--   * Logger events (info / warn / error / fatal / debug)
--   * Plugin errors via eventBus "plugin.error"
--   * Network entries via eventBus "network.entry"  (compact one-liner)
--   * Direct push via :push(severity, text)         (anyone can call)
--   * pcall failures via :wrap(fn) helper
--
-- Each entry:
--   { id, ts, severity, source, text, payload, marker? }
-- =====================================================================

local Component         = _G.IDARo.require("UI.Framework.Component")
local Element           = _G.IDARo.require("UI.Framework.Element")
local ScrollVirtualizer = _G.IDARo.require("UI.Framework.ScrollVirtualizer")

local e     = Element.create
local Event = Element.Event

local ConsoleView = Component.extend("ConsoleView")

Component.setDefaultProps(ConsoleView, {
    ringSize     = 4096,
    onCopyResult = nil,
    Size         = UDim2.fromScale(1, 1),
})

local SEVERITY_ORDER = { "fatal", "error", "warn", "info", "debug" }

local ROW_H     = 16
local TOP_BAR_H = 30
local FOOTER_H  = 20
local REFRESH_HZ = 20

-- ---------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------

function ConsoleView:init(props)
    self.state = {
        ring        = table.create(props.ringSize or 4096),
        ringHead    = 0,
        ringCount   = 0,
        idCounter   = 0,
        searchText  = "",
        filters     = { fatal = true, error = true, warn = true,
                        info = true, debug = false },
        sourceFilters = { logger = true, plugin = true, network = false,
                          system = true, user = true },
        paused      = false,
        autoScroll  = true,
        selectedId  = nil,
        lastRefreshAt = 0,
        pendingRefresh = false,
    }
    self._eventConns = {}
end

function ConsoleView:didMount()
    if self.eventBus then
        local function on(evt, sev, src, fn)
            local conn = self.eventBus:on(evt, function(payload)
                if self.state.paused then return end
                self:_push(sev, src, fn(payload), payload)
            end)
            self._eventConns[#self._eventConns + 1] = conn
        end
        on("log.entry",     nil,      "logger",
            function(p) return string.format("[%s] %s",
                (p.severity or "info"):upper(), p.message or "") end)
        on("plugin.error",  "error",  "plugin",
            function(p) return string.format("plugin '%s' [%s]: %s",
                p.id or "?", p.hook or "?", p.err or "?") end)
        on("plugin.disabled", "warn", "plugin",
            function(p) return string.format("plugin '%s' disabled: %s",
                p.id or "?", p.reason or "?") end)
        on("network.entry", "info",   "network",
            function(p) return string.format("%s %s:%s  %s",
                p.direction == "outgoing" and "→" or "←",
                p.kind or "?", p.method or "?", p.path or "?") end)
    end
    -- Welcome banner
    self:_push("info", "system", "IDARo console online — press Copy All to "
        .. "send a snapshot for debugging")
end

function ConsoleView:willUnmount()
    for _, conn in self._eventConns do
        if type(conn) == "function" then conn()
        elseif conn and conn.Disconnect then conn:Disconnect() end
    end
    self._eventConns = {}
end

-- ---------------------------------------------------------------------
-- Push entry
-- ---------------------------------------------------------------------

function ConsoleView:_push(severity, source, text, payload)
    if self.state.paused then return end
    local sev = severity
    -- Auto-promote logger source entries based on prefix
    if not sev and string.find(text, "%[FATAL%]") then sev = "fatal"
    elseif not sev and string.find(text, "%[ERROR%]") then sev = "error"
    elseif not sev and string.find(text, "%[WARN%]")  then sev = "warn"
    elseif not sev and string.find(text, "%[DEBUG%]") then sev = "debug"
    else sev = sev or "info" end

    self.state.idCounter = self.state.idCounter + 1
    local entry = {
        id       = self.state.idCounter,
        ts       = os.clock(),
        severity = sev,
        source   = source or "user",
        text     = tostring(text),
        payload  = payload,
    }
    local rs = #self.state.ring > 0 and #self.state.ring or self.props.ringSize
    rs = self.props.ringSize or 4096
    self.state.ringHead = (self.state.ringHead % rs) + 1
    self.state.ring[self.state.ringHead] = entry
    if self.state.ringCount < rs then
        self.state.ringCount = self.state.ringCount + 1
    end
    self:_scheduleRefresh()
end

-- Public push API (anyone can call self.consoleViewRef:push(...))
function ConsoleView:push(severity, text, source, payload)
    self:_push(severity, source or "user", text, payload)
end

-- Wrap a function so any error it raises shows in the console.
function ConsoleView:wrap(fn, label)
    return function(...)
        local args = table.pack(...)
        local results = table.pack(xpcall(function()
            return fn(table.unpack(args, 1, args.n))
        end, function(err)
            self:_push("error", "system",
                string.format("%s: %s", label or "wrapped fn", tostring(err)),
                { traceback = debug.traceback(nil, 2) })
            return err
        end))
        if results[1] then
            return table.unpack(results, 2, results.n)
        end
    end
end

function ConsoleView:_scheduleRefresh()
    if self.state.pendingRefresh then return end
    self.state.pendingRefresh = true
    local gap = 1 / REFRESH_HZ
    local elapsed = os.clock() - self.state.lastRefreshAt
    task.delay(math.max(0, gap - elapsed), function()
        self.state.pendingRefresh = false
        if self.state then
            self:setState({ lastRefreshAt = os.clock() })
        end
    end)
end

-- ---------------------------------------------------------------------
-- Filter + iterate
-- ---------------------------------------------------------------------

function ConsoleView:_collect()
    local rs = self.props.ringSize or 4096
    local n = self.state.ringCount
    if n == 0 then return {} end
    local startIdx
    if n < rs then startIdx = 1
    else startIdx = (self.state.ringHead % rs) + 1 end
    local q = self.state.searchText
    local lq = q ~= "" and string.lower(q) or nil
    local out = {}
    for i = 0, n - 1 do
        local idx = ((startIdx - 1 + i) % rs) + 1
        local en = self.state.ring[idx]
        if en then
            if self.state.filters[en.severity]
                and self.state.sourceFilters[en.source] then
                if not lq or string.find(string.lower(en.text), lq, 1, true) then
                    out[#out + 1] = en
                end
            end
        end
    end
    return out
end

-- ---------------------------------------------------------------------
-- Clipboard helpers
-- ---------------------------------------------------------------------

local function copyToClipboard(text)
    local setclipboard = rawget(_G, "setclipboard") or rawget(getfenv(0), "setclipboard")
    if type(setclipboard) ~= "function" then return false, "setclipboard unavailable" end
    local ok, err = pcall(setclipboard, text)
    return ok, err
end

function ConsoleView:_copyAll()
    local entries = self:_collect()
    local parts = {
        "=== IDARo console export ===",
        string.format("Generated: %s", os.date("%Y-%m-%dT%H:%M:%S")),
        string.format("Entries:   %d", #entries),
        "",
    }
    for _, en in entries do
        parts[#parts + 1] = string.format("[%.2f] %s/%s  %s",
            en.ts % 100000, en.severity, en.source, en.text)
        if en.payload and en.payload.traceback then
            for line in string.gmatch(en.payload.traceback, "[^\n]+") do
                parts[#parts + 1] = "  " .. line
            end
        end
    end
    parts[#parts + 1] = "=== end ==="
    local text = table.concat(parts, "\n")
    local ok, err = copyToClipboard(text)
    if self.props.onCopyResult then
        self.props.onCopyResult(ok, ok and { string.format("copied %d entries", #entries) }
            or { tostring(err) })
    end
end

function ConsoleView:_copySelected()
    local sel = self.state.selectedId
    if not sel then return end
    local en
    for _, x in self:_collect() do
        if x.id == sel then en = x; break end
    end
    if not en then return end
    local parts = {
        string.format("[%.2f] %s/%s  %s",
            en.ts % 100000, en.severity, en.source, en.text),
    }
    if en.payload and en.payload.traceback then
        parts[#parts + 1] = en.payload.traceback
    end
    copyToClipboard(table.concat(parts, "\n"))
end

-- ---------------------------------------------------------------------
-- Toolbar
-- ---------------------------------------------------------------------

local function buttonStyle(theme, on)
    return on and theme:color("accent") or theme:color("surfaceAlt")
end

function ConsoleView:_renderToolbar()
    local theme = self.theme
    local function btn(label, x, w, color, onClick)
        return e("TextButton", {
            Size = UDim2.fromOffset(w, TOP_BAR_H - 6),
            Position = UDim2.fromOffset(x, 3),
            BackgroundColor3 = color,
            BorderColor3 = theme:color("border"),
            BorderSizePixel = 1,
            Text = label,
            TextColor3 = theme:color("text"),
            TextSize = 11,
            Font = Enum.Font.Code,
            [Event.Activated] = onClick,
        })
    end
    local children = {
        btn("📋 Copy All",     4,   80, theme:color("surface"),
            function() self:_copyAll() end),
        btn("📋 Copy Sel",     88,  80, theme:color("surface"),
            function() self:_copySelected() end),
        btn("Clear",          172,  60, theme:color("surface"),
            function()
                self.state.ring = table.create(self.props.ringSize or 4096)
                self.state.ringHead = 0
                self.state.ringCount = 0
                self:setState({ selectedId = nil })
            end),
        btn(self.state.paused and "▶ Resume" or "❚❚ Pause", 236, 80,
            theme:color("surface"),
            function() self:setState({ paused = not self.state.paused }) end),
        btn("Test", 320, 56, theme:color("surface"), function()
            self:_push("info",  "user", "test info line")
            self:_push("warn",  "user", "test warn line")
            self:_push("error", "user", "test error line")
        end),
    }
    -- Severity chips
    local x = 384
    for _, sev in SEVERITY_ORDER do
        children[#children + 1] = e("TextButton", {
            Size = UDim2.fromOffset(58, TOP_BAR_H - 6),
            Position = UDim2.fromOffset(x, 3),
            BackgroundColor3 = buttonStyle(theme, self.state.filters[sev]),
            BorderColor3 = theme:color("border"),
            BorderSizePixel = 1,
            Text = sev,
            TextColor3 = theme:color("text"),
            TextSize = 11,
            Font = Enum.Font.Code,
            [Event.Activated] = function()
                local copy = {}
                for k, v in self.state.filters do copy[k] = v end
                copy[sev] = not copy[sev]
                self:setState({ filters = copy })
            end,
        })
        x = x + 62
    end
    -- Search box
    children[#children + 1] = e("TextBox", {
        Size = UDim2.new(1, -(x + 8), 0, TOP_BAR_H - 6),
        Position = UDim2.fromOffset(x, 3),
        BackgroundColor3 = theme:color("surfaceAlt"),
        BorderColor3 = theme:color("border"),
        BorderSizePixel = 1,
        Text = self.state.searchText,
        PlaceholderText = "Filter log…",
        TextColor3 = theme:color("text"),
        PlaceholderColor3 = theme:color("textMuted"),
        TextSize = 12,
        Font = Enum.Font.Code,
        ClearTextOnFocus = false,
        [Element.Changed.Text] = function(rbx)
            if rbx.Text == self.state.searchText then return end
            self:setState({ searchText = rbx.Text })
        end,
    }, {
        e("UIPadding", { PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6) }),
    })

    return e("Frame", {
        Name = "toolbar",
        Size = UDim2.new(1, 0, 0, TOP_BAR_H),
        BackgroundColor3 = theme:color("surfaceAlt"),
        BorderSizePixel = 0,
    }, children)
end

-- ---------------------------------------------------------------------
-- Row
-- ---------------------------------------------------------------------

local SEV_COLOR_KEY = {
    fatal = "errorBg", error = "errorBg",
    warn  = "warnBg",
    info  = "text",
    debug = "textDim",
}

function ConsoleView:_renderRow(en, idx)
    local theme = self.theme
    local rowBg = self.state.selectedId == en.id
        and theme:color("primaryMuted")
        or ((idx % 2 == 0) and theme:color("backgroundAlt") or theme:color("background"))
    local sevColor = theme:color(SEV_COLOR_KEY[en.severity] or "text")
    return e("Frame", {
        Name = "logrow_" .. tostring(en.id),
        Size = UDim2.new(1, 0, 0, ROW_H),
        BackgroundColor3 = rowBg,
        BorderSizePixel = 0,
        [Event.InputBegan] = function(_rbx, input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 then
                self:setState({ selectedId = en.id })
            end
        end,
    }, {
        e("TextLabel", {
            Size = UDim2.fromOffset(50, ROW_H - 2),
            Position = UDim2.fromOffset(4, 1),
            BackgroundTransparency = 1,
            Text = string.format("%6.2fs", en.ts % 100000),
            TextColor3 = theme:color("textMuted"),
            TextSize = 11,
            Font = Enum.Font.Code,
            TextXAlignment = Enum.TextXAlignment.Right,
        }),
        e("TextLabel", {
            Size = UDim2.fromOffset(46, ROW_H - 2),
            Position = UDim2.fromOffset(58, 1),
            BackgroundTransparency = 1,
            Text = en.severity,
            TextColor3 = sevColor,
            TextSize = 11,
            Font = Enum.Font.Code,
            TextXAlignment = Enum.TextXAlignment.Left,
        }),
        e("TextLabel", {
            Size = UDim2.fromOffset(60, ROW_H - 2),
            Position = UDim2.fromOffset(108, 1),
            BackgroundTransparency = 1,
            Text = en.source,
            TextColor3 = theme:color("textMuted"),
            TextSize = 11,
            Font = Enum.Font.Code,
            TextXAlignment = Enum.TextXAlignment.Left,
        }),
        e("TextLabel", {
            Size = UDim2.new(1, -176, 0, ROW_H - 2),
            Position = UDim2.fromOffset(172, 1),
            BackgroundTransparency = 1,
            Text = en.text,
            TextColor3 = sevColor,
            TextSize = 12,
            Font = Enum.Font.Code,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd,
            ClipsDescendants = true,
        }),
    })
end

-- ---------------------------------------------------------------------
-- Render
-- ---------------------------------------------------------------------

function ConsoleView:render()
    local theme = self.theme
    local entries = self:_collect()
    local counts = { fatal = 0, error = 0, warn = 0, info = 0, debug = 0 }
    for _, en in entries do
        counts[en.severity] = (counts[en.severity] or 0) + 1
    end
    return e("Frame", {
        Name = "ConsoleView",
        Size = self.props.Size,
        Position = self.props.Position or UDim2.fromOffset(0, 0),
        BackgroundColor3 = theme:color("surface"),
        BorderSizePixel = 0,
    }, {
        self:_renderToolbar(),
        e(ScrollVirtualizer, {
            Size = UDim2.new(1, 0, 1, -(TOP_BAR_H + FOOTER_H)),
            Position = UDim2.fromOffset(0, TOP_BAR_H),
            itemCount = #entries,
            itemHeight = ROW_H,
            renderItem = function(i)
                return self:_renderRow(entries[i], i)
            end,
            stickyBottom = self.state.autoScroll,
        }),
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
                Text = string.format(
                    "%d total · %d fatal · %d error · %d warn · %d info · %d debug",
                    #entries, counts.fatal, counts.error, counts.warn,
                    counts.info, counts.debug),
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

return ConsoleView
