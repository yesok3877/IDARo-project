--!nonstrict
-- =====================================================================
-- IDARoblox / UI / Widgets / HexEditor
-- ---------------------------------------------------------------------
-- Full-featured hex viewer / editor. Three columns:
--
--   ADDR          HEX BYTES (16 per row)             ASCII
--   00000000     48 65 6c 6c 6f 20 77 6f  72 6c 64 21 0d 0a 00 00   Hello world!....
--
-- Features
--   * Virtualized scrolling (rows constructed on demand)
--   * Per-byte selection: click to anchor, drag to extend
--   * Keyboard navigation: arrows / PgUp / PgDn / Home / End
--   * Edit mode: hex digits overwrite the selected byte (two-press
--     per byte; second press commits)
--   * Find: hex-byte-sequence search; arrow keys cycle hits
--   * Color rules: 00 → dim, printable → highlighted in ASCII col
--   * Read-only mode (default) and writable mode
--
-- Props
--   data           string of raw bytes
--   readonly       boolean (default true)
--   bytesPerRow    default 16
--   baseAddress    integer (display offset; default 0)
--   onByteEdit     fn(offset, newByte)
--   onSelect       fn(start, end) — byte offsets (inclusive)
--   findPattern    optional string of hex bytes to highlight
-- =====================================================================

local Component         = _G.IDARo.require("UI.Framework.Component")
local Element           = _G.IDARo.require("UI.Framework.Element")
local ScrollVirtualizer = _G.IDARo.require("UI.Framework.ScrollVirtualizer")
local UserInputService  = game:GetService("UserInputService")
local e = Element.create
local Event = Element.Event

local HexEditor = Component.extend("HexEditor")

Component.setDefaultProps(HexEditor, {
    data         = "",
    readonly     = true,
    bytesPerRow  = 16,
    baseAddress  = 0,
    onByteEdit   = nil,
    onSelect     = nil,
    findPattern  = nil,
    rowHeight    = 16,
    fontSize     = 13,
})

function HexEditor:init()
    self.state = {
        selectionStart = nil,
        selectionEnd   = nil,
        dragAnchor     = nil,
        editingOffset  = nil,
        editFirstNibble = nil,
        findMatches    = {},
    }
    self._keyConn = nil
end

function HexEditor:didMount()
    -- Capture keyboard while focused
    self._keyConn = UserInputService.InputBegan:Connect(function(input, processed)
        if processed then return end
        if not self._hasFocus then return end
        self:_handleKey(input)
    end)
    self:_recomputeFind()
end

function HexEditor:willUnmount()
    if self._keyConn then self._keyConn:Disconnect() end
end

function HexEditor:didUpdate(prevProps)
    if prevProps.findPattern ~= self.props.findPattern
        or prevProps.data ~= self.props.data then
        self:_recomputeFind()
    end
end

-- ---------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------

local function isPrintableByte(b) return b >= 32 and b <= 126 end
local function hexNibble(c)
    local b = string.byte(c)
    if b >= 48 and b <= 57 then return b - 48 end
    if b >= 65 and b <= 70 then return b - 55 end
    if b >= 97 and b <= 102 then return b - 87 end
    return nil
end

function HexEditor:_dataLen() return #self.props.data end
function HexEditor:_rowCount()
    local n = self:_dataLen()
    return math.ceil(n / self.props.bytesPerRow)
end

function HexEditor:_byteAt(off)
    if off < 0 or off >= self:_dataLen() then return nil end
    return string.byte(self.props.data, off + 1)
end

function HexEditor:_recomputeFind()
    local matches = {}
    local pattern = self.props.findPattern
    if pattern and pattern ~= "" then
        -- Parse hex bytes from pattern (e.g. "48 65 6c 6c 6f")
        local bytes = {}
        local hex = pattern:gsub("%s+", ""):gsub("0x", "")
        for i = 1, #hex - 1, 2 do
            local hi = hexNibble(string.sub(hex, i, i))
            local lo = hexNibble(string.sub(hex, i + 1, i + 1))
            if hi and lo then bytes[#bytes + 1] = hi * 16 + lo end
        end
        if #bytes > 0 then
            -- Naive scan; fine for the data sizes we expect (single proto bytecode)
            local data = self.props.data
            for off = 0, #data - #bytes do
                local match = true
                for j = 1, #bytes do
                    if string.byte(data, off + j) ~= bytes[j] then
                        match = false; break
                    end
                end
                if match then
                    matches[#matches + 1] = { start = off, length = #bytes }
                end
            end
        end
    end
    self:setState({ findMatches = matches })
end

-- Is `off` inside any current find-highlight match?
function HexEditor:_isFindHit(off)
    for _, m in self.state.findMatches do
        if off >= m.start and off < m.start + m.length then return true end
    end
    return false
end

function HexEditor:_isSelected(off)
    local s, eo = self.state.selectionStart, self.state.selectionEnd
    if not s or not eo then return false end
    if s > eo then s, eo = eo, s end
    return off >= s and off <= eo
end

-- ---------------------------------------------------------------------
-- Selection + click handlers
-- ---------------------------------------------------------------------

function HexEditor:_setSelection(s, eo)
    self:setState({ selectionStart = s, selectionEnd = eo or s })
    if self.props.onSelect then self.props.onSelect(s, eo or s) end
end

function HexEditor:_clickByte(off, modifiers)
    modifiers = modifiers or {}
    if modifiers.shift and self.state.selectionStart ~= nil then
        self:_setSelection(self.state.selectionStart, off)
    else
        self:_setSelection(off, off)
        self.state.dragAnchor = off
    end
    self._hasFocus = true
end

-- ---------------------------------------------------------------------
-- Keyboard handling
-- ---------------------------------------------------------------------

function HexEditor:_handleKey(input)
    local kc = input.KeyCode
    local s = self.state.selectionStart or 0
    local bpr = self.props.bytesPerRow
    local total = self:_dataLen()

    local function move(delta, modifiers)
        local n = math.max(0, math.min(total - 1, s + delta))
        if modifiers and modifiers.shift then
            self:_setSelection(self.state.selectionStart or n, n)
        else
            self:_setSelection(n, n)
        end
    end
    local mods = {
        shift = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
            or UserInputService:IsKeyDown(Enum.KeyCode.RightShift),
        ctrl = UserInputService:IsKeyDown(Enum.KeyCode.LeftControl)
            or UserInputService:IsKeyDown(Enum.KeyCode.RightControl),
    }
    if     kc == Enum.KeyCode.Left  then move(-1, mods)
    elseif kc == Enum.KeyCode.Right then move( 1, mods)
    elseif kc == Enum.KeyCode.Up    then move(-bpr, mods)
    elseif kc == Enum.KeyCode.Down  then move( bpr, mods)
    elseif kc == Enum.KeyCode.Home  then move(-(s % bpr), mods)
    elseif kc == Enum.KeyCode.End   then move(bpr - 1 - (s % bpr), mods)
    elseif kc == Enum.KeyCode.PageUp   then move(-bpr * 16, mods)
    elseif kc == Enum.KeyCode.PageDown then move( bpr * 16, mods)
    elseif (not self.props.readonly) and self.state.selectionStart then
        -- Hex digit edit
        local kcs = tostring(kc):gsub("Enum%.KeyCode%.", "")
        local digit = nil
        if string.match(kcs, "^Zero$") then digit = 0
        elseif string.match(kcs, "^One$") then digit = 1
        elseif string.match(kcs, "^Two$") then digit = 2
        elseif string.match(kcs, "^Three$") then digit = 3
        elseif string.match(kcs, "^Four$") then digit = 4
        elseif string.match(kcs, "^Five$") then digit = 5
        elseif string.match(kcs, "^Six$") then digit = 6
        elseif string.match(kcs, "^Seven$") then digit = 7
        elseif string.match(kcs, "^Eight$") then digit = 8
        elseif string.match(kcs, "^Nine$") then digit = 9
        else digit = hexNibble(string.lower(string.sub(kcs, 1, 1))) end
        if digit then
            local off = self.state.selectionStart
            local current = self:_byteAt(off) or 0
            if self.state.editFirstNibble == nil then
                -- First nibble: set high
                local newByte = digit * 16 + (current % 16)
                self.state.editFirstNibble = digit
                if self.props.onByteEdit then self.props.onByteEdit(off, newByte) end
            else
                local newByte = self.state.editFirstNibble * 16 + digit
                self.state.editFirstNibble = nil
                if self.props.onByteEdit then self.props.onByteEdit(off, newByte) end
                move(1, {})
            end
        end
    end
end

-- ---------------------------------------------------------------------
-- Render single row
-- ---------------------------------------------------------------------

function HexEditor:_renderRow(rowIdx)
    local theme = self.theme
    local bpr = self.props.bytesPerRow
    local startOff = rowIdx * bpr
    local addr = self.props.baseAddress + startOff
    local rowH = self.props.rowHeight
    local fontSize = self.props.fontSize

    local children = {}
    -- Address column
    children[#children + 1] = e("TextLabel", {
        Size = UDim2.new(0, 90, 1, 0),
        Position = UDim2.new(0, 4, 0, 0),
        Text = string.format("%08X", addr),
        Font = Enum.Font.Code,
        TextSize = fontSize,
        TextColor3 = theme:color("hexAddr"),
        TextXAlignment = Enum.TextXAlignment.Left,
        BackgroundTransparency = 1,
    })

    -- Hex byte cells
    local hexX = 100
    for i = 0, bpr - 1 do
        local off = startOff + i
        local b = self:_byteAt(off)
        if b ~= nil then
            local color = (b == 0) and theme:color("hexZero")
                or theme:color("hexByte")
            local bg
            if self:_isSelected(off) then
                bg = theme:color("hexSelectedBg")
            elseif self:_isFindHit(off) then
                bg = theme:color("hexFindBg")
            end
            local cellX = hexX + i * 22 + math.floor(i / 8) * 6     -- extra gap at midpoint
            local cell = e("TextButton", {
                Size = UDim2.new(0, 20, 1, 0),
                Position = UDim2.new(0, cellX, 0, 0),
                Text = string.format("%02X", b),
                Font = Enum.Font.Code,
                TextSize = fontSize,
                TextColor3 = color,
                BackgroundColor3 = bg or theme:color("transparent"),
                BackgroundTransparency = bg and 0 or 1,
                BorderSizePixel = 0,
                AutoButtonColor = false,
                [Event "Activated"] = function(_, input)
                    local mods = { shift = input and input:IsModifierKeyDown(Enum.ModifierKey.Shift) }
                    self:_clickByte(off, mods)
                end,
            })
            children[#children + 1] = cell
        end
    end

    -- ASCII column
    local asciiX = hexX + bpr * 22 + 8
    local asciiBuf = {}
    for i = 0, bpr - 1 do
        local off = startOff + i
        local b = self:_byteAt(off)
        if b then
            asciiBuf[#asciiBuf + 1] = isPrintableByte(b) and string.char(b) or "."
        else
            asciiBuf[#asciiBuf + 1] = " "
        end
    end
    children[#children + 1] = e("TextLabel", {
        Size = UDim2.new(0, bpr * 8 + 8, 1, 0),
        Position = UDim2.new(0, asciiX, 0, 0),
        Text = table.concat(asciiBuf),
        Font = Enum.Font.Code,
        TextSize = fontSize,
        TextColor3 = theme:color("hexAscii"),
        TextXAlignment = Enum.TextXAlignment.Left,
        BackgroundTransparency = 1,
    })

    return e("Frame", {
        Size = UDim2.new(1, 0, 0, rowH),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        LayoutOrder = rowIdx,
    }, children)
end

-- ---------------------------------------------------------------------
-- Render
-- ---------------------------------------------------------------------

function HexEditor:render()
    local rowCount = self:_rowCount()
    local rh       = self.props.rowHeight
    -- Build flat list of row indices for the virtualizer
    local items = table.create(rowCount)
    for i = 0, rowCount - 1 do items[i + 1] = i end

    return e("Frame", {
        Size = self.props.Size or UDim2.new(1, 0, 1, 0),
        Position = self.props.Position or UDim2.new(0, 0, 0, 0),
        BackgroundColor3 = self.theme:color("hexBg"),
        BorderSizePixel = 0,
        [Event "InputBegan"] = function(_, input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 then
                self._hasFocus = true
            end
        end,
    }, {
        e(ScrollVirtualizer, {
            Size = UDim2.new(1, 0, 1, 0),
            itemHeight = rh,
            items = items,
            renderItem = function(rowIdx) return self:_renderRow(rowIdx) end,
        })
    })
end

return HexEditor
