--!nonstrict
-- =====================================================================
-- IDARoblox / UI / Views / ProtoTreeView
-- ---------------------------------------------------------------------
-- Nested function-prototype browser.
--
-- Props:
--   bytecode        — ParsedBytecode result (must have .protos + .mainProtoId)
--   selectedProtoId — currently-selected proto id (nil = none)
--   onSelect        — fn(protoId) called when row clicked
--   onOpen          — fn(protoId) called on double-click / Enter
--   expandRoot      — boolean, default true; auto-expands the main proto
--
-- Internally maintains:
--   self.state.expanded[protoId] = boolean
--   self.state.flatRows           — array of {protoId, depth, hasChildren}
--                                   recomputed whenever expanded changes
-- =====================================================================

local Component          = _G.IDARo.require("UI.Framework.Component")
local Element            = _G.IDARo.require("UI.Framework.Element")
local ScrollVirtualizer  = _G.IDARo.require("UI.Framework.ScrollVirtualizer")
local e                  = Element.create
local Event              = Element.Event

local ProtoTreeView = Component.extend("ProtoTreeView")

Component.setDefaultProps(ProtoTreeView, {
    bytecode        = nil,
    selectedProtoId = nil,
    onSelect        = nil,
    onOpen          = nil,
    expandRoot      = true,
    Size            = UDim2.fromScale(1, 1),
    Position        = UDim2.fromOffset(0, 0),
})

local ROW_HEIGHT  = 36
local INDENT_PX   = 14
local CHEVRON_W   = 18

-- ---------------------------------------------------------------------
-- Tree flattening
-- ---------------------------------------------------------------------

local function buildFlat(bytecode, expanded): { any }
    local rows = {}
    if not bytecode or not bytecode.protos then return rows end
    local mainId = bytecode.mainProtoId
    local visited = {}

    local function visit(protoId, depth)
        if visited[protoId] then return end                          -- guard against bytecode bugs
        visited[protoId] = true
        local proto = bytecode.protos[protoId]
        if not proto then return end
        local children = proto.childProtoIds or {}
        rows[#rows + 1] = {
            protoId      = protoId,
            depth        = depth,
            hasChildren  = #children > 0,
            isExpanded   = expanded[protoId] == true,
            proto        = proto,
        }
        if expanded[protoId] then
            for _, childId in children do
                visit(childId, depth + 1)
            end
        end
    end

    visit(mainId, 0)
    -- Append any orphan protos (defensive — should never happen with
    -- well-formed bytecode but harmless if it does).
    for id, _ in bytecode.protos do
        if not visited[id] then
            visit(id, 0)
        end
    end
    return rows
end

-- ---------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------

function ProtoTreeView:init(props)
    self.state = {
        expanded   = {},
        flatRows   = {},
        clickCount = 0,
        lastClickPc = nil,
        lastClickAt = 0,
    }
    if props.bytecode and props.expandRoot then
        self.state.expanded[props.bytecode.mainProtoId] = true
    end
    self.state.flatRows = buildFlat(props.bytecode, self.state.expanded)
end

function ProtoTreeView:willUpdate(nextProps)
    if nextProps.bytecode ~= self.props.bytecode then
        local expanded = {}
        if nextProps.bytecode and nextProps.expandRoot then
            expanded[nextProps.bytecode.mainProtoId] = true
        end
        self.state.expanded = expanded
        self.state.flatRows = buildFlat(nextProps.bytecode, expanded)
    end
end

-- ---------------------------------------------------------------------
-- Interaction
-- ---------------------------------------------------------------------

function ProtoTreeView:_toggle(protoId)
    local expanded = table.clone(self.state.expanded)
    expanded[protoId] = not expanded[protoId]
    self:setState({
        expanded = expanded,
        flatRows = buildFlat(self.props.bytecode, expanded),
    })
end

function ProtoTreeView:_onRowClick(row)
    local now = os.clock()
    local isDoubleClick = self.state.lastClickPc == row.protoId
        and (now - self.state.lastClickAt) < 0.4
    self.state.lastClickPc = row.protoId
    self.state.lastClickAt = now

    if self.props.onSelect then pcall(self.props.onSelect, row.protoId) end
    if isDoubleClick and self.props.onOpen then
        pcall(self.props.onOpen, row.protoId)
    end
end

-- ---------------------------------------------------------------------
-- Row renderer
-- ---------------------------------------------------------------------

function ProtoTreeView:_renderRow(rowData, _index, isOdd)
    local theme = self.theme
    local row = rowData
    local proto = row.proto
    local indent = row.depth * INDENT_PX
    local isSelected = self.props.selectedProtoId == row.protoId

    local nameText = proto.debugName
    if not nameText or nameText == "" then
        nameText = string.format("anonymous_%d", row.protoId)
    end

    local subtitle = string.format("p[%d] · %d insn · %d k · %d↑",
        row.protoId,
        proto.sizecode or 0,
        #(proto.constants or {}),
        proto.nups or 0)

    local bg
    if isSelected then bg = theme:color("primaryMuted")
    elseif isOdd then bg = theme:color("background")
    else bg = theme:color("surface") end

    local kids = {
        e("UIPadding", {
            PaddingLeft  = UDim.new(0, indent + 4),
            PaddingRight = UDim.new(0, 4),
        }),
    }

    -- Chevron
    if row.hasChildren then
        kids[#kids + 1] = e("TextButton", {
            key              = "chevron",
            Position         = UDim2.fromOffset(0, 0),
            Size             = UDim2.fromOffset(CHEVRON_W, ROW_HEIGHT),
            Text             = row.isExpanded and "▾" or "▸",
            Font             = Enum.Font.Gotham,
            TextSize         = 12,
            TextColor3       = theme:color("textMuted"),
            BackgroundTransparency = 1,
            AutoButtonColor  = false,
            [Event.Activated] = function() self:_toggle(row.protoId) end,
        })
    end

    -- Icon
    kids[#kids + 1] = e("TextLabel", {
        key            = "icon",
        Position       = UDim2.fromOffset(CHEVRON_W, 0),
        Size           = UDim2.fromOffset(16, ROW_HEIGHT),
        Text           = "ƒ",
        Font           = Enum.Font.GothamBold,
        TextSize       = 12,
        TextColor3     = theme:color("primary"),
        BackgroundTransparency = 1,
    })
    -- Name (top line)
    kids[#kids + 1] = e("TextLabel", {
        key            = "name",
        Position       = UDim2.fromOffset(CHEVRON_W + 18, 1),
        Size           = UDim2.new(1, -(CHEVRON_W + 18), 0, math.floor(ROW_HEIGHT / 2)),
        Text           = nameText,
        Font           = Enum.Font.GothamMedium,
        TextSize       = theme:size("font.ui"),
        TextColor3     = theme:color("text"),
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate   = Enum.TextTruncate.AtEnd,
        BackgroundTransparency = 1,
    })
    -- Subtitle (bottom line)
    kids[#kids + 1] = e("TextLabel", {
        key            = "sub",
        Position       = UDim2.fromOffset(CHEVRON_W + 18, math.floor(ROW_HEIGHT / 2)),
        Size           = UDim2.new(1, -(CHEVRON_W + 18), 0, math.floor(ROW_HEIGHT / 2) - 1),
        Text           = subtitle,
        Font           = Enum.Font.RobotoMono,
        TextSize       = theme:size("font.ui") - 2,
        TextColor3     = theme:color("textSubtle"),
        TextXAlignment = Enum.TextXAlignment.Left,
        BackgroundTransparency = 1,
    })

    return e("TextButton", {
        Size             = UDim2.new(1, 0, 1, 0),
        Text             = "",
        AutoButtonColor  = false,
        BackgroundColor3 = bg,
        BorderSizePixel  = 0,
        [Event.Activated] = function() self:_onRowClick(row) end,
        [Event.MouseEnter] = function(inst)
            if not isSelected then
                pcall(function() inst.BackgroundColor3 = theme:color("surfaceHover") end)
            end
        end,
        [Event.MouseLeave] = function(inst)
            if not isSelected then
                pcall(function() inst.BackgroundColor3 = bg end)
            end
        end,
    }, kids)
end

-- ---------------------------------------------------------------------
-- Render
-- ---------------------------------------------------------------------

function ProtoTreeView:render()
    local theme = self.theme
    local rows = self.state.flatRows

    if #rows == 0 then
        return e("Frame", {
            Size             = self.props.Size,
            Position         = self.props.Position,
            BackgroundColor3 = theme:color("background"),
            BorderSizePixel  = 0,
        }, {
            e("TextLabel", {
                Size             = UDim2.fromScale(1, 1),
                Text             = "no protos loaded",
                Font             = Enum.Font.Gotham,
                TextSize         = theme:size("font.ui"),
                TextColor3       = theme:color("textMuted"),
                BackgroundTransparency = 1,
            }),
        })
    end

    return e(ScrollVirtualizer, {
        Size           = self.props.Size,
        Position       = self.props.Position,
        items          = rows,
        itemCount      = #rows,
        rowHeight      = ROW_HEIGHT,
        overscan       = 6,
        striped        = true,
        renderItem     = function(item, index, isOdd) return self:_renderRow(item, index, isOdd) end,
    })
end

return ProtoTreeView
