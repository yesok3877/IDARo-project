--!nonstrict
-- =====================================================================
-- IDARoblox / UI / Views / ClosuresView
-- ---------------------------------------------------------------------
-- Active closures with upvalues + constants. Consumes Runtime.closures
-- (the ClosureInspector service). Two-pane layout:
--
--   Left  — sortable list of closures (source, name, #upvalues, #consts)
--           with a filter box.
--   Right — inspector for the selected closure showing:
--              * Per-upvalue rows: index, name (if known), live value
--                with an "Edit" button that invokes setUpvalue()
--              * Per-constant rows: index, kind, value
--                Read-only by default; "Edit" promotes to writable when
--                executor exposes debug.setconstant (kind-locked unless
--                Force is checked).
--           A "Revert" button reverts every patch this closure has
--           accumulated (the inspector tracks patches per fn).
-- =====================================================================

local Component         = _G.IDARo.require("UI.Framework.Component")
local Element           = _G.IDARo.require("UI.Framework.Element")
local ScrollVirtualizer = _G.IDARo.require("UI.Framework.ScrollVirtualizer")

local e     = Element.create
local Event = Element.Event

local ClosuresView = Component.extend("ClosuresView")

Component.setDefaultProps(ClosuresView, {
    runtime        = nil,
    onSelectClosure = nil,
    Size           = UDim2.fromScale(1, 1),
})

local LIST_W   = 280
local ROW_H    = 18
local HEADER_H = 28
local FOOTER_H = 20
local TOP_BAR_H = 30

-- ---------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------

function ClosuresView:init(_props)
    self.state = {
        closures        = {},
        filteredCache   = nil,
        searchText      = "",
        sortKey         = "source",
        sortDir         = "asc",
        selectedClosure = nil,
        scanning        = false,
        editingUpvalue  = nil,                                       -- { fnRef, index, draft }
        editingConstant = nil,                                       -- { fnRef, index, draft }
        forceTypeChange = false,
    }
end

function ClosuresView:didMount()
    if self.props.runtime and self.props.runtime.closures then
        self:_scan()
    end
end

function ClosuresView:didUpdate(prev)
    if prev.runtime ~= self.props.runtime and self.props.runtime
        and self.props.runtime.closures then
        self:_scan()
    end
end

-- ---------------------------------------------------------------------
-- Scan
-- ---------------------------------------------------------------------

function ClosuresView:_scan()
    local inspector = self.props.runtime and self.props.runtime.closures
    local gc = self.props.runtime and self.props.runtime.gc
    if not inspector or not gc then return end
    self:setState({ scanning = true })
    -- Pull functions out of the GC scanner; the inspector summarises each
    -- with its current upvalue/constant counts.
    local ok, snap = pcall(function() return gc:scan({ includeReferences = false }) end)
    if not ok or not snap then self:setState({ scanning = false }); return end
    local closures = {}
    for _, obj in snap.objects do
        if obj.type == "func" and obj.ref then
            local ok2, desc = pcall(function()
                return inspector:summarise(obj.ref)
            end)
            if ok2 and desc then
                desc.gc = obj
                desc.ref = obj.ref
                closures[#closures + 1] = desc
            end
        end
    end
    self:setState({
        closures      = closures,
        scanning      = false,
        filteredCache = nil,
    })
end

-- ---------------------------------------------------------------------
-- Filter + sort
-- ---------------------------------------------------------------------

function ClosuresView:_filtered()
    if self.state.filteredCache then return self.state.filteredCache end
    local q = self.state.searchText
    local lq = q ~= "" and string.lower(q) or nil
    local out = {}
    for _, c in self.state.closures do
        local label = c.label or c.source or ""
        if not lq or string.find(string.lower(label), lq, 1, true) then
            out[#out + 1] = c
        end
    end
    table.sort(out, function(a, b)
        local av = a[self.state.sortKey]
        local bv = b[self.state.sortKey]
        if av == bv then
            return tostring(a.label or "") < tostring(b.label or "")
        end
        if av == nil then return false end
        if bv == nil then return true end
        if self.state.sortDir == "asc" then return av < bv end
        return av > bv
    end)
    self.state.filteredCache = out
    return out
end

-- ---------------------------------------------------------------------
-- Top bar
-- ---------------------------------------------------------------------

function ClosuresView:_renderTopBar()
    local theme = self.theme
    return e("Frame", {
        Name = "topbar",
        Size = UDim2.new(1, 0, 0, TOP_BAR_H),
        BackgroundColor3 = theme:color("surfaceAlt"),
        BorderSizePixel = 0,
    }, {
        e("TextButton", {
            Size = UDim2.fromOffset(80, TOP_BAR_H - 6),
            Position = UDim2.fromOffset(4, 3),
            BackgroundColor3 = self.state.scanning and theme:color("surfaceAlt")
                or theme:color("surface"),
            BorderColor3 = theme:color("border"),
            BorderSizePixel = 1,
            Text = self.state.scanning and "Scanning…" or "Refresh",
            TextColor3 = theme:color("text"),
            TextSize = 12,
            Font = Enum.Font.Code,
            AutoButtonColor = not self.state.scanning,
            [Event.Activated] = function()
                if not self.state.scanning then self:_scan() end
            end,
        }),
        e("TextBox", {
            Size = UDim2.new(0, LIST_W - 92, 0, TOP_BAR_H - 6),
            Position = UDim2.fromOffset(92, 3),
            BackgroundColor3 = theme:color("surfaceAlt"),
            BorderColor3 = theme:color("border"),
            BorderSizePixel = 1,
            Text = self.state.searchText,
            PlaceholderText = "Filter closures…",
            TextColor3 = theme:color("text"),
            PlaceholderColor3 = theme:color("textMuted"),
            TextSize = 12,
            Font = Enum.Font.Code,
            TextXAlignment = Enum.TextXAlignment.Left,
            ClearTextOnFocus = false,
            [Element.Changed.Text] = function(rbx)
                if rbx.Text == self.state.searchText then return end
                self:setState({ searchText = rbx.Text, filteredCache = nil })
            end,
        }, {
            e("UIPadding", { PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6) }),
        }),
        -- Force-type-change toggle (right side)
        e("TextButton", {
            Size = UDim2.fromOffset(100, TOP_BAR_H - 6),
            Position = UDim2.new(1, -104, 0, 3),
            BackgroundColor3 = self.state.forceTypeChange
                and theme:color("warning") or theme:color("surface"),
            BorderColor3 = theme:color("border"),
            BorderSizePixel = 1,
            Text = self.state.forceTypeChange and "Force ON" or "Force OFF",
            TextColor3 = theme:color("text"),
            TextSize = 11,
            Font = Enum.Font.Code,
            AutoButtonColor = true,
            [Event.Activated] = function()
                self:setState({ forceTypeChange = not self.state.forceTypeChange })
            end,
        }),
    })
end

-- ---------------------------------------------------------------------
-- Closure list row
-- ---------------------------------------------------------------------

function ClosuresView:_renderClosureRow(c, idx)
    local theme = self.theme
    local selected = self.state.selectedClosure == c
    local rowBg = selected and theme:color("primaryMuted")
        or ((idx % 2 == 0) and theme:color("backgroundAlt") or theme:color("background"))
    return e("Frame", {
        Name = "crow_" .. tostring(idx),
        Size = UDim2.new(1, 0, 0, ROW_H),
        BackgroundColor3 = rowBg,
        BorderSizePixel = 0,
        [Event.InputBegan] = function(_rbx, input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 then
                self:setState({ selectedClosure = c })
                if self.props.onSelectClosure then
                    self.props.onSelectClosure(c)
                end
            end
        end,
    }, {
        e("TextLabel", {
            Size = UDim2.fromOffset(50, ROW_H - 2),
            Position = UDim2.fromOffset(4, 1),
            BackgroundTransparency = 1,
            Text = c.source or "?",
            TextColor3 = theme:color("textMuted"),
            TextSize = 11,
            Font = Enum.Font.Code,
            TextXAlignment = Enum.TextXAlignment.Left,
        }),
        e("TextLabel", {
            Size = UDim2.new(1, -(50 + 70 + 8 + 4), 0, ROW_H - 2),
            Position = UDim2.fromOffset(58, 1),
            BackgroundTransparency = 1,
            Text = c.label or "(anon)",
            TextColor3 = theme:color("text"),
            TextSize = 12,
            Font = Enum.Font.Code,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd,
            ClipsDescendants = true,
        }),
        e("TextLabel", {
            Size = UDim2.fromOffset(70, ROW_H - 2),
            Position = UDim2.new(1, -74, 0, 1),
            BackgroundTransparency = 1,
            Text = string.format("%du / %dk",
                c.numUpvalues or 0, c.numConstants or 0),
            TextColor3 = theme:color("textMuted"),
            TextSize = 11,
            Font = Enum.Font.Code,
            TextXAlignment = Enum.TextXAlignment.Right,
        }),
    })
end

-- ---------------------------------------------------------------------
-- Inspector
-- ---------------------------------------------------------------------

function ClosuresView:_setUpvalue(c, index, draft)
    local inspector = self.props.runtime and self.props.runtime.closures
    if not inspector then return false, "no inspector" end
    -- Try to coerce draft string into the most likely native type
    local value
    if draft == "nil" then value = nil
    elseif draft == "true" then value = true
    elseif draft == "false" then value = false
    elseif tonumber(draft) then value = tonumber(draft)
    else value = draft end
    local ok, err = pcall(function()
        inspector:setUpvalue(c.ref, index, value)
    end)
    if ok then self:_scan() end
    return ok, err
end

function ClosuresView:_setConstant(c, index, draft)
    local inspector = self.props.runtime and self.props.runtime.closures
    if not inspector then return false, "no inspector" end
    local value
    if tonumber(draft) then value = tonumber(draft)
    elseif draft == "true" then value = true
    elseif draft == "false" then value = false
    elseif draft == "nil" then value = nil
    else value = draft end
    local ok, err = pcall(function()
        inspector:setConstant(c.ref, index, value, { allowTypeChange = self.state.forceTypeChange })
    end)
    if ok then self:_scan() end
    return ok, err
end

function ClosuresView:_revertAll(c)
    local inspector = self.props.runtime and self.props.runtime.closures
    if not inspector then return end
    pcall(function() inspector:revertAll(c.ref) end)
    self:_scan()
end

function ClosuresView:_renderInspector()
    local theme = self.theme
    local c = self.state.selectedClosure
    if not c then
        return e("Frame", {
            Name = "inspector",
            Size = UDim2.new(1, -LIST_W, 1, -(TOP_BAR_H + FOOTER_H)),
            Position = UDim2.fromOffset(LIST_W, TOP_BAR_H),
            BackgroundColor3 = theme:color("surface"),
            BorderSizePixel = 0,
        }, {
            e("TextLabel", {
                Size = UDim2.fromScale(1, 1),
                BackgroundTransparency = 1,
                Text = "Select a closure to inspect",
                TextColor3 = theme:color("textMuted"),
                TextSize = 12,
                Font = Enum.Font.Code,
            }),
        })
    end

    local rows = {}
    local y = 4
    local function header(text)
        rows[#rows + 1] = e("TextLabel", {
            Size = UDim2.new(1, -8, 0, 16),
            Position = UDim2.fromOffset(6, y),
            BackgroundTransparency = 1,
            Text = text,
            TextColor3 = theme:color("textMuted"),
            TextSize = 11,
            Font = Enum.Font.Code,
            TextXAlignment = Enum.TextXAlignment.Left,
        })
        y = y + 18
    end

    header(string.format("Closure: %s (source=%s)", c.label or "?", c.source or "?"))
    if c.patchCount and c.patchCount > 0 then
        rows[#rows + 1] = e("TextButton", {
            Size = UDim2.fromOffset(120, 18),
            Position = UDim2.fromOffset(6, y),
            BackgroundColor3 = theme:color("warning"),
            BorderColor3 = theme:color("border"),
            BorderSizePixel = 1,
            Text = string.format("Revert (%d patches)", c.patchCount),
            TextColor3 = theme:color("text"),
            TextSize = 11,
            Font = Enum.Font.Code,
            [Event.Activated] = function() self:_revertAll(c) end,
        })
        y = y + 22
    end

    -- Upvalues
    header(string.format("Upvalues (%d)", #(c.upvalues or {})))
    if c.upvalues then
        for i, uv in c.upvalues do
            local editing = self.state.editingUpvalue
                and self.state.editingUpvalue.fnRef == c.ref
                and self.state.editingUpvalue.index == i
            rows[#rows + 1] = e("TextLabel", {
                Size = UDim2.fromOffset(120, 16),
                Position = UDim2.fromOffset(6, y),
                BackgroundTransparency = 1,
                Text = string.format("[%d] %s", i, uv.name or "?"),
                TextColor3 = theme:color("text"),
                TextSize = 12,
                Font = Enum.Font.Code,
                TextXAlignment = Enum.TextXAlignment.Left,
            })
            if editing then
                rows[#rows + 1] = e("TextBox", {
                    Size = UDim2.new(1, -260, 0, 16),
                    Position = UDim2.fromOffset(128, y),
                    BackgroundColor3 = theme:color("surfaceAlt"),
                    BorderColor3 = theme:color("accent"),
                    BorderSizePixel = 1,
                    Text = tostring(self.state.editingUpvalue.draft or ""),
                    TextColor3 = theme:color("text"),
                    TextSize = 12,
                    Font = Enum.Font.Code,
                    TextXAlignment = Enum.TextXAlignment.Left,
                    ClearTextOnFocus = false,
                    [Element.Changed.Text] = function(rbx)
                        self.state.editingUpvalue.draft = rbx.Text
                    end,
                    [Event.FocusLost] = function(rbx, enterPressed)
                        if enterPressed then
                            self:_setUpvalue(c, i, rbx.Text)
                        end
                        self:setState({ editingUpvalue = nil })
                    end,
                })
            else
                rows[#rows + 1] = e("TextLabel", {
                    Size = UDim2.new(1, -260, 0, 16),
                    Position = UDim2.fromOffset(128, y),
                    BackgroundTransparency = 1,
                    Text = tostring(uv.value),
                    TextColor3 = theme:color("text"),
                    TextSize = 12,
                    Font = Enum.Font.Code,
                    TextXAlignment = Enum.TextXAlignment.Left,
                    TextTruncate = Enum.TextTruncate.AtEnd,
                })
            end
            rows[#rows + 1] = e("TextButton", {
                Size = UDim2.fromOffset(40, 16),
                Position = UDim2.new(1, -100, 0, y),
                BackgroundColor3 = theme:color("surface"),
                BorderColor3 = theme:color("border"),
                BorderSizePixel = 1,
                Text = editing and "Save" or "Edit",
                TextColor3 = theme:color("text"),
                TextSize = 11,
                Font = Enum.Font.Code,
                [Event.Activated] = function()
                    if editing then
                        self:_setUpvalue(c, i, self.state.editingUpvalue.draft or "")
                        self:setState({ editingUpvalue = nil })
                    else
                        self:setState({ editingUpvalue = {
                            fnRef = c.ref, index = i, draft = tostring(uv.value),
                        } })
                    end
                end,
            })
            y = y + 18
            if i >= 64 then
                rows[#rows + 1] = e("TextLabel", {
                    Size = UDim2.new(1, -8, 0, 14),
                    Position = UDim2.fromOffset(6, y),
                    BackgroundTransparency = 1,
                    Text = string.format("(showing first 64 of %d)", #c.upvalues),
                    TextColor3 = theme:color("textMuted"),
                    TextSize = 11,
                    Font = Enum.Font.Code,
                })
                y = y + 16
                break
            end
        end
    end

    -- Constants
    header(string.format("Constants (%d)", #(c.constants or {})))
    if c.constants then
        for i, k in c.constants do
            local editing = self.state.editingConstant
                and self.state.editingConstant.fnRef == c.ref
                and self.state.editingConstant.index == i
            rows[#rows + 1] = e("TextLabel", {
                Size = UDim2.fromOffset(120, 16),
                Position = UDim2.fromOffset(6, y),
                BackgroundTransparency = 1,
                Text = string.format("[%d] %s", i, k.kind or type(k.value)),
                TextColor3 = theme:color("text"),
                TextSize = 12,
                Font = Enum.Font.Code,
                TextXAlignment = Enum.TextXAlignment.Left,
            })
            if editing then
                rows[#rows + 1] = e("TextBox", {
                    Size = UDim2.new(1, -260, 0, 16),
                    Position = UDim2.fromOffset(128, y),
                    BackgroundColor3 = theme:color("surfaceAlt"),
                    BorderColor3 = theme:color("accent"),
                    BorderSizePixel = 1,
                    Text = tostring(self.state.editingConstant.draft or ""),
                    TextColor3 = theme:color("text"),
                    TextSize = 12,
                    Font = Enum.Font.Code,
                    ClearTextOnFocus = false,
                    [Element.Changed.Text] = function(rbx)
                        self.state.editingConstant.draft = rbx.Text
                    end,
                    [Event.FocusLost] = function(rbx, enterPressed)
                        if enterPressed then
                            self:_setConstant(c, i, rbx.Text)
                        end
                        self:setState({ editingConstant = nil })
                    end,
                })
            else
                local v = k.value
                local strV = tostring(v)
                if type(v) == "string" and #strV > 64 then
                    strV = string.format("%q", string.sub(v, 1, 60)) .. "…"
                end
                rows[#rows + 1] = e("TextLabel", {
                    Size = UDim2.new(1, -260, 0, 16),
                    Position = UDim2.fromOffset(128, y),
                    BackgroundTransparency = 1,
                    Text = strV,
                    TextColor3 = theme:color("text"),
                    TextSize = 12,
                    Font = Enum.Font.Code,
                    TextXAlignment = Enum.TextXAlignment.Left,
                    TextTruncate = Enum.TextTruncate.AtEnd,
                })
            end
            rows[#rows + 1] = e("TextButton", {
                Size = UDim2.fromOffset(40, 16),
                Position = UDim2.new(1, -100, 0, y),
                BackgroundColor3 = theme:color("surface"),
                BorderColor3 = theme:color("border"),
                BorderSizePixel = 1,
                Text = editing and "Save" or "Edit",
                TextColor3 = theme:color("text"),
                TextSize = 11,
                Font = Enum.Font.Code,
                [Event.Activated] = function()
                    if editing then
                        self:_setConstant(c, i, self.state.editingConstant.draft or "")
                        self:setState({ editingConstant = nil })
                    else
                        self:setState({ editingConstant = {
                            fnRef = c.ref, index = i, draft = tostring(k.value),
                        } })
                    end
                end,
            })
            y = y + 18
            if i >= 64 then
                rows[#rows + 1] = e("TextLabel", {
                    Size = UDim2.new(1, -8, 0, 14),
                    Position = UDim2.fromOffset(6, y),
                    BackgroundTransparency = 1,
                    Text = string.format("(showing first 64 of %d)", #c.constants),
                    TextColor3 = theme:color("textMuted"),
                    TextSize = 11,
                    Font = Enum.Font.Code,
                })
                y = y + 16
                break
            end
        end
    end

    return e("Frame", {
        Name = "inspector",
        Size = UDim2.new(1, -LIST_W, 1, -(TOP_BAR_H + FOOTER_H)),
        Position = UDim2.fromOffset(LIST_W, TOP_BAR_H),
        BackgroundColor3 = theme:color("surface"),
        BorderSizePixel = 0,
    }, {
        e("ScrollingFrame", {
            Size = UDim2.fromScale(1, 1),
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            CanvasSize = UDim2.fromOffset(0, y + 16),
            ScrollBarThickness = 6,
            ScrollBarImageColor3 = theme:color("borderStrong"),
        }, rows),
    })
end

-- ---------------------------------------------------------------------
-- Render
-- ---------------------------------------------------------------------

function ClosuresView:render()
    local theme = self.theme
    local closures = self:_filtered()
    return e("Frame", {
        Name = "ClosuresView",
        Size = self.props.Size,
        Position = self.props.Position or UDim2.fromOffset(0, 0),
        BackgroundColor3 = theme:color("surface"),
        BorderSizePixel = 0,
    }, {
        self:_renderTopBar(),
        e(ScrollVirtualizer, {
            Size = UDim2.new(0, LIST_W, 1, -(TOP_BAR_H + FOOTER_H)),
            Position = UDim2.fromOffset(0, TOP_BAR_H),
            itemCount = #closures,
            itemHeight = ROW_H,
            renderItem = function(i)
                return self:_renderClosureRow(closures[i], i)
            end,
        }),
        self:_renderInspector(),
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
                Text = string.format("%d closures (showing %d)",
                    #self.state.closures, #closures),
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

return ClosuresView
