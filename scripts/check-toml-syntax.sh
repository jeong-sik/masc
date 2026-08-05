#!/usr/bin/env bash
set -eo pipefail

echo "Checking TOML syntax..."
python3 -c '
import sys
import glob
import os

# Try importing tomllib (Python 3.11+) or tomli (older versions)
try:
    import tomllib
except ImportError:
    try:
        import tomli as tomllib
    except ImportError:
        print("Error: Python 3.11+ (tomllib) or the tomli package is required for TOML validation.")
        sys.exit(1)

# Was config/**/*.toml, which left nine files unchecked -- including the four
# keeper profiles under presets/classic/keepers/ that carry the same [keeper]
# tables as config/keepers/ and are meant to be copied there.
SKIP = ("_build/", ".git/", ".worktrees/", ".claude/", "node_modules/",
        "viewer/target/", "archive/")
files = [p for p in glob.glob("**/*.toml", recursive=True)
         if not p.startswith(SKIP)]

# A glob that matches nothing used to print "All 0 TOML files parsed
# successfully" and exit 0, so a moved directory would have read as a pass.
if not files:
    print("Error: no TOML files found — the syntax check is not reading the repository.")
    sys.exit(1)

has_error = False
for f in sorted(files):
    try:
        with open(f, "rb") as file:
            tomllib.load(file)
    except Exception as e:
        print(f"Syntax error in {f}: {e}")
        has_error = True

if has_error:
    sys.exit(1)
else:
    print(f"All {len(files)} TOML files parsed successfully.")
'
