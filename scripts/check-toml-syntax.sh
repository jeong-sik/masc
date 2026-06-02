#!/usr/bin/env bash
set -eo pipefail

echo "Checking TOML syntax..."
python3 -c '
import sys
import glob

# Try importing tomllib (Python 3.11+) or tomli (older versions)
try:
    import tomllib
except ImportError:
    try:
        import tomli as tomllib
    except ImportError:
        print("Error: Python 3.11+ (tomllib) or the tomli package is required for TOML validation.")
        sys.exit(1)

files = glob.glob("config/**/*.toml", recursive=True)
has_error = False
for f in files:
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
