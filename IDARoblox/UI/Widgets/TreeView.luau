--!nonstrict
-- =====================================================================
-- IDARoblox / UI / Widgets / TreeView
-- ---------------------------------------------------------------------
-- Hierarchical tree with collapse/expand, single or multi-select,
-- virtualized rendering, keyboard navigation, and substring filtering.
--
-- Node shape (caller-provided)
--   {
--     id        = "unique"             — required
--     label     = "display text"
--     icon      = "·" | "ƒ" | "T" | …  — optional 1-char icon
--     children  = { … }                — array of child nodes
--     leaf      = bool                 — disables expand chevron
--     payload   = any                  — caller-attached data
--   }
--
-- Props
--   root           array of top-level nodes
--   selectedIds    set of selected ids (multi) OR single id (single mode)
--   selectionMode  "single" | "multi"
--   onSelect       fn(node, allSelected)
--   onActivate     fn(node, double)
--   onExpand       fn(node, expanded)
--   rowHeight      px per row (default 18)
--   indentPx       px per depth level (default 16)
--   filter         string (case-insensitive substring); empty disables
-- =====================================================================

local Component         = _G.IDARo.require("UI.Framework.Component")
local Element           = _G.IDARo.require("UI.Framework.Element")
local ScrollVirtualizer = _G.IDARo.require("UI.Framework.ScrollVirtualizer")
local e = Element.create
local Event = Element.Event

local TreeView = Component.extend("TreeView")

Component.setDefaultProps(TreeView, {
    root          = {},
    selectedIds   = nil,
    selectionMode = "single",
    onSelect      = nil,
    onActivate    = nil,
    onExpand      = nil,
    rowHeight     = 18,
    indentPx      = 16,
    filter        = nil,
})

function TreeView:init()
    self.state = {
        expanded   = {},                                             -- id → true
        selectedIds = {},
        focusedRow  = nil,                                           -- linearized row index
        flatRows    = {},                                            -- cached
    }
    self._rebuildPending = true
end

function TreeView:didMount()
    self:_rebuildFlatRows()
end

function TreeView:didUpdate(prevProps, prevState)
    if prevProps.root ~= self.props.root
        or prevProps.filter ~= self.props.filter
        or prevState.expanded ~= self.state.expanded then
        self:_rebuildFlatRows()
    end
end

-- ---------------------------------------------------------------------
-- Flatten the tree into a visible row list
-- ---------------------------------------------------------------------

function TreeView:_matchesFilter(node, filter)
    if not filter or filter == "" then return true end
    if string.find(string.lower(node.label or ""), filter, 1, true) then return true end
    if node.children then
        for _, c in node.children do
            if self:_matchesFilter(c, filter) then return true end
        end
    end
    return false
end

function TreeView:_rebuildFlatRows()
    local rows = {}
    local expanded = self.state.expanded
    local filter   = self.props.filter and self.props.filter ~= "" and string.lower(self.props.filter) or nil

    local function visit(node, depth, path)
        if not self:_matchesFilter(node, filter) then return end
        local hasChildren = node.children and #node.children > 0
        rows[#rows + 1] = {
            node      = node,
            depth     = depth,
            isExpandable = hasChildren and not node.leaf,
            isExpanded   = expanded[node.id] or false,
            path      = path,
        }
        if hasChildren and (expanded[node.id] or filter) then
            local nextPath = path .. "/" .. tostring(node.id)
            for _, c in node.children do
                visit(c, depth + 1, nextPath)
            end
        end
    end
    for _, n in self.props.root do visit(n, 0, "") end
    self:setState({ flatRows = rows })
end

-- ---------------------------------------------------------------------
-- Toggles
-- ---------------------------------------------------------------------

function TreeView:_toggleExpand(node)
    local exp = self.state.expanded
    local nextExp = {}
    for k, v in exp do nextExp[k] = v end
    nextExp[node.id] = not nextExp[node.id]
    self:setState({ expanded = nextExp })
    if self.props.onExpand then
        self.props.onExpand(node, nextExp[node.id])
    end
end

function TreeView:expand(nodeId)
    local exp = self.state.expanded
    if exp[nodeId] then return end
    local nextExp = {}
    for k, v in exp do nextExp[k] = v end
    nextExp[nodeId] = true
    self:setState({ expanded = nextExp })
end

function TreeView:expandAll()
    local exp = {}
    local function walk(n)
        exp[n.id] = true
        if n.children then for _, c in n.children do walk(c) end end
    end
    for _, n in self.props.root do walk(n) end
    self:setState({ expanded = exp })
end

function TreeView:collapseAll()
    self:setState({ expanded = {} })
end

-- ---------------------------------------------------------------------
-- Selection
-- ---------------------------------------------------------------------

function TreeView:_selectNode(node, modifiers)
    modifiers = modifiers or {}
    local sel = {}
    if self.props.selectionMode == "multi" and (modifiers.ctrl or modifiers.shift) then
        for id, v in self.state.selectedIds do sel[id] = v end
        sel[node.id] = not sel[node.id]
    else
        sel[node.id] = true
    end
    self:setState({ selectedIds = sel })
    if self.props.onSelect then self.props.onSelect(node, sel) end
end

function TreeView:_isSelected(node)
    return self.state.selectedIds[node.id] == true
end

-- ---------------------------------------------------------------------
-- Render
-- ---------------------------------------------------------------------

function TreeView:_renderRow(row, idx)
    local theme = self.theme
    local node  = row.node
    local rh    = self.props.rowHeight
    local indent = row.depth * self.props.indentPx
    local selected = self:_isSelected(node)
    local focused  = self.state.focusedRow == idx

    local bg
    if selected     then bg = theme:color("treeSelectedBg")
    elseif focused  then bg = theme:color("treeFocusBg")
    else                 bg = theme:color("transparent") end

    local chevron = ""
    if row.isExpandable then
        chevron = row.isExpanded and "▾" or "▸"
    end

    local children = {}
    children[#children + 1] = e("TextButton", {
        Size = UDim2.new(0, 14, 1, 0),
        Position = UDim2.new(0, indent, 0, 0),
        Text = chevron,
        Font = Enum.Font.SourceSans,
        TextSize = 12,
        TextColor3 = theme:color("treeFg"),
        BackgroundTransparency = 1,
        [Event "Activated"] = function()
            if row.isExpandable then self:_toggleExpand(node) end
        end,
    })
    if node.icon then
        children[#children + 1] = e("TextLabel", {
            Size = UDim2.new(0, 14, 1, 0),
            Position = UDim2.new(0, indent + 16, 0, 0),
            Text = node.icon,
            Font = Enum.Font.Code,
            TextSize = 12,
            TextColor3 = theme:color("treeIcon"),
            BackgroundTransparency = 1,
        })
    end
    children[#children + 1] = e("TextButton", {
        Size = UDim2.new(1, -(indent + 32), 1, 0),
        Position = UDim2.new(0, indent + (node.icon and 30 or 16), 0, 0),
        Text = node.label or tostring(node.id),
        Font = Enum.Font.SourceSans,
        TextSize = 13,
        TextColor3 = theme:color(selected and "treeSelectedFg" or "treeFg"),
        TextXAlignment = Enum.TextXAlignment.Left,
        BackgroundTransparency = 1,
        [Event "Activated"] = function(_, input)
            local mod = { ctrl = input and input:IsModifierKeyDown(Enum.ModifierKey.Ctrl),
                          shift = input and input:IsModifierKeyDown(Enum.ModifierKey.Shift) }
            self:_selectNode(node, mod)
            if self.props.onActivate then
                self.props.onActivate(node, false)
            end
        end,
    })

    return e("Frame", {
        Size = UDim2.new(1, 0, 0, rh),
        BackgroundColor3 = bg,
        BackgroundTransparency = (bg == self.theme:color("transparent")) and 1 or 0,
        BorderSizePixel = 0,
        LayoutOrder = idx,
    }, children)
end

function TreeView:render()
    local rows = self.state.flatRows or {}
    local rh = self.props.rowHeight
    return e(ScrollVirtualizer, {
        Size       = self.props.Size or UDim2.new(1, 0, 1, 0),
        Position   = self.props.Position or UDim2.new(0, 0, 0, 0),
        itemHeight = rh,
        items      = rows,
        renderItem = function(row, idx) return self:_renderRow(row, idx) end,
        BackgroundColor3 = self.theme:color("treeBg"),
    })
end

return TreeView
