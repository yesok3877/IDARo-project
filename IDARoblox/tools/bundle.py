#!/usr/bin/env python3
"""
IDARo bundler — converts the project's tree of .luau files (which use
Roblox-style require(script.Parent.X)) into a single distributable
IDARo.bundle.luau that can be run by an executor via:

    loadstring(game:HttpGet("https://raw.githubusercontent.com/<repo>/.../IDARo.bundle.luau"))()

How it works
------------
1.  Walk every .luau file under IDARoblox/.
2.  Each file's module path is derived from its filesystem position:
        Foo/Bar.luau   ->  module "Foo.Bar"
        Foo/init.luau  ->  module "Foo"
3.  For every `require(<expr>)` in the source, parse `<expr>` (which
    will look like  `script[.Parent…][.Identifier…]`).  Walk the
    expression relative to the file's module path to resolve it to a
    target module name.  Rewrite `require(<expr>)` to
    `__IDARo_require("Target.Path")`.
4.  Wrap each file's body in:
        __IDARo_modules["Path"] = function() <body> end
5.  Prepend a runtime prologue defining `__IDARo_modules`,
    `__IDARo_cache`, and `__IDARo_require` (lazy + memoised).
6.  Append the entry: `return __IDARo_require("Bootstrap")`.

The output preserves the original source structure verbatim aside from
the require() rewrites — comments, type annotations, everything else
passes through untouched.  Each module evaluates lazily (only on its
first require), so a script that imports a single leaf module doesn't
pay the parse cost of the rest of the project.

Run from project root:

    python3 tools/bundle.py

Outputs:
    IDARo.bundle.luau
"""

import os
import re
import sys
import argparse

# ---------------------------------------------------------------------
# Paths + module resolution
# ---------------------------------------------------------------------

DEFAULT_SRC = "IDARoblox"
DEFAULT_OUT = "IDARo.bundle.luau"
ENTRY_MODULE = "Bootstrap"

def module_path_of(filepath, root):
    """Convert /<root>/Foo/Bar.luau to module name 'Foo.Bar'.
    /<root>/Foo/init.luau collapses to 'Foo'.  /<root>/init.luau is ''."""
    rel = os.path.relpath(filepath, root)
    base, _ext = os.path.splitext(rel)
    parts = base.split(os.sep)
    if parts and parts[-1] == "init":
        parts = parts[:-1]
    return ".".join(parts)


# Regex over the *expression* inside require(...). We capture from
# `script` outward through a dotted chain. The grammar in source is:
#
#   require(script.Parent.Framework.Component)
#   require(script.Parent.Parent.Database)
#   require(script.Database.SerializeBinary)
#   require(script.Parent.Parent.Parent.Database)
#
# The trailing close-paren is consumed by REQUIRE_RE below; this just
# parses the inner expression.
SCRIPT_EXPR = re.compile(r"^\s*script((?:\.\w+)*)\s*$")

# Top-level matcher: require(<expr>) where <expr> is a balanced
# parenthesisation. We don't expect nested parens in real Roblox
# require chains, so a non-greedy match of any chars except ')' is
# sufficient and avoids the cost of a balanced grammar.
REQUIRE_RE = re.compile(r"require\s*\(\s*([^()]*?)\s*\)")

# Alias pattern: `local Foo = script.Bar.Baz` (or `script` itself).
# Files like UI/init.luau use this to abbreviate require paths:
#
#     local Framework = script.Framework
#     local ThemeEngine = require(Framework.ThemeEngine)
#
# We collect aliases per-file so the require resolver can expand
# `Framework.ThemeEngine` back to `script.Framework.ThemeEngine`.
ALIAS_RE = re.compile(
    r"^\s*local\s+(\w+)\s*=\s*(script(?:\.\w+)*)\s*$",
    re.MULTILINE,
)


def collect_aliases(src):
    """Return dict of {alias_name: 'script.Sub.Path'} for one file."""
    aliases = {}
    for m in ALIAS_RE.finditer(src):
        aliases[m.group(1)] = m.group(2)
    return aliases


def resolve_require(current_module, expr, aliases=None):
    """Resolve an `script[.Parent]*[.Identifier]*` (or alias-rooted)
    expression relative to current_module to a fully-qualified module
    path.

    Returns None if the expression doesn't look like a Roblox-style
    require chain (e.g., dynamic requires like `require(someVar)`)."""
    aliases = aliases or {}
    # Expand a leading alias like `Framework.ThemeEngine` into
    # `script.Framework.ThemeEngine` before matching.
    first_dot = expr.find(".")
    head = expr if first_dot < 0 else expr[:first_dot]
    head = head.strip()
    if head in aliases:
        rest = "" if first_dot < 0 else expr[first_dot:]
        expr = aliases[head] + rest
    m = SCRIPT_EXPR.match(expr)
    if not m:
        return None
    chain = m.group(1)
    parts = [p for p in chain.split(".") if p]
    current = current_module.split(".") if current_module else []
    for p in parts:
        if p == "Parent":
            if current:
                current.pop()
        else:
            current.append(p)
    return ".".join(current)


def transform_source(src, module_path, all_modules, warnings):
    """Walk every require(...) match in src and rewrite when possible."""
    aliases = collect_aliases(src)
    def repl(m):
        expr = m.group(1)
        resolved = resolve_require(module_path, expr, aliases)
        if resolved is None:
            warnings.append(
                "%s: dynamic require kept verbatim: require(%s)" % (module_path, expr))
            return m.group(0)
        if resolved not in all_modules:
            warnings.append(
                "%s: require resolves to '%s' which is not in the bundle"
                % (module_path, resolved))
        return '__IDARo_require("%s")' % resolved
    return REQUIRE_RE.sub(repl, src)


# ---------------------------------------------------------------------
# Bundle assembly
# ---------------------------------------------------------------------

PROLOGUE = r"""--!nonstrict
-- =====================================================================
-- IDARo bundle (auto-generated by tools/bundle.py — do not hand-edit)
--
-- Usage (Roblox executor):
--     loadstring(game:HttpGet(URL_TO_THIS_FILE))()
--
-- The bundle contains every IDARo module as a lazy closure.  Modules
-- evaluate the first time they're required and the result is cached.
-- The entry point at the bottom returns the value of Bootstrap.
-- =====================================================================

local __IDARo_modules = {}
local __IDARo_cache   = {}
local __IDARo_loading = {}

local function __IDARo_require(path)
    if __IDARo_cache[path] ~= nil then
        return __IDARo_cache[path]
    end
    if __IDARo_loading[path] then
        error("IDARo: circular require: " .. path, 2)
    end
    local fn = __IDARo_modules[path]
    if not fn then
        error("IDARo: module not found: " .. tostring(path), 2)
    end
    __IDARo_loading[path] = true
    local result = fn()
    __IDARo_loading[path] = nil
    __IDARo_cache[path] = result == nil and true or result          -- record presence even if nil
    return result
end

-- Expose to global so plugins / generated scripts can require sub-modules
_G.IDARo = _G.IDARo or {}
_G.IDARo.require = __IDARo_require
_G.IDARo.modules = __IDARo_modules
_G.IDARo.version = "1.0"

"""

EPILOGUE_FMT = """
-- ===== entry =====
return __IDARo_require("%s")
"""


def collect_files(root):
    files = []
    for dirpath, _, filenames in os.walk(root):
        for f in filenames:
            if f.endswith(".luau"):
                files.append(os.path.join(dirpath, f))
    files.sort()
    return files


def build(root, out_path, entry_module=ENTRY_MODULE, verbose=False):
    if not os.path.isdir(root):
        print("ERROR: source root not found: %s" % root, file=sys.stderr)
        return 2

    files = collect_files(root)
    if not files:
        print("ERROR: no .luau files under %s" % root, file=sys.stderr)
        return 2

    module_paths = {}
    for fp in files:
        mp = module_path_of(fp, root)
        module_paths[fp] = mp

    all_modules = set(module_paths.values())
    if entry_module not in all_modules:
        print("ERROR: entry module '%s' not found among %d modules"
              % (entry_module, len(all_modules)), file=sys.stderr)
        return 2

    warnings = []
    out = [PROLOGUE]
    total_lines = 0

    for fp in files:
        mp = module_paths[fp]
        with open(fp, "r", encoding="utf-8") as f:
            src = f.read()
        transformed = transform_source(src, mp, all_modules, warnings)
        total_lines += transformed.count("\n")
        out.append("-- ===== module %s =====" % mp)
        out.append("__IDARo_modules[%r] = function()" % mp)
        out.append(transformed)
        # Some modules end with `return X` and not all end with a
        # trailing newline; ensure clean separation.
        if not transformed.endswith("\n"):
            out.append("")
        out.append("end")
        out.append("")

    out.append(EPILOGUE_FMT % entry_module)
    bundle = "\n".join(out)

    with open(out_path, "w", encoding="utf-8") as f:
        f.write(bundle)

    print("IDARo bundle:")
    print("  source root : %s" % root)
    print("  modules     : %d" % len(files))
    print("  entry       : %s" % entry_module)
    print("  output      : %s" % out_path)
    print("  size        : %d bytes (%d lines)" % (len(bundle), total_lines))
    if warnings:
        print("  warnings    : %d" % len(warnings))
        if verbose:
            for w in warnings:
                print("    - %s" % w)
    return 0


def main():
    parser = argparse.ArgumentParser(description="IDARo bundler")
    parser.add_argument("--src", default=DEFAULT_SRC,
                        help="source root directory (default: %s)" % DEFAULT_SRC)
    parser.add_argument("--out", default=DEFAULT_OUT,
                        help="output bundle path (default: %s)" % DEFAULT_OUT)
    parser.add_argument("--entry", default=ENTRY_MODULE,
                        help="entry module name (default: %s)" % ENTRY_MODULE)
    parser.add_argument("-v", "--verbose", action="store_true",
                        help="print each warning")
    args = parser.parse_args()
    return build(args.src, args.out, args.entry, args.verbose)


if __name__ == "__main__":
    sys.exit(main())
