--!nonstrict
-- =====================================================================
-- IDARoblox / UI / Framework / ScrollVirtualizer
-- ---------------------------------------------------------------------
-- Renders a windowed slice of a potentially-huge item list. Only rows
-- within the visible viewport (plus an overscan buffer) become real
-- Roblox Instances; the rest exist only as user data.
--
-- Two modes:
--   * Fixed-height (rowHeight is a number) — O(1) index math, no row
--     measurement.
--   * Variable-height (rowHeight is a function returning per-row height)
--     — caches per-index heights and builds a prefix-sum table for O(log n)
--     index↔offset queries via binary search.
--
-- Usage:
--   e(ScrollVirtualizer, {
--       items     = aTable,                       -- length = itemCount
--       itemCount = #aTable,
--       rowHeight = 18,                           -- or function(i) return … end
--       overscan  = 10,
--       renderItem = function(item, index, isOdd) return e("Frame", ...) end,
--       Size      = UDim2.fromScale(1, 1),
--   })
-- =====================================================================

local Component = _G.IDARo.require("UI.Framework.Component")
local Element   = _G.IDARo.require("UI.Framework.Element")
local e         = Element.create
local Changed   = Element.Changed

local ScrollVirtualizer = Component.extend("ScrollVirtualizer")

Component.setDefaultProps(ScrollVirtualizer, {
    items       = nil,
    itemCount   = 0,
    rowHeight   = 18,
    overscan    = 8,
    renderItem  = nil,
    Size        = UDim2.fromScale(1, 1),
    Position    = UDim2.fromOffset(0, 0),
    background  = nil,                                              -- color key, default "background"
    onScroll    = nil,
    autoScrollToBottom = false,
    striped     = false,
})

-- ---------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------

function ScrollVirtualizer:init(props)
    self.state = {
        viewportSize  = Vector2.new(800, 600),
        canvasY       = 0,
        startIndex    = 1,
        endIndex      = 1,
        totalHeight   = 0,
    }
    self._scrollFrame = nil
    self._heightCache = {}                                         -- only used in variable mode
    self._prefixSums = nil                                         -- only built when needed
    self._lastItemCount = 0
    self:_rebuildHeights(props.itemCount, props.rowHeight)
end

function ScrollVirtualizer:didMount()
    self:_recalcWindow()
    if self.props.onMount then
        local ok, err = pcall(self.props.onMount, self)
        if not ok and self.logger then
            self.logger:warn("ScrollVirtualizer onMount error: %s", tostring(err))
        end
    end
end

function ScrollVirtualizer:willUnmount()
    if self.props.onUnmount then
        pcall(self.props.onUnmount, self)
    end
end

function ScrollVirtualizer:willUpdate(nextProps)
    if nextProps.itemCount ~= self.props.itemCount
        or nextProps.rowHeight ~= self.props.rowHeight then
        self:_rebuildHeights(nextProps.itemCount, nextProps.rowHeight)
    end
end

function ScrollVirtualizer:didUpdate(prevProps)
    if self.props.itemCount ~= prevProps.itemCount then
        self:_recalcWindow()
        if self.props.autoScrollToBottom and self._scrollFrame then
            local total = self.state.totalHeight
            self._scrollFrame.CanvasPosition = Vector2.new(0, math.max(0, total - self.state.viewportSize.Y))
        end
    end
end

-- ---------------------------------------------------------------------
-- Height management
-- ---------------------------------------------------------------------

function ScrollVirtualizer:_rebuildHeights(itemCount, rowHeight)
    if type(rowHeight) == "number" then
        self._heightCache = nil
        self._prefixSums  = nil
        self.state.totalHeight = itemCount * rowHeight
        self._lastItemCount = itemCount
        return
    end
    -- Variable: lazily fill cache, build prefix sums.
    local cache = self._heightCache or table.create(itemCount)
    local sums = table.create(itemCount + 1)
    sums[1] = 0
    local total = 0
    for i = 1, itemCount do
        local h = cache[i]
        if h == nil then
            local ok, v = pcall(rowHeight, i)
            h = (ok and type(v) == "number") and v or 18
            cache[i] = h
        end
        total = total + h
        sums[i + 1] = total
    end
    self._heightCache = cache
    self._prefixSums  = sums
    self.state.totalHeight = total
    self._lastItemCount = itemCount
end

function ScrollVirtualizer:_offsetOf(index: number): number
    if type(self.props.rowHeight) == "number" then
        return (index - 1) * self.props.rowHeight
    end
    return self._prefixSums and self._prefixSums[index] or 0
end

function ScrollVirtualizer:_heightOf(index: number): number
    if type(self.props.rowHeight) == "number" then return self.props.rowHeight end
    return (self._heightCache and self._heightCache[index]) or 18
end

-- Binary search: return first index whose offset is >= y
function ScrollVirtualizer:_indexAtOffset(y: number): number
    if type(self.props.rowHeight) == "number" then
        local rh = self.props.rowHeight
        return math.max(1, math.floor(y / rh) + 1)
    end
    local sums = self._prefixSums
    if not sums then return 1 end
    local lo, hi = 1, #sums
    while lo < hi do
        local mid = math.floor((lo + hi) / 2)
        if sums[mid] < y then lo = mid + 1 else hi = mid end
    end
    return math.max(1, lo - 1)
end

-- ---------------------------------------------------------------------
-- Window calc
-- ---------------------------------------------------------------------

function ScrollVirtualizer:_recalcWindow()
    local vy = self.state.viewportSize.Y
    local sy = self.state.canvasY
    local overscan = self.props.overscan
    local first = self:_indexAtOffset(sy) - overscan
    local last  = self:_indexAtOffset(sy + vy) + overscan
    if first < 1 then first = 1 end
    if last > self.props.itemCount then last = self.props.itemCount end
    if first > last then first = last end
    if first ~= self.state.startIndex or last ~= self.state.endIndex then
        self:setState({ startIndex = first, endIndex = last })
    end
end

-- ---------------------------------------------------------------------
-- Render
-- ---------------------------------------------------------------------

function ScrollVirtualizer:render()
    local theme = self.theme
    local props = self.props
    local renderItem = props.renderItem
    if type(renderItem) ~= "function" then
        return e("TextLabel", {
            Size = props.Size,
            Position = props.Position,
            Text = "ScrollVirtualizer: missing renderItem prop",
            TextColor3 = theme:color("danger"),
            BackgroundColor3 = theme:color("background"),
        })
    end

    local items = props.items
    local first, last = self.state.startIndex, self.state.endIndex
    -- Clamp against props.itemCount (and the items array length when
    -- provided) in case _render is called before _updateRange has
    -- clamped these state values (e.g. on initial mount when
    -- itemCount = 0).
    --
    -- Two calling conventions supported:
    --   (a) caller provides items array → we look up items[i] and pass
    --       it to renderItem alongside the index;
    --   (b) caller provides only itemCount + renderItem → we pass nil
    --       as the item and the caller's renderItem(item, i) does its
    --       own lookup by index. This is the common case for views
    --       that build a transient filtered array each render.
    local itemCountProp = props.itemCount or 0
    local upperBound = items and math.min(itemCountProp, #items) or itemCountProp
    if last > upperBound then last = upperBound end
    local rows = {}
    if upperBound > 0 and last >= first then
        for i = first, last do
            local item = items and items[i] or nil
            -- If an items array was provided but the slot is empty,
            -- skip (transient gap during a filter rescan). If no items
            -- array was provided, pass nil — caller looks up by index.
            local emptySlot = items ~= nil and item == nil
            if not emptySlot then
                local y = self:_offsetOf(i)
                local h = self:_heightOf(i)
                local element = renderItem(item, i, i % 2 == 1)
                if element then
                    rows[#rows + 1] = e("Frame", {
                        key              = "row:" .. i,
                        Size             = UDim2.new(1, 0, 0, h),
                        Position         = UDim2.fromOffset(0, y),
                        BackgroundColor3 = if self.props.striped and (i % 2 == 0)
                            then theme:color("surfaceAlt") else theme:color("background"),
                        BackgroundTransparency = if self.props.striped then 0 else 1,
                        BorderSizePixel  = 0,
                    }, { element })
                end
            end
        end
    end

    local bg = self.props.background and theme:color(self.props.background) or theme:color("background")

    return e("ScrollingFrame", {
        Size                     = props.Size,
        Position                 = props.Position,
        BackgroundColor3         = bg,
        BorderSizePixel          = 0,
        CanvasSize               = UDim2.new(0, 0, 0, self.state.totalHeight),
        ScrollBarThickness       = 6,
        ScrollBarImageColor3     = theme:color("border"),
        ScrollBarImageTransparency = 0.2,
        TopImage                 = "",
        BottomImage              = "",
        VerticalScrollBarInset   = Enum.ScrollBarInset.ScrollBar,
        ScrollingDirection       = Enum.ScrollingDirection.Y,
        ClipsDescendants         = true,
        AutomaticCanvasSize      = Enum.AutomaticSize.None,
        [Element.Ref] = function(instance)
            if instance then
                self._scrollFrame = instance
                local sz = instance.AbsoluteWindowSize
                local cur = self.state.viewportSize
                if not cur or cur.X ~= sz.X or cur.Y ~= sz.Y then
                    -- Defer the setState so it doesn't fire during the
                    -- reconcile that just mounted this frame (which
                    -- would trigger the cascade).
                    task.defer(function()
                        if not self.state or not self._mounted then return end
                        local sz2 = self._scrollFrame and self._scrollFrame.AbsoluteWindowSize or sz
                        local c = self.state.viewportSize
                        if c and c.X == sz2.X and c.Y == sz2.Y then return end
                        self:setState({ viewportSize = sz2 })
                    end)
                end
            else
                self._scrollFrame = nil
            end
        end,
        [Changed.AbsoluteWindowSize] = function(instance)
            -- Defer to escape the reconcile that just mounted this
            -- frame (see same comment in GraphCanvas:_onCanvasResize).
            if self._viewportPending then return end
            self._viewportPending = true
            task.defer(function()
                self._viewportPending = false
                if not self.state then return end
                local sz = instance.AbsoluteWindowSize
                if self.state.viewportSize
                    and sz.X == self.state.viewportSize.X
                    and sz.Y == self.state.viewportSize.Y then return end
                self:setState({ viewportSize = sz })
                self:_recalcWindow()
            end)
        end,
        [Changed.CanvasPosition] = function(instance)
            local y = instance.CanvasPosition.Y
            if y ~= self.state.canvasY then
                self.state.canvasY = y                              -- set without setState to avoid loop
                self:_recalcWindow()
                if self.props.onScroll then pcall(self.props.onScroll, y) end
            end
        end,
    }, rows)
end

-- ---------------------------------------------------------------------
-- Imperative API (via ref to ScrollVirtualizer component)
-- ---------------------------------------------------------------------

function ScrollVirtualizer:scrollToIndex(index: number, alignment: string?)
    if not self._scrollFrame then return end
    alignment = alignment or "top"
    local y = self:_offsetOf(index)
    if alignment == "center" then
        y = y + self:_heightOf(index) / 2 - self.state.viewportSize.Y / 2
    elseif alignment == "bottom" then
        y = y + self:_heightOf(index) - self.state.viewportSize.Y
    end
    y = math.max(0, math.min(y, self.state.totalHeight - self.state.viewportSize.Y))
    self._scrollFrame.CanvasPosition = Vector2.new(0, y)
end

function ScrollVirtualizer:scrollToBottom()
    if not self._scrollFrame then return end
    local y = math.max(0, self.state.totalHeight - self.state.viewportSize.Y)
    self._scrollFrame.CanvasPosition = Vector2.new(0, y)
end

function ScrollVirtualizer:invalidateHeights()
    self._heightCache = nil
    self:_rebuildHeights(self.props.itemCount, self.props.rowHeight)
    self:_recalcWindow()
end

return ScrollVirtualizer
