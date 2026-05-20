--!nonstrict
-- =====================================================================
-- IDARoblox / UI / Views / SearchView
-- ---------------------------------------------------------------------
-- Multi-mode search across the entire bytecode.
--
-- Modes:
--   text      — substring match against mnemonic + operand text of
--               every disassembled row across every proto. The catch-all.
--   mnemonic  — exact match against the opcode name (e.g. "GETGLOBAL").
--   string    — XRef bucket lookup for byString[value]
--   global    — XRef bucket lookup for byGlobal[name]
--   field     — XRef bucket lookup for byField[name]
--   method    — XRef bucket lookup for byMethod[name]
--   builtin   — XRef bucket lookup for byBuiltin[name]
--
-- The text/mnemonic modes iterate every disassembly stream which is
-- O(total instructions) per query. Capped at MAX_RESULTS to keep big
-- scripts manageable; UI shows "showing first N of M+" when truncated.
--
-- Props:
--   bytecode      — ParsedBytecode
--   disassembler  — Analysis.Disassembler
--   xrefIndex     — XRefIndex
--   onJumpToSite  — fn(protoId, pc, hit)
-- =====================================================================

local Component         = _G.IDARo.require("UI.Framework.Component")
local Element           = _G.IDARo.require("UI.Framework.Element")
local ScrollVirtualizer = _G.IDARo.require("UI.Framework.ScrollVirtualizer")
local e                 = Element.create
local Event             = Element.Event

local SearchView = Component.extend("SearchView")

Component.setDefaultProps(SearchView, {
    bytecode     = nil,
    disassembler = nil,
    xrefIndex    = nil,
    onJumpToSite = nil,
    Size         = UDim2.fromScale(1, 1),
    Position     = UDim2.fromOffset(0, 0),
})

local ROW_HEIGHT  = 18
local HEADER_H    = 30
local FOOTER_H    = 20
local MAX_RESULTS = 1500

local MODES = { "text", "mnemonic", "string", "global", "field", "method", "builtin" }

-- ---------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------

function SearchView:init(props)
    self.state = {
        query    = "",
        mode     = "text",
        hits     = {},
        truncated = false,
        scanned  = 0,
        elapsed  = 0,
    }
end

-- ---------------------------------------------------------------------
-- Search engines
-- ---------------------------------------------------------------------

local function pushHit(out, protoId, row, comment)
    out[#out + 1] = {
        protoId  = protoId,
        pc       = row.pc,
        mnemonic = row.mnemonic,
        operand  = row.operandText or "",
        comment  = comment or row.commentText,
        site     = nil,
    }
end

local function searchText(disassembler, bytecode, needle)
    if not bytecode or not disassembler then return {}, 0, false end
    needle = string.lower(needle or "")
    if needle == "" then return {}, 0, false end
    local hits = {}
    local scanned = 0
    local truncated = false
    for protoId in bytecode.protos do
        local stream = disassembler:disassembleProto(protoId)
        if not stream then continue end
        for _, row in stream.rows do
            scanned = scanned + 1
            local hay = string.lower(
                (row.mnemonic or "") .. " " .. (row.operandText or "") .. " " .. (row.commentText or ""))
            if string.find(hay, needle, 1, true) then
                pushHit(hits, protoId, row)
                if #hits >= MAX_RESULTS then truncated = true; break end
            end
        end
        if truncated then break end
    end
    return hits, scanned, truncated
end

local function searchMnemonic(disassembler, bytecode, query)
    if not bytecode or not disassembler then return {}, 0, false end
    local target = string.upper(string.gsub(query or "", "%s", ""))
    if target == "" then return {}, 0, false end
    local hits = {}
    local scanned = 0
    local truncated = false
    for protoId in bytecode.protos do
        local stream = disassembler:disassembleProto(protoId)
        if not stream then continue end
        for _, row in stream.rows do
            scanned = scanned + 1
            if (row.mnemonic or "") == target then
                pushHit(hits, protoId, row)
                if #hits >= MAX_RESULTS then truncated = true; break end
            end
        end
        if truncated then break end
    end
    return hits, scanned, truncated
end

local function sitesToHits(xrefIndex, disassembler, sites)
    local hits = {}
    local truncated = false
    for _, site in sites do
        local stream = disassembler:disassembleProto(site.protoId)
        local row = stream and stream.rowByPc and stream.rowByPc[site.pc]
        if row then
            local hit = {
                protoId  = site.protoId,
                pc       = site.pc,
                mnemonic = row.mnemonic,
                operand  = row.operandText or "",
                comment  = row.commentText or "",
                site     = site,
            }
            hits[#hits + 1] = hit
            if #hits >= MAX_RESULTS then truncated = true; break end
        end
    end
    return hits, #sites, truncated
end

local function searchXref(xrefIndex, disassembler, mode, query)
    if not xrefIndex or not disassembler or not query or query == "" then
        return {}, 0, false
    end
    local sites
    if mode == "string"  then sites = xrefIndex:sitesForString(query)
    elseif mode == "global"  then sites = xrefIndex:sitesForGlobal(query)
    elseif mode == "field"   then sites = xrefIndex:sitesForField(query)
    elseif mode == "method"  then sites = xrefIndex:sitesForMethod(query)
    elseif mode == "builtin" then sites = xrefIndex:sitesForBuiltin(query)
    end
    if not sites or #sites == 0 then return {}, 0, false end
    return sitesToHits(xrefIndex, disassembler, sites)
end

function SearchView:_runSearch()
    if not self.props.bytecode or not self.props.disassembler then
        self.state.hits = {}; self.state.scanned = 0; self.state.truncated = false
        self:setState({})
        return
    end
    local q = self.state.query
    local mode = self.state.mode
    local hits, scanned, truncated
    local startedAt = os.clock()
    if mode == "text"     then hits, scanned, truncated = searchText(self.props.disassembler, self.props.bytecode, q)
    elseif mode == "mnemonic" then hits, scanned, truncated = searchMnemonic(self.props.disassembler, self.props.bytecode, q)
    else
        hits, scanned, truncated = searchXref(self.props.xrefIndex, self.props.disassembler, mode, q)
    end
    self.state.hits      = hits
    self.state.scanned   = scanned
    self.state.truncated = truncated
    self.state.elapsed   = (os.clock() - startedAt) * 1000             -- ms
    self:setState({})
end

function SearchView:_setQuery(q) self.state.query = q or ""; self:_runSearch() end
function SearchView:_setMode(m)  self.state.mode = m;          self:_runSearch() end

-- ---------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------

function SearchView:_renderHeader()
    local theme = self.theme
    local modeButtons = {}
    for i, m in MODES do
        local active = self.state.mode == m
        modeButtons[i] = e("TextButton", {
            key              = "mode:" .. m,
            Size             = UDim2.fromOffset(72, HEADER_H - 10),
            Text             = m,
            Font             = active and Enum.Font.GothamMedium or Enum.Font.Gotham,
            TextSize         = theme:size("font.ui") - 2,
            TextColor3       = active and theme:color("text") or theme:color("textMuted"),
            BackgroundColor3 = active and theme:color("primaryMuted") or theme:color("surface"),
            BorderSizePixel  = 0,
            AutoButtonColor  = false,
            LayoutOrder      = i + 1,
            [Event.Activated] = function() self:_setMode(m) end,
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
            Size             = UDim2.fromOffset(280, HEADER_H - 10),
            PlaceholderText  = "  type your query…",
            Text             = self.state.query,
            Font             = Enum.Font.RobotoMono,
            TextSize         = theme:size("font.ui") - 1,
            TextColor3       = theme:color("text"),
            PlaceholderColor3 = theme:color("textSubtle"),
            BackgroundColor3 = theme:color("background"),
            BorderSizePixel  = 0,
            ClearTextOnFocus = false,
            LayoutOrder      = 1,
            [Event.FocusLost] = function(inst, enterPressed)
                self:_setQuery(inst.Text)
            end,
        }, {
            e("UICorner",  { CornerRadius = UDim.new(0, theme:radius("sm")) }),
            e("UIPadding", { PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6) }),
        }),
        Element.fragment(modeButtons),
    })
end

function SearchView:_renderRow(hit, _index, isOdd)
    local theme   = self.theme
    local bc      = self.props.bytecode
    local proto   = bc and bc.protos[hit.protoId]
    local pname   = (proto and proto.debugName ~= "" and proto.debugName)
        or string.format("p[%d]", hit.protoId)
    local bg = isOdd and theme:color("disassemblyRowOdd") or theme:color("disassemblyRowEven")

    return e("TextButton", {
        Size             = UDim2.new(1, 0, 1, 0),
        Text             = "",
        AutoButtonColor  = false,
        BackgroundColor3 = bg,
        BorderSizePixel  = 0,
        [Event.Activated] = function()
            if self.props.onJumpToSite then
                pcall(self.props.onJumpToSite, hit.protoId, hit.pc, hit)
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
            key = "proto", Position = UDim2.fromOffset(8, 0),
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
            key = "addr", Position = UDim2.fromOffset(176, 0),
            Size = UDim2.fromOffset(72, ROW_HEIGHT),
            Text = string.format("0x%04X", (hit.pc - 1) * 4),
            Font = Enum.Font.RobotoMono,
            TextSize = theme:size("font.mono") - 1,
            TextColor3 = theme:color("disassemblyAddr"),
            TextXAlignment = Enum.TextXAlignment.Left,
            BackgroundTransparency = 1,
        }),
        e("TextLabel", {
            key = "mnem", Position = UDim2.fromOffset(252, 0),
            Size = UDim2.fromOffset(96, ROW_HEIGHT),
            Text = hit.mnemonic,
            Font = Enum.Font.RobotoMono,
            TextSize = theme:size("font.mono") - 1,
            TextColor3 = theme:color("disassemblyMnem"),
            TextXAlignment = Enum.TextXAlignment.Left,
            BackgroundTransparency = 1,
        }),
        e("TextLabel", {
            key = "operand", Position = UDim2.fromOffset(352, 0),
            Size = UDim2.new(1, -360, 0, ROW_HEIGHT),
            Text = hit.operand,
            Font = Enum.Font.RobotoMono,
            TextSize = theme:size("font.mono") - 1,
            TextColor3 = theme:color("disassemblyOperand"),
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd,
            BackgroundTransparency = 1,
        }),
    })
end

function SearchView:_renderFooter()
    local theme = self.theme
    local n = #(self.state.hits or {})
    local trunc = self.state.truncated and string.format(" (showing first %d)", MAX_RESULTS) or ""
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
            Text = string.format("%d hit%s · scanned %d%s%s",
                n, n == 1 and "" or "s", self.state.scanned, trunc, elapsed),
            Font = Enum.Font.Gotham,
            TextSize = theme:size("font.ui") - 2,
            TextColor3 = theme:color("textMuted"),
            TextXAlignment = Enum.TextXAlignment.Left,
            BackgroundTransparency = 1,
            Size = UDim2.fromScale(1, 1),
        }),
    })
end

function SearchView:render()
    local theme = self.theme
    if not self.props.bytecode then
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

    local hits = self.state.hits or {}
    return e("Frame", {
        Size = self.props.Size, Position = self.props.Position,
        BackgroundColor3 = theme:color("background"), BorderSizePixel = 0,
    }, {
        self:_renderHeader(),
        e(ScrollVirtualizer, {
            key       = "body",
            Position  = UDim2.fromOffset(0, HEADER_H),
            Size      = UDim2.new(1, 0, 1, -(HEADER_H + FOOTER_H)),
            items     = hits,
            itemCount = #hits,
            rowHeight = ROW_HEIGHT,
            overscan  = 16,
            renderItem = function(item, idx, isOdd) return self:_renderRow(item, idx, isOdd) end,
        }),
        self:_renderFooter(),
    })
end

return SearchView
