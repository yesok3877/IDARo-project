-- UI/Widgets/Dialog.luau
-- A generic modal dialog widget. Renders a full-screen overlay that
-- darkens the background, a centered panel with a title, a label,
-- a text input, and OK / Cancel buttons. Used by Workspace for
-- prompts like "Goto Proto", "Rename Symbol", etc.
--
-- Props:
--   title       — string         (header text)
--   label       — string         (caption above the input box)
--   placeholder — string         (placeholder text for the input)
--   initialText — string         (initial value for the input)
--   onSubmit    — fn(text)       (called when user presses Enter / clicks OK)
--   onCancel    — fn()           (called when user presses Escape / clicks Cancel / clicks overlay)
--   submitLabel — string         (defaults to "OK")
--   cancelLabel — string         (defaults to "Cancel")
--
-- The dialog mounts an Active overlay that captures all clicks outside the
-- panel so users can't interact with anything else. Pressing Escape or
-- clicking the overlay fires onCancel. Pressing Enter while focused on
-- the input fires onSubmit with the current text.

local Component = _G.IDARo.require("UI.Framework.Component")
local Element   = _G.IDARo.require("UI.Framework.Element")
local e         = Element.create
local Event     = Element.Event
local Changed   = Element.Changed

local Dialog = Component.extend("Dialog")

local PANEL_W = 420
local PANEL_H = 168
local PADDING = 16

function Dialog:init(props)
    self.state = {
        text = props.initialText or "",
    }
end

function Dialog:didMount()
    -- Focus the input on next frame (must be deferred so Roblox has
    -- the instance attached). Best-effort — failure is silent.
    task.defer(function()
        if self._inputRef and self._inputRef:IsA("TextBox") then
            pcall(function() self._inputRef:CaptureFocus() end)
        end
    end)
end

function Dialog:_submit()
    local txt = self.state.text or ""
    if self.props.onSubmit then
        local ok, err = pcall(self.props.onSubmit, txt)
        if not ok and self.logger then
            self.logger:warn("Dialog onSubmit threw: %s", tostring(err))
        end
    end
end

function Dialog:_cancel()
    if self.props.onCancel then
        local ok, err = pcall(self.props.onCancel)
        if not ok and self.logger then
            self.logger:warn("Dialog onCancel threw: %s", tostring(err))
        end
    end
end

function Dialog:render()
    local theme = self.theme
    local submitLabel = self.props.submitLabel or "OK"
    local cancelLabel = self.props.cancelLabel or "Cancel"

    return e("Frame", {
        Name = "DialogOverlay",
        Size = UDim2.fromScale(1, 1),
        Position = UDim2.fromScale(0, 0),
        BackgroundColor3 = Color3.fromRGB(0, 0, 0),
        BackgroundTransparency = 0.55,
        BorderSizePixel = 0,
        ZIndex = 100,
        Active = true,
    }, {
        -- Click-outside-to-cancel catcher (sized as the full overlay)
        e("TextButton", {
            key = "overlay-catcher",
            Size = UDim2.fromScale(1, 1),
            BackgroundTransparency = 1,
            Text = "",
            AutoButtonColor = false,
            ZIndex = 100,
            [Event.Activated] = function() self:_cancel() end,
        }),
        -- Centered panel
        e("Frame", {
            key = "panel",
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.fromScale(0.5, 0.5),
            Size = UDim2.fromOffset(PANEL_W, PANEL_H),
            BackgroundColor3 = theme:color("surface"),
            BorderSizePixel = 0,
            ZIndex = 101,
        }, {
            e("UICorner", { CornerRadius = UDim.new(0, theme:radius("md")) }),
            e("UIStroke", { Color = theme:color("border"), Thickness = 1 }),
            -- Title bar
            e("TextLabel", {
                key = "title",
                Position = UDim2.fromOffset(PADDING, 12),
                Size = UDim2.new(1, -PADDING * 2, 0, 22),
                BackgroundTransparency = 1,
                Text = self.props.title or "Dialog",
                TextColor3 = theme:color("text"),
                TextSize = 16,
                Font = Enum.Font.GothamBold,
                TextXAlignment = Enum.TextXAlignment.Left,
                ZIndex = 102,
            }),
            -- Label
            e("TextLabel", {
                key = "label",
                Position = UDim2.fromOffset(PADDING, 44),
                Size = UDim2.new(1, -PADDING * 2, 0, 16),
                BackgroundTransparency = 1,
                Text = self.props.label or "",
                TextColor3 = theme:color("textMuted"),
                TextSize = 12,
                Font = Enum.Font.Gotham,
                TextXAlignment = Enum.TextXAlignment.Left,
                ZIndex = 102,
            }),
            -- Input box
            e("TextBox", {
                key = "input",
                Position = UDim2.fromOffset(PADDING, 64),
                Size = UDim2.new(1, -PADDING * 2, 0, 28),
                BackgroundColor3 = theme:color("backgroundAlt"),
                BorderSizePixel = 0,
                Text = self.state.text,
                PlaceholderText = self.props.placeholder or "",
                TextColor3 = theme:color("text"),
                PlaceholderColor3 = theme:color("textSubtle"),
                TextSize = 13,
                Font = Enum.Font.Code,
                TextXAlignment = Enum.TextXAlignment.Left,
                ClearTextOnFocus = false,
                ZIndex = 102,
                [Element.Ref] = function(inst) self._inputRef = inst end,
                [Changed.Text] = function(rbx)
                    if rbx.Text == self.state.text then return end
                    self:setState({ text = rbx.Text })
                end,
                [Event.FocusLost] = function(rbx, enterPressed)
                    if enterPressed then self:_submit() end
                end,
            }, {
                e("UICorner", { CornerRadius = UDim.new(0, 4) }),
                e("UIStroke", { Color = theme:color("border"), Thickness = 1 }),
                e("UIPadding", {
                    PaddingLeft = UDim.new(0, 8),
                    PaddingRight = UDim.new(0, 8),
                }),
            }),
            -- Cancel button
            e("TextButton", {
                key = "cancel",
                AnchorPoint = Vector2.new(1, 1),
                Position = UDim2.new(1, -(PADDING + 84 + 8), 1, -PADDING),
                Size = UDim2.fromOffset(80, 28),
                BackgroundColor3 = theme:color("background"),
                BorderSizePixel = 0,
                Text = cancelLabel,
                TextColor3 = theme:color("text"),
                TextSize = 13,
                Font = Enum.Font.Gotham,
                AutoButtonColor = false,
                ZIndex = 102,
                [Event.Activated] = function() self:_cancel() end,
                [Event.MouseEnter] = function(btn)
                    btn.BackgroundColor3 = theme:color("surfaceHover")
                end,
                [Event.MouseLeave] = function(btn)
                    btn.BackgroundColor3 = theme:color("background")
                end,
            }, {
                e("UICorner", { CornerRadius = UDim.new(0, 4) }),
                e("UIStroke", { Color = theme:color("border"), Thickness = 1 }),
            }),
            -- Submit button (primary)
            e("TextButton", {
                key = "submit",
                AnchorPoint = Vector2.new(1, 1),
                Position = UDim2.new(1, -PADDING, 1, -PADDING),
                Size = UDim2.fromOffset(80, 28),
                BackgroundColor3 = theme:color("primary"),
                BorderSizePixel = 0,
                Text = submitLabel,
                TextColor3 = theme:color("textOnPrimary"),
                TextSize = 13,
                Font = Enum.Font.GothamBold,
                AutoButtonColor = false,
                ZIndex = 102,
                [Event.Activated] = function() self:_submit() end,
                [Event.MouseEnter] = function(btn)
                    btn.BackgroundColor3 = theme:color("primaryHover")
                end,
                [Event.MouseLeave] = function(btn)
                    btn.BackgroundColor3 = theme:color("primary")
                end,
            }, {
                e("UICorner", { CornerRadius = UDim.new(0, 4) }),
            }),
        }),
    })
end

return Dialog
