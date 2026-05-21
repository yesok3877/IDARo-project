--!nonstrict
-- =====================================================================
-- IDARoblox / UI / Views / GCHeapView
-- ---------------------------------------------------------------------
-- Live garbage-collected heap explorer. Consumes Runtime.gc (the
-- GCScanner service) and renders a three-pane explorer:
--
--   Left   — category tree:
--              Functions (by source: core/script/executor/anon)
--              Tables    (top-N shape hashes)
--              Threads   (by status: running/suspended/dead)
--              Userdata  (by metatable class)
--   Center — virtualized list of objects matching the selected
--              category filter; sortable by type/source/shape/refcount.
--   Right  — inspector pane:
--              Functions: upvalues + constants + source label
--              Tables:    shape sample + metatable classifier
--              Threads:   coroutine status + name
--              Userdata:  metatable class + key methods
--
-- Top strip shows a shape histogram (most common table shapes by count)
-- as a compact bar chart.
-- =====================================================================

local Component         = _G.IDARo.require("UI.Framework.Component")
local Element           = _G.IDARo.require("UI.Framework.Element")
local ScrollVirtualizer = _G.IDARo.require("UI.Framework.ScrollVirtualizer")

local e     = Element.create
local Event = Element.Event

local GCHeapView = Component.extend("GCHeapView")

Component.setDefaultProps(GCHeapView, {
    runtime         = nil,    -- Runtime; we use runtime.gc (GCScanner)
    onSelectObject  = nil,
    onScanRequested = nil,
    Size            = UDim2.fromScale(1, 1),
})

local TREE_W   = 200
local INSPECTOR_W = 280
local ROW_H    = 18
local HEADER_H = 28
local TOP_BAR_H = 30
local FOOTER_H = 20
local HISTO_H  = 36

-- ---------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------

function GCHeapView:init(_props)
    self.state = {
        snapshot       = nil,
        searchText     = "",
        sortKey        = "type",
        sortDir        = "asc",
        categoryFilter = nil,           -- { kind = "type"|"source"|"shape"|"mt", key = ... }
        selectedObject = nil,
        scanning       = false,
        lastScanAt     = 0,
        filteredCache  = nil,
    }
end

function GCHeapView:didMount()
    -- If a runtime is already available, kick off an initial scan.
    if self.props.runtime and self.props.runtime.gc then
        self:_scan()
    end
end

function GCHeapView:didUpdate(prevProps)
    if prevProps.runtime ~= self.props.runtime and self.props.runtime
        and self.props.runtime.gc then
        self:_scan()
    end
end

-- ---------------------------------------------------------------------
-- Scan trigger
-- ---------------------------------------------------------------------

function GCHeapView:_scan()
    local gc = self.props.runtime and self.props.runtime.gc
    if not gc then return end
    self:setState({ scanning = true })
    -- Synchronous call; GCScanner is responsible for chunking large heaps.
    local ok, snap = pcall(function() return gc:scan({ includeReferences = true }) end)
    if not ok then
        self:setState({ scanning = false })
        if self.logger then
            self.logger:warn("GCHeapView: scan failed: %s", tostring(snap))
        end
        return
    end
    self:setState({
        snapshot      = snap,
        scanning      = false,
        lastScanAt    = os.clock(),
        filteredCache = nil,
    })
    if self.props.onScanRequested then
        self.props.onScanRequested(snap)
    end
end

-- ---------------------------------------------------------------------
-- Filter + sort
-- ---------------------------------------------------------------------

function GCHeapView:_filteredObjects()
    if self.state.filteredCache then return self.state.filteredCache end
    local snap = self.state.snapshot
    if not snap or not snap.objects then return {} end
    local filt = self.state.categoryFilter
    local q = self.state.searchText
    local lq = q ~= "" and string.lower(q) or nil

    local out = {}
    for _, obj in snap.objects do
        local matchesCat = true
        if filt then
            if filt.kind == "type"   and obj.type ~= filt.key then matchesCat = false end
            if filt.kind == "source" and (obj.source or "") ~= filt.key then matchesCat = false end
            if filt.kind == "shape"  and (obj.shapeHash or "") ~= filt.key then matchesCat = false end
            if filt.kind == "mt"     and (obj.mtClass or "") ~= filt.key then matchesCat = false end
        end
        if matchesCat and lq then
            local label = obj.label or obj.name or tostring(obj.id or "")
            if not string.find(string.lower(label), lq, 1, true) then
                matchesCat = false
            end
        end
        if matchesCat then out[#out + 1] = obj end
    end

    local key, dir = self.state.sortKey, self.state.sortDir
    table.sort(out, function(a, b)
        local av, bv = a[key], b[key]
        if av == bv then return (a.id or 0) < (b.id or 0) end
        if av == nil then return false end
        if bv == nil then return true end
        if dir == "asc" then return av < bv end
        return av > bv
    end)
    self.state.filteredCache = out
    return out
end

-- ---------------------------------------------------------------------
-- Tree (left pane)
-- ---------------------------------------------------------------------

local function tally(snap, field)
    local counts = {}
    for _, o in (snap and snap.objects) or {} do
        local key = o[field] or "?"
        counts[key] = (counts[key] or 0) + 1
    end
    local list = {}
    for k, v in counts do list[#list + 1] = { key = k, count = v } end
    table.sort(list, function(a, b)
        if a.count == b.count then return tostring(a.key) < tostring(b.key) end
        return a.count > b.count
    end)
    return list
end

function GCHeapView:_renderCategoryTree()
    local theme = self.theme
    local snap = self.state.snapshot
    local children = {}
    local y = 4

    local function header(text)
        children[#children + 1] = e("TextLabel", {
            Size = UDim2.new(1, -8, 0, 16),
            Position = UDim2.fromOffset(4, y),
            BackgroundTransparency = 1,
            Text = text,
            TextColor3 = theme:color("textMuted"),
            TextSize = 11,
            Font = Enum.Font.Code,
            TextXAlignment = Enum.TextXAlignment.Left,
        })
        y = y + 18
    end

    local function entry(kind, key, count)
        local selected = self.state.categoryFilter
            and self.state.categoryFilter.kind == kind
            and self.state.categoryFilter.key == key
        local label = string.format("  %s (%d)", tostring(key), count)
        children[#children + 1] = e("TextButton", {
            Size = UDim2.new(1, -8, 0, 16),
            Position = UDim2.fromOffset(4, y),
            BackgroundColor3 = selected and theme:color("primaryMuted") or theme:color("surface"),
            BackgroundTransparency = selected and 0 or 1,
            BorderSizePixel = 0,
            Text = label,
            TextColor3 = selected and theme:color("accent") or theme:color("text"),
            TextSize = 12,
            Font = Enum.Font.Code,
            TextXAlignment = Enum.TextXAlignment.Left,
            AutoButtonColor = false,
            [Event.Activated] = function()
                if selected then
                    self:setState({ categoryFilter = nil, filteredCache = nil })
                else
                    self:setState({ categoryFilter = { kind = kind, key = key },
                                    filteredCache = nil })
                end
            end,
        })
        y = y + 18
    end

    if not snap then
        children[#children + 1] = e("TextLabel", {
            Size = UDim2.new(1, -8, 0, 32),
            Position = UDim2.fromOffset(4, 8),
            BackgroundTransparency = 1,
            Text = "(no snapshot — press Scan)",
            TextColor3 = theme:color("textMuted"),
            TextSize = 12,
            Font = Enum.Font.Code,
            TextWrapped = true,
        })
    else
        header("By type")
        for _, t in tally(snap, "type") do entry("type", t.key, t.count) end
        header("By source")
        for _, t in tally(snap, "source") do entry("source", t.key, t.count) end
        header("By metatable class")
        for _, t in tally(snap, "mtClass") do
            if t.key and t.key ~= "?" and t.key ~= "" then
                entry("mt", t.key, t.count)
            end
        end
    end

    return e("ScrollingFrame", {
        Size = UDim2.new(0, TREE_W, 1, -(TOP_BAR_H + HISTO_H + FOOTER_H)),
        Position = UDim2.fromOffset(0, TOP_BAR_H + HISTO_H),
        BackgroundColor3 = theme:color("surface"),
        BorderSizePixel = 0,
        CanvasSize = UDim2.fromOffset(0, y + 8),
        ScrollBarThickness = 6,
        ScrollBarImageColor3 = theme:color("borderStrong"),
    }, children)
end

-- ---------------------------------------------------------------------
-- Histogram strip (top, full width)
-- ---------------------------------------------------------------------

function GCHeapView:_renderHistogram()
    local theme = self.theme
    local snap = self.state.snapshot
    local children = {
        e("Frame", {
            Size = UDim2.fromScale(1, 1),
            BackgroundColor3 = theme:color("backgroundAlt"),
            BorderSizePixel = 0,
        }),
    }
    if snap and snap.shapeHistogram then
        local top = snap.shapeHistogram
        local maxN = 12
        local total = 0
        local rows = {}
        for shape, count in top do
            rows[#rows + 1] = { shape = shape, count = count }
            total = total + count
        end
        table.sort(rows, function(a, b) return a.count > b.count end)
        local W = self._histoWidth or 600
        local barW = math.max(8, math.floor((W - 12) / math.min(maxN, #rows)))
        for i = 1, math.min(maxN, #rows) do
            local r = rows[i]
            local h = math.max(2, math.floor((r.count / rows[1].count) * (HISTO_H - 8)))
            children[#children + 1] = e("Frame", {
                Size = UDim2.fromOffset(barW - 2, h),
                Position = UDim2.fromOffset(6 + (i - 1) * barW, HISTO_H - 4 - h),
                BackgroundColor3 = theme:color("accent"),
                BorderSizePixel = 0,
                [Event.InputBegan] = function(_rbx, input)
                    if input.UserInputType == Enum.UserInputType.MouseButton1 then
                        self:setState({
                            categoryFilter = { kind = "shape", key = r.shape },
                            filteredCache  = nil,
                        })
                    end
                end,
            })
        end
        children[#children + 1] = e("TextLabel", {
            Size = UDim2.new(1, -8, 0, 14),
            Position = UDim2.fromOffset(6, 2),
            BackgroundTransparency = 1,
            Text = string.format("Table shapes (%d distinct)", #rows),
            TextColor3 = theme:color("textMuted"),
            TextSize = 10,
            Font = Enum.Font.Code,
            TextXAlignment = Enum.TextXAlignment.Left,
        })
    end
    return e("Frame", {
        Name = "histogram",
        Size = UDim2.new(1, 0, 0, HISTO_H),
        Position = UDim2.fromOffset(0, TOP_BAR_H),
        BackgroundTransparency = 1,
        [Element.Changed.AbsoluteSize] = function(rbx)
            self._histoWidth = rbx.AbsoluteSize.X
        end,
    }, children)
end

-- ---------------------------------------------------------------------
-- Center list
-- ---------------------------------------------------------------------

function GCHeapView:_renderObjectRow(obj, idx, totalW)
    local theme = self.theme
    local rowBg = (idx % 2 == 0) and theme:color("backgroundAlt") or theme:color("background")
    local selected = self.state.selectedObject == obj
    if selected then rowBg = theme:color("primaryMuted") end

    local label = obj.label or obj.name or tostring(obj.id or "?")
    return e("Frame", {
        Name = "row_" .. tostring(obj.id or idx),
        Size = UDim2.new(1, 0, 0, ROW_H),
        BackgroundColor3 = rowBg,
        BorderSizePixel = 0,
        [Event.InputBegan] = function(_rbx, input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 then
                self:setState({ selectedObject = obj })
                if self.props.onSelectObject then
                    self.props.onSelectObject(obj)
                end
            end
        end,
    }, {
        e("TextLabel", {
            Size = UDim2.fromOffset(60, ROW_H - 2),
            Position = UDim2.fromOffset(4, 1),
            BackgroundTransparency = 1,
            Text = obj.type or "?",
            TextColor3 = theme:color("textMuted"),
            TextSize = 11,
            Font = Enum.Font.Code,
            TextXAlignment = Enum.TextXAlignment.Left,
        }),
        e("TextLabel", {
            Size = UDim2.fromOffset(70, ROW_H - 2),
            Position = UDim2.fromOffset(68, 1),
            BackgroundTransparency = 1,
            Text = obj.source or "",
            TextColor3 = theme:color("textMuted"),
            TextSize = 11,
            Font = Enum.Font.Code,
            TextXAlignment = Enum.TextXAlignment.Left,
        }),
        e("TextLabel", {
            Size = UDim2.new(1, -(60 + 70 + 8 + 8), 0, ROW_H - 2),
            Position = UDim2.fromOffset(142, 1),
            BackgroundTransparency = 1,
            Text = label,
            TextColor3 = theme:color("text"),
            TextSize = 12,
            Font = Enum.Font.Code,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd,
            ClipsDescendants = true,
        }),
    })
end

-- ---------------------------------------------------------------------
-- Right inspector pane
-- ---------------------------------------------------------------------

function GCHeapView:_renderInspector()
    local theme = self.theme
    local obj = self.state.selectedObject
    local lines = {}
    if not obj then
        lines[#lines + 1] = "(no selection)"
    else
        lines[#lines + 1] = string.format("Type:    %s", obj.type or "?")
        lines[#lines + 1] = string.format("Source:  %s", obj.source or "")
        lines[#lines + 1] = string.format("Label:   %s", obj.label or "")
        if obj.id then lines[#lines + 1] = string.format("Id:      %s", tostring(obj.id)) end
        if obj.shapeHash then lines[#lines + 1] = string.format("Shape:   %s", obj.shapeHash) end
        if obj.mtClass then lines[#lines + 1] = string.format("MtClass: %s", obj.mtClass) end
        if obj.numFields then lines[#lines + 1] = string.format("Fields:  %d", obj.numFields) end
        if obj.numUpvalues then lines[#lines + 1] = string.format("Upvals:  %d", obj.numUpvalues) end
        if obj.numConstants then lines[#lines + 1] = string.format("Consts:  %d", obj.numConstants) end
        if obj.threadStatus then lines[#lines + 1] = string.format("Status:  %s", obj.threadStatus) end
        if obj.upvalues then
            lines[#lines + 1] = ""
            lines[#lines + 1] = "Upvalues:"
            for i, uv in obj.upvalues do
                lines[#lines + 1] = string.format("  [%d] %s = %s",
                    i, uv.name or "?", tostring(uv.value))
                if i >= 24 then lines[#lines + 1] = "  …"; break end
            end
        end
        if obj.shape then
            lines[#lines + 1] = ""
            lines[#lines + 1] = "Shape sample:"
            for i, f in obj.shape do
                lines[#lines + 1] = string.format("  %s : %s", f.key or "?", f.kind or "?")
                if i >= 24 then lines[#lines + 1] = "  …"; break end
            end
        end
    end
    return e("Frame", {
        Name = "inspector",
        Size = UDim2.new(0, INSPECTOR_W, 1, -(TOP_BAR_H + HISTO_H + FOOTER_H)),
        Position = UDim2.new(1, -INSPECTOR_W, 0, TOP_BAR_H + HISTO_H),
        BackgroundColor3 = theme:color("surface"),
        BorderSizePixel = 0,
    }, {
        e("ScrollingFrame", {
            Size = UDim2.fromScale(1, 1),
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            CanvasSize = UDim2.fromOffset(0, #lines * 16 + 16),
            ScrollBarThickness = 6,
            ScrollBarImageColor3 = theme:color("borderStrong"),
        }, (function()
            local out = {}
            for i, line in lines do
                out[#out + 1] = e("TextLabel", {
                    Size = UDim2.new(1, -8, 0, 14),
                    Position = UDim2.fromOffset(6, 4 + (i - 1) * 16),
                    BackgroundTransparency = 1,
                    Text = line,
                    TextColor3 = self.theme:color("text"),
                    TextSize = 12,
                    Font = Enum.Font.Code,
                    TextXAlignment = Enum.TextXAlignment.Left,
                    TextTruncate = Enum.TextTruncate.AtEnd,
                    ClipsDescendants = true,
                })
            end
            return out
        end)()),
    })
end

-- ---------------------------------------------------------------------
-- Top bar (scan button + filters)
-- ---------------------------------------------------------------------

function GCHeapView:_renderTopBar()
    local theme = self.theme
    return e("Frame", {
        Name = "topbar",
        Size = UDim2.new(1, 0, 0, TOP_BAR_H),
        BackgroundColor3 = theme:color("surfaceAlt"),
        BorderSizePixel = 0,
    }, {
        e("TextButton", {
            Size = UDim2.fromOffset(80, TOP_BAR_H - 6),
            Position = UDim2.fromOffset(4, 3),
            BackgroundColor3 = self.state.scanning and theme:color("surfaceAlt")
                or theme:color("surface"),
            BorderColor3 = theme:color("border"),
            BorderSizePixel = 1,
            Text = self.state.scanning and "Scanning…" or "Scan",
            TextColor3 = theme:color("text"),
            TextSize = 12,
            Font = Enum.Font.Code,
            AutoButtonColor = not self.state.scanning,
            [Event.Activated] = function()
                if not self.state.scanning then self:_scan() end
            end,
        }),
        e("TextBox", {
            Size = UDim2.new(1, -(80 + 16), 0, TOP_BAR_H - 6),
            Position = UDim2.fromOffset(92, 3),
            BackgroundColor3 = theme:color("surfaceAlt"),
            BorderColor3 = theme:color("border"),
            BorderSizePixel = 1,
            Text = self.state.searchText,
            PlaceholderText = "Filter heap objects…",
            TextColor3 = theme:color("text"),
            PlaceholderColor3 = theme:color("textMuted"),
            TextSize = 12,
            Font = Enum.Font.Code,
            TextXAlignment = Enum.TextXAlignment.Left,
            ClearTextOnFocus = false,
            [Element.Changed.Text] = function(rbx)
                if rbx.Text == self.state.searchText then return end
                self:setState({ searchText = rbx.Text, filteredCache = nil })
            end,
        }, {
            e("UIPadding", { PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6) }),
        }),
    })
end

-- ---------------------------------------------------------------------
-- Render
-- ---------------------------------------------------------------------

function GCHeapView:render()
    local theme = self.theme
    local objects = self:_filteredObjects()
    local snap = self.state.snapshot

    return e("Frame", {
        Name = "GCHeapView",
        Size = self.props.Size,
        Position = self.props.Position or UDim2.fromOffset(0, 0),
        BackgroundColor3 = theme:color("surface"),
        BorderSizePixel = 0,
    }, {
        self:_renderTopBar(),
        self:_renderHistogram(),
        self:_renderCategoryTree(),
        self:_renderInspector(),

        -- Center virtualized list
        e(ScrollVirtualizer, {
            Size = UDim2.new(1, -(TREE_W + INSPECTOR_W), 1, -(TOP_BAR_H + HISTO_H + FOOTER_H)),
            Position = UDim2.fromOffset(TREE_W, TOP_BAR_H + HISTO_H),
            items     = objects,
            itemCount = #objects,
            itemHeight = ROW_H,
            renderItem = function(item, i, _isOdd)
    -- Fall back to looking up by index if items prop wasn't passed
    local row = item ~= nil and item or (objects and objects[i])
    if row == nil then return nil end
    return self:_renderObjectRow(row, i, _isOdd)
            end,
        }),

        -- Footer
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
                Text = (snap and string.format(
                    "%d objects · %d functions · %d tables · scan @ %.1fs ago",
                    (snap.summary and snap.summary.totalObjects)
                        or (snap.objects and #snap.objects) or 0,
                    (snap.summary and snap.summary.byType and snap.summary.byType["function"])
                        or (snap.functions and #snap.functions) or 0,
                    (snap.summary and snap.summary.byType and snap.summary.byType.table)
                        or (snap.tables and #snap.tables) or 0,
                    os.clock() - self.state.lastScanAt))
                    or "no snapshot",
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

return GCHeapView
