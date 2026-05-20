--!nonstrict
-- =====================================================================
-- IDARo / Core / ScriptGenerator
-- ---------------------------------------------------------------------
-- Produces ready-to-paste executor scripts for things the user clicked
-- on. Every generator returns:
--
--   {
--     source   = "<the script source>",
--     warnings = { "requires hookfunction", … },
--     metadata = { target, kind, … },
--   }
--
-- The UI's "Generate" buttons copy `.source` into the clipboard and
-- surface `.warnings` in a toast.
--
-- Supported generators
--   fetchClosureFromGC(desc)     — re-locate a closure later via getgc
--   fetchTableFromGC(desc)       — re-locate a table by shape + sample
--   hookClosure(desc)            — hookfunction wrapper that logs
--   setUpvalue(desc, idx, val)   — debug.setupvalue stub
--   setConstant(desc, idx, val)  — debug.setconstant stub
--   dumpScript(scriptInst)       — getscriptbytecode + writefile
--   replayRemote(entry)          — re-fire a remote with stored args
--   fireRemote(path, args)       — manual fire of any remote
--   injectNamecallHook()         — a class-wide namecall override skeleton
--   inspectInstance(instance)    — print Class/Children/Methods info
-- =====================================================================

local ScriptGenerator = {}

-- ---------------------------------------------------------------------
-- Safe literal emit
-- ---------------------------------------------------------------------

local function fmtString(s)
    return string.format("%q", tostring(s)):gsub("\\\n", "\\n")
end

local function fmtValue(v)
    local t = type(v)
    if t == "nil"     then return "nil" end
    if t == "boolean" then return tostring(v) end
    if t == "number"  then
        if v ~= v then return "0/0" end                              -- NaN
        if v == math.huge then return "math.huge" end
        if v == -math.huge then return "-math.huge" end
        return tostring(v)
    end
    if t == "string"  then return fmtString(v) end
    return "nil --[[ unrepresentable " .. t .. " ]]"
end

local function header(title)
    return string.format(
        "--[[\n  IDARo generated script\n  %s\n  Generated: %s\n--]]\n\n",
        title, os.date("%Y-%m-%dT%H:%M:%S"))
end

-- ---------------------------------------------------------------------
-- Closure-locating helper (shared by fetchClosureFromGC + hookClosure)
-- ---------------------------------------------------------------------

local function emitClosureLocator(varName, desc)
    -- The "fingerprint" we use:
    --   * numUpvalues + numConstants (cheap exact match)
    --   * source string (debug.info :S)
    --   * first 4 constants stringified (for tighter match)
    local upN = desc.numUpvalues or 0
    local kN  = desc.numConstants or 0
    local src = (desc.source or "")
    local labelHint = (desc.label or ""):gsub("%s+", " ")
    local firstK = {}
    if desc.constants then
        for i = 1, math.min(4, #desc.constants) do
            firstK[#firstK + 1] = fmtValue(desc.constants[i].value)
        end
    end
    local kListLit = "{" .. table.concat(firstK, ", ") .. "}"

    local lines = {}
    table.insert(lines, string.format("local %s = nil", varName))
    table.insert(lines, "do")
    table.insert(lines, "    local target_upN, target_kN = " .. upN .. ", " .. kN)
    table.insert(lines, "    local target_src   = " .. fmtString(src))
    table.insert(lines, "    local target_label = " .. fmtString(labelHint))
    table.insert(lines, "    local target_firstK = " .. kListLit)
    table.insert(lines, "    local dbg = debug")
    table.insert(lines, "    for _, fn in ipairs(getgc(true)) do")
    table.insert(lines, "        if type(fn) == 'function' and not iscclosure(fn) then")
    table.insert(lines, "            local ok, ups = pcall(dbg.getupvalues, fn)")
    table.insert(lines, "            local _ok, ks = pcall(dbg.getconstants, fn)")
    table.insert(lines, "            if ok and _ok and ups and ks and #ups == target_upN and #ks == target_kN then")
    table.insert(lines, "                local info; pcall(function() info = dbg.info(fn, 'sln') end)")
    table.insert(lines, "                local src = (info and (info.source or info.short_src)) or ''")
    table.insert(lines, "                if target_src == '' or src == target_src or string.find(src, target_src, 1, true) then")
    table.insert(lines, "                    local match = true")
    table.insert(lines, "                    for i, expected in ipairs(target_firstK) do")
    table.insert(lines, "                        if ks[i] ~= expected then match = false; break end")
    table.insert(lines, "                    end")
    table.insert(lines, "                    if match then " .. varName .. " = fn; break end")
    table.insert(lines, "                end")
    table.insert(lines, "            end")
    table.insert(lines, "        end")
    table.insert(lines, "    end")
    table.insert(lines, "end")
    return table.concat(lines, "\n")
end

-- ---------------------------------------------------------------------
-- Generators
-- ---------------------------------------------------------------------

function ScriptGenerator.fetchClosureFromGC(desc)
    local src = header("Fetch closure from GC")
        .. emitClosureLocator("target", desc) .. "\n\n"
        .. "if target then\n"
        .. "    print('IDARo: located closure', target)\n"
        .. "else\n"
        .. "    warn('IDARo: closure not found in current GC')\n"
        .. "end\n"
        .. "return target\n"
    return {
        source   = src,
        warnings = {
            "requires getgc, debug.getupvalues, debug.getconstants",
        },
        metadata = { kind = "closure", target = desc },
    }
end

function ScriptGenerator.fetchTableFromGC(desc)
    local shape = desc.shapeHash or ""
    local sample = {}
    if desc.shape then
        for i = 1, math.min(6, #desc.shape) do
            local f = desc.shape[i]
            sample[#sample + 1] = string.format("{ key = %s, kind = %s }",
                fmtString(f.key or ""), fmtString(f.kind or ""))
        end
    end
    local sampleLit = "{" .. table.concat(sample, ", ") .. "}"
    local src = header("Fetch table from GC by shape")
        .. "local target = nil\n"
        .. "local target_shape = " .. fmtString(shape) .. "\n"
        .. "local target_sample = " .. sampleLit .. "\n"
        .. "for _, t in ipairs(getgc(true)) do\n"
        .. "    if type(t) == 'table' then\n"
        .. "        local ok = true\n"
        .. "        for _, s in ipairs(target_sample) do\n"
        .. "            local v = rawget(t, s.key)\n"
        .. "            if v == nil or type(v) ~= s.kind then ok = false; break end\n"
        .. "        end\n"
        .. "        if ok then target = t; break end\n"
        .. "    end\n"
        .. "end\n"
        .. "if target then print('IDARo: located table', target)\n"
        .. "else warn('IDARo: table not found') end\n"
        .. "return target\n"
    return {
        source   = src,
        warnings = { "shape match is heuristic; multiple tables may match" },
        metadata = { kind = "table", target = desc },
    }
end

function ScriptGenerator.hookClosure(desc, opts)
    opts = opts or {}
    local logArgs    = opts.logArgs ~= false
    local logReturns = opts.logReturns ~= false
    local src = header("Hook closure (log + passthrough)")
        .. emitClosureLocator("target", desc) .. "\n\n"
        .. "if not target then warn('IDARo: target not found'); return end\n"
        .. "if type(hookfunction) ~= 'function' then\n"
        .. "    warn('IDARo: hookfunction unavailable on this executor'); return end\n\n"
        .. "local original\n"
        .. "original = hookfunction(target, function(...)\n"
        .. (logArgs and "    print('[hook] args:', ...)\n" or "")
        .. "    local results = table.pack(original(...))\n"
        .. (logReturns and "    print('[hook] returns:', table.unpack(results, 1, results.n))\n" or "")
        .. "    return table.unpack(results, 1, results.n)\n"
        .. "end)\n"
        .. "print('IDARo: hook installed; call original() to unhook via hookfunction(target, original)')\n"
        .. "return { target = target, original = original }\n"
    return {
        source   = src,
        warnings = { "requires hookfunction", "leaves the hook in place until you restore it" },
        metadata = { kind = "hook", target = desc },
    }
end

function ScriptGenerator.setUpvalue(desc, index, value)
    local src = header(string.format("Set upvalue [%d] on closure", index))
        .. emitClosureLocator("target", desc) .. "\n\n"
        .. "if not target then warn('IDARo: target not found'); return end\n"
        .. "if type(debug) ~= 'table' or type(debug.setupvalue) ~= 'function' then\n"
        .. "    warn('IDARo: debug.setupvalue unavailable'); return end\n\n"
        .. string.format("local ok, err = pcall(debug.setupvalue, target, %d, %s)\n",
                         index, fmtValue(value))
        .. "if ok then print('IDARo: setupvalue ok')\n"
        .. "else warn('IDARo: setupvalue failed: ' .. tostring(err)) end\n"
    return {
        source   = src,
        warnings = { "requires debug.setupvalue", "type narrowing rules vary by executor" },
        metadata = { kind = "setupvalue", target = desc, index = index, value = value },
    }
end

function ScriptGenerator.setConstant(desc, index, value)
    local src = header(string.format("Set constant [%d] on closure", index))
        .. emitClosureLocator("target", desc) .. "\n\n"
        .. "if not target then warn('IDARo: target not found'); return end\n"
        .. "if type(debug) ~= 'table' or type(debug.setconstant) ~= 'function' then\n"
        .. "    warn('IDARo: debug.setconstant unavailable'); return end\n\n"
        .. string.format("local ok, err = pcall(debug.setconstant, target, %d, %s)\n",
                         index, fmtValue(value))
        .. "if ok then print('IDARo: setconstant ok')\n"
        .. "else warn('IDARo: setconstant failed: ' .. tostring(err)) end\n"
    return {
        source   = src,
        warnings = { "requires debug.setconstant", "many executors enforce type-locking on constants" },
        metadata = { kind = "setconstant", target = desc, index = index, value = value },
    }
end

function ScriptGenerator.dumpScript(scriptInst)
    local pathOk, fullName = pcall(function() return scriptInst:GetFullName() end)
    local nameOk, name     = pcall(function() return scriptInst.Name end)
    local src = header(string.format("Dump script bytecode: %s", pathOk and fullName or "?"))
        .. "local script_path = " .. fmtString(pathOk and fullName or "") .. "\n"
        .. "local script_name = " .. fmtString(nameOk and name or "anon") .. "\n"
        .. "if type(getscriptbytecode) ~= 'function' then\n"
        .. "    warn('IDARo: getscriptbytecode unavailable'); return end\n"
        .. "local target = nil\n"
        .. "do\n"
        .. "    local parts = string.split(script_path, '.')\n"
        .. "    local node = game\n"
        .. "    for i, p in ipairs(parts) do\n"
        .. "        if i == 1 then\n"
        .. "            local ok = pcall(function() node = game:GetService(p) end)\n"
        .. "            if not ok then node = game:FindFirstChild(p) end\n"
        .. "        else node = node and node:FindFirstChild(p) end\n"
        .. "        if not node then break end\n"
        .. "    end\n"
        .. "    target = node\n"
        .. "end\n"
        .. "if not target then warn('IDARo: script not found'); return end\n"
        .. "local ok, bytes = pcall(getscriptbytecode, target)\n"
        .. "if not ok then warn('IDARo: getscriptbytecode failed: ' .. tostring(bytes)); return end\n"
        .. "if type(writefile) == 'function' then\n"
        .. "    writefile('IDARo/dumps/' .. script_name .. '.luac', bytes)\n"
        .. "    print('IDARo: wrote ' .. #bytes .. ' bytes to IDARo/dumps/' .. script_name .. '.luac')\n"
        .. "else print('IDARo: bytecode collected (' .. #bytes .. ' bytes); writefile unavailable') end\n"
    return {
        source   = src,
        warnings = { "requires getscriptbytecode", "writefile is optional but recommended" },
        metadata = { kind = "dumpScript", target = scriptInst },
    }
end

function ScriptGenerator.replayRemote(entry)
    local pathLit = fmtString(entry.path or "")
    local argLit  = entry.args or ""                                  -- already a stringified args list
    local src = header(string.format("Replay %s.%s", entry.kind or "?", entry.method or "?"))
        .. "local target_path = " .. pathLit .. "\n"
        .. "local parts = string.split(target_path, '.')\n"
        .. "local node = game\n"
        .. "for i, p in ipairs(parts) do\n"
        .. "    if i == 1 then\n"
        .. "        local ok = pcall(function() node = game:GetService(p) end)\n"
        .. "        if not ok then node = game:FindFirstChild(p) end\n"
        .. "    else node = node and node:FindFirstChild(p) end\n"
        .. "    if not node then break end\n"
        .. "end\n"
        .. "if not node then warn('IDARo: remote not found at ' .. target_path); return end\n"
        .. string.format("local ok, err = pcall(function() return node:%s(%s) end)\n",
                          entry.method or "Fire", argLit)
        .. "if ok then print('IDARo: replay sent') else warn('IDARo: replay failed: ' .. tostring(err)) end\n"
    return {
        source   = src,
        warnings = {
            "args are stringified; complex Instance/table args may not round-trip exactly",
            "anti-cheat may flag rapid replay",
        },
        metadata = { kind = "replayRemote", entry = entry },
    }
end

function ScriptGenerator.injectNamecallHook(opts)
    opts = opts or {}
    local className = opts.className or "RemoteEvent"
    local method    = opts.method    or "FireServer"
    local src = header(string.format("Inject namecall hook on %s:%s", className, method))
        .. "if type(hookmetamethod) ~= 'function' then warn('IDARo: hookmetamethod unavailable'); return end\n"
        .. "local target_class  = " .. fmtString(className) .. "\n"
        .. "local target_method = " .. fmtString(method) .. "\n"
        .. "local old\n"
        .. "old = hookmetamethod(game, '__namecall', function(self, ...)\n"
        .. "    local m = getnamecallmethod()\n"
        .. "    if m == target_method and typeof(self) == 'Instance' and self:IsA(target_class) then\n"
        .. "        print('[namecall hook] ' .. self:GetFullName() .. ':' .. m, ...)\n"
        .. "    end\n"
        .. "    return old(self, ...)\n"
        .. "end)\n"
        .. "print('IDARo: namecall hook installed')\n"
    return {
        source   = src,
        warnings = { "requires hookmetamethod", "requires getnamecallmethod" },
        metadata = { kind = "namecallHook", className = className, method = method },
    }
end

function ScriptGenerator.inspectInstance(instance)
    local pathOk, fullName = pcall(function() return instance:GetFullName() end)
    local src = header(string.format("Inspect instance: %s", pathOk and fullName or "?"))
        .. "local target_path = " .. fmtString(pathOk and fullName or "") .. "\n"
        .. "local parts = string.split(target_path, '.')\n"
        .. "local node = game\n"
        .. "for i, p in ipairs(parts) do\n"
        .. "    if i == 1 then\n"
        .. "        local ok = pcall(function() node = game:GetService(p) end)\n"
        .. "        if not ok then node = game:FindFirstChild(p) end\n"
        .. "    else node = node and node:FindFirstChild(p) end\n"
        .. "    if not node then break end\n"
        .. "end\n"
        .. "if not node then warn('IDARo: instance not found'); return end\n"
        .. "print('Class:', node.ClassName)\n"
        .. "print('Full name:', node:GetFullName())\n"
        .. "print('Children:')\n"
        .. "for _, c in ipairs(node:GetChildren()) do\n"
        .. "    print(' ', c.ClassName, c.Name)\n"
        .. "end\n"
        .. "if type(getproperties) == 'function' then\n"
        .. "    print('Properties:')\n"
        .. "    for _, prop in ipairs(getproperties(node)) do\n"
        .. "        local ok, v = pcall(function() return node[prop] end)\n"
        .. "        if ok then print(' ', prop, '=', v) end\n"
        .. "    end\n"
        .. "end\n"
    return {
        source   = src,
        warnings = {},
        metadata = { kind = "inspect", target = instance },
    }
end

-- ---------------------------------------------------------------------
-- Clipboard helper — copies a generated script + returns the warnings
-- via callback so the caller can show a toast.
-- ---------------------------------------------------------------------

function ScriptGenerator.copyToClipboard(result, opts)
    opts = opts or {}
    local setclipboard = rawget(_G, "setclipboard") or rawget(getfenv(0), "setclipboard")
    if type(setclipboard) ~= "function" then
        if opts.storage and opts.storage.setClipboard then
            return opts.storage:setClipboard(result.source)
        end
        return false, "setclipboard unavailable"
    end
    local ok, err = pcall(setclipboard, result.source)
    if ok then return true, result.warnings end
    return false, err
end

return ScriptGenerator
