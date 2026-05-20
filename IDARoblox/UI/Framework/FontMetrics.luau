--!nonstrict
-- =====================================================================
-- IDARoblox / UI / Framework / FontMetrics
-- ---------------------------------------------------------------------
-- Text measurement for layout. Heavily-cached because TextService calls
-- are not free.
--
-- API:
--   metrics:measure(text, font, size)           -> Vector2
--   metrics:cellSize(font, size)                -> Vector2  (mono char)
--   metrics:lineHeight(font, size)              -> number
--   metrics:columnFromPixel(font, size, x)      -> number  (mono only)
--   metrics:pixelFromColumn(font, size, col)    -> number  (mono only)
--   metrics:wrap(text, font, size, maxWidth)    -> { string }
--
-- Cache key is (font, size). The TextService global is fetched lazily
-- so the module also imports cleanly in test harnesses without the
-- service registry.
-- =====================================================================

local FontMetrics = {}
FontMetrics.__index = FontMetrics

local LARGE_FRAME = Vector2.new(10000, 10000)

local function getTextService()
    local ok, ts = pcall(function() return game:GetService("TextService") end)
    return ok and ts or nil
end

function FontMetrics.new(opts)
    opts = opts or {}
    local self = setmetatable({
        _ts             = getTextService(),
        _cellCache      = {},                                       -- (font:size) -> Vector2
        _measureCache   = {},                                       -- (font:size:text) -> Vector2
        _measureCacheCap = opts.cacheCap or 2048,
        _measureCacheN  = 0,
        _wrapCache      = {},
        _tabWidth       = opts.tabWidth or 4,                       -- columns
    }, FontMetrics)
    return self
end

-- ---------------------------------------------------------------------
-- Internal: stable cache key
-- ---------------------------------------------------------------------

local function fontKey(font): string
    if typeof(font) == "Font" then
        return font.Family .. "|" .. tostring(font.Weight.Value) .. "|" .. tostring(font.Style.Value)
    end
    return tostring(font)
end

local function cellKey(font, size: number)
    return fontKey(font) .. "@" .. tostring(size)
end

local function measureKey(font, size: number, text: string)
    return fontKey(font) .. "@" .. tostring(size) .. "/" .. text
end

-- ---------------------------------------------------------------------
-- Measurement
-- ---------------------------------------------------------------------

local function rawMeasure(self, text, font, size): Vector2
    if not self._ts then
        -- Fallback approximation when TextService is unavailable: assume a
        -- monospace cell of (size * 0.6, size * 1.2) and multiply by length.
        return Vector2.new(#text * size * 0.6, size * 1.2)
    end
    -- Roblox API differs across versions: prefer GetTextSize, fall back to
    -- GetTextBoundsAsync's sync sibling GetTextSize when font is Font object.
    local ok, result
    if typeof(font) == "Font" and type(self._ts.GetTextBoundsAsync) == "function" then
        local params = Instance.new("GetTextBoundsParams")
        params.Text = text
        params.Font = font
        params.Size = size
        params.Width = LARGE_FRAME.X
        ok, result = pcall(function() return self._ts:GetTextBoundsAsync(params) end)
        if ok and typeof(result) == "Vector2" then return result end
    end
    ok, result = pcall(function()
        return self._ts:GetTextSize(text, size,
            typeof(font) == "EnumItem" and font or Enum.Font.SourceSans,
            LARGE_FRAME)
    end)
    if ok and typeof(result) == "Vector2" then return result end
    return Vector2.new(#text * size * 0.6, size * 1.2)
end

function FontMetrics:measure(text: string, font, size: number): Vector2
    if text == "" then return Vector2.new(0, size * 1.2) end
    local key = measureKey(font, size, text)
    local cached = self._measureCache[key]
    if cached then return cached end
    if self._measureCacheN >= self._measureCacheCap then
        -- Cheap full flush — measurement is a hot path and we don't want
        -- the cache to grow unbounded but also don't want LRU overhead.
        self._measureCache = {}
        self._measureCacheN = 0
    end
    local v = rawMeasure(self, text, font, size)
    self._measureCache[key] = v
    self._measureCacheN += 1
    return v
end

function FontMetrics:cellSize(font, size: number): Vector2
    local key = cellKey(font, size)
    local cached = self._cellCache[key]
    if cached then return cached end
    -- Use "M" as a representative monospace character; for a true mono
    -- font every glyph is the same width.
    local width = rawMeasure(self, "M", font, size).X
    -- Height: use the bounds of a tall character
    local height = rawMeasure(self, "Mq", font, size).Y
    local v = Vector2.new(width, height)
    self._cellCache[key] = v
    return v
end

function FontMetrics:lineHeight(font, size: number): number
    return self:cellSize(font, size).Y
end

function FontMetrics:columnFromPixel(font, size: number, x: number): number
    local cell = self:cellSize(font, size)
    if cell.X <= 0 then return 0 end
    return math.floor(x / cell.X + 0.5)
end

function FontMetrics:pixelFromColumn(font, size: number, col: number): number
    return col * self:cellSize(font, size).X
end

-- ---------------------------------------------------------------------
-- Tab handling
-- ---------------------------------------------------------------------

function FontMetrics:expandTabs(text: string, startCol: number?): (string, number)
    startCol = startCol or 0
    if string.find(text, "\t", 1, true) == nil then
        return text, startCol + #text
    end
    local out = {}
    local col = startCol
    for i = 1, #text do
        local c = string.sub(text, i, i)
        if c == "\t" then
            local pad = self._tabWidth - (col % self._tabWidth)
            out[#out + 1] = string.rep(" ", pad)
            col = col + pad
        else
            out[#out + 1] = c
            col = col + 1
        end
    end
    return table.concat(out), col
end

function FontMetrics:setTabWidth(n: number)
    if n < 1 then error("tabWidth must be >= 1", 2) end
    self._tabWidth = n
    self._wrapCache = {}
end

-- ---------------------------------------------------------------------
-- Word wrap (greedy)
-- ---------------------------------------------------------------------

function FontMetrics:wrap(text: string, font, size: number, maxWidth: number): { string }
    if maxWidth <= 0 then return { text } end
    local key = fontKey(font) .. "@" .. size .. "/" .. maxWidth .. ":" .. text
    local cached = self._wrapCache[key]
    if cached then return cached end

    local cell = self:cellSize(font, size)
    local lines = {}
    for paragraph in string.gmatch(text, "[^\n]*") do
        if #paragraph == 0 then
            lines[#lines + 1] = ""
        else
            local line, lineWidth = {}, 0
            for word, sep in string.gmatch(paragraph, "(%S+)(%s*)") do
                local ww = self:measure(word, font, size).X
                if lineWidth > 0 and lineWidth + ww > maxWidth then
                    lines[#lines + 1] = table.concat(line)
                    line, lineWidth = {}, 0
                end
                if ww > maxWidth then
                    -- Hard-break long words by column.
                    local maxCols = math.max(1, math.floor(maxWidth / cell.X))
                    local i = 1
                    while i <= #word do
                        local slice = string.sub(word, i, i + maxCols - 1)
                        if lineWidth > 0 then
                            lines[#lines + 1] = table.concat(line)
                            line, lineWidth = {}, 0
                        end
                        if i + maxCols - 1 >= #word then
                            line[#line + 1] = slice
                            lineWidth = self:measure(slice, font, size).X
                        else
                            lines[#lines + 1] = slice
                        end
                        i = i + maxCols
                    end
                else
                    line[#line + 1] = word
                    lineWidth = lineWidth + ww
                end
                if sep and sep ~= "" then
                    local sw = self:measure(sep, font, size).X
                    if lineWidth + sw > maxWidth then
                        lines[#lines + 1] = table.concat(line)
                        line, lineWidth = {}, 0
                    else
                        line[#line + 1] = sep
                        lineWidth = lineWidth + sw
                    end
                end
            end
            if #line > 0 then
                lines[#lines + 1] = table.concat(line)
            end
        end
    end
    self._wrapCache[key] = lines
    return lines
end

-- ---------------------------------------------------------------------
-- Invalidation
-- ---------------------------------------------------------------------

function FontMetrics:flush()
    self._cellCache    = {}
    self._measureCache = {}
    self._measureCacheN = 0
    self._wrapCache    = {}
end

return FontMetrics
