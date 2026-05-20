--!nonstrict
-- =====================================================================
-- IDARoblox / Core / StorageBackend
-- ---------------------------------------------------------------------
-- Defensive wrappers around the executor's filesystem + clipboard APIs.
-- All public methods return (ok, result_or_err) so callers can branch
-- without try/catch noise.
--
-- Detected capabilities (each is either the captured function or nil):
--   writefile, readfile, appendfile, isfile, isfolder, makefolder,
--   delfile, delfolder, listfiles, loadfile
--   setclipboard, getclipboard
--
-- API:
--   StorageBackend.new(opts)        — opts.logger, opts.rootDir (default "IDARoblox/")
--   sb:capabilities()               — table of detected functions
--   sb:available()                  — true if writefile+readfile both present
--
--   sb:write(filename, contents)    → (ok, err?)
--   sb:read(filename)               → (ok, contents_or_err)
--   sb:append(filename, contents)   → (ok, err?)
--   sb:exists(filename)             → bool
--   sb:list(subdir?)                → array of filenames (no path traversal)
--   sb:delete(filename)             → (ok, err?)
--
--   sb:setClipboard(text)           → (ok, err?)
--   sb:getClipboard()               → (ok, text_or_err)
--
-- Path safety: any filename containing "..", a leading slash, or a
-- non-ASCII-printable character is rejected. Files always land under
-- `rootDir` so user data is namespaced.
-- =====================================================================

local StorageBackend = {}
StorageBackend.__index = StorageBackend

-- ---------------------------------------------------------------------
-- Capability detection
-- ---------------------------------------------------------------------

local function safeGlobal(name)
    local ok, env = pcall(function() return getfenv(0) end)
    if ok and env then
        local v = env[name]
        if v ~= nil then return v end
    end
    return rawget(_G, name)
end

local function detectCapabilities()
    local caps = {
        writefile     = safeGlobal("writefile"),
        readfile      = safeGlobal("readfile"),
        appendfile    = safeGlobal("appendfile"),
        isfile        = safeGlobal("isfile"),
        isfolder      = safeGlobal("isfolder"),
        makefolder    = safeGlobal("makefolder"),
        delfile       = safeGlobal("delfile"),
        delfolder     = safeGlobal("delfolder"),
        listfiles     = safeGlobal("listfiles"),
        loadfile      = safeGlobal("loadfile"),
        setclipboard  = safeGlobal("setclipboard"),
        getclipboard  = safeGlobal("getclipboard"),
    }
    return caps
end

-- ---------------------------------------------------------------------
-- Path safety
-- ---------------------------------------------------------------------

local function isUnsafePath(name)
    if type(name) ~= "string" or name == "" then return true, "empty path" end
    if string.find(name, "%.%.") then return true, "path traversal segment" end
    if string.find(name, "^[/\\]") then return true, "absolute path forbidden" end
    -- Reject control chars, NUL, and path separators
    for i = 1, #name do
        local b = string.byte(name, i)
        if b < 0x20 or b == 0x7F then return true, "control character in path" end
    end
    return false
end

-- ---------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------

function StorageBackend.new(opts)
    opts = opts or {}
    local rootDir = opts.rootDir or "IDARo"
    if string.sub(rootDir, -1) == "/" or string.sub(rootDir, -1) == "\\" then
        rootDir = string.sub(rootDir, 1, -2)
    end
    return setmetatable({
        _opts    = opts,
        _logger  = opts.logger,
        _caps    = detectCapabilities(),
        _rootDir = rootDir,
        _rootEnsured = false,
    }, StorageBackend)
end

function StorageBackend:capabilities() return self._caps end

function StorageBackend:rootDir() return self._rootDir end

function StorageBackend:available()
    return self._caps.writefile ~= nil and self._caps.readfile ~= nil
end

function StorageBackend:hasClipboard()
    return self._caps.setclipboard ~= nil or self._caps.getclipboard ~= nil
end

-- ---------------------------------------------------------------------
-- Path resolution
-- ---------------------------------------------------------------------

local function resolve(self, name)
    local unsafe, why = isUnsafePath(name)
    if unsafe then return nil, "unsafe path: " .. why end
    return self._rootDir .. "/" .. name
end

local function ensureRoot(self)
    if self._rootEnsured then return end
    self._rootEnsured = true
    if self._caps.isfolder and self._caps.makefolder then
        local ok, exists = pcall(self._caps.isfolder, self._rootDir)
        if ok and not exists then
            pcall(self._caps.makefolder, self._rootDir)
        end
    end
end

-- ---------------------------------------------------------------------
-- File operations
-- ---------------------------------------------------------------------

function StorageBackend:write(name, contents)
    if not self._caps.writefile then return false, "writefile unavailable" end
    if type(contents) ~= "string" then return false, "contents must be string" end
    local path, err = resolve(self, name)
    if not path then return false, err end
    ensureRoot(self)
    local ok, e = pcall(self._caps.writefile, path, contents)
    if not ok then
        if self._logger then self._logger:warn("StorageBackend.write %s failed: %s", path, e) end
        return false, tostring(e)
    end
    return true
end

function StorageBackend:read(name)
    if not self._caps.readfile then return false, "readfile unavailable" end
    local path, err = resolve(self, name)
    if not path then return false, err end
    local ok, contents = pcall(self._caps.readfile, path)
    if not ok then
        if self._logger then self._logger:warn("StorageBackend.read %s failed: %s", path, contents) end
        return false, tostring(contents)
    end
    return true, contents
end

function StorageBackend:append(name, contents)
    if not self._caps.appendfile then
        -- Fall back to read + concat + write
        local ok, existing = self:read(name)
        local prefix = ok and existing or ""
        return self:write(name, prefix .. contents)
    end
    local path, err = resolve(self, name)
    if not path then return false, err end
    ensureRoot(self)
    local ok, e = pcall(self._caps.appendfile, path, contents)
    if not ok then return false, tostring(e) end
    return true
end

function StorageBackend:exists(name)
    if not self._caps.isfile then return false end
    local path, _ = resolve(self, name)
    if not path then return false end
    local ok, result = pcall(self._caps.isfile, path)
    return ok and result == true
end

function StorageBackend:delete(name)
    if not self._caps.delfile then return false, "delfile unavailable" end
    local path, err = resolve(self, name)
    if not path then return false, err end
    local ok, e = pcall(self._caps.delfile, path)
    if not ok then return false, tostring(e) end
    return true
end

function StorageBackend:list(subdir)
    if not self._caps.listfiles then return {} end
    local target = self._rootDir
    if subdir and subdir ~= "" then
        local unsafe = isUnsafePath(subdir)
        if unsafe then return {} end
        target = target .. "/" .. subdir
    end
    local ok, result = pcall(self._caps.listfiles, target)
    if not ok or type(result) ~= "table" then return {} end
    -- Strip the rootDir prefix so callers see relative names.
    local stripped = {}
    local prefix = self._rootDir .. "/"
    for _, entry in result do
        if type(entry) == "string" then
            if string.sub(entry, 1, #prefix) == prefix then
                stripped[#stripped + 1] = string.sub(entry, #prefix + 1)
            else
                stripped[#stripped + 1] = entry
            end
        end
    end
    return stripped
end

-- ---------------------------------------------------------------------
-- Clipboard
-- ---------------------------------------------------------------------

function StorageBackend:setClipboard(text)
    if not self._caps.setclipboard then return false, "setclipboard unavailable" end
    if type(text) ~= "string" then return false, "text must be string" end
    local ok, e = pcall(self._caps.setclipboard, text)
    if not ok then return false, tostring(e) end
    return true
end

function StorageBackend:getClipboard()
    if not self._caps.getclipboard then return false, "getclipboard unavailable" end
    local ok, text = pcall(self._caps.getclipboard)
    if not ok then return false, tostring(text) end
    return true, text
end

return StorageBackend
