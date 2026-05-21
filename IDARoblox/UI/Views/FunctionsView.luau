--!nonstrict
-- =====================================================================
-- IDARoblox / UI / Views / FunctionsView
-- ---------------------------------------------------------------------
-- Flat, IDA-style "Functions" window listing every proto in the
-- bytecode with per-row summary statistics:
--
--   id  · name · params · upvals · stack · insns · blocks · calls · refs · flags
--
-- The list is virtualized (ScrollVirtualizer) and column-sortable.
-- Click selects + opens the proto; right-click opens a context menu
-- (rename, jump to entry, bookmark entry pc, "show xrefs to this proto").
-- A search-box header filters by name/id with the SearchEngine if
-- available, otherwise plain-substring.
--
-- Props
--   bytecode      — ParsedBytecode
--   disassembler  — Analysis.Disassembler  (for instruction counts)
--   cfgBuilder    — Analysis.CFGBuilder    (for block/loop counts)
--   xrefIndex     — XRefIndex              (for refs)
--   projectDB     — Database.ProjectDB     (for symbol names + flags)
--   onOpenProto   — fn(protoId)
--   onContextMenu — fn(protoId, position) — open ContextMenu widget
-- =====================================================================

local Component         = _G.IDARo.require("UI.Framework.Component")
local Element           = _G.IDARo.require("UI.Framework.Element")
local ScrollVirtualizer = _G.IDARo.require("UI.Framework.ScrollVirtualizer")

local Database          = _G.IDARo.require("Database")
local SymbolFlags       = Database.SymbolTable.Flags

local e     = Element.create
local Event = Element.Event

local FunctionsView = Component.extend("FunctionsView")

Component.setDefaultProps(FunctionsView, {
    bytecode      = nil,
    disassembler  = nil,
    cfgBuilder    = nil,
    xrefIndex     = nil,
    projectDB     = nil,
    onOpenProto   = nil,
    onContextMenu = nil,
    Size          = UDim2.fromScale(1, 1),
})

local ROW_HEIGHT = 18
local HEADER_H   = 28
local FOOTER_H   = 20

local COLUMNS = {
    { key = "id",      label = "ID",     width = 50,  align = "right" },
    { key = "name",    label = "Name",   width = 0,   align = "left"  },  -- 0 = flex
    { key = "params",  label = "P",      width = 30,  align = "right" },
    { key = "upvals",  label = "U",      width = 30,  align = "right" },
    { key = "stack",   label = "Stk",    width = 40,  align = "right" },
    { key = "insns",   label = "Insns",  width = 60,  align = "right" },
    { key = "blocks",  label = "Blk",    width = 40,  align = "right" },
    { key = "loops",   label = "Loop",   width = 40,  align = "right" },
    { key = "calls",   label = "Call",   width = 40,  align = "right" },
    { key = "refs",    label = "Refs",   width = 50,  align = "right" },
    { key = "flags",   label = "Flags",  width = 60,  align = "left"  },
}

-- ---------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------

function FunctionsView:init(_props)
    self.state = {
        searchText = "",
        sortKey    = "id",
        sortDir    = "asc",
        rows       = nil,                                            -- cached
    }
end

function FunctionsView:didUpdate(prevProps)
    if prevProps.bytecode ~= self.props.bytecode
        or prevProps.disassembler ~= self.props.disassembler
        or prevProps.xrefIndex ~= self.props.xrefIndex
        or prevProps.projectDB ~= self.props.projectDB then
        self:setState({ rows = nil })                                -- invalidate cache
    end
end

-- ---------------------------------------------------------------------
-- Row computation
-- ---------------------------------------------------------------------

local function flagsToString(symbols, sym)
    if not sym then return "" end
    local parts = {}
    if symbols:hasFlag(sym, SymbolFlags.USER_NAMED) then parts[#parts + 1] = "N" end
    if symbols:hasFlag(sym, SymbolFlags.ENTRY)      then parts[#parts + 1] = "E" end
    if symbols:hasFlag(sym, SymbolFlags.OBFUSCATED) then parts[#parts + 1] = "O" end
    if symbols:hasFlag(sym, SymbolFlags.HOOK_TARGET) then parts[#parts + 1] = "H" end
    if symbols:hasFlag(sym, SymbolFlags.PINNED)     then parts[#parts + 1] = "P" end
    if symbols:hasFlag(sym, SymbolFlags.DEAD)       then parts[#parts + 1] = "D" end
    return table.concat(parts)
end

function FunctionsView:_buildRows()
    if self.state.rows then return self.state.rows end
    local bc = self.props.bytecode
    if not bc or not bc.protos then return {} end

    local d         = self.props.disassembler
    local cfgb      = self.props.cfgBuilder
    local xrefs     = self.props.xrefIndex
    local db        = self.props.projectDB
    local symbols   = db and db:symbols()
    local mainPid   = bc.mainProtoId

    local rows = {}
    for protoId, proto in bc.protos do
        local sym = symbols and symbols:byKey("proto", tostring(protoId))
        local name = (sym and sym.name) or proto.debugName
        if not name or name == "" then name = string.format("proto_%d", protoId) end

        local insns = 0
        if proto.instructions then insns = #proto.instructions
        elseif d then
            local ok, stream = pcall(function() return d:disassembleProto(protoId) end)
            if ok and stream and stream.instructions then insns = #stream.instructions end
        end

        local blocks, loops, calls = 0, 0, 0
        if cfgb then
            local ok, cfg = pcall(function() return cfgb:cfgForProto(protoId) end)
            if ok and cfg and cfg.stats then
                blocks = cfg.stats.blockCount or 0
                loops  = cfg.stats.loopCount  or 0
                calls  = cfg.stats.callCount  or 0
            end
        end

        local refs = 0
        if xrefs and xrefs.byProto then
            local bucket = xrefs.byProto[protoId]
            if bucket then refs = #bucket end
        elseif xrefs and xrefs.callerSitesByProto then
            local bucket = xrefs.callerSitesByProto[protoId]
            if bucket then refs = #bucket end
        end

        local flagsStr = ""
        if symbols and sym then flagsStr = flagsToString(symbols, sym) end
        if protoId == mainPid then
            flagsStr = (flagsStr == "") and "M" or ("M" .. flagsStr)
        end

        rows[#rows + 1] = {
            id     = protoId,
            name   = name,
            params = proto.numparams or 0,
            upvals = proto.nups      or proto.numupvalues or 0,
            stack  = proto.maxstacksize or 0,
            insns  = insns,
            blocks = blocks,
            loops  = loops,
            calls  = calls,
            refs   = refs,
            flags  = flagsStr,
            _sym   = sym,
            _isMain = protoId == mainPid,
        }
    end

    -- Filter by search
    local q = self.state.searchText
    if q and q ~= "" then
        local lq = string.lower(q)
        local filtered = {}
        for _, r in rows do
            if string.find(string.lower(r.name), lq, 1, true)
                or tostring(r.id) == q then
                filtered[#filtered + 1] = r
            end
        end
        rows = filtered
    end

    -- Sort
    local key, dir = self.state.sortKey, self.state.sortDir
    table.sort(rows, function(a, b)
        local av, bv = a[key], b[key]
        if av == bv then return a.id < b.id end
        if av == nil then return false end
        if bv == nil then return true end
        if dir == "asc" then return av < bv end
        return av > bv
    end)

    self.state.rows = rows
    return rows
end

-- ---------------------------------------------------------------------
-- Row renderer
-- ---------------------------------------------------------------------

local function colXs(totalWidth)
    -- Compute starting x of each column given the flex column
    local fixed = 0
    local flexCount = 0
    for _, c in COLUMNS do
        if c.width == 0 then flexCount = flexCount + 1
        else fixed = fixed + c.width end
    end
    local flexW = math.max(80, math.floor((totalWidth - fixed - #COLUMNS * 4) / math.max(1, flexCount)))
    local xs = {}
    local cur = 0
    for i, c in COLUMNS do
        xs[i] = { x = cur, w = c.width == 0 and flexW or c.width }
        cur = cur + xs[i].w + 4
    end
    return xs, cur
end

function FunctionsView:_renderRow(row, idx, totalWidth)
    local theme = self.theme
    local rowBg = (idx % 2 == 0) and theme:color("backgroundAlt") or theme:color("background")
    local fg    = row._isMain and theme:color("accent") or theme:color("text")
    local xs    = colXs(totalWidth)

    local cells = {}
    for i, col in COLUMNS do
        local v = row[col.key]
        if v == nil then v = "" end
        cells[#cells + 1] = e("TextLabel", {
            Size             = UDim2.fromOffset(xs[i].w, ROW_HEIGHT - 2),
            Position         = UDim2.fromOffset(xs[i].x, 1),
            BackgroundTransparency = 1,
            Text             = tostring(v),
            TextColor3       = fg,
            TextSize         = 12,
            Font             = Enum.Font.Code,
            TextXAlignment   = col.align == "right" and Enum.TextXAlignment.Right
                or Enum.TextXAlignment.Left,
            TextTruncate     = Enum.TextTruncate.AtEnd,
            ClipsDescendants = true,
        }, {
            e("UIPadding", {
                PaddingLeft  = UDim.new(0, col.align == "right" and 0 or 4),
                PaddingRight = UDim.new(0, col.align == "right" and 4 or 0),
            }),
        })
    end

    return e("Frame", {
        Name             = "row_" .. tostring(row.id),
        Size             = UDim2.new(1, 0, 0, ROW_HEIGHT),
        BackgroundColor3 = rowBg,
        BorderSizePixel  = 0,
        [Event.InputBegan] = function(_rbx, input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 then
                if self.props.onOpenProto then
                    self.props.onOpenProto(row.id)
                end
            elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
                if self.props.onContextMenu then
                    self.props.onContextMenu(row.id,
                        Vector2.new(input.Position.X, input.Position.Y),
                        row)
                end
            end
        end,
    }, cells)
end

-- ---------------------------------------------------------------------
-- Header row (clickable column buttons)
-- ---------------------------------------------------------------------

function FunctionsView:_renderHeader(totalWidth)
    local theme = self.theme
    local xs = colXs(totalWidth)
    local cells = {
        e("Frame", {
            Size = UDim2.fromScale(1, 1),
            BackgroundColor3 = theme:color("surfaceAlt"),
            BorderSizePixel = 0,
        }),
    }
    for i, col in COLUMNS do
        local isSort = self.state.sortKey == col.key
        local label = col.label .. (isSort and (self.state.sortDir == "asc" and " ▲" or " ▼") or "")
        cells[#cells + 1] = e("TextButton", {
            Size = UDim2.fromOffset(xs[i].w, HEADER_H - 4),
            Position = UDim2.fromOffset(xs[i].x, 2),
            BackgroundTransparency = 1,
            Text = label,
            TextColor3 = theme:color("text"),
            TextSize = 11,
            Font = Enum.Font.Code,
            TextXAlignment = col.align == "right" and Enum.TextXAlignment.Right
                or Enum.TextXAlignment.Left,
            AutoButtonColor = false,
            [Event.Activated] = function()
                local dir = "asc"
                if self.state.sortKey == col.key then
                    dir = self.state.sortDir == "asc" and "desc" or "asc"
                end
                self:setState({ sortKey = col.key, sortDir = dir, rows = nil })
            end,
        })
    end
    return e("Frame", {
        Name = "header",
        Size = UDim2.new(1, 0, 0, HEADER_H),
        BackgroundTransparency = 1,
    }, cells)
end

-- ---------------------------------------------------------------------
-- Search box
-- ---------------------------------------------------------------------

function FunctionsView:_renderSearchBar()
    local theme = self.theme
    return e("Frame", {
        Name = "searchbar",
        Size = UDim2.new(1, -8, 0, 22),
        Position = UDim2.fromOffset(4, 3),
        BackgroundColor3 = theme:color("surfaceAlt"),
        BorderColor3 = theme:color("border"),
        BorderSizePixel = 1,
    }, {
        e("TextBox", {
            Size = UDim2.fromScale(1, 1),
            BackgroundTransparency = 1,
            Text = self.state.searchText,
            PlaceholderText = "Filter functions…",
            TextColor3 = theme:color("text"),
            PlaceholderColor3 = theme:color("textMuted"),
            TextSize = 12,
            Font = Enum.Font.Code,
            TextXAlignment = Enum.TextXAlignment.Left,
            ClearTextOnFocus = false,
            [Element.Changed.Text] = function(rbx)
                if rbx.Text == self.state.searchText then return end
                self:setState({ searchText = rbx.Text, rows = nil })
            end,
        }, {
            e("UIPadding", { PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6) }),
        }),
    })
end

-- ---------------------------------------------------------------------
-- Render
-- ---------------------------------------------------------------------

function FunctionsView:render()
    local theme = self.theme
    local rows = self:_buildRows()
    local total = self.props.bytecode and self.props.bytecode.stats
        and self.props.bytecode.stats.protos or 0

    return e("Frame", {
        Name = "FunctionsView",
        Size = self.props.Size,
        Position = self.props.Position or UDim2.fromOffset(0, 0),
        BackgroundColor3 = theme:color("surface"),
        BorderSizePixel = 0,
    }, {
        -- Search bar (top)
        e("Frame", {
            Name = "topbar",
            Size = UDim2.new(1, 0, 0, 28),
            BackgroundTransparency = 1,
        }, { self:_renderSearchBar() }),

        -- Column header
        e("Frame", {
            Name = "headerContainer",
            Size = UDim2.new(1, 0, 0, HEADER_H),
            Position = UDim2.fromOffset(0, 28),
            BackgroundColor3 = theme:color("surfaceAlt"),
            BorderSizePixel = 0,
            [Element.Changed.AbsoluteSize] = function(rbx)
                self._headerWidth = rbx.AbsoluteSize.X
            end,
        }, { self:_renderHeader(self._headerWidth or 800) }),

        -- Virtualized body
        e(ScrollVirtualizer, {
            Size = UDim2.new(1, 0, 1, -(28 + HEADER_H + FOOTER_H)),
            Position = UDim2.fromOffset(0, 28 + HEADER_H),
            items     = rows,
            itemCount = #rows,
            itemHeight = ROW_HEIGHT,
            renderItem = function(item, i, _isOdd)
    -- Fall back to looking up by index if items prop wasn't passed
    local row = item ~= nil and item or (rows and rows[i])
    if row == nil then return nil end
    return self:_renderRow(row, i, _isOdd)
            end,
        }),

        -- Footer
        e("Frame", {
            Name = "footer",
            Size = UDim2.new(1, 0, 0, FOOTER_H),
            Position = UDim2.new(0, 0, 1, -FOOTER_H),
            BackgroundColor3 = theme:color("backgroundAlt"),
            BorderSizePixel = 0,
        }, {
            e("TextLabel", {
                Size = UDim2.fromScale(1, 1),
                BackgroundTransparency = 1,
                Text = string.format("%d functions (showing %d)", total, #rows),
                TextColor3 = theme:color("textMuted"),
                TextSize = 11,
                Font = Enum.Font.Code,
                TextXAlignment = Enum.TextXAlignment.Left,
            }, {
                e("UIPadding", { PaddingLeft = UDim.new(0, 8) }),
            }),
        }),
    })
end

return FunctionsView
