--!nonstrict
-- =====================================================================
-- IDARoblox / UI / Views / XRefView
-- ---------------------------------------------------------------------
-- Cross-reference inspector. Given a query, displays every site that
-- references the keyed thing.
--
-- Props:
--   xrefIndex     — XRefIndex
--   query         — {
--                     kind  = "string"|"global"|"field"|"method"|"closure"
--                           |"import"|"builtin"|"upval"|"branch",
--                     key   = "Players" | protoId | …,
--                     label = display string, e.g. "string \"Players\"",
--                   }
--   onJumpToSite  — fn(protoId, pc, site) when a row is clicked
--   onClearQuery  — fn() when the user dismisses the query (× button)
-- =====================================================================

local Component         = _G.IDARo.require("UI.Framework.Component")
local Element           = _G.IDARo.require("UI.Framework.Element")
local ScrollVirtualizer = _G.IDARo.require("UI.Framework.ScrollVirtualizer")
local e                 = Element.create
local Event             = Element.Event

local XRefView = Component.extend("XRefView")

Component.setDefaultProps(XRefView, {
    xrefIndex    = nil,
    query        = nil,
    onJumpToSite = nil,
    onClearQuery = nil,
    Size         = UDim2.fromScale(1, 1),
    Position     = UDim2.fromOffset(0, 0),
})

local ROW_HEIGHT = 18
local HEADER_H   = 30
local FOOTER_H   = 20

-- ---------------------------------------------------------------------
-- Site resolution
-- ---------------------------------------------------------------------

local function resolveSites(xref, query)
    if not xref or not query or not query.kind then return {} end
    local k = query.kind
    if k == "string"  then return xref:sitesForString(query.key)
    elseif k == "global" then return xref:sitesForGlobal(query.key)
    elseif k == "field"  then return xref:sitesForField(query.key)
    elseif k == "method" then return xref:sitesForMethod(query.key)
    elseif k == "import" then return xref:sitesForImport(query.key)
    elseif k == "closure" then return xref:sitesForClosure(query.key)
    elseif k == "builtin" then return xref:sitesForBuiltin(query.key)
    elseif k == "branch"  then return xref:sitesForBranchTarget(query.key.protoId, query.key.pc)
    elseif k == "upval"   then return xref:sitesForUpval(query.key.protoId, query.key.index)
    end
    return {}
end

-- ---------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------

function XRefView:init(props)
    self.state = { sites = resolveSites(props.xrefIndex, props.query) }
end

function XRefView:willUpdate(nextProps)
    if nextProps.xrefIndex ~= self.props.xrefIndex
        or nextProps.query ~= self.props.query then
        self.state.sites = resolveSites(nextProps.xrefIndex, nextProps.query)
    end
end

-- ---------------------------------------------------------------------
-- Header + row
-- ---------------------------------------------------------------------

function XRefView:_renderHeader()
    local theme = self.theme
    local label = self.props.query and (self.props.query.label or self.props.query.key)
        or "no query"
    local kind  = self.props.query and self.props.query.kind or "—"

    return e("Frame", {
        key              = "header",
        Size             = UDim2.new(1, 0, 0, HEADER_H),
        BackgroundColor3 = theme:color("surfaceAlt"),
        BorderSizePixel  = 0,
    }, {
        e("UIPadding", {
            PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10),
            PaddingTop  = UDim.new(0, 5), PaddingBottom = UDim.new(0, 5),
        }),
        e("TextLabel", {
            key            = "kindBadge",
            Position       = UDim2.fromOffset(0, 0),
            Size           = UDim2.fromOffset(72, HEADER_H - 10),
            Text           = "[" .. kind .. "]",
            Font           = Enum.Font.GothamMedium,
            TextSize       = theme:size("font.ui") - 1,
            TextColor3     = theme:color("primary"),
            TextXAlignment = Enum.TextXAlignment.Left,
            BackgroundTransparency = 1,
        }),
        e("TextLabel", {
            key            = "label",
            Position       = UDim2.fromOffset(74, 0),
            Size           = UDim2.new(1, -154, 1, 0),
            Text           = tostring(label),
            Font           = Enum.Font.RobotoMono,
            TextSize       = theme:size("font.ui"),
            TextColor3     = theme:color("text"),
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate   = Enum.TextTruncate.AtEnd,
            BackgroundTransparency = 1,
        }),
        self.props.query and e("TextButton", {
            key              = "clear",
            AnchorPoint      = Vector2.new(1, 0.5),
            Position         = UDim2.new(1, 0, 0.5, 0),
            Size             = UDim2.fromOffset(64, HEADER_H - 12),
            Text             = "clear ×",
            Font             = Enum.Font.Gotham,
            TextSize         = theme:size("font.ui") - 2,
            TextColor3       = theme:color("textMuted"),
            BackgroundColor3 = theme:color("surface"),
            BorderSizePixel  = 0,
            AutoButtonColor  = false,
            [Event.Activated] = function()
                if self.props.onClearQuery then pcall(self.props.onClearQuery) end
            end,
        }, { e("UICorner", { CornerRadius = UDim.new(0, theme:radius("sm")) }) }),
    })
end

function XRefView:_renderRow(site, _index, isOdd)
    local theme   = self.theme
    local xref    = self.props.xrefIndex
    local proto   = xref and xref.bytecode.protos[site.protoId]
    local pname   = proto and (proto.debugName ~= "" and proto.debugName or string.format("p[%d]", site.protoId))
        or string.format("p[%d]", site.protoId)
    local modeTxt = site.mode and ("[" .. site.mode .. "]") or ""

    -- We don't have the Disassembler here; show address + refKind. The
    -- workspace's onJumpToSite resolves the row when the user clicks
    -- (which is fine — the row preview here is intentionally minimal).
    local bg = isOdd and theme:color("disassemblyRowOdd") or theme:color("disassemblyRowEven")

    return e("TextButton", {
        Size             = UDim2.new(1, 0, 1, 0),
        Text             = "",
        AutoButtonColor  = false,
        BackgroundColor3 = bg,
        BorderSizePixel  = 0,
        [Event.Activated] = function()
            if self.props.onJumpToSite then
                pcall(self.props.onJumpToSite, site.protoId, site.pc, site)
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
            key            = "proto",
            Position       = UDim2.fromOffset(8, 0),
            Size           = UDim2.fromOffset(160, ROW_HEIGHT),
            Text           = pname,
            Font           = Enum.Font.RobotoMono,
            TextSize       = theme:size("font.mono") - 1,
            TextColor3     = theme:color("primary"),
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate   = Enum.TextTruncate.AtEnd,
            BackgroundTransparency = 1,
        }),
        e("TextLabel", {
            key            = "addr",
            Position       = UDim2.fromOffset(176, 0),
            Size           = UDim2.fromOffset(72, ROW_HEIGHT),
            Text           = string.format("0x%04X", (site.pc - 1) * 4),
            Font           = Enum.Font.RobotoMono,
            TextSize       = theme:size("font.mono") - 1,
            TextColor3     = theme:color("disassemblyAddr"),
            TextXAlignment = Enum.TextXAlignment.Left,
            BackgroundTransparency = 1,
        }),
        e("TextLabel", {
            key            = "kind",
            Position       = UDim2.fromOffset(252, 0),
            Size           = UDim2.fromOffset(90, ROW_HEIGHT),
            Text           = site.refKind,
            Font           = Enum.Font.RobotoMono,
            TextSize       = theme:size("font.mono") - 1,
            TextColor3     = theme:color("disassemblyMnem"),
            TextXAlignment = Enum.TextXAlignment.Left,
            BackgroundTransparency = 1,
        }),
        e("TextLabel", {
            key            = "mode",
            Position       = UDim2.fromOffset(344, 0),
            Size           = UDim2.new(1, -350, 0, ROW_HEIGHT),
            Text           = modeTxt,
            Font           = Enum.Font.RobotoMono,
            TextSize       = theme:size("font.mono") - 1,
            TextColor3     = theme:color("disassemblyComment"),
            TextXAlignment = Enum.TextXAlignment.Left,
            BackgroundTransparency = 1,
        }),
    })
end

function XRefView:_renderFooter()
    local theme = self.theme
    local n = #(self.state.sites or {})
    return e("Frame", {
        key              = "footer",
        Size             = UDim2.new(1, 0, 0, FOOTER_H),
        Position         = UDim2.new(0, 0, 1, -FOOTER_H),
        BackgroundColor3 = theme:color("surfaceAlt"),
        BorderSizePixel  = 0,
    }, {
        e("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) }),
        e("TextLabel", {
            Text                  = string.format("%d reference%s", n, n == 1 and "" or "s"),
            Font                  = Enum.Font.Gotham,
            TextSize              = theme:size("font.ui") - 2,
            TextColor3            = theme:color("textMuted"),
            TextXAlignment        = Enum.TextXAlignment.Left,
            BackgroundTransparency = 1,
            Size                  = UDim2.fromScale(1, 1),
        }),
    })
end

function XRefView:render()
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

    if not self.props.query then
        return e("Frame", {
            Size             = self.props.Size,
            Position         = self.props.Position,
            BackgroundColor3 = theme:color("background"),
            BorderSizePixel  = 0,
        }, {
            self:_renderHeader(),
            e("TextLabel", {
                Position       = UDim2.fromOffset(0, HEADER_H),
                Size           = UDim2.new(1, 0, 1, -HEADER_H),
                Text           = "select a string in Strings or a name in Names\nto see its references",
                Font           = Enum.Font.Gotham,
                TextSize       = theme:size("font.ui"),
                TextColor3     = theme:color("textMuted"),
                BackgroundTransparency = 1,
            }),
        })
    end

    local sites = self.state.sites
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
            items          = sites,
            itemCount      = #sites,
            rowHeight      = ROW_HEIGHT,
            overscan       = 12,
            renderItem     = function(item, idx, isOdd) return self:_renderRow(item, idx, isOdd) end,
        }),
        self:_renderFooter(),
    })
end

return XRefView
