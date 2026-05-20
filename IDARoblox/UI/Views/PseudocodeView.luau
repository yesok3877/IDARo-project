--!nonstrict
-- =====================================================================
-- IDARoblox / UI / Views / PseudocodeView
-- ---------------------------------------------------------------------
-- Displays decompiled Luau source from Analysis/Decompiler with full
-- syntax highlighting. Uses Roblox TextLabel.RichText to colour each
-- line's tokens cheaply — one TextLabel per visible row, no per-token
-- Frame proliferation.
--
-- Props:
--   decompiler   — Analysis.Decompiler instance (or nil)
--   protoId      — proto to decompile
--   selectedLine — currently-highlighted line (cursor)
--   onSelectLine — fn(lineIndex, lineText) on row click
--
-- Layout:
--   Header (28 px): function name · stats badge bar
--   Body   : virtualized rows = (line-number gutter + rich-text code)
--   Footer (20 px): "N lines · X constructs"
-- =====================================================================

local Component         = _G.IDARo.require("UI.Framework.Component")
local Element           = _G.IDARo.require("UI.Framework.Element")
local ScrollVirtualizer = _G.IDARo.require("UI.Framework.ScrollVirtualizer")
local e                 = Element.create
local Event             = Element.Event

local PseudocodeView = Component.extend("PseudocodeView")

Component.setDefaultProps(PseudocodeView, {
    decompiler   = nil,
    protoId      = nil,
    selectedLine = nil,
    onSelectLine = nil,
    Size         = UDim2.fromScale(1, 1),
    Position     = UDim2.fromOffset(0, 0),
})

local ROW_HEIGHT  = 18
local HEADER_H    = 32
local FOOTER_H    = 20
local GUTTER_W    = 52

-- ---------------------------------------------------------------------
-- Luau tokenizer
-- ---------------------------------------------------------------------

local KEYWORDS = {
    ["and"]=true, ["break"]=true, ["do"]=true, ["else"]=true,
    ["elseif"]=true, ["end"]=true, ["false"]=true, ["for"]=true,
    ["function"]=true, ["if"]=true, ["in"]=true, ["local"]=true,
    ["nil"]=true, ["not"]=true, ["or"]=true, ["repeat"]=true,
    ["return"]=true, ["then"]=true, ["true"]=true, ["until"]=true,
    ["while"]=true, ["continue"]=true,
}

local function tokenizeLuauLine(line)
    local tokens = {}
    local pos = 1
    local len = #line
    while pos <= len do
        local char = string.sub(line, pos, pos)

        -- Whitespace run
        if char == " " or char == "\t" then
            local start = pos
            while pos <= len do
                local c = string.sub(line, pos, pos)
                if c ~= " " and c ~= "\t" then break end
                pos = pos + 1
            end
            tokens[#tokens + 1] = { kind = "ws", text = string.sub(line, start, pos - 1) }
            continue
        end

        -- Comment
        if char == "-" and string.sub(line, pos + 1, pos + 1) == "-" then
            if string.sub(line, pos, pos + 3) == "--[[" then
                -- Inline block-comment scan for `]]` on the same line
                local endPos = string.find(line, "]]", pos + 4, true)
                if endPos then
                    tokens[#tokens + 1] = { kind = "comment", text = string.sub(line, pos, endPos + 1) }
                    pos = endPos + 2
                else
                    tokens[#tokens + 1] = { kind = "comment", text = string.sub(line, pos) }
                    pos = len + 1
                end
            else
                tokens[#tokens + 1] = { kind = "comment", text = string.sub(line, pos) }
                pos = len + 1
            end
            continue
        end

        -- Strings (double or single quoted, with \-escapes)
        if char == '"' or char == "'" then
            local quote = char
            local start = pos
            pos = pos + 1
            while pos <= len do
                local c = string.sub(line, pos, pos)
                if c == "\\" then
                    pos = pos + 2
                elseif c == quote then
                    pos = pos + 1; break
                else
                    pos = pos + 1
                end
            end
            tokens[#tokens + 1] = { kind = "string", text = string.sub(line, start, pos - 1) }
            continue
        end

        -- Long-bracket string `[[...]]`
        if char == "[" and string.sub(line, pos + 1, pos + 1) == "[" then
            local endPos = string.find(line, "]]", pos + 2, true)
            if endPos then
                tokens[#tokens + 1] = { kind = "string", text = string.sub(line, pos, endPos + 1) }
                pos = endPos + 2
                continue
            end
        end

        -- Number (decimal, hex, optional exponent)
        if string.match(char, "%d") then
            local start = pos
            if string.sub(line, pos, pos + 1) == "0x" or string.sub(line, pos, pos + 1) == "0X" then
                pos = pos + 2
                while pos <= len and string.match(string.sub(line, pos, pos), "[%da-fA-F]") do
                    pos = pos + 1
                end
            else
                while pos <= len and string.match(string.sub(line, pos, pos), "%d") do
                    pos = pos + 1
                end
                if string.sub(line, pos, pos) == "." then
                    pos = pos + 1
                    while pos <= len and string.match(string.sub(line, pos, pos), "%d") do
                        pos = pos + 1
                    end
                end
                local ec = string.sub(line, pos, pos)
                if ec == "e" or ec == "E" then
                    pos = pos + 1
                    local sc = string.sub(line, pos, pos)
                    if sc == "+" or sc == "-" then pos = pos + 1 end
                    while pos <= len and string.match(string.sub(line, pos, pos), "%d") do
                        pos = pos + 1
                    end
                end
            end
            tokens[#tokens + 1] = { kind = "number", text = string.sub(line, start, pos - 1) }
            continue
        end

        -- Identifier or keyword
        if string.match(char, "[%a_]") then
            local ident = string.match(line, "^[%a_][%w_]*", pos)
            if ident then
                local kind = KEYWORDS[ident] and "keyword" or "ident"
                -- Subtle: `function foo` — color "foo" as a function-name accent
                tokens[#tokens + 1] = { kind = kind, text = ident }
                pos = pos + #ident
                continue
            end
        end

        -- Goto label `::name::`
        if char == ":" and string.sub(line, pos, pos + 1) == "::" then
            local closeAt = string.find(line, "::", pos + 2, true)
            if closeAt then
                tokens[#tokens + 1] = { kind = "label", text = string.sub(line, pos, closeAt + 1) }
                pos = closeAt + 2
                continue
            end
        end

        -- Punctuation / operator fallback
        tokens[#tokens + 1] = { kind = "punct", text = char }
        pos = pos + 1
    end
    return tokens
end

-- ---------------------------------------------------------------------
-- RichText builder
-- ---------------------------------------------------------------------

local function color3Rgb(c)
    return string.format("rgb(%d,%d,%d)",
        math.floor(c.R * 255 + 0.5),
        math.floor(c.G * 255 + 0.5),
        math.floor(c.B * 255 + 0.5))
end

local function escapeRichText(text)
    text = string.gsub(text, "&", "&amp;")
    text = string.gsub(text, "<", "&lt;")
    text = string.gsub(text, ">", "&gt;")
    text = string.gsub(text, '"', "&quot;")
    return text
end

local function tokenColor(theme, kind)
    if kind == "keyword" then return theme:color("syntaxKeyword")
    elseif kind == "string"  then return theme:color("syntaxString")
    elseif kind == "number"  then return theme:color("syntaxNumber")
    elseif kind == "comment" then return theme:color("syntaxComment")
    elseif kind == "label"   then return theme:color("syntaxComment")
    elseif kind == "ident"   then return theme:color("text")
    elseif kind == "punct"   then return theme:color("textMuted")
    end
    return theme:color("text")
end

local function buildRichText(tokens, theme)
    local parts = {}
    for _, tk in tokens do
        if tk.kind == "ws" then
            parts[#parts + 1] = tk.text
        else
            local clr = tokenColor(theme, tk.kind)
            parts[#parts + 1] = string.format('<font color="%s">%s</font>',
                color3Rgb(clr), escapeRichText(tk.text))
        end
    end
    return table.concat(parts)
end

-- ---------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------

function PseudocodeView:init(props)
    self.state = {
        text   = nil,
        lines  = nil,
        tokens = nil,
        stats  = nil,
        err    = nil,
        debugName = nil,
    }
    self:_recompute(props)
end

function PseudocodeView:willUpdate(nextProps)
    if nextProps.decompiler ~= self.props.decompiler
        or nextProps.protoId ~= self.props.protoId then
        self:_recompute(nextProps)
    end
end

function PseudocodeView:_recompute(props)
    props = props or self.props
    if not props.decompiler or props.protoId == nil then
        self.state.text  = nil
        self.state.lines = {}
        self.state.tokens = {}
        self.state.stats = nil
        self.state.err   = nil
        return
    end
    local ok, payload = pcall(function()
        local text = props.decompiler:decompileToText(props.protoId)
        local result = props.decompiler:decompileProto(props.protoId)
        return { text = text, result = result }
    end)
    if not ok then
        self.state.err = tostring(payload)
        self.state.text = nil
        self.state.lines = {}
        self.state.tokens = {}
        return
    end
    self.state.err   = nil
    self.state.text  = payload.text
    self.state.lines = string.split(payload.text or "", "\n")
    self.state.stats = payload.result and payload.result.structured
        and payload.result.structured.stats
    self.state.debugName = payload.result and payload.result.lifted
        and payload.result.lifted.debugName
    -- Tokenize each line up-front (cheap; usually a few hundred lines max).
    self.state.tokens = {}
    for i, line in self.state.lines do
        self.state.tokens[i] = tokenizeLuauLine(line)
    end
end

-- ---------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------

function PseudocodeView:_renderHeader()
    local theme  = self.theme
    local name   = self.state.debugName or "anonymous"
    local stats  = self.state.stats or {}
    local pills = {
        { icon = "≣",  label = string.format("%d line%s",
            self.state.lines and #self.state.lines or 0,
            self.state.lines and #self.state.lines == 1 and "" or "s") },
    }
    if stats.ifCount and stats.ifCount > 0 then
        pills[#pills + 1] = { icon = "?", label = string.format("%d if", stats.ifCount) }
    end
    if stats.whileCount and stats.whileCount > 0 then
        pills[#pills + 1] = { icon = "↻", label = string.format("%d while", stats.whileCount) }
    end
    if stats.forNumCount and stats.forNumCount > 0 then
        pills[#pills + 1] = { icon = "Σ", label = string.format("%d for-n", stats.forNumCount) }
    end
    if stats.forGenCount and stats.forGenCount > 0 then
        pills[#pills + 1] = { icon = "→", label = string.format("%d for-in", stats.forGenCount) }
    end
    if stats.gotoCount and stats.gotoCount > 0 then
        pills[#pills + 1] = { icon = "⚠", label = string.format("%d goto", stats.gotoCount) }
    end

    local pillElements = {}
    for i, p in pills do
        pillElements[i] = e("Frame", {
            key              = "pill:" .. i,
            Size             = UDim2.fromOffset(72, HEADER_H - 12),
            BackgroundColor3 = theme:color("surface"),
            BorderSizePixel  = 0,
            LayoutOrder      = i + 1,
        }, {
            e("UICorner",  { CornerRadius = UDim.new(0, theme:radius("sm")) }),
            e("UIPadding", { PaddingLeft  = UDim.new(0, 6), PaddingRight = UDim.new(0, 6) }),
            e("TextLabel", {
                Text             = string.format("%s  %s", p.icon, p.label),
                Font             = Enum.Font.RobotoMono,
                TextSize         = theme:size("font.ui") - 2,
                TextColor3       = theme:color("textMuted"),
                TextXAlignment   = Enum.TextXAlignment.Left,
                BackgroundTransparency = 1,
                Size             = UDim2.fromScale(1, 1),
            }),
        })
    end

    return e("Frame", {
        key              = "header",
        Size             = UDim2.new(1, 0, 0, HEADER_H),
        BackgroundColor3 = theme:color("surfaceAlt"),
        BorderSizePixel  = 0,
    }, {
        e("UIPadding", {
            PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10),
            PaddingTop  = UDim.new(0, 6),  PaddingBottom = UDim.new(0, 6),
        }),
        e("UIListLayout", {
            FillDirection     = Enum.FillDirection.Horizontal,
            VerticalAlignment = Enum.VerticalAlignment.Center,
            SortOrder         = Enum.SortOrder.LayoutOrder,
            Padding           = UDim.new(0, 6),
        }),
        e("TextLabel", {
            key              = "name",
            LayoutOrder      = 1,
            Size             = UDim2.fromOffset(220, HEADER_H - 12),
            Text             = "ƒ " .. name,
            Font             = Enum.Font.RobotoMono,
            TextSize         = theme:size("font.ui"),
            TextColor3       = theme:color("syntaxKeyword"),
            TextXAlignment   = Enum.TextXAlignment.Left,
            TextTruncate     = Enum.TextTruncate.AtEnd,
            BackgroundTransparency = 1,
        }),
        Element.fragment(pillElements),
    })
end

function PseudocodeView:_renderRow(line, idx, isOdd)
    local theme    = self.theme
    local tokens   = self.state.tokens and self.state.tokens[idx] or {}
    local rich     = buildRichText(tokens, theme)
    local selected = self.props.selectedLine == idx
    local bg
    if selected then bg = theme:color("primaryMuted")
    elseif isOdd  then bg = theme:color("disassemblyRowOdd")
    else                bg = theme:color("disassemblyRowEven") end

    return e("TextButton", {
        Size             = UDim2.new(1, 0, 1, 0),
        Text             = "",
        AutoButtonColor  = false,
        BackgroundColor3 = bg,
        BorderSizePixel  = 0,
        [Event.Activated] = function()
            if self.props.onSelectLine then
                pcall(self.props.onSelectLine, idx, line)
            end
        end,
        [Event.MouseEnter] = function(inst)
            if not selected then
                pcall(function() inst.BackgroundColor3 = theme:color("surfaceHover") end)
            end
        end,
        [Event.MouseLeave] = function(inst)
            if not selected then
                pcall(function() inst.BackgroundColor3 = bg end)
            end
        end,
    }, {
        -- Line-number gutter
        e("TextLabel", {
            key              = "ln",
            Position         = UDim2.fromOffset(0, 0),
            Size             = UDim2.fromOffset(GUTTER_W - 4, ROW_HEIGHT),
            Text             = tostring(idx),
            Font             = Enum.Font.RobotoMono,
            TextSize         = theme:size("font.mono") - 1,
            TextColor3       = theme:color("disassemblyAddr"),
            TextXAlignment   = Enum.TextXAlignment.Right,
            BackgroundTransparency = 1,
        }),
        -- Gutter separator
        e("Frame", {
            key              = "sep",
            Position         = UDim2.fromOffset(GUTTER_W - 1, 0),
            Size             = UDim2.fromOffset(1, ROW_HEIGHT),
            BackgroundColor3 = theme:color("border"),
            BorderSizePixel  = 0,
        }),
        -- Rich-text code
        e("TextLabel", {
            key              = "code",
            Position         = UDim2.fromOffset(GUTTER_W + 6, 0),
            Size             = UDim2.new(1, -(GUTTER_W + 12), 1, 0),
            Text             = rich,
            RichText         = true,
            Font             = Enum.Font.RobotoMono,
            TextSize         = theme:size("font.mono"),
            TextColor3       = theme:color("text"),
            TextXAlignment   = Enum.TextXAlignment.Left,
            TextTruncate     = Enum.TextTruncate.AtEnd,
            BackgroundTransparency = 1,
        }),
    })
end

function PseudocodeView:_renderFooter()
    local theme = self.theme
    local n = self.state.lines and #self.state.lines or 0
    local stats = self.state.stats or {}
    local constructs = (stats.ifCount or 0) + (stats.whileCount or 0)
        + (stats.forNumCount or 0) + (stats.forGenCount or 0)
        + (stats.repeatCount or 0)
    return e("Frame", {
        key              = "footer",
        Size             = UDim2.new(1, 0, 0, FOOTER_H),
        Position         = UDim2.new(0, 0, 1, -FOOTER_H),
        BackgroundColor3 = theme:color("surfaceAlt"),
        BorderSizePixel  = 0,
    }, {
        e("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) }),
        e("TextLabel", {
            Text                  = string.format("%d lines · %d structured construct%s recovered",
                n, constructs, constructs == 1 and "" or "s"),
            Font                  = Enum.Font.Gotham,
            TextSize              = theme:size("font.ui") - 2,
            TextColor3            = theme:color("textMuted"),
            TextXAlignment        = Enum.TextXAlignment.Left,
            BackgroundTransparency = 1,
            Size                  = UDim2.fromScale(1, 1),
        }),
    })
end

function PseudocodeView:render()
    local theme = self.theme

    if self.state.err then
        return e("Frame", {
            Size             = self.props.Size,
            Position         = self.props.Position,
            BackgroundColor3 = theme:color("background"),
            BorderSizePixel  = 0,
        }, {
            e("TextLabel", {
                Size             = UDim2.fromScale(1, 1),
                Text             = "decompiler error:\n" .. self.state.err,
                Font             = Enum.Font.RobotoMono,
                TextSize         = theme:size("font.ui"),
                TextColor3       = theme:color("danger"),
                BackgroundTransparency = 1,
                TextWrapped      = true,
            }),
        })
    end

    if not self.state.text then
        return e("Frame", {
            Size             = self.props.Size,
            Position         = self.props.Position,
            BackgroundColor3 = theme:color("background"),
            BorderSizePixel  = 0,
        }, {
            e("TextLabel", {
                Size             = UDim2.fromScale(1, 1),
                Text             = "no proto selected — open one from the Functions tree",
                Font             = Enum.Font.Gotham,
                TextSize         = theme:size("font.ui"),
                TextColor3       = theme:color("textMuted"),
                BackgroundTransparency = 1,
            }),
        })
    end

    local rows = self.state.lines or {}
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
            overscan       = 16,
            renderItem     = function(item, idx, isOdd) return self:_renderRow(item, idx, isOdd) end,
        }),
        self:_renderFooter(),
    })
end

return PseudocodeView
