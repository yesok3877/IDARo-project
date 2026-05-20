#!/usr/bin/env python3
"""
IDARo / tools / rewrite_requires.py
====================================

Rewrites every `require(script.Parent.X)` chain in the project tree to
`_G.IDARo.require("Module.Path")` so the project can be deployed as a
flat directory on GitHub and fetched per-file at runtime via
`game:HttpGet`.

Deployment model (after running this):

    1. Upload the entire IDARoblox/ directory to GitHub.
    2. User runs:
           loadstring(game:HttpGet("https://raw.githubusercontent.com/"
               .. "<owner>/<repo>/<branch>/IDARoblox/Bootstrap.luau"))()
    3. Bootstrap.luau defines `_G.IDARo.require` which HTTP-fetches the
       requested module from the repo's raw URL, loadstring()s it, and
       caches the result.
    4. Every other module in the tree then uses
       `_G.IDARo.require("Path.To.Module")` instead of Roblox-style
       require(script.Parent.X).

Resolution rules
----------------
* `Foo/Bar.luau`       --> module "Foo.Bar"
* `Foo/init.luau`      --> module "Foo"
* `script.Parent.X`    relative to current file's module path
* `local X = script.Y` aliases are tracked and expanded

Bootstrap.luau is skipped because it owns the loader definition and is
maintained by hand.

Usage
-----
    python3 tools/rewrite_requires.py                # rewrite in place
    python3 tools/rewrite_requires.py --dry-run      # preview only
    python3 tools/rewrite_requires.py --src OtherDir # different root

The script is idempotent — running it again on already-rewritten files
is a no-op (no more `require(script…)` calls remain to match).
"""

import os
import re
import sys
import argparse

DEFAULT_SRC = "IDARoblox"
ENTRY_FILE = "Bootstrap.luau"                                          # skipped (owns the loader)

# Same regex set as the bundler.
SCRIPT_EXPR = re.compile(r"^\s*script((?:\.\w+)*)\s*$")
REQUIRE_RE  = re.compile(r"require\s*\(\s*([^()]*?)\s*\)")
ALIAS_RE    = re.compile(
    r"^\s*local\s+(\w+)\s*=\s*(script(?:\.\w+)*)\s*$",
    re.MULTILINE,
)


def module_path_of(filepath, root):
    rel = os.path.relpath(filepath, root)
    base, _ext = os.path.splitext(rel)
    parts = base.split(os.sep)
    if parts and parts[-1] == "init":
        parts = parts[:-1]
    return ".".join(parts)


def collect_aliases(src):
    return {m.group(1): m.group(2) for m in ALIAS_RE.finditer(src)}


def resolve_require(current_module, expr, aliases):
    first_dot = expr.find(".")
    head = expr.strip() if first_dot < 0 else expr[:first_dot].strip()
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


def rewrite(src, module_path, all_modules, warnings):
    aliases = collect_aliases(src)
    changes = [0]
    def repl(m):
        expr = m.group(1)
        resolved = resolve_require(module_path, expr, aliases)
        if resolved is None:
            warnings.append(
                "%s: dynamic require kept verbatim: require(%s)" % (module_path, expr))
            return m.group(0)
        if resolved not in all_modules:
            warnings.append(
                "%s: resolves to '%s' which is not in the tree"
                % (module_path, resolved))
        changes[0] += 1
        return '_G.IDARo.require("%s")' % resolved
    new_src = REQUIRE_RE.sub(repl, src)
    return new_src, changes[0]


def collect_files(root):
    files = []
    for dirpath, _, filenames in os.walk(root):
        for f in filenames:
            if f.endswith(".luau"):
                files.append(os.path.join(dirpath, f))
    files.sort()
    return files


def main():
    p = argparse.ArgumentParser(description="Rewrite requires for IDARo")
    p.add_argument("--src", default=DEFAULT_SRC,
                   help="project root (default %s)" % DEFAULT_SRC)
    p.add_argument("--dry-run", action="store_true",
                   help="show what would change without writing")
    p.add_argument("-v", "--verbose", action="store_true")
    args = p.parse_args()

    if not os.path.isdir(args.src):
        print("ERROR: source root not found: %s" % args.src, file=sys.stderr)
        return 2

    files = collect_files(args.src)
    if not files:
        print("ERROR: no .luau files under %s" % args.src, file=sys.stderr)
        return 2

    # Build module index up-front so we can warn on unresolved requires.
    module_paths = {fp: module_path_of(fp, args.src) for fp in files}
    all_modules = set(module_paths.values())

    warnings = []
    total_changes = 0
    files_changed = 0
    files_skipped = 0

    for fp in files:
        mp = module_paths[fp]
        is_entry = os.path.basename(fp) == ENTRY_FILE and mp == "Bootstrap"
        if is_entry:
            files_skipped += 1
            if args.verbose:
                print("  skip   %s (Bootstrap.luau is the loader)" % mp)
            continue

        with open(fp, "r", encoding="utf-8") as f:
            src = f.read()

        new_src, count = rewrite(src, mp, all_modules, warnings)

        if count == 0:
            if args.verbose:
                print("  noop   %s" % mp)
            continue

        total_changes += count
        files_changed += 1

        if args.dry_run:
            print("  would update %s (%d requires)" % (mp, count))
        else:
            with open(fp, "w", encoding="utf-8") as f:
                f.write(new_src)
            if args.verbose:
                print("  wrote  %s (%d requires)" % (mp, count))

    print("rewrite_requires summary:")
    print("  source root      : %s" % args.src)
    print("  files scanned    : %d" % len(files))
    print("  files modified   : %d" % files_changed)
    print("  files skipped    : %d" % files_skipped)
    print("  requires rewrote : %d" % total_changes)
    print("  warnings         : %d" % len(warnings))
    if args.verbose and warnings:
        for w in warnings:
            print("    - %s" % w)
    if args.dry_run:
        print("  (dry-run; no files were changed)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
