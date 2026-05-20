--!nonstrict
-- =====================================================================
-- IDARoblox / Database
-- ---------------------------------------------------------------------
-- Aggregate exports for the project-state stores.
-- =====================================================================

local SerializeBinary = _G.IDARo.require("Database.SerializeBinary")
local HistoryStack    = _G.IDARo.require("Database.HistoryStack")
local SymbolTable     = _G.IDARo.require("Database.SymbolTable")
local CommentStore    = _G.IDARo.require("Database.CommentStore")
local BookmarkStore   = _G.IDARo.require("Database.BookmarkStore")
local ProjectDB       = _G.IDARo.require("Database.ProjectDB")

local Database = {}

Database.SerializeBinary = SerializeBinary
Database.HistoryStack    = HistoryStack
Database.SymbolTable     = SymbolTable
Database.CommentStore    = CommentStore
Database.BookmarkStore   = BookmarkStore
Database.ProjectDB       = ProjectDB

-- ---------------------------------------------------------------------
-- Self-test
-- ---------------------------------------------------------------------

function Database.runSelfTest(opts)
    opts = opts or {}
    local logger = opts.logger
    local passes, fails = 0, 0
    local function check(name, cond, ...)
        if cond then
            passes = passes + 1
            if logger and opts.verbose then logger:info("PASS %s", name) end
        else
            fails = fails + 1
            if logger then
                local extras = ""
                local args = table.pack(...)
                if args.n > 0 then
                    local parts = {}
                    for i = 1, args.n do parts[i] = tostring(args[i]) end
                    extras = " — " .. table.concat(parts, " ")
                end
                logger:error("FAIL %s%s", name, extras)
            end
        end
    end

    -- =========================================================
    -- SerializeBinary
    -- =========================================================
    do
        local cases = {
            nil,
            false, true,
            0, 1, -1,
            127, 128, 255, 256, 65535, 65536, 4294967295, 4294967296,
            -127, -128, -65536, -1234567890,
            3.14, -2.718, 1e100, math.pi, math.huge, -math.huge,
            "", "a", "hello", string.rep("X", 255), string.rep("Y", 256), string.rep("Z", 8192),
            {},
            { 1, 2, 3 },
            { "alpha", "beta", "gamma" },
            { a = 1, b = 2, c = 3 },
            { nested = { deep = { deeper = { value = 42 } } } },
            { 1, "two", 3.14, true, false, nil, "five" },              -- array with mixed types (note: nil in middle truncates Lua arrays)
            { intern = "shared", also = "shared", more = "shared" },
            { mix = { 1, 2, 3, name = "fred" } },                      -- mixed-form table → MAP
        }
        for i, payload in ipairs(cases) do
            local ok1, encoded = pcall(SerializeBinary.encode, payload)
            check("SerializeBinary.encode #" .. i, ok1, encoded)
            if ok1 then
                local decoded, err = SerializeBinary.decode(encoded)
                check("SerializeBinary.decode #" .. i, decoded ~= nil or payload == nil, err)
                -- Equality check (table-recursive). For simple types == is fine.
                local function eq(a, b)
                    if type(a) ~= type(b) then return false end
                    if type(a) == "table" then
                        local seenKeys = {}
                        for k, v in a do
                            if not eq(v, b[k]) then return false end
                            seenKeys[k] = true
                        end
                        for k in b do
                            if not seenKeys[k] then return false end
                        end
                        return true
                    end
                    if a ~= a and b ~= b then return true end          -- both NaN
                    return a == b
                end
                check("SerializeBinary roundtrip #" .. i, eq(decoded, payload),
                    "input", tostring(payload), "output", tostring(decoded))
            end
        end

        -- Bytes blob (for raw bytecode)
        local blob = string.rep("\x00\x01\xFE\xFF", 32)
        local wrapped = SerializeBinary.wrapBytes(blob)
        local encoded = SerializeBinary.encode({ payload = wrapped })
        local decoded = SerializeBinary.decode(encoded)
        check("SerializeBinary bytes blob preserves data",
            decoded and decoded.payload == blob,
            decoded and decoded.payload and #decoded.payload, #blob)

        -- Magic verification
        local notv = SerializeBinary.decode("garbage")
        check("SerializeBinary rejects garbage", notv == nil)

        -- Inspect
        local info = SerializeBinary.inspect(encoded)
        check("SerializeBinary.inspect returns info",
            info and info.version == SerializeBinary.FORMAT_VERSION)
    end

    -- =========================================================
    -- HistoryStack
    -- =========================================================
    do
        local hs = HistoryStack.new({})
        local v = 0
        hs:execute({
            kind = "test.inc",
            apply  = function() v = v + 1 end,
            revert = function() v = v - 1 end,
        })
        check("HistoryStack execute applies", v == 1)
        check("HistoryStack canUndo", hs:canUndo())
        hs:undo()
        check("HistoryStack undo reverts", v == 0)
        check("HistoryStack canRedo", hs:canRedo())
        hs:redo()
        check("HistoryStack redo re-applies", v == 1)

        -- Coalesce
        local cv = 0
        for i = 1, 5 do
            hs:execute({
                kind = "test.coal",
                coalesceKey = "test-coal-key",
                apply  = function() cv = cv + 1 end,
                revert = function() cv = cv - 1 end,
            })
        end
        check("HistoryStack coalesce collapses 5 → ≤2 entries (1 inc + 1 coalesced)",
            hs:undoDepth() <= 2, hs:undoDepth())
        check("HistoryStack coalesce stats > 0",
            hs:stats().coalesced >= 4, hs:stats().coalesced)

        -- Transaction
        local hs2 = HistoryStack.new({})
        local tv = { a = 0, b = 0 }
        hs2:transaction("test-tx", function()
            hs2:execute({
                kind = "test.tx-a",
                apply  = function() tv.a = tv.a + 10 end,
                revert = function() tv.a = tv.a - 10 end,
            })
            hs2:execute({
                kind = "test.tx-b",
                apply  = function() tv.b = tv.b + 100 end,
                revert = function() tv.b = tv.b - 100 end,
            })
        end)
        check("Transaction applies all children", tv.a == 10 and tv.b == 100)
        check("Transaction is single undo unit", hs2:undoDepth() == 1, hs2:undoDepth())
        hs2:undo()
        check("Transaction undo reverts all children", tv.a == 0 and tv.b == 0)

        -- Transaction rollback on error
        local hs3 = HistoryStack.new({})
        local rv = 0
        local ok, _ = pcall(function()
            hs3:transaction("test-rollback", function()
                hs3:execute({
                    kind = "step1",
                    apply  = function() rv = rv + 5 end,
                    revert = function() rv = rv - 5 end,
                })
                error("simulated failure")
            end)
        end)
        check("Transaction rollback caught error", not ok)
        check("Transaction rollback reverted partial work", rv == 0, rv)
        check("Transaction rollback stats > 0", hs3:stats().rollbacks > 0)
    end

    -- =========================================================
    -- SymbolTable
    -- =========================================================
    do
        local hs = HistoryStack.new({})
        local st = SymbolTable.new({ history = hs })
        local sym = st:create(SymbolTable.Kind.PROTO, "0", "main")
        check("SymbolTable.create returns symbol", sym and sym.id == 1, sym and sym.id)
        check("SymbolTable.byKey works",
            st:byKey(SymbolTable.Kind.PROTO, "0") == sym)
        check("SymbolTable.byName works",
            #st:byName("main") == 1)

        st:rename(sym.id, "Main")
        check("SymbolTable.rename updates name", sym.name == "Main")
        check("SymbolTable byName old gone", #st:byName("main") == 0)
        check("SymbolTable byName new present", #st:byName("Main") == 1)

        hs:undo()
        check("SymbolTable rename undone", sym.name == "main")
        hs:redo()
        check("SymbolTable rename redone", sym.name == "Main")

        st:setFlag(sym.id, SymbolTable.Flags.USER_NAMED, true)
        check("SymbolTable setFlag applied",
            st:hasFlag(sym, SymbolTable.Flags.USER_NAMED))
        hs:undo()
        check("SymbolTable setFlag undone",
            not st:hasFlag(sym, SymbolTable.Flags.USER_NAMED))

        st:create(SymbolTable.Kind.GLOBAL, "warn", "warn")
        st:create(SymbolTable.Kind.GLOBAL, "print", "print")
        check("SymbolTable.allOfKind",
            #st:allOfKind(SymbolTable.Kind.GLOBAL) == 2)

        -- Pattern search
        local found = st:findByPattern("ai")     -- "Main", "warn" → "Main" matches
        check("SymbolTable.findByPattern",
            #found >= 1, #found)
    end

    -- =========================================================
    -- CommentStore
    -- =========================================================
    do
        local hs = HistoryStack.new({})
        local cs = CommentStore.new({ history = hs })
        local c1 = cs:add(0, 10, "first comment")
        local c2 = cs:add(0, 10, "anterior note", { kind = CommentStore.Kind.ANTERIOR })
        check("CommentStore.add returns comment", c1 ~= nil and c1.id == 1)
        check("CommentStore.byAddress returns 2",
            #cs:byAddress(0, 10) == 2, #cs:byAddress(0, 10))
        check("CommentStore.byKind ANTERIOR returns 1",
            #cs:byKind(CommentStore.Kind.ANTERIOR) == 1)

        cs:update(c1.id, "edited comment")
        check("CommentStore.update changes text", c1.text == "edited comment")
        hs:undo()
        check("CommentStore.update undone", c1.text == "first comment")

        cs:remove(c2.id)
        check("CommentStore.remove",
            #cs:byKind(CommentStore.Kind.ANTERIOR) == 0)
        hs:undo()
        check("CommentStore.remove undone",
            #cs:byKind(CommentStore.Kind.ANTERIOR) == 1)
    end

    -- =========================================================
    -- BookmarkStore
    -- =========================================================
    do
        local hs = HistoryStack.new({})
        local bs = BookmarkStore.new({ history = hs })
        local b1 = bs:add(0, 5, "important", BookmarkStore.Color.RED)
        check("BookmarkStore.add returns bookmark", b1 and b1.id == 1)
        check("BookmarkStore.byColor RED returns 1",
            #bs:byColor(BookmarkStore.Color.RED) == 1)

        local added, _ = bs:toggle(0, 5)
        check("BookmarkStore.toggle at existing address removes", added == false)
        check("BookmarkStore now has 0", bs:count() == 0)

        local added2, _ = bs:toggle(1, 10, "fresh", BookmarkStore.Color.BLUE)
        check("BookmarkStore.toggle at new address adds", added2 == true)
        check("BookmarkStore now has 1", bs:count() == 1)

        -- Find what we just added
        local all = bs:all()
        check("BookmarkStore.all returns 1", #all == 1)
        if all[1] then
            bs:rename(all[1].id, "renamed")
            check("BookmarkStore.rename", all[1].label == "renamed")
            bs:recolor(all[1].id, BookmarkStore.Color.GREEN)
            check("BookmarkStore.recolor",
                all[1].color == BookmarkStore.Color.GREEN)
        end
    end

    -- =========================================================
    -- ProjectDB end-to-end
    -- =========================================================
    do
        local db = ProjectDB.new({ name = "test-project" })
        -- Synthesize a minimal bytecode object
        local fakeBC = {
            version = 6, typesVersion = 0,
            stringTable = { "main", "helper" },
            protos = {
                [0] = { id = 0, debugName = "main", sizecode = 1, instructions = { 0 },
                        constants = {}, childProtoIds = {} },
                [1] = { id = 1, debugName = "",     sizecode = 1, instructions = { 0 },
                        constants = {}, childProtoIds = {} },
            },
            mainProtoId = 0,
            stats = { protos = 2, totalInstructions = 2, totalConstants = 0, totalStrings = 2 },
        }
        db:attachBytecode(fakeBC, "\x01\x02\x03\xFFFAKEBYTECODE")
        check("ProjectDB attachBytecode created proto symbols",
            #db:symbols():allOfKind(SymbolTable.Kind.PROTO) == 2)
        local mainSym = db:symbols():byKey(SymbolTable.Kind.PROTO, "0")
        check("ProjectDB main proto has ENTRY flag",
            db:symbols():hasFlag(mainSym, SymbolTable.Flags.ENTRY))

        db:addComment(0, 0, "interesting start")
        db:toggleBookmark(0, 0, "entry point", BookmarkStore.Color.RED)
        db:setViewState({ viewMode = "decomp", selectedProtoId = 1, selectedPc = 1 })

        -- Serialize
        local blob = db:serialize()
        check("ProjectDB.serialize produces non-empty blob",
            type(blob) == "string" and #blob > 16, blob and #blob)

        local info = SerializeBinary.inspect(blob)
        check("ProjectDB blob has correct magic",
            info and info.magic == SerializeBinary.MAGIC)

        -- Deserialize into a fresh DB
        local db2 = ProjectDB.new({})
        local ok, err = db2:deserialize(blob)
        check("ProjectDB.deserialize succeeded", ok, err)
        check("ProjectDB.deserialize restored symbols",
            db2:symbols():count() == db:symbols():count(),
            db2:symbols():count(), db:symbols():count())
        check("ProjectDB.deserialize restored comments",
            db2:comments():count() == 1)
        check("ProjectDB.deserialize restored bookmarks",
            db2:bookmarks():count() == 1)
        check("ProjectDB.deserialize restored viewState.viewMode",
            db2:viewState().viewMode == "decomp")
        check("ProjectDB.deserialize restored bytecode bytes",
            db2:bytecodeBytes() == "\x01\x02\x03\xFFFAKEBYTECODE")

        -- Undo/redo through ProjectDB
        check("ProjectDB.canUndo after attach", db:canUndo())
        local depthBefore = db:history():undoDepth()
        db:renameProto(0, "renamed-main")
        check("ProjectDB.renameProto applied",
            db:protoName(0) == "renamed-main")
        check("ProjectDB undo depth grew",
            db:history():undoDepth() > depthBefore)
        db:undo()
        check("ProjectDB.undo restored old name",
            db:protoName(0) == "main")
    end

    if logger then logger:info("Database self-test: %d pass, %d fail", passes, fails) end
    return passes, fails
end

return Database
