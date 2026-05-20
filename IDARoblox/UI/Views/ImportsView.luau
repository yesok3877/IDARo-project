--!nonstrict
-- =====================================================================
-- IDARoblox / UI / Views / ImportsView
-- ---------------------------------------------------------------------
-- Imports browser. Every GETIMPORT instruction in the bytecode produces
-- a (root, chain) pair; the XRefIndex's byImport bucket already
-- aggregates them. This view renders the sorted-by-count list and
-- offers root-namespace filtering for quick navigation.
--
-- Each row:
--   { chain = "game.Players.LocalPlayer", root = "game", count = N, sites = {…} }
--
-- Filter chips at the top represent root namespaces (auto-derived from
-- the active import list). Clicking a chip narrows the visible rows.
-- The "all" chip clears the filter.
--
-- Props:
--   xrefIndex     — XRefIndex
--   onSelectChain — fn(chain, count, sites) — workspace handler sets
--                   the XRef query and flips the bottom tab.
-- =====================================================================

local Component         = _G.IDARo.require("UI.Framework.Component")
local Element           = _G.IDARo.require("UI.Framework.Element")
local ScrollVirtualizer = _G.IDARo.require("UI.Framework.ScrollVirtualizer")
local e                 = Element.create
local Event             = Element.Event

local ImportsView = Component.extend("ImportsView")

Component.setDefaultProps(ImportsView, {
    xrefIndex     = nil,
    onSelectChain = nil,
    Size          = UDim2.fromScale(1, 1),
    Position      = UDim2.fromOffset(0, 0),
})

local ROW_HEIGHT = 18
local HEADER_H   = 28
local FOOTER_H   = 20

-- ---------------------------------------------------------------------
-- Recompute
-- ---------------------------------------------------------------------

local function rootOf(chain)
    local dot = string.find(chain, ".", 1, true)
    if dot then return string.sub(chain, 1, dot - 1) end
    return chain
end

function ImportsView:init(props)
    self.state = {
        filter   = "*",                                              -- "*" = all
        search   = "",
        roots    = {},
        items    = {},
    }
    self:_recompute(props)
end

function ImportsView:willUpdate(nextProps)
    if nextProps.xrefIndex ~= self.props.xrefIndex then self:_recompute(nextProps) end
end

function ImportsView:_recompute(props)
    props = props or self.props
    if not props.xrefIndex then
        self.state.roots = {}; self.state.items = {}; return
    end
    local top = props.xrefIndex:topImports(nil)
    local roots = {}
    local items = {}
    for _, entry in top do
        local r = rootOf(entry.name)
        roots[r] = (roots[r] or 0) + 1
        local hit = {
            chain = entry.name, root = r, count = entry.count, sites = entry.sites,
        }
        if self.state.filter == "*" or self.state.filter == r then
            if self.state.search == "" or string.find(
                string.lower(entry.name), string.lower(self.state.search), 1, true) then
                items[#items + 1] = hit
            end
        end
    end
    -- Sort: by count desc, then alphabetically
    table.sort(items, function(a, b)
        if a.count == b.count then return a.chain < b.chain end
        return a.count > b.count
    end)
    self.state.roots = roots
    self.state.items = items
end

function ImportsView:_setFilter(r)
    self.state.filter = r
    self:_recompute()
    self:setState({})
end

function ImportsView:_setSearch(text)
    self.state.search = text
    self:_recompute()
    self:setState({})
end

-- ---------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------

function ImportsView:_renderHeader()
    local theme = self.theme
    -- Build chips for "all" + each detected root
    local chipDefs = { { id = "*", label = "all" } }
    local sortedRoots = {}
    for r in self.state.roots do sortedRoots[#sortedRoots + 1] = r end
    table.sort(sortedRoots, function(a, b)
        return (self.state.roots[a] or 0) > (self.state.roots[b] or 0)
    end)
    for _, r in sortedRoots do
        chipDefs[#chipDefs + 1] = { id = r, label = r .. " (" .. (self.state.roots[r] or 0) .. ")" }
    end

    local chips = {}
    for i, def in chipDefs do
        local active = self.state.filter == def.id
        chips[i] = e("TextButton", {
            key              = "chip:" .. def.id,
            Size             = UDim2.fromOffset(96, HEADER_H - 10),
            Text             = def.label,
            Font             = active and Enum.Font.GothamMedium or Enum.Font.Gotham,
            TextSize         = theme:size("font.ui") - 2,
            TextColor3       = active and theme:color("text") or theme:color("textSubtle"),
            BackgroundColor3 = active and theme:color("primaryMuted") or theme:color("surface"),
            BorderSizePixel  = 0,
            AutoButtonColor  = false,
            LayoutOrder      = i + 1,
            [Event.Activated] = function() self:_setFilter(def.id) end,
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
            Size             = UDim2.fromOffset(220, HEADER_H - 10),
            PlaceholderText  = "  search chain…",
            Text             = self.state.search,
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

function ImportsView:_renderRow(item, _idx, isOdd)
    local theme = self.theme
    local bg = isOdd and theme:color("disassemblyRowOdd") or theme:color("disassemblyRowEven")
    return e("TextButton", {
        Size             = UDim2.new(1, 0, 1, 0),
        Text             = "",
        AutoButtonColor  = false,
        BackgroundColor3 = bg,
        BorderSizePixel  = 0,
        [Event.Activated] = function()
            if self.props.onSelectChain then
                pcall(self.props.onSelectChain, item.chain, item.count, item.sites)
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
            key = "root", Position = UDim2.fromOffset(8, 0),
            Size = UDim2.fromOffset(96, ROW_HEIGHT),
            Text = item.root,
            Font = Enum.Font.RobotoMono,
            TextSize = theme:size("font.mono") - 1,
            TextColor3 = theme:color("primary"),
            TextXAlignment = Enum.TextXAlignment.Left,
            BackgroundTransparency = 1,
        }),
        e("TextLabel", {
            key = "chain", Position = UDim2.fromOffset(112, 0),
            Size = UDim2.new(1, -180, 0, ROW_HEIGHT),
            Text = item.chain,
            Font = Enum.Font.RobotoMono,
            TextSize = theme:size("font.mono") - 1,
            TextColor3 = theme:color("text"),
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd,
            BackgroundTransparency = 1,
        }),
        e("TextLabel", {
            key = "count", AnchorPoint = Vector2.new(1, 0),
            Position = UDim2.new(1, -8, 0, 0),
            Size = UDim2.fromOffset(60, ROW_HEIGHT),
            Text = string.format("%d×", item.count),
            Font = Enum.Font.RobotoMono,
            TextSize = theme:size("font.mono") - 1,
            TextColor3 = theme:color("disassemblyOperand"),
            TextXAlignment = Enum.TextXAlignment.Right,
            BackgroundTransparency = 1,
        }),
    })
end

function ImportsView:_renderFooter()
    local theme = self.theme
    local items = self.state.items
    local total = items and #items or 0
    local roots = 0; for _ in self.state.roots do roots = roots + 1 end
    return e("Frame", {
        Size             = UDim2.new(1, 0, 0, FOOTER_H),
        Position         = UDim2.new(0, 0, 1, -FOOTER_H),
        BackgroundColor3 = theme:color("surfaceAlt"),
        BorderSizePixel  = 0,
    }, {
        e("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) }),
        e("TextLabel", {
            Text = string.format("%d unique import%s across %d root namespace%s",
                total, total == 1 and "" or "s",
                roots, roots == 1 and "" or "s"),
            Font = Enum.Font.Gotham, TextSize = theme:size("font.ui") - 2,
            TextColor3 = theme:color("textMuted"),
            TextXAlignment = Enum.TextXAlignment.Left,
            BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1),
        }),
    })
end

function ImportsView:render()
    local theme = self.theme
    if not self.props.xrefIndex then
        return e("Frame", {
            Size = self.props.Size, Position = self.props.Position,
            BackgroundColor3 = theme:color("background"), BorderSizePixel = 0,
        }, {
            e("TextLabel", {
                Size = UDim2.fromScale(1, 1),
                Text = "no bytecode loaded",
                Font = Enum.Font.Gotham, TextSize = theme:size("font.ui"),
                TextColor3 = theme:color("textMuted"),
                BackgroundTransparency = 1,
            }),
        })
    end
    local items = self.state.items or {}
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

return ImportsView
