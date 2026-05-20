--!nonstrict
-- =====================================================================
-- IDARoblox / UI / Views / ConstantsView
-- ---------------------------------------------------------------------
-- Per-proto constant-pool browser. Each row in the current proto's
-- `constants` array becomes a renderable entry with type-aware value
-- preview. The user can:
--   * filter by tag (STRING / NUMBER / BOOLEAN / NIL / IMPORT / TABLE
--                    / CLOSURE / VECTOR) via toggle chips
--   * substring-search the rendered value text
--   * click a row to fire onSelectConstant (the workspace flips to
--     XRefs and queries the appropriate bucket — string sites for
--     STRINGs, import chain sites for IMPORTs, etc.)
--
-- Props:
--   proto             — current proto
--   onSelectConstant  — fn(constantEntry, kidx)
-- =====================================================================

local Component         = _G.IDARo.require("UI.Framework.Component")
local Element           = _G.IDARo.require("UI.Framework.Element")
local ScrollVirtualizer = _G.IDARo.require("UI.Framework.ScrollVirtualizer")
local e                 = Element.create
local Event             = Element.Event

local ConstantsView = Component.extend("ConstantsView")

Component.setDefaultProps(ConstantsView, {
    proto             = nil,
    onSelectConstant  = nil,
    Size              = UDim2.fromScale(1, 1),
    Position          = UDim2.fromOffset(0, 0),
})

local ROW_HEIGHT = 18
local HEADER_H   = 28
local FOOTER_H   = 20

local TAGS_ORDER = { "STRING", "NUMBER", "BOOLEAN", "NIL", "IMPORT", "TABLE", "CLOSURE", "VECTOR" }

-- ---------------------------------------------------------------------
-- Value rendering
-- ---------------------------------------------------------------------

local function escapeStringPreview(s, max)
    max = max or 96
    if type(s) ~= "string" then return tostring(s) end
    if #s > max then s = string.sub(s, 1, max - 3) .. "..." end
    local b = {}
    for i = 1, #s do
        local c = string.byte(s, i)
        if c < 0x20 or c == 0x7F then
            b[i] = string.format("\\x%02X", c)
        else
            b[i] = string.char(c)
        end
    end
    return table.concat(b)
end

local function valuePreview(entry)
    if not entry then return "<nil>" end
    local t = entry.tag
    if t == "STRING"  then return '"' .. escapeStringPreview(entry.value, 96) .. '"'
    elseif t == "NUMBER" then return tostring(entry.value)
    elseif t == "BOOLEAN" then return tostring(entry.value)
    elseif t == "NIL" then return "nil"
    elseif t == "IMPORT" then
        if entry.chain then return table.concat(entry.chain, ".") end
        return string.format("import#%s", tostring(entry.encodedId))
    elseif t == "TABLE" then
        local n = entry.keys and #entry.keys or 0
        return string.format("{table, %d key%s}", n, n == 1 and "" or "s")
    elseif t == "CLOSURE" then
        return string.format("closure → proto[%d]", entry.protoId or -1)
    elseif t == "VECTOR" then
        local v = entry.value
        return string.format("vector(%g, %g, %g, %g)",
            v.x or 0, v.y or 0, v.z or 0, v.w or 0)
    end
    return "<" .. tostring(t) .. ">"
end

-- ---------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------

function ConstantsView:init(props)
    local activeTags = {}
    for _, t in TAGS_ORDER do activeTags[t] = true end
    self.state = {
        searchText = "",
        tags       = activeTags,
        cached     = nil,
    }
    self:_recompute(props)
end

function ConstantsView:willUpdate(nextProps)
    if nextProps.proto ~= self.props.proto then self:_recompute(nextProps) end
end

function ConstantsView:_recompute(props)
    props = props or self.props
    local proto = props.proto
    if not proto or not proto.constants then self.state.cached = {}; return end
    local needle = self.state.searchText ~= ""
        and string.lower(self.state.searchText) or nil
    local activeTags = self.state.tags
    local out = {}
    for kidx, entry in proto.constants do
        if entry and activeTags[entry.tag] then
            local preview = valuePreview(entry)
            if not needle or string.find(string.lower(preview), needle, 1, true) then
                out[#out + 1] = { kidx = kidx, entry = entry, preview = preview }
            end
        end
    end
    self.state.cached = out
end

function ConstantsView:_toggleTag(tag)
    self.state.tags[tag] = not self.state.tags[tag]
    self:_recompute()
    self:setState({})
end

function ConstantsView:_setSearch(text)
    self.state.searchText = text
    self:_recompute()
    self:setState({})
end

-- ---------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------

function ConstantsView:_renderHeader()
    local theme = self.theme
    local chips = {}
    for i, tag in TAGS_ORDER do
        local active = self.state.tags[tag]
        chips[i] = e("TextButton", {
            key              = "chip:" .. tag,
            Size             = UDim2.fromOffset(70, HEADER_H - 10),
            Text             = string.lower(tag),
            Font             = active and Enum.Font.GothamMedium or Enum.Font.Gotham,
            TextSize         = theme:size("font.ui") - 2,
            TextColor3       = active and theme:color("text") or theme:color("textSubtle"),
            BackgroundColor3 = active and theme:color("primaryMuted") or theme:color("surface"),
            BorderSizePixel  = 0,
            AutoButtonColor  = false,
            LayoutOrder      = i + 1,
            [Event.Activated] = function() self:_toggleTag(tag) end,
        }, {
            e("UICorner", { CornerRadius = UDim.new(0, theme:radius("sm")) }),
        })
    end
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
            key              = "search",
            Size             = UDim2.fromOffset(180, HEADER_H - 10),
            PlaceholderText  = "  search value…",
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
            e("UICorner",  { CornerRadius = UDim.new(0, theme:radius("sm")) }),
            e("UIPadding", { PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6) }),
        }),
        Element.fragment(chips),
    })
end

local function tagColor(theme, tag)
    if tag == "STRING"  then return theme:color("syntaxString")
    elseif tag == "NUMBER" then return theme:color("syntaxNumber")
    elseif tag == "BOOLEAN" then return theme:color("syntaxKeyword")
    elseif tag == "NIL" then return theme:color("textSubtle")
    elseif tag == "IMPORT" then return theme:color("primary")
    elseif tag == "TABLE" then return theme:color("disassemblyOperand")
    elseif tag == "CLOSURE" then return theme:color("syntaxKeyword")
    elseif tag == "VECTOR" then return theme:color("disassemblyOperand")
    end
    return theme:color("text")
end

function ConstantsView:_renderRow(item, _idx, isOdd)
    local theme = self.theme
    local bg = isOdd and theme:color("disassemblyRowOdd") or theme:color("disassemblyRowEven")
    local clr = tagColor(theme, item.entry.tag)
    return e("TextButton", {
        Size             = UDim2.new(1, 0, 1, 0),
        Text             = "",
        AutoButtonColor  = false,
        BackgroundColor3 = bg,
        BorderSizePixel  = 0,
        [Event.Activated] = function()
            if self.props.onSelectConstant then
                pcall(self.props.onSelectConstant, item.entry, item.kidx)
            end
        end,
        [Event.MouseEnter] = function(inst)
            pcall(function() inst.BackgroundColor3 = theme:color("surfaceHover") end)
        end,
        [Event.MouseLeave] = function(inst)
            pcall(function() inst.BackgroundColor3 = bg end)
        end,
    }, {
        e("TextLabel", {
            key = "kidx", Position = UDim2.fromOffset(8, 0),
            Size = UDim2.fromOffset(48, ROW_HEIGHT),
            Text = string.format("K%d", item.kidx - 1),
            Font = Enum.Font.RobotoMono,
            TextSize = theme:size("font.mono") - 1,
            TextColor3 = theme:color("disassemblyAddr"),
            TextXAlignment = Enum.TextXAlignment.Right,
            BackgroundTransparency = 1,
        }),
        e("TextLabel", {
            key = "tag", Position = UDim2.fromOffset(66, 0),
            Size = UDim2.fromOffset(70, ROW_HEIGHT),
            Text = string.lower(item.entry.tag or "?"),
            Font = Enum.Font.RobotoMono,
            TextSize = theme:size("font.mono") - 1,
            TextColor3 = theme:color("textMuted"),
            TextXAlignment = Enum.TextXAlignment.Left,
            BackgroundTransparency = 1,
        }),
        e("TextLabel", {
            key = "val", Position = UDim2.fromOffset(140, 0),
            Size = UDim2.new(1, -148, 0, ROW_HEIGHT),
            Text = item.preview,
            Font = Enum.Font.RobotoMono,
            TextSize = theme:size("font.mono") - 1,
            TextColor3 = clr,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd,
            BackgroundTransparency = 1,
        }),
    })
end

function ConstantsView:_renderFooter()
    local theme = self.theme
    local proto = self.props.proto
    local total = proto and proto.constants and #proto.constants or 0
    local shown = self.state.cached and #self.state.cached or 0
    return e("Frame", {
        Size             = UDim2.new(1, 0, 0, FOOTER_H),
        Position         = UDim2.new(0, 0, 1, -FOOTER_H),
        BackgroundColor3 = theme:color("surfaceAlt"),
        BorderSizePixel  = 0,
    }, {
        e("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) }),
        e("TextLabel", {
            Text = string.format("%d constant%s · showing %d", total,
                total == 1 and "" or "s", shown),
            Font = Enum.Font.Gotham, TextSize = theme:size("font.ui") - 2,
            TextColor3 = theme:color("textMuted"),
            TextXAlignment = Enum.TextXAlignment.Left,
            BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1),
        }),
    })
end

function ConstantsView:render()
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
    local items = self.state.cached or {}
    return e("Frame", {
        Size = self.props.Size, Position = self.props.Position,
        BackgroundColor3 = theme:color("background"), BorderSizePixel = 0,
    }, {
        self:_renderHeader(),
        e(ScrollVirtualizer, {
            key = "body", Position = UDim2.fromOffset(0, HEADER_H),
            Size = UDim2.new(1, 0, 1, -(HEADER_H + FOOTER_H)),
            items = items, itemCount = #items, rowHeight = ROW_HEIGHT,
            overscan = 12,
            renderItem = function(item, idx, isOdd) return self:_renderRow(item, idx, isOdd) end,
        }),
        self:_renderFooter(),
    })
end

return ConstantsView
