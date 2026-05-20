--!nonstrict
-- =====================================================================
-- IDARoblox / UI / Views / StringsView
-- ---------------------------------------------------------------------
-- Browser for every string in the bytecode string table. The XRefIndex
-- has already computed how many call/global/field/method/import/k sites
-- mention each string; this view simply renders the sorted/filtered list.
--
-- Props:
--   xrefIndex      — XRefIndex result from XRefEngine.build
--   onSelectString — fn(value, entry) — entry is the stringsList row
--                    {stringId, value, length, refCount, sites}
--   showZeroRefs   — default true; toggleable via header button
--
-- Layout:
--   Header (28 px): search box · "hide unrefs" toggle · column sort
--                   buttons (id / value / len / refs)
--   Body:   virtualized rows, monospace, alternating-row stripe
--   Footer (20 px): "N strings (showing M)"
--
-- Sort:
--   Default by stringId ascending. Clicking a column header re-sorts
--   stably by that column; clicking the same column toggles asc/desc.
-- =====================================================================

local Component         = _G.IDARo.require("UI.Framework.Component")
local Element           = _G.IDARo.require("UI.Framework.Element")
local ScrollVirtualizer = _G.IDARo.require("UI.Framework.ScrollVirtualizer")
local e                 = Element.create
local Event             = Element.Event

local StringsView = Component.extend("StringsView")

Component.setDefaultProps(StringsView, {
    xrefIndex      = nil,
    onSelectString = nil,
    showZeroRefs   = true,
    Size           = UDim2.fromScale(1, 1),
    Position       = UDim2.fromOffset(0, 0),
})

local ROW_HEIGHT = 18
local HEADER_H   = 28
local FOOTER_H   = 20
local COL_ID_W   = 56
local COL_LEN_W  = 56
local COL_REF_W  = 56

-- ---------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------

function StringsView:init(props)
    self.state = {
        searchText  = "",
        sortKey     = "stringId",
        sortDir     = "asc",
        hideZeroRef = false,
        cached      = nil,                                           -- post-filter/sort
    }
    self:_recompute(props)
end

function StringsView:willUpdate(nextProps)
    if nextProps.xrefIndex ~= self.props.xrefIndex then
        self:_recompute(nextProps)
    end
end

-- ---------------------------------------------------------------------
-- Sort + filter
-- ---------------------------------------------------------------------

local function escapeValue(s, max)
    if type(s) ~= "string" then return tostring(s) end
    max = max or 80
    if #s > max then s = s:sub(1, max - 3) .. "..." end
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

function StringsView:_recompute(props)
    props = props or self.props
    if not props.xrefIndex then
        self.state.cached = {}
        return
    end
    local list = props.xrefIndex:stringsList()
    local needle = self.state.searchText ~= "" and string.lower(self.state.searchText) or nil
    local hideZero = self.state.hideZeroRef
    local out = {}
    for _, entry in list do
        if hideZero and entry.refCount == 0 then continue end
        if needle then
            local hay = string.lower(entry.value or "")
            if not string.find(hay, needle, 1, true) then continue end
        end
        out[#out + 1] = entry
    end
    -- Sort
    local key = self.state.sortKey
    local dir = self.state.sortDir
    local cmp
    if key == "value" then
        cmp = function(a, b) return (a.value or "") < (b.value or "") end
    elseif key == "length" then
        cmp = function(a, b) return a.length < b.length end
    elseif key == "refCount" then
        cmp = function(a, b) return a.refCount < b.refCount end
    else
        cmp = function(a, b) return a.stringId < b.stringId end
    end
    if dir == "desc" then
        local upCmp = cmp
        cmp = function(a, b) return upCmp(b, a) end
    end
    table.sort(out, cmp)
    self.state.cached = out
end

function StringsView:_setSort(key)
    if self.state.sortKey == key then
        self:setState({ sortDir = self.state.sortDir == "asc" and "desc" or "asc" })
    else
        self:setState({ sortKey = key, sortDir = "asc" })
    end
    self:_recompute()
end

function StringsView:_setSearch(text)
    self.state.searchText = text
    self:_recompute()
    self:setState({})                                                -- trigger re-render
end

function StringsView:_toggleHideZero()
    self.state.hideZeroRef = not self.state.hideZeroRef
    self:_recompute()
    self:setState({})
end

-- ---------------------------------------------------------------------
-- Row + header rendering
-- ---------------------------------------------------------------------

function StringsView:_renderHeader()
    local theme = self.theme

    local function sortBtn(key, label, width, layoutOrder)
        local active = self.state.sortKey == key
        local arrow  = active and (self.state.sortDir == "asc" and " ▲" or " ▼") or ""
        return e("TextButton", {
            key              = "col:" .. key,
            Size             = UDim2.fromOffset(width, HEADER_H - 8),
            Text             = label .. arrow,
            Font             = active and Enum.Font.GothamMedium or Enum.Font.Gotham,
            TextSize         = theme:size("font.ui") - 1,
            TextColor3       = active and theme:color("text") or theme:color("textMuted"),
            BackgroundColor3 = active and theme:color("primaryMuted") or theme:color("surface"),
            BorderSizePixel  = 0,
            AutoButtonColor  = false,
            LayoutOrder      = layoutOrder,
            [Event.Activated] = function() self:_setSort(key) end,
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
            Size             = UDim2.fromOffset(200, HEADER_H - 8),
            PlaceholderText  = "  search…",
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
        e("TextButton", {
            key              = "hideZero",
            Size             = UDim2.fromOffset(110, HEADER_H - 8),
            Text             = self.state.hideZeroRef and "showing only referenced" or "showing all",
            Font             = Enum.Font.Gotham,
            TextSize         = theme:size("font.ui") - 2,
            TextColor3       = theme:color("textMuted"),
            BackgroundColor3 = self.state.hideZeroRef
                and theme:color("primaryMuted") or theme:color("surface"),
            BorderSizePixel  = 0,
            AutoButtonColor  = false,
            LayoutOrder      = 2,
            [Event.Activated] = function() self:_toggleHideZero() end,
        }, {
            e("UICorner", { CornerRadius = UDim.new(0, theme:radius("sm")) }),
        }),
        sortBtn("stringId", "id",     COL_ID_W,  3),
        sortBtn("value",    "value",  120,        4),
        sortBtn("length",   "len",    COL_LEN_W,  5),
        sortBtn("refCount", "refs",   COL_REF_W,  6),
    })
end

function StringsView:_renderRow(entry, _index, isOdd)
    local theme = self.theme
    local bg = isOdd and theme:color("disassemblyRowOdd") or theme:color("disassemblyRowEven")

    local refCountColor = entry.refCount > 0
        and theme:color("disassemblyOperand") or theme:color("textSubtle")

    return e("TextButton", {
        Size             = UDim2.new(1, 0, 1, 0),
        Text             = "",
        AutoButtonColor  = false,
        BackgroundColor3 = bg,
        BorderSizePixel  = 0,
        [Event.Activated] = function()
            if self.props.onSelectString then
                pcall(self.props.onSelectString, entry.value, entry)
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
            key            = "id",
            Position       = UDim2.fromOffset(6, 0),
            Size           = UDim2.fromOffset(COL_ID_W, ROW_HEIGHT),
            Text           = string.format("%d", entry.stringId),
            Font           = Enum.Font.RobotoMono,
            TextSize       = theme:size("font.mono") - 1,
            TextColor3     = theme:color("disassemblyAddr"),
            TextXAlignment = Enum.TextXAlignment.Right,
            BackgroundTransparency = 1,
        }),
        e("TextLabel", {
            key            = "value",
            Position       = UDim2.fromOffset(6 + COL_ID_W + 10, 0),
            Size           = UDim2.new(1, -(6 + COL_ID_W + COL_LEN_W + COL_REF_W + 36), 0, ROW_HEIGHT),
            Text           = '"' .. escapeValue(entry.value, 96) .. '"',
            Font           = Enum.Font.RobotoMono,
            TextSize       = theme:size("font.mono") - 1,
            TextColor3     = theme:color("disassemblyOperand"),
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate   = Enum.TextTruncate.AtEnd,
            BackgroundTransparency = 1,
        }),
        e("TextLabel", {
            key            = "len",
            AnchorPoint    = Vector2.new(1, 0),
            Position       = UDim2.new(1, -(COL_REF_W + 12), 0, 0),
            Size           = UDim2.fromOffset(COL_LEN_W, ROW_HEIGHT),
            Text           = tostring(entry.length),
            Font           = Enum.Font.RobotoMono,
            TextSize       = theme:size("font.mono") - 1,
            TextColor3     = theme:color("textSubtle"),
            TextXAlignment = Enum.TextXAlignment.Right,
            BackgroundTransparency = 1,
        }),
        e("TextLabel", {
            key            = "refs",
            AnchorPoint    = Vector2.new(1, 0),
            Position       = UDim2.new(1, -6, 0, 0),
            Size           = UDim2.fromOffset(COL_REF_W, ROW_HEIGHT),
            Text           = entry.refCount > 0 and string.format("%d×", entry.refCount) or "—",
            Font           = Enum.Font.RobotoMono,
            TextSize       = theme:size("font.mono") - 1,
            TextColor3     = refCountColor,
            TextXAlignment = Enum.TextXAlignment.Right,
            BackgroundTransparency = 1,
        }),
    })
end

function StringsView:_renderFooter()
    local theme = self.theme
    local total = self.props.xrefIndex
        and #(self.props.xrefIndex.bytecode.stringTable or {}) or 0
    local shown = self.state.cached and #self.state.cached or 0
    return e("Frame", {
        key              = "footer",
        Size             = UDim2.new(1, 0, 0, FOOTER_H),
        Position         = UDim2.new(0, 0, 1, -FOOTER_H),
        BackgroundColor3 = theme:color("surfaceAlt"),
        BorderSizePixel  = 0,
    }, {
        e("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) }),
        e("TextLabel", {
            Text                  = string.format("%d strings (showing %d)", total, shown),
            Font                  = Enum.Font.Gotham,
            TextSize              = theme:size("font.ui") - 2,
            TextColor3            = theme:color("textMuted"),
            TextXAlignment        = Enum.TextXAlignment.Left,
            BackgroundTransparency = 1,
            Size                  = UDim2.fromScale(1, 1),
        }),
    })
end

-- ---------------------------------------------------------------------
-- Render
-- ---------------------------------------------------------------------

function StringsView:render()
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

return StringsView
