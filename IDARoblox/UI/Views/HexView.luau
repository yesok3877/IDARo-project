--!nonstrict
-- =====================================================================
-- IDARoblox / UI / Views / HexView
-- ---------------------------------------------------------------------
-- Hex dump of a proto's raw instruction bytes.
--
-- Each Luau instruction is a 32-bit little-endian word. We unpack each
-- word to four bytes and display 16 bytes (= 4 instructions) per row.
-- This gives the classic IDA-style hex view that sits alongside the
-- disassembly text.
--
-- Layout per row:
--   {byteOffset}   {b0} {b1} … {bF}   {ascii printable / .}
--
-- Selected PC: highlights the row containing that instruction in
-- `primaryMuted` and bolds the bytes of that specific instruction.
--
-- Props:
--   proto       — proto whose instructions to display
--   selectedPc  — currently-focused PC
--   onSelectPc  — fn(pc, row) when a row is clicked
-- =====================================================================

local Component         = _G.IDARo.require("UI.Framework.Component")
local Element           = _G.IDARo.require("UI.Framework.Element")
local ScrollVirtualizer = _G.IDARo.require("UI.Framework.ScrollVirtualizer")
local e                 = Element.create
local Event             = Element.Event

local HexView = Component.extend("HexView")

Component.setDefaultProps(HexView, {
    proto      = nil,
    selectedPc = nil,
    onSelectPc = nil,
    Size       = UDim2.fromScale(1, 1),
    Position   = UDim2.fromOffset(0, 0),
})

local ROW_HEIGHT          = 18
local HEADER_H            = 28
local FOOTER_H            = 20
local INSTRUCTIONS_PER_ROW = 4
local BYTES_PER_ROW       = INSTRUCTIONS_PER_ROW * 4

-- ---------------------------------------------------------------------
-- Unpacking
-- ---------------------------------------------------------------------

local function unpackBytes(insn)
    local b0 = bit32.band(insn, 0xFF)
    local b1 = bit32.band(bit32.rshift(insn, 8),  0xFF)
    local b2 = bit32.band(bit32.rshift(insn, 16), 0xFF)
    local b3 = bit32.band(bit32.rshift(insn, 24), 0xFF)
    return b0, b1, b2, b3
end

local function byteAscii(b)
    if b >= 0x20 and b < 0x7F then return string.char(b) end
    return "."
end

-- Build the rows of the hex view: each row holds INSTRUCTIONS_PER_ROW
-- instruction words plus their byte-level breakdown.
local function buildRows(proto)
    if not proto or not proto.instructions then return {} end
    local rows = {}
    local insns = proto.instructions
    local total = proto.sizecode or #insns
    local rowCount = math.ceil(total / INSTRUCTIONS_PER_ROW)
    for r = 1, rowCount do
        local firstPc = (r - 1) * INSTRUCTIONS_PER_ROW + 1
        local row = {
            firstPc  = firstPc,
            bytes    = {},
            ascii    = {},
            pcRange  = {},
        }
        for i = 1, INSTRUCTIONS_PER_ROW do
            local pc = firstPc + (i - 1)
            local insn = insns[pc]
            row.pcRange[i] = pc
            if insn then
                local b0, b1, b2, b3 = unpackBytes(insn)
                row.bytes[(i-1)*4 + 1] = b0
                row.bytes[(i-1)*4 + 2] = b1
                row.bytes[(i-1)*4 + 3] = b2
                row.bytes[(i-1)*4 + 4] = b3
                row.ascii[(i-1)*4 + 1] = byteAscii(b0)
                row.ascii[(i-1)*4 + 2] = byteAscii(b1)
                row.ascii[(i-1)*4 + 3] = byteAscii(b2)
                row.ascii[(i-1)*4 + 4] = byteAscii(b3)
            end
        end
        rows[r] = row
    end
    return rows
end

-- ---------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------

function HexView:init(props)
    self.state = { rows = buildRows(props.proto) }
end

function HexView:willUpdate(nextProps)
    if nextProps.proto ~= self.props.proto then
        self.state.rows = buildRows(nextProps.proto)
    end
end

-- ---------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------

function HexView:_renderHeader()
    local theme = self.theme
    return e("Frame", {
        Size             = UDim2.new(1, 0, 0, HEADER_H),
        BackgroundColor3 = theme:color("surfaceAlt"),
        BorderSizePixel  = 0,
    }, {
        e("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) }),
        e("TextLabel", {
            Text = string.format("Hex dump — %s",
                self.props.proto
                and (self.props.proto.debugName and self.props.proto.debugName ~= ""
                    and self.props.proto.debugName
                    or string.format("p[%d]", self.props.proto.id or -1))
                or "(no proto)"),
            Font = Enum.Font.GothamMedium,
            TextSize = theme:size("font.ui"),
            TextColor3 = theme:color("text"),
            TextXAlignment = Enum.TextXAlignment.Left,
            BackgroundTransparency = 1,
            Size = UDim2.fromScale(1, 1),
        }),
    })
end

function HexView:_renderRow(row, _idx, isOdd)
    local theme = self.theme
    local addrText = string.format("%06X", (row.firstPc - 1) * 4)
    local bytesParts = {}
    local asciiParts = {}
    for i = 1, BYTES_PER_ROW do
        local b = row.bytes[i]
        bytesParts[i] = b and string.format("%02X", b) or "  "
        asciiParts[i] = b and row.ascii[i] or " "
        if i == 4 or i == 8 or i == 12 then
            bytesParts[i] = bytesParts[i] .. " "                     -- group separator
        end
    end
    local bytesStr = table.concat(bytesParts, " ")
    local asciiStr = table.concat(asciiParts)

    local selected = false
    if self.props.selectedPc then
        for _, pc in row.pcRange do
            if pc == self.props.selectedPc then selected = true; break end
        end
    end

    local bg
    if selected then bg = theme:color("primaryMuted")
    elseif isOdd then bg = theme:color("disassemblyRowOdd")
    else                bg = theme:color("disassemblyRowEven") end

    return e("TextButton", {
        Size             = UDim2.new(1, 0, 1, 0),
        Text             = "",
        AutoButtonColor  = false,
        BackgroundColor3 = bg,
        BorderSizePixel  = 0,
        [Event.Activated] = function()
            if self.props.onSelectPc and row.firstPc then
                pcall(self.props.onSelectPc, row.firstPc, row)
            end
        end,
        [Event.MouseEnter] = function(inst)
            if not selected then
                pcall(function() inst.BackgroundColor3 = theme:color("surfaceHover") end)
            end
        end,
        [Event.MouseLeave] = function(inst)
            if not selected then
                pcall(function() inst.BackgroundColor3 = bg end)
            end
        end,
    }, {
        -- Address gutter
        e("TextLabel", {
            key = "addr", Position = UDim2.fromOffset(8, 0),
            Size = UDim2.fromOffset(80, ROW_HEIGHT),
            Text = addrText,
            Font = Enum.Font.RobotoMono,
            TextSize = theme:size("font.mono") - 1,
            TextColor3 = theme:color("disassemblyAddr"),
            TextXAlignment = Enum.TextXAlignment.Left,
            BackgroundTransparency = 1,
        }),
        -- Hex bytes
        e("TextLabel", {
            key = "bytes", Position = UDim2.fromOffset(96, 0),
            Size = UDim2.new(0.6, -96, 0, ROW_HEIGHT),
            Text = bytesStr,
            Font = Enum.Font.RobotoMono,
            TextSize = theme:size("font.mono") - 1,
            TextColor3 = theme:color("text"),
            TextXAlignment = Enum.TextXAlignment.Left,
            BackgroundTransparency = 1,
        }),
        -- Separator
        e("Frame", {
            key = "sep",
            Position = UDim2.new(0.6, 4, 0, 2),
            Size = UDim2.new(0, 1, 0, ROW_HEIGHT - 4),
            BackgroundColor3 = theme:color("border"),
            BorderSizePixel = 0,
        }),
        -- ASCII column
        e("TextLabel", {
            key = "ascii", Position = UDim2.new(0.6, 12, 0, 0),
            Size = UDim2.new(0.4, -16, 0, ROW_HEIGHT),
            Text = asciiStr,
            Font = Enum.Font.RobotoMono,
            TextSize = theme:size("font.mono") - 1,
            TextColor3 = theme:color("textMuted"),
            TextXAlignment = Enum.TextXAlignment.Left,
            BackgroundTransparency = 1,
        }),
    })
end

function HexView:_renderFooter()
    local theme = self.theme
    local total = self.state.rows and #self.state.rows or 0
    local proto = self.props.proto
    local insnCount = proto and proto.sizecode or 0
    return e("Frame", {
        Size             = UDim2.new(1, 0, 0, FOOTER_H),
        Position         = UDim2.new(0, 0, 1, -FOOTER_H),
        BackgroundColor3 = theme:color("surfaceAlt"),
        BorderSizePixel  = 0,
    }, {
        e("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) }),
        e("TextLabel", {
            Text = string.format("%d instructions · %d bytes · %d row%s",
                insnCount, insnCount * 4, total, total == 1 and "" or "s"),
            Font = Enum.Font.Gotham,
            TextSize = theme:size("font.ui") - 2,
            TextColor3 = theme:color("textMuted"),
            TextXAlignment = Enum.TextXAlignment.Left,
            BackgroundTransparency = 1,
            Size = UDim2.fromScale(1, 1),
        }),
    })
end

function HexView:render()
    local theme = self.theme
    if not self.props.proto then
        return e("Frame", {
            Size = self.props.Size, Position = self.props.Position,
            BackgroundColor3 = theme:color("background"), BorderSizePixel = 0,
        }, {
            e("TextLabel", {
                Size = UDim2.fromScale(1, 1),
                Text = "no proto loaded",
                Font = Enum.Font.Gotham, TextSize = theme:size("font.ui"),
                TextColor3 = theme:color("textMuted"),
                BackgroundTransparency = 1,
            }),
        })
    end
    local rows = self.state.rows or {}
    return e("Frame", {
        Size = self.props.Size, Position = self.props.Position,
        BackgroundColor3 = theme:color("background"), BorderSizePixel = 0,
    }, {
        self:_renderHeader(),
        e(ScrollVirtualizer, {
            key = "body", Position = UDim2.fromOffset(0, HEADER_H),
            Size = UDim2.new(1, 0, 1, -(HEADER_H + FOOTER_H)),
            items = rows, itemCount = #rows, rowHeight = ROW_HEIGHT,
            overscan = 12,
            renderItem = function(item, idx, isOdd) return self:_renderRow(item, idx, isOdd) end,
        }),
        self:_renderFooter(),
    })
end

return HexView
