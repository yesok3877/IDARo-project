--!nonstrict
-- =====================================================================
-- IDARoblox / UI / Views / DisassemblyView
-- ---------------------------------------------------------------------
-- IDA-style disassembly listing for a single proto. Renders every row
-- from an InstructionStream (from Step 4's Disassembler) as a
-- monospace line with semantic colouring:
--
--   - addr column   — bar
--   - mnemonic      — instruction
--   - operands      — text colour by token kind (register / K / label)
--   - comments      — comment colour, after `;`
--   - label lines   — "loc_XXXX:" rendered as their own row above the
--                     instruction at that PC
--
-- Click handling:
--   - row click → onSelectRow(pc)
--   - row dbl-click → onActivateRow(pc); for branch rows, the parent
--     workspace scrolls to the target; for call/import rows, it can
--     hand off to a different view
--
-- Implementation notes:
--   - Each instruction row gets ROW_HEIGHT pixels. Rows with labels
--     get LABEL_HEIGHT extra (the label is drawn inside the row, above
--     the instruction line). This keeps row indexing in lock-step with
--     stream.rows[].
--   - All colour decisions go through the Theme so dark/light themes
--     work without per-component edits.
-- =====================================================================

local Component         = _G.IDARo.require("UI.Framework.Component")
local Element           = _G.IDARo.require("UI.Framework.Element")
local ScrollVirtualizer = _G.IDARo.require("UI.Framework.ScrollVirtualizer")
local e                 = Element.create
local Event             = Element.Event

local DisassemblyView = Component.extend("DisassemblyView")

Component.setDefaultProps(DisassemblyView, {
    stream         = nil,                                           -- InstructionStream
    selectedPc     = nil,
    onSelectRow    = nil,
    onActivateRow  = nil,                                            -- double click
    showLineInfo   = true,
    showRawWords   = false,
    Size           = UDim2.fromScale(1, 1),
    Position       = UDim2.fromOffset(0, 0),
})

local ROW_HEIGHT     = 18
local LABEL_HEIGHT   = 18
local ADDR_W         = 64
local MNEM_W         = 92
local OP_PAD         = 6

-- ---------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------

function DisassemblyView:init(props)
    self.state = {
        lastClickPc = nil,
        lastClickAt = 0,
    }
    self._virtComponent = nil                                       -- captured via ScrollVirtualizer onMount
end

function DisassemblyView:didMount()
    if self.props.onMount then
        local ok, err = pcall(self.props.onMount, self)
        if not ok and self.logger then
            self.logger:warn("DisassemblyView onMount error: %s", tostring(err))
        end
    end
end

function DisassemblyView:willUnmount()
    if self.props.onUnmount then pcall(self.props.onUnmount, self) end
end

-- ---------------------------------------------------------------------
-- Row geometry
-- ---------------------------------------------------------------------

local function rowHeightFor(row)
    return (row.label and LABEL_HEIGHT or 0) + ROW_HEIGHT
end

-- ---------------------------------------------------------------------
-- Click handling
-- ---------------------------------------------------------------------

function DisassemblyView:_onRowClick(row)
    local now = os.clock()
    local isDouble = self.state.lastClickPc == row.pc and (now - self.state.lastClickAt) < 0.4
    self.state.lastClickPc = row.pc
    self.state.lastClickAt = now
    if self.props.onSelectRow then pcall(self.props.onSelectRow, row.pc, row) end
    if isDouble and self.props.onActivateRow then
        pcall(self.props.onActivateRow, row.pc, row)
    end
end

-- ---------------------------------------------------------------------
-- Color choices
-- ---------------------------------------------------------------------

-- Map an operand or comment token to a theme colour key. The token
-- colour palette is defined in ThemeEngine as the "disassembly.*" set.
local function colorForKind(theme, kind: string): Color3
    if kind == "addr"     then return theme:color("disassemblyAddr")    end
    if kind == "mnem"     then return theme:color("disassemblyMnem")    end
    if kind == "op"       then return theme:color("disassemblyOperand") end
    if kind == "comment"  then return theme:color("disassemblyComment") end
    if kind == "label"    then return theme:color("disassemblyLabel")   end
    if kind == "selected" then return theme:color("primaryMuted")       end
    return theme:color("text")
end

-- ---------------------------------------------------------------------
-- Row renderer (called per virtual row)
-- ---------------------------------------------------------------------

function DisassemblyView:_renderRow(row, _index, isOdd)
    local theme    = self.theme
    local selected = row.pc == self.props.selectedPc
    local height   = rowHeightFor(row)

    local bg
    if selected then bg = theme:color("primaryMuted")
    elseif isOdd then bg = theme:color("disassemblyRowOdd")
    else bg = theme:color("disassemblyRowEven") end

    local kids = {}

    -- Optional label line at the top of this row's box
    if row.label then
        kids[#kids + 1] = e("TextLabel", {
            key            = "label",
            Position       = UDim2.fromOffset(0, 0),
            Size           = UDim2.new(1, 0, 0, LABEL_HEIGHT),
            Text           = row.label .. ":",
            Font           = Enum.Font.RobotoMono,
            TextSize       = theme:size("font.mono"),
            TextColor3     = colorForKind(theme, "label"),
            TextXAlignment = Enum.TextXAlignment.Left,
            BackgroundTransparency = 1,
        })
    end

    local yOff = row.label and LABEL_HEIGHT or 0

    -- Address column
    kids[#kids + 1] = e("TextLabel", {
        key            = "addr",
        Position       = UDim2.fromOffset(OP_PAD, yOff),
        Size           = UDim2.fromOffset(ADDR_W, ROW_HEIGHT),
        Text           = string.format("0x%04X", row.address),
        Font           = Enum.Font.RobotoMono,
        TextSize       = theme:size("font.mono"),
        TextColor3     = colorForKind(theme, "addr"),
        TextXAlignment = Enum.TextXAlignment.Left,
        BackgroundTransparency = 1,
    })

    -- Mnemonic column
    kids[#kids + 1] = e("TextLabel", {
        key            = "mnem",
        Position       = UDim2.fromOffset(OP_PAD + ADDR_W, yOff),
        Size           = UDim2.fromOffset(MNEM_W, ROW_HEIGHT),
        Text           = row.mnemonic or "",
        Font           = Enum.Font.RobotoMono,
        TextSize       = theme:size("font.mono"),
        TextColor3     = colorForKind(theme, "mnem"),
        TextXAlignment = Enum.TextXAlignment.Left,
        BackgroundTransparency = 1,
    })

    -- Operand text + (separator) comment text
    local commentText = nil
    if row.comments and #row.comments > 0 then
        commentText = "; " .. table.concat(row.comments, " · ")
    end
    if self.props.showLineInfo and row.line and row.line > 0 then
        commentText = (commentText or "; ") .. string.format("  (line %d)", row.line)
    end
    kids[#kids + 1] = e("TextLabel", {
        key            = "ops",
        Position       = UDim2.fromOffset(OP_PAD + ADDR_W + MNEM_W, yOff),
        Size           = UDim2.new(1, -(OP_PAD * 2 + ADDR_W + MNEM_W + 220), 0, ROW_HEIGHT),
        Text           = row.operandText or "",
        Font           = Enum.Font.RobotoMono,
        TextSize       = theme:size("font.mono"),
        TextColor3     = colorForKind(theme, "op"),
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate   = Enum.TextTruncate.AtEnd,
        BackgroundTransparency = 1,
    })
    if commentText then
        kids[#kids + 1] = e("TextLabel", {
            key            = "cmt",
            AnchorPoint    = Vector2.new(1, 0),
            Position       = UDim2.new(1, -OP_PAD, 0, yOff),
            Size           = UDim2.fromOffset(220, ROW_HEIGHT),
            Text           = commentText,
            Font           = Enum.Font.RobotoMono,
            TextSize       = theme:size("font.mono"),
            TextColor3     = colorForKind(theme, "comment"),
            TextXAlignment = Enum.TextXAlignment.Right,
            TextTruncate   = Enum.TextTruncate.AtEnd,
            BackgroundTransparency = 1,
        })
    end

    return e("TextButton", {
        Size             = UDim2.new(1, 0, 1, 0),
        Text             = "",
        AutoButtonColor  = false,
        BackgroundColor3 = bg,
        BorderSizePixel  = 0,
        [Event.Activated] = function() self:_onRowClick(row) end,
    }, kids)
end

-- ---------------------------------------------------------------------
-- Imperative: scroll to a PC
-- ---------------------------------------------------------------------

function DisassemblyView:scrollToPc(pc: number, alignment: string?)
    if not self._virtComponent then return end
    local stream = self.props.stream
    if not stream then return end
    -- Find the index of the row whose .pc == pc.
    for idx, row in stream.rows do
        if row.pc == pc then
            self._virtComponent:scrollToIndex(idx, alignment or "center")
            return
        end
    end
end

-- ---------------------------------------------------------------------
-- Render
-- ---------------------------------------------------------------------

function DisassemblyView:render()
    local theme = self.theme
    local stream = self.props.stream

    if not stream or #stream.rows == 0 then
        return e("Frame", {
            Size             = self.props.Size,
            Position         = self.props.Position,
            BackgroundColor3 = theme:color("background"),
            BorderSizePixel  = 0,
        }, {
            e("TextLabel", {
                Size             = UDim2.fromScale(1, 1),
                Text             = "no disassembly\n(select a proto)",
                Font             = Enum.Font.Gotham,
                TextSize         = theme:size("font.ui"),
                TextColor3       = theme:color("textMuted"),
                BackgroundTransparency = 1,
            }),
        })
    end

    local rows = stream.rows
    return e(ScrollVirtualizer, {
        Size           = self.props.Size,
        Position       = self.props.Position,
        items          = rows,
        itemCount      = #rows,
        rowHeight      = function(i) return rowHeightFor(rows[i]) end,
        overscan       = 12,
        striped        = false,
        background     = "background",
        renderItem     = function(item, index, isOdd) return self:_renderRow(item, index, isOdd) end,
        onMount        = function(component) self._virtComponent = component end,
        onUnmount      = function() self._virtComponent = nil end,
    })
end

return DisassemblyView
