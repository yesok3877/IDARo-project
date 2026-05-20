--!nonstrict
-- =====================================================================
-- IDARoblox / UI / Views / NamesView
-- ---------------------------------------------------------------------
-- Browser for every proto that carries a non-empty debugName, plus the
-- number of NEWCLOSURE/DUPCLOSURE sites that instantiate it (from
-- XRefIndex.byClosure). Effectively the "Functions" tab in IDA Pro.
--
-- Props:
--   xrefIndex      — XRefIndex result
--   selectedProtoId
--   onSelectProto  — fn(protoId, entry) on click (the workspace uses this
--                    to open that proto)
--   onShowXrefs    — fn(protoId, entry) on Ctrl-click / context (defers
--                    to XRefView with kind="closure")
--
-- Layout:
--   Header (28 px): search box · count
--   Body: virtualized rows
--   Footer (20 px): totals
-- =====================================================================

local Component         = _G.IDARo.require("UI.Framework.Component")
local Element           = _G.IDARo.require("UI.Framework.Element")
local ScrollVirtualizer = _G.IDARo.require("UI.Framework.ScrollVirtualizer")
local e                 = Element.create
local Event             = Element.Event

local NamesView = Component.extend("NamesView")

Component.setDefaultProps(NamesView, {
    xrefIndex       = nil,
    selectedProtoId = nil,
    onSelectProto   = nil,
    onShowXrefs     = nil,
    Size            = UDim2.fromScale(1, 1),
    Position        = UDim2.fromOffset(0, 0),
})

local ROW_HEIGHT = 20
local HEADER_H   = 28
local FOOTER_H   = 20

local COL_ID_W      = 56
local COL_INSN_W    = 64
local COL_PARAMS_W  = 56
local COL_REFS_W    = 70

function NamesView:init(props)
    self.state = {
        searchText = "",
        cached     = nil,
    }
    self:_recompute(props)
end

function NamesView:willUpdate(nextProps)
    if nextProps.xrefIndex ~= self.props.xrefIndex then
        self:_recompute(nextProps)
    end
end

function NamesView:_recompute(props)
    props = props or self.props
    if not props.xrefIndex then self.state.cached = {}; return end
    local list = props.xrefIndex:namedProtos()
    local needle = self.state.searchText ~= "" and string.lower(self.state.searchText) or nil
    local out = {}
    for _, entry in list do
        if needle and not string.find(string.lower(entry.debugName or ""), needle, 1, true) then
            -- skip
        else
            out[#out + 1] = entry
        end
    end
    self.state.cached = out
end

function NamesView:_setSearch(text)
    self.state.searchText = text
    self:_recompute()
    self:setState({})
end

-- ---------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------

function NamesView:_renderHeader()
    local theme = self.theme
    return e("Frame", {
        key              = "header",
        Size             = UDim2.new(1, 0, 0, HEADER_H),
        BackgroundColor3 = theme:color("surfaceAlt"),
        BorderSizePixel  = 0,
    }, {
        e("UIPadding", {
            PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6),
            PaddingTop  = UDim.new(0, 4), PaddingBottom = UDim.new(0, 4),
        }),
        e("UIListLayout", {
            FillDirection     = Enum.FillDirection.Horizontal,
            VerticalAlignment = Enum.VerticalAlignment.Center,
            SortOrder         = Enum.SortOrder.LayoutOrder,
            Padding           = UDim.new(0, 4),
        }),
        e("TextBox", {
            Size             = UDim2.fromOffset(220, HEADER_H - 8),
            PlaceholderText  = "  search names…",
            Text             = self.state.searchText,
            Font             = Enum.Font.RobotoMono,
            TextSize         = theme:size("font.ui") - 1,
            TextColor3       = theme:color("text"),
            PlaceholderColor3 = theme:color("textSubtle"),
            BackgroundColor3 = theme:color("background"),
            BorderSizePixel  = 0,
            ClearTextOnFocus = false,
            LayoutOrder      = 1,
            [Event.FocusLost] = function(inst) self:_setSearch(inst.Text) end,
        }, {
            e("UICorner", { CornerRadius = UDim.new(0, theme:radius("sm")) }),
            e("UIPadding", { PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6) }),
        }),
        e("TextLabel", {
            Size             = UDim2.fromOffset(160, HEADER_H - 8),
            Text             = "id   name                    insn  args  closures",
            Font             = Enum.Font.RobotoMono,
            TextSize         = theme:size("font.ui") - 2,
            TextColor3       = theme:color("textSubtle"),
            TextXAlignment   = Enum.TextXAlignment.Left,
            BackgroundTransparency = 1,
            LayoutOrder      = 2,
        }),
    })
end

function NamesView:_renderRow(entry, _index, isOdd)
    local theme = self.theme
    local selected = self.props.selectedProtoId == entry.protoId
    local bg
    if selected then bg = theme:color("primaryMuted")
    elseif isOdd then bg = theme:color("disassemblyRowOdd")
    else bg = theme:color("disassemblyRowEven") end

    return e("TextButton", {
        Size             = UDim2.new(1, 0, 1, 0),
        Text             = "",
        AutoButtonColor  = false,
        BackgroundColor3 = bg,
        BorderSizePixel  = 0,
        [Event.Activated] = function()
            if self.props.onSelectProto then
                pcall(self.props.onSelectProto, entry.protoId, entry)
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
        e("UIPadding", { PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6) }),
        e("TextLabel", {
            key            = "id",
            Position       = UDim2.fromOffset(0, 0),
            Size           = UDim2.fromOffset(COL_ID_W, ROW_HEIGHT),
            Text           = string.format("p%d", entry.protoId),
            Font           = Enum.Font.RobotoMono,
            TextSize       = theme:size("font.mono") - 1,
            TextColor3     = theme:color("disassemblyAddr"),
            TextXAlignment = Enum.TextXAlignment.Left,
            BackgroundTransparency = 1,
        }),
        e("TextLabel", {
            key            = "icon",
            Position       = UDim2.fromOffset(COL_ID_W + 4, 0),
            Size           = UDim2.fromOffset(16, ROW_HEIGHT),
            Text           = "ƒ",
            Font           = Enum.Font.GothamBold,
            TextSize       = theme:size("font.mono") - 1,
            TextColor3     = theme:color("primary"),
            BackgroundTransparency = 1,
        }),
        e("TextLabel", {
            key            = "name",
            Position       = UDim2.fromOffset(COL_ID_W + 22, 0),
            Size           = UDim2.new(1, -(COL_ID_W + 22 + COL_INSN_W + COL_PARAMS_W + COL_REFS_W + 12), 0, ROW_HEIGHT),
            Text           = entry.debugName or "(anonymous)",
            Font           = Enum.Font.RobotoMono,
            TextSize       = theme:size("font.mono"),
            TextColor3     = theme:color("text"),
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate   = Enum.TextTruncate.AtEnd,
            BackgroundTransparency = 1,
        }),
        e("TextLabel", {
            key            = "insn",
            AnchorPoint    = Vector2.new(1, 0),
            Position       = UDim2.new(1, -(COL_PARAMS_W + COL_REFS_W + 10), 0, 0),
            Size           = UDim2.fromOffset(COL_INSN_W, ROW_HEIGHT),
            Text           = tostring(entry.sizecode),
            Font           = Enum.Font.RobotoMono,
            TextSize       = theme:size("font.mono") - 1,
            TextColor3     = theme:color("disassemblyOperand"),
            TextXAlignment = Enum.TextXAlignment.Right,
            BackgroundTransparency = 1,
        }),
        e("TextLabel", {
            key            = "params",
            AnchorPoint    = Vector2.new(1, 0),
            Position       = UDim2.new(1, -(COL_REFS_W + 10), 0, 0),
            Size           = UDim2.fromOffset(COL_PARAMS_W, ROW_HEIGHT),
            Text           = tostring(entry.numparams),
            Font           = Enum.Font.RobotoMono,
            TextSize       = theme:size("font.mono") - 1,
            TextColor3     = theme:color("textSubtle"),
            TextXAlignment = Enum.TextXAlignment.Right,
            BackgroundTransparency = 1,
        }),
        e("TextLabel", {
            key            = "refs",
            AnchorPoint    = Vector2.new(1, 0),
            Position       = UDim2.new(1, -4, 0, 0),
            Size           = UDim2.fromOffset(COL_REFS_W, ROW_HEIGHT),
            Text           = entry.closureCount > 0
                and string.format("%d×", entry.closureCount) or "—",
            Font           = Enum.Font.RobotoMono,
            TextSize       = theme:size("font.mono") - 1,
            TextColor3     = entry.closureCount > 0
                and theme:color("disassemblyOperand")
                or theme:color("textSubtle"),
            TextXAlignment = Enum.TextXAlignment.Right,
            BackgroundTransparency = 1,
        }),
    })
end

function NamesView:_renderFooter()
    local theme = self.theme
    local rows = self.state.cached or {}
    return e("Frame", {
        key              = "footer",
        Size             = UDim2.new(1, 0, 0, FOOTER_H),
        Position         = UDim2.new(0, 0, 1, -FOOTER_H),
        BackgroundColor3 = theme:color("surfaceAlt"),
        BorderSizePixel  = 0,
    }, {
        e("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) }),
        e("TextLabel", {
            Text                  = string.format("%d named function%s", #rows,
                #rows == 1 and "" or "s"),
            Font                  = Enum.Font.Gotham,
            TextSize              = theme:size("font.ui") - 2,
            TextColor3            = theme:color("textMuted"),
            TextXAlignment        = Enum.TextXAlignment.Left,
            BackgroundTransparency = 1,
            Size                  = UDim2.fromScale(1, 1),
        }),
    })
end

function NamesView:render()
    local theme = self.theme
    if not self.props.xrefIndex then
        return e("Frame", {
            Size             = self.props.Size,
            Position         = self.props.Position,
            BackgroundColor3 = theme:color("background"),
            BorderSizePixel  = 0,
        }, {
            e("TextLabel", {
                Size             = UDim2.fromScale(1, 1),
                Text             = "no bytecode loaded",
                Font             = Enum.Font.Gotham,
                TextSize         = theme:size("font.ui"),
                TextColor3       = theme:color("textMuted"),
                BackgroundTransparency = 1,
            }),
        })
    end

    local rows = self.state.cached or {}
    return e("Frame", {
        Size             = self.props.Size,
        Position         = self.props.Position,
        BackgroundColor3 = theme:color("background"),
        BorderSizePixel  = 0,
    }, {
        self:_renderHeader(),
        e(ScrollVirtualizer, {
            key            = "body",
            Position       = UDim2.fromOffset(0, HEADER_H),
            Size           = UDim2.new(1, 0, 1, -(HEADER_H + FOOTER_H)),
            items          = rows,
            itemCount      = #rows,
            rowHeight      = ROW_HEIGHT,
            overscan       = 12,
            renderItem     = function(item, idx, isOdd) return self:_renderRow(item, idx, isOdd) end,
        }),
        self:_renderFooter(),
    })
end

return NamesView
