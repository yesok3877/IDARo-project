--!nonstrict
-- =====================================================================
-- IDARoblox / UI / Framework / Camera
-- ---------------------------------------------------------------------
-- 2D pan/zoom transform.
--
--   screen = world * zoom + pan
--   world  = (screen - pan) / zoom
--
-- Usage pattern (typical for a graph or hex view):
--
--   local cam = Camera.new({ minZoom = 0.1, maxZoom = 4 })
--   cam:onChange(function() rerender() end)
--   cam:pan(deltaPixels)                          -- during a mouse drag
--   cam:zoomAtScreen(1.1, mouseScreenPos)         -- on wheel-up
--   cam:fitBounds(min, max, viewportSize, padPx)  -- on "fit to view"
--
-- The transform is held in plain numbers (panX, panY, zoom). Callers
-- read them via getters or use camera:worldToScreen / screenToWorld.
-- Observers subscribe with :onChange(fn) and disconnect via the
-- returned handle.
--
-- The camera also exposes inertia tracking: each `pan()` call records
-- a velocity sample, and `applyInertia(dt)` decays + applies the
-- velocity — useful for flicked panning if the host wants it.
-- =====================================================================

local Camera = {}
Camera.__index = Camera

local DEFAULTS = {
    minZoom        = 0.10,
    maxZoom        = 4.0,
    zoomSmoothing  = 0.0,                                            -- 0 = instant, 1 = no movement
    inertiaDecay   = 6.0,                                            -- per-second exponential decay
    flickThreshold = 8.0,
}

-- ---------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------

function Camera.new(opts)
    opts = opts or {}
    local self = setmetatable({
        _panX           = opts.panX or 0,
        _panY           = opts.panY or 0,
        _zoom           = opts.zoom or 1.0,
        _minZoom        = opts.minZoom or DEFAULTS.minZoom,
        _maxZoom        = opts.maxZoom or DEFAULTS.maxZoom,
        _zoomSmoothing  = opts.zoomSmoothing or DEFAULTS.zoomSmoothing,
        _inertiaDecay   = opts.inertiaDecay or DEFAULTS.inertiaDecay,
        _flickThreshold = opts.flickThreshold or DEFAULTS.flickThreshold,
        _velX           = 0,
        _velY           = 0,
        _lastPanAt      = 0,
        _listeners      = {},
    }, Camera)
    return self
end

-- ---------------------------------------------------------------------
-- State accessors
-- ---------------------------------------------------------------------

function Camera:pan_x() return self._panX end
function Camera:pan_y() return self._panY end
function Camera:zoom() return self._zoom end
function Camera:state()
    return {
        panX  = self._panX,
        panY  = self._panY,
        zoom  = self._zoom,
        velX  = self._velX,
        velY  = self._velY,
    }
end

-- ---------------------------------------------------------------------
-- Projection
-- ---------------------------------------------------------------------

function Camera:worldToScreen(x: number, y: number): (number, number)
    return x * self._zoom + self._panX, y * self._zoom + self._panY
end

function Camera:screenToWorld(x: number, y: number): (number, number)
    return (x - self._panX) / self._zoom, (y - self._panY) / self._zoom
end

function Camera:worldToScreenVec(v: Vector2): Vector2
    return Vector2.new(v.X * self._zoom + self._panX, v.Y * self._zoom + self._panY)
end

function Camera:screenToWorldVec(v: Vector2): Vector2
    return Vector2.new((v.X - self._panX) / self._zoom, (v.Y - self._panY) / self._zoom)
end

-- ---------------------------------------------------------------------
-- Mutators
-- ---------------------------------------------------------------------

local function clampZoom(self, z)
    if z < self._minZoom then return self._minZoom end
    if z > self._maxZoom then return self._maxZoom end
    return z
end

function Camera:setPan(x: number, y: number)
    if x == self._panX and y == self._panY then return end
    self._panX = x
    self._panY = y
    self:_notify()
end

function Camera:pan(dx: number, dy: number)
    if dx == 0 and dy == 0 then return end
    self._panX += dx
    self._panY += dy
    -- Update velocity sample for optional inertia.
    local now = os.clock()
    local dt  = math.max(1e-3, now - (self._lastPanAt or now))
    self._velX = dx / dt
    self._velY = dy / dt
    self._lastPanAt = now
    self:_notify()
end

function Camera:setZoom(z: number)
    z = clampZoom(self, z)
    if z == self._zoom then return end
    self._zoom = z
    self:_notify()
end

function Camera:zoomBy(factor: number)
    self:setZoom(self._zoom * factor)
end

-- Zoom while keeping `anchorScreen` glued to its current world point.
-- This is the standard "zoom toward the cursor" behaviour.
function Camera:zoomAtScreen(factor: number, anchorScreenX: number, anchorScreenY: number)
    local oldZoom = self._zoom
    local newZoom = clampZoom(self, oldZoom * factor)
    if newZoom == oldZoom then return end
    -- World point under the anchor at the OLD zoom:
    local wx = (anchorScreenX - self._panX) / oldZoom
    local wy = (anchorScreenY - self._panY) / oldZoom
    -- New pan so the same world point lands under the same screen point:
    self._panX = anchorScreenX - wx * newZoom
    self._panY = anchorScreenY - wy * newZoom
    self._zoom = newZoom
    self:_notify()
end

-- ---------------------------------------------------------------------
-- Fitting and resetting
-- ---------------------------------------------------------------------

function Camera:reset(zoom: number?)
    self._panX = 0
    self._panY = 0
    self._zoom = zoom or 1.0
    self._velX = 0
    self._velY = 0
    self:_notify()
end

-- Fit a world AABB (minX/minY → maxX/maxY) into a viewport of given
-- size, with `pad` pixels of padding on each side. Used by "Reset View"
-- / "Fit to Screen" / "Center Selection".
function Camera:fitBounds(minX: number, minY: number,
                          maxX: number, maxY: number,
                          viewportW: number, viewportH: number,
                          pad: number?)
    pad = pad or 24
    local worldW = math.max(1, maxX - minX)
    local worldH = math.max(1, maxY - minY)
    local availW = math.max(1, viewportW - pad * 2)
    local availH = math.max(1, viewportH - pad * 2)
    local zoom = math.min(availW / worldW, availH / worldH)
    zoom = clampZoom(self, zoom)
    self._zoom = zoom
    -- Center the bounding box in the viewport:
    local worldCx = (minX + maxX) * 0.5
    local worldCy = (minY + maxY) * 0.5
    local viewCx  = viewportW * 0.5
    local viewCy  = viewportH * 0.5
    self._panX = viewCx - worldCx * zoom
    self._panY = viewCy - worldCy * zoom
    self._velX = 0
    self._velY = 0
    self:_notify()
end

-- Center the camera on a world point without changing zoom.
function Camera:centerOn(worldX: number, worldY: number,
                        viewportW: number, viewportH: number)
    self._panX = viewportW * 0.5 - worldX * self._zoom
    self._panY = viewportH * 0.5 - worldY * self._zoom
    self:_notify()
end

-- ---------------------------------------------------------------------
-- Inertia
-- ---------------------------------------------------------------------

function Camera:beginFlick()
    self._velX = 0
    self._velY = 0
end

function Camera:endFlick()
    -- Cap to flickThreshold so very slow pans don't slide.
    if math.abs(self._velX) < self._flickThreshold then self._velX = 0 end
    if math.abs(self._velY) < self._flickThreshold then self._velY = 0 end
end

function Camera:applyInertia(dt: number): boolean
    if self._velX == 0 and self._velY == 0 then return false end
    local decay = math.exp(-self._inertiaDecay * dt)
    local dx = self._velX * dt
    local dy = self._velY * dt
    self._panX += dx
    self._panY += dy
    self._velX *= decay
    self._velY *= decay
    if math.abs(self._velX) < 0.5 and math.abs(self._velY) < 0.5 then
        self._velX = 0
        self._velY = 0
    end
    self:_notify()
    return true
end

-- ---------------------------------------------------------------------
-- Observers
-- ---------------------------------------------------------------------

function Camera:onChange(fn): { disconnect: () -> () }
    table.insert(self._listeners, fn)
    return {
        disconnect = function()
            for i, f in self._listeners do
                if f == fn then table.remove(self._listeners, i); return end
            end
        end,
    }
end

function Camera:_notify()
    for _, fn in self._listeners do
        local ok, err = pcall(fn, self)
        if not ok then
            -- Silently swallow; the camera shouldn't crash because a
            -- subscriber misbehaved.
        end
    end
end

return Camera
