--!nonstrict
-- =====================================================================
-- IDARoblox / UI / Views / PatternsView
-- ---------------------------------------------------------------------
-- Pattern-match browser. Displays the results of running the
-- PatternMatcher across the loaded bytecode, grouped by pattern id.
-- Each group is a collapsible header; individual matches expand below.
--
-- Props:
--   matcher        — Analysis.PatternMatcher (live instance)
--   bytecode       — ParsedBytecode
--   disassembler   — Analysis.Disassembler
--   onJumpToMatch  — fn(protoId, pc, match)
--
-- Layout:
--   Header (28): [Run scan] button · category filter chips
--   Body : virtualized list of group-header / match-row entries
--   Footer (20): "N matches across M patterns"
-- =====================================================================

local Component         = _G.IDARo.require("UI.Framework.Component")
local Element           = _G.IDARo.require("UI.Framework.Element")
local ScrollVirtualizer = _G.IDARo.require("UI.Framework.ScrollVirtualizer")
local e                 = Element.create
local Event             = Element.Event

local PatternsView = Component.extend("PatternsView")

Component.setDefaultProps(PatternsView, {
    matcher       = nil,
    bytecode      = nil,
    disassembler  = nil,
    onJumpToMatch = nil,
    Size          = UDim2.fromScale(1, 1),
    Position      = UDim2.fromOffset(0, 0),
})

local ROW_HEIGHT  = 18
local GROUP_H     = 22
local HEADER_H    = 30
local FOOTER_H    = 20

-- ---------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------

function PatternsView:init(props)
    self.state = {
        matches    = {},
        groups     = {},
        flat       = {},                                             -- flat list for virtualizer (group + child rows)
        expanded   = {},                                             -- patternId → bool
        categories = {},                                             -- category set
        filter     = "*",                                            -- "*" or category id
        scanning   = false,
        elapsed    = 0,
    }
end

function PatternsView:willUpdate(nextProps)
    if nextProps.bytecode ~= self.props.bytecode then
        -- Bytecode changed → clear stale matches
        self.state.matches = {}; self.state.groups = {}; self.state.flat = {}
    end
end

-- ---------------------------------------------------------------------
-- Scan
-- ---------------------------------------------------------------------

function PatternsView:_runScan()
    if not self.props.matcher or not self.props.disassembler or not self.props.bytecode then
        return
    end
    self.state.scanning = true
    self:setState({})
    local startedAt = os.clock()
    local matches = self.props.matcher:scanBytecode(
        self.props.disassembler, self.props.bytecode)
    self.state.matches = matches
    self.state.elapsed = (os.clock() - startedAt) * 1000

    -- Group
    local PatternMatcher = self.props.matcher                        -- has the static groupByPattern
    -- Build groups manually so we don't depend on importing the class
    local groupsMap = {}
    local categories = {}
    for _, m in matches do
        local g = groupsMap[m.patternId]
        if not g then
            g = { patternId = m.patternId, pattern = m.pattern, matches = {} }
            groupsMap[m.patternId] = g
        end
        g.matches[#g.matches + 1] = m
        local cat = m.pattern and m.pattern.category or "other"
        categories[cat] = (categories[cat] or 0) + 1
    end
    local groups = {}
    for _, g in groupsMap do groups[#groups + 1] = g end
    table.sort(groups, function(a, b)
        if #a.matches == #b.matches then return a.patternId < b.patternId end
        return #a.matches > #b.matches
    end)
    self.state.groups = groups
    self.state.categories = categories
    self:_rebuildFlat()
    self.state.scanning = false
    self:setState({})
end

function PatternsView:_toggleGroup(patternId)
    self.state.expanded[patternId] = not self.state.expanded[patternId]
    self:_rebuildFlat()
    self:setState({})
end

function PatternsView:_setFilter(cat)
    self.state.filter = cat
    self:_rebuildFlat()
    self:setState({})
end

function PatternsView:_rebuildFlat()
    local flat = {}
    for _, group in self.state.groups do
        local cat = group.pattern and group.pattern.category or "other"
        if self.state.filter == "*" or self.state.filter == cat then
            flat[#flat + 1] = { kind = "group", group = group }
            if self.state.expanded[group.patternId] then
                for _, m in group.matches do
                    flat[#flat + 1] = { kind = "match", match = m }
                end
            end
        end
    end
    self.state.flat = flat
end

-- ---------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------

function PatternsView:_renderHeader()
    local theme = self.theme
    local chips = { { id = "*", label = "all" } }
    local sortedCats = {}
    for c in self.state.categories do sortedCats[#sortedCats + 1] = c end
    table.sort(sortedCats, function(a, b)
        return (self.state.categories[a] or 0) > (self.state.categories[b] or 0)
    end)
    for _, c in sortedCats do
        chips[#chips + 1] = { id = c, label = c .. " (" .. (self.state.categories[c] or 0) .. ")" }
    end
    local chipElements = {}
    for i, chip in chips do
        local active = self.state.filter == chip.id
        chipElements[i] = e("TextButton", {
            key              = "chip:" .. chip.id,
            Size             = UDim2.fromOffset(90, HEADER_H - 12),
            Text             = chip.label,
            Font             = active and Enum.Font.GothamMedium or Enum.Font.Gotham,
            TextSize         = theme:size("font.ui") - 2,
            TextColor3       = active and theme:color("text") or theme:color("textSubtle"),
            BackgroundColor3 = active and theme:color("primaryMuted") or theme:color("surface"),
            BorderSizePixel  = 0,
            AutoButtonColor  = false,
            LayoutOrder      = i + 2,
            [Event.Activated] = function() self:_setFilter(chip.id) end,
        }, {
            e("UICorner", { CornerRadius = UDim.new(0, theme:radius("sm")) }),
        })
    end
    return e("Frame", {
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
        e("TextButton", {
            key              = "scan",
            Size             = UDim2.fromOffset(80, HEADER_H - 10),
            Text             = self.state.scanning and "scanning…" or "▶ Run scan",
            Font             = Enum.Font.GothamMedium,
            TextSize         = theme:size("font.ui") - 1,
            TextColor3       = theme:color("text"),
            BackgroundColor3 = theme:color("primaryMuted"),
            BorderSizePixel  = 0,
            AutoButtonColor  = false,
            LayoutOrder      = 1,
            [Event.Activated] = function()
                if not self.state.scanning then self:_runScan() end
            end,
        }, {
            e("UICorner", { CornerRadius = UDim.new(0, theme:radius("sm")) }),
        }),
        e("TextLabel", {
            key = "summary",
            Size = UDim2.fromOffset(120, HEADER_H - 10),
            Text = string.format("%d match%s",
                #(self.state.matches or {}),
                #(self.state.matches or {}) == 1 and "" or "es"),
            Font = Enum.Font.Gotham, TextSize = theme:size("font.ui") - 2,
            TextColor3 = theme:color("textMuted"),
            TextXAlignment = Enum.TextXAlignment.Left,
            BackgroundTransparency = 1,
            LayoutOrder = 2,
        }),
        Element.fragment(chipElements),
    })
end

function PatternsView:_renderGroupRow(group)
    local theme = self.theme
    local expanded = self.state.expanded[group.patternId] or false
    local arrow = expanded and "▼" or "▶"
    return e("TextButton", {
        Size             = UDim2.new(1, 0, 1, 0),
        Text             = "",
        AutoButtonColor  = false,
        BackgroundColor3 = theme:color("surfaceAlt"),
        BorderSizePixel  = 0,
        [Event.Activated] = function() self:_toggleGroup(group.patternId) end,
        [Event.MouseEnter] = function(inst)
            pcall(function() inst.BackgroundColor3 = theme:color("surfaceHover") end)
        end,
        [Event.MouseLeave] = function(inst)
            pcall(function() inst.BackgroundColor3 = theme:color("surfaceAlt") end)
        end,
    }, {
        e("TextLabel", {
            key = "arrow", Position = UDim2.fromOffset(8, 0),
            Size = UDim2.fromOffset(14, GROUP_H),
            Text = arrow,
            Font = Enum.Font.RobotoMono,
            TextSize = theme:size("font.ui") - 2,
            TextColor3 = theme:color("textMuted"),
            BackgroundTransparency = 1,
        }),
        e("TextLabel", {
            key = "id", Position = UDim2.fromOffset(26, 0),
            Size = UDim2.fromOffset(200, GROUP_H),
            Text = group.patternId,
            Font = Enum.Font.RobotoMono,
            TextSize = theme:size("font.mono"),
            TextColor3 = theme:color("primary"),
            TextXAlignment = Enum.TextXAlignment.Left,
            BackgroundTransparency = 1,
        }),
        e("TextLabel", {
            key = "desc", Position = UDim2.fromOffset(232, 0),
            Size = UDim2.new(1, -288, 0, GROUP_H),
            Text = group.pattern and group.pattern.description or "",
            Font = Enum.Font.Gotham,
            TextSize = theme:size("font.ui") - 1,
            TextColor3 = theme:color("text"),
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd,
            BackgroundTransparency = 1,
        }),
        e("TextLabel", {
            key = "count", AnchorPoint = Vector2.new(1, 0),
            Position = UDim2.new(1, -8, 0, 0),
            Size = UDim2.fromOffset(48, GROUP_H),
            Text = string.format("%d×", #group.matches),
            Font = Enum.Font.RobotoMono,
            TextSize = theme:size("font.mono"),
            TextColor3 = theme:color("disassemblyOperand"),
            TextXAlignment = Enum.TextXAlignment.Right,
            BackgroundTransparency = 1,
        }),
    })
end

function PatternsView:_renderMatchRow(match, isOdd)
    local theme = self.theme
    local bc    = self.props.bytecode
    local proto = bc and bc.protos[match.protoId]
    local pname = (proto and proto.debugName ~= "" and proto.debugName)
        or string.format("p[%d]", match.protoId)
    local bg = isOdd and theme:color("disassemblyRowOdd") or theme:color("disassemblyRowEven")
    return e("TextButton", {
        Size             = UDim2.new(1, 0, 1, 0),
        Text             = "",
        AutoButtonColor  = false,
        BackgroundColor3 = bg,
        BorderSizePixel  = 0,
        [Event.Activated] = function()
            if self.props.onJumpToMatch then
                pcall(self.props.onJumpToMatch, match.protoId, match.startPc, match)
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
            key = "indent", Position = UDim2.fromOffset(34, 0),
            Size = UDim2.fromOffset(12, ROW_HEIGHT),
            Text = "└", Font = Enum.Font.RobotoMono,
            TextSize = theme:size("font.mono") - 1,
            TextColor3 = theme:color("textSubtle"),
            BackgroundTransparency = 1,
        }),
        e("TextLabel", {
            key = "proto", Position = UDim2.fromOffset(50, 0),
            Size = UDim2.fromOffset(160, ROW_HEIGHT),
            Text = pname,
            Font = Enum.Font.RobotoMono,
            TextSize = theme:size("font.mono") - 1,
            TextColor3 = theme:color("primary"),
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd,
            BackgroundTransparency = 1,
        }),
        e("TextLabel", {
            key = "pc", Position = UDim2.fromOffset(216, 0),
            Size = UDim2.fromOffset(72, ROW_HEIGHT),
            Text = string.format("0x%04X", (match.startPc - 1) * 4),
            Font = Enum.Font.RobotoMono,
            TextSize = theme:size("font.mono") - 1,
            TextColor3 = theme:color("disassemblyAddr"),
            TextXAlignment = Enum.TextXAlignment.Left,
            BackgroundTransparency = 1,
        }),
        e("TextLabel", {
            key = "span", Position = UDim2.fromOffset(292, 0),
            Size = UDim2.new(1, -300, 0, ROW_HEIGHT),
            Text = string.format("%d instruction%s",
                #match.rows, #match.rows == 1 and "" or "s"),
            Font = Enum.Font.RobotoMono,
            TextSize = theme:size("font.mono") - 1,
            TextColor3 = theme:color("textMuted"),
            TextXAlignment = Enum.TextXAlignment.Left,
            BackgroundTransparency = 1,
        }),
    })
end

function PatternsView:_renderFooter()
    local theme = self.theme
    local n = #(self.state.matches or {})
    local groups = #(self.state.groups or {})
    local elapsed = self.state.elapsed > 0
        and string.format(" · %.0f ms", self.state.elapsed) or ""
    return e("Frame", {
        Size             = UDim2.new(1, 0, 0, FOOTER_H),
        Position         = UDim2.new(0, 0, 1, -FOOTER_H),
        BackgroundColor3 = theme:color("surfaceAlt"),
        BorderSizePixel  = 0,
    }, {
        e("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) }),
        e("TextLabel", {
            Text = string.format("%d match%s across %d pattern%s%s",
                n, n == 1 and "" or "es", groups, groups == 1 and "" or "s", elapsed),
            Font = Enum.Font.Gotham, TextSize = theme:size("font.ui") - 2,
            TextColor3 = theme:color("textMuted"),
            TextXAlignment = Enum.TextXAlignment.Left,
            BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1),
        }),
    })
end

function PatternsView:render()
    local theme = self.theme
    if not self.props.bytecode or not self.props.matcher then
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

    local flat = self.state.flat or {}
    return e("Frame", {
        Size = self.props.Size, Position = self.props.Position,
        BackgroundColor3 = theme:color("background"), BorderSizePixel = 0,
    }, {
        self:_renderHeader(),
        e(ScrollVirtualizer, {
            key = "body", Position = UDim2.fromOffset(0, HEADER_H),
            Size = UDim2.new(1, 0, 1, -(HEADER_H + FOOTER_H)),
            items = flat, itemCount = #flat,
            rowHeight = ROW_HEIGHT,
            overscan = 12,
            renderItem = function(item, idx, isOdd)
                if item.kind == "group" then return self:_renderGroupRow(item.group)
                else return self:_renderMatchRow(item.match, isOdd) end
            end,
        }),
        self:_renderFooter(),
    })
end

return PatternsView
