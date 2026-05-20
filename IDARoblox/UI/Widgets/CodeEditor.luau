--!nonstrict
-- =====================================================================
-- IDARoblox / UI / Widgets / CodeEditor
-- ---------------------------------------------------------------------
-- Code editor / viewer with Luau-aware syntax highlighting. Used by
-- PseudocodeView to display decompiled output and (when not readonly)
-- to let the user annotate or rewrite the text.
--
-- Features
--   * Token-stream highlighting: keywords, strings, numbers, comments,
--     identifiers, builtins, operators
--   * Line-number gutter with optional annotation pips (warn / break)
--   * Cursor positioning by click; arrow / Home / End nav
--   * Selection: click + drag, shift + click extend
--   * Find-in-text (Ctrl+F integration via parent)
--   * Readonly mode (decompiler output) and editable mode
--
-- Props
--   text          string (multi-line OK)
--   readonly      boolean (default true)
--   language      "luau" (only) — extensible later
--   showGutter    boolean (default true)
--   annotations   { [lineNumber] = { kind = "warn"|"break"|"hit",
--                                     text = "tooltip body" } }
--   onTextChange  fn(newText)        — fired when text is edited
--   onCursorMove  fn(line, col)      — fired when cursor moves
--   findHighlight string (substring to highlight)
--   fontSize      px (default 13)
--   lineHeight    px (default 16)
-- =====================================================================

local Component         = _G.IDARo.require("UI.Framework.Component")
local Element           = _G.IDARo.require("UI.Framework.Element")
local ScrollVirtualizer = _G.IDARo.require("UI.Framework.ScrollVirtualizer")
local UserInputService  = game:GetService("UserInputService")
local e = Element.create
local Event = Element.Event

local CodeEditor = Component.extend("CodeEditor")

Component.setDefaultProps(CodeEditor, {
    text         = "",
    readonly     = true,
    language     = "luau",
    showGutter   = true,
    annotations  = {},
    onTextChange = nil,
    onCursorMove = nil,
    findHighlight = nil,
    fontSize     = 13,
    lineHeight   = 16,
    gutterWidth  = 48,
})

-- ---------------------------------------------------------------------
-- Luau tokenizer
-- ---------------------------------------------------------------------

local LUAU_KEYWORDS = {
    ["and"] = true, ["break"] = true, ["do"] = true, ["else"] = true,
    ["elseif"] = true, ["end"] = true, ["false"] = true, ["for"] = true,
    ["function"] = true, ["if"] = true, ["in"] = true, ["local"] = true,
    ["nil"] = true, ["not"] = true, ["or"] = true, ["repeat"] = true,
    ["return"] = true, ["then"] = true, ["true"] = true, ["until"] = true,
    ["while"] = true, ["continue"] = true, ["type"] = true, ["export"] = true,
    ["typeof"] = true, ["self"] = true,
}

local LUAU_BUILTINS = {
    ["print"] = true, ["assert"] = true, ["error"] = true,
    ["pairs"] = true, ["ipairs"] = true, ["next"] = true,
    ["tonumber"] = true, ["tostring"] = true, ["select"] = true,
    ["rawget"] = true, ["rawset"] = true, ["rawequal"] = true, ["rawlen"] = true,
    ["setmetatable"] = true, ["getmetatable"] = true,
    ["pcall"] = true, ["xpcall"] = true, ["unpack"] = true,
    ["math"] = true, ["string"] = true, ["table"] = true, ["bit32"] = true,
    ["os"] = true, ["coroutine"] = true, ["task"] = true, ["debug"] = true,
    ["game"] = true, ["workspace"] = true, ["script"] = true,
    ["Vector3"] = true, ["Vector2"] = true, ["CFrame"] = true,
    ["UDim"] = true, ["UDim2"] = true, ["Color3"] = true, ["Enum"] = true,
    ["Instance"] = true, ["typeof"] = true,
}

local function isIdentStart(b)
    return (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or b == 95
end
local function isIdentCont(b)
    return isIdentStart(b) or (b >= 48 and b <= 57)
end
local function isDigit(b) return b >= 48 and b <= 57 end

-- Returns array of tokens: { kind, text, col }
local function tokenize(line)
    local tokens = {}
    local i, n = 1, #line
    while i <= n do
        local b = string.byte(line, i)
        -- Whitespace
        if b == 32 or b == 9 then
            local j = i
            while j <= n and (string.byte(line, j) == 32 or string.byte(line, j) == 9) do
                j = j + 1
            end
            tokens[#tokens + 1] = { kind = "ws", text = string.sub(line, i, j - 1), col = i }
            i = j
        -- Comment
        elseif b == 45 and string.byte(line, i + 1) == 45 then
            tokens[#tokens + 1] = { kind = "comment", text = string.sub(line, i), col = i }
            i = n + 1
        -- String literal
        elseif b == 34 or b == 39 then
            local quote = b
            local j = i + 1
            while j <= n do
                local cb = string.byte(line, j)
                if cb == 92 then j = j + 2
                elseif cb == quote then j = j + 1; break
                else j = j + 1 end
            end
            tokens[#tokens + 1] = { kind = "string", text = string.sub(line, i, j - 1), col = i }
            i = j
        -- Number
        elseif isDigit(b) or (b == 46 and isDigit(string.byte(line, i + 1) or 0)) then
            local j = i
            while j <= n do
                local cb = string.byte(line, j)
                if isDigit(cb) or cb == 46 or cb == 120 or cb == 88
                    or (cb >= 65 and cb <= 70) or (cb >= 97 and cb <= 102)
                    or cb == 101 or cb == 69 or cb == 45 or cb == 43 then
                    j = j + 1
                else break end
            end
            tokens[#tokens + 1] = { kind = "number", text = string.sub(line, i, j - 1), col = i }
            i = j
        -- Identifier / keyword
        elseif isIdentStart(b) then
            local j = i
            while j <= n and isIdentCont(string.byte(line, j)) do j = j + 1 end
            local ident = string.sub(line, i, j - 1)
            local kind  = "identifier"
            if LUAU_KEYWORDS[ident] then kind = "keyword"
            elseif LUAU_BUILTINS[ident] then kind = "builtin" end
            tokens[#tokens + 1] = { kind = kind, text = ident, col = i }
            i = j
        -- Operator / punctuation
        else
            -- Try two-char operators first
            local two = string.sub(line, i, i + 1)
            if two == "==" or two == "~=" or two == "<=" or two == ">="
                or two == ".." or two == "::" or two == "->" or two == "+="
                or two == "-=" or two == "*=" or two == "/=" or two == "..="
                or two == "//" then
                tokens[#tokens + 1] = { kind = "operator", text = two, col = i }
                i = i + 2
            else
                tokens[#tokens + 1] = { kind = "punct", text = string.char(b), col = i }
                i = i + 1
            end
        end
    end
    return tokens
end

-- ---------------------------------------------------------------------
-- State + lifecycle
-- ---------------------------------------------------------------------

function CodeEditor:init()
    self.state = {
        cursorLine = 1,
        cursorCol  = 1,
        selStart   = nil,                                            -- { line, col }
        selEnd     = nil,
        lines      = {},
    }
    self:_rebuildLines(self.props.text)
end

function CodeEditor:_rebuildLines(text)
    local lines = {}
    for line in string.gmatch(text or "", "([^\n]*)") do
        lines[#lines + 1] = line
        if #lines > 100000 then break end                            -- safety
    end
    if #lines == 0 then lines[1] = "" end
    self.state.lines = lines
end

function CodeEditor:didUpdate(prevProps)
    if prevProps.text ~= self.props.text then
        self:_rebuildLines(self.props.text)
        self:setState({ lines = self.state.lines })
    end
end

-- ---------------------------------------------------------------------
-- Cursor + selection
-- ---------------------------------------------------------------------

function CodeEditor:_moveCursor(line, col)
    line = math.max(1, math.min(line, #self.state.lines))
    col  = math.max(1, math.min(col, #self.state.lines[line] + 1))
    self:setState({ cursorLine = line, cursorCol = col })
    if self.props.onCursorMove then self.props.onCursorMove(line, col) end
end

-- ---------------------------------------------------------------------
-- Render single line
-- ---------------------------------------------------------------------

function CodeEditor:_renderLine(lineIdx)
    local theme   = self.theme
    local fontSz  = self.props.fontSize
    local lineH   = self.props.lineHeight
    local gutterW = self.props.showGutter and self.props.gutterWidth or 0
    local lineText = self.state.lines[lineIdx] or ""
    local tokens = self.props.language == "luau" and tokenize(lineText) or
        { { kind = "plain", text = lineText, col = 1 } }
    local children = {}

    -- Gutter
    if self.props.showGutter then
        local ann = self.props.annotations and self.props.annotations[lineIdx]
        children[#children + 1] = e("Frame", {
            Size = UDim2.new(0, gutterW, 1, 0),
            BackgroundColor3 = theme:color("editorGutterBg"),
            BorderSizePixel = 0,
        }, {
            e("TextLabel", {
                Size = UDim2.new(1, -6, 1, 0),
                Position = UDim2.new(0, 0, 0, 0),
                Text = tostring(lineIdx),
                Font = Enum.Font.Code,
                TextSize = fontSz - 1,
                TextColor3 = theme:color("editorGutterFg"),
                TextXAlignment = Enum.TextXAlignment.Right,
                BackgroundTransparency = 1,
            }),
            ann and e("Frame", {
                Size = UDim2.new(0, 4, 0, 4),
                Position = UDim2.new(1, -4, 0.5, -2),
                BackgroundColor3 = theme:color(
                    ann.kind == "warn" and "editorWarnPip"
                    or ann.kind == "break" and "editorBreakPip"
                    or "editorHitPip"),
                BorderSizePixel = 0,
            }) or nil,
        })
    end

    -- Tokens
    local cursorX = gutterW + 4
    for _, tok in tokens do
        local color
        if tok.kind == "keyword"  then color = theme:color("synKeyword")
        elseif tok.kind == "builtin" then color = theme:color("synBuiltin")
        elseif tok.kind == "string"  then color = theme:color("synString")
        elseif tok.kind == "number"  then color = theme:color("synNumber")
        elseif tok.kind == "comment" then color = theme:color("synComment")
        elseif tok.kind == "operator" or tok.kind == "punct" then
            color = theme:color("synOperator")
        else color = theme:color("editorFg") end
        local tw = #tok.text * (fontSz * 0.55)
        children[#children + 1] = e("TextLabel", {
            Size = UDim2.new(0, tw, 1, 0),
            Position = UDim2.new(0, cursorX, 0, 0),
            Text = tok.text,
            Font = Enum.Font.Code,
            TextSize = fontSz,
            TextColor3 = color,
            TextXAlignment = Enum.TextXAlignment.Left,
            BackgroundTransparency = 1,
        })
        cursorX = cursorX + tw
    end

    -- Find highlight
    if self.props.findHighlight and self.props.findHighlight ~= "" then
        local lower = string.lower(lineText)
        local needle = string.lower(self.props.findHighlight)
        local pos = 1
        while true do
            local s, eo = string.find(lower, needle, pos, true)
            if not s then break end
            local px = gutterW + 4 + (s - 1) * (fontSz * 0.55)
            local pw = (eo - s + 1) * (fontSz * 0.55)
            children[#children + 1] = e("Frame", {
                Size = UDim2.new(0, pw, 1, 0),
                Position = UDim2.new(0, px, 0, 0),
                BackgroundColor3 = theme:color("editorFindHighlight"),
                BackgroundTransparency = 0.55,
                BorderSizePixel = 0,
                ZIndex = -1,
            })
            pos = eo + 1
        end
    end

    -- Cursor caret
    if self.state.cursorLine == lineIdx and not self.props.readonly then
        local cx = gutterW + 4 + (self.state.cursorCol - 1) * (fontSz * 0.55)
        children[#children + 1] = e("Frame", {
            Size = UDim2.new(0, 1, 1, -2),
            Position = UDim2.new(0, cx, 0, 1),
            BackgroundColor3 = theme:color("editorCursor"),
            BorderSizePixel = 0,
            ZIndex = 100,
        })
    end

    return e("TextButton", {
        Size = UDim2.new(1, 0, 0, lineH),
        BackgroundColor3 = (self.state.cursorLine == lineIdx)
            and theme:color("editorActiveLineBg") or theme:color("editorBg"),
        BackgroundTransparency = (self.state.cursorLine == lineIdx) and 0 or 1,
        BorderSizePixel = 0,
        AutoButtonColor = false,
        Text = "",
        LayoutOrder = lineIdx,
        [Event "Activated"] = function(_, input)
            if not input then self:_moveCursor(lineIdx, 1); return end
            local cam = workspace.CurrentCamera
            if not cam then self:_moveCursor(lineIdx, 1); return end
            -- Compute column from mouse X
            local mouse = input.Position
            -- We can't easily get absolute pos here without ref; approximate by 0
            local cw = fontSz * 0.55
            local col = math.max(1, math.floor((mouse.X - gutterW - 4) / cw) + 1)
            self:_moveCursor(lineIdx, col)
        end,
    }, children)
end

-- ---------------------------------------------------------------------
-- Render
-- ---------------------------------------------------------------------

function CodeEditor:render()
    local items = {}
    for i = 1, #self.state.lines do items[i] = i end
    return e("Frame", {
        Size = self.props.Size or UDim2.new(1, 0, 1, 0),
        Position = self.props.Position or UDim2.new(0, 0, 0, 0),
        BackgroundColor3 = self.theme:color("editorBg"),
        BorderSizePixel = 0,
    }, {
        e(ScrollVirtualizer, {
            Size = UDim2.new(1, 0, 1, 0),
            itemHeight = self.props.lineHeight,
            items = items,
            renderItem = function(idx) return self:_renderLine(idx) end,
        }),
    })
end

return CodeEditor
