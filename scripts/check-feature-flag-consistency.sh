#!/usr/bin/env bash
# check-feature-flag-consistency.sh — registry/consumer consistency lint.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB_DIR="$REPO_ROOT/lib"
REGISTRY="$LIB_DIR/config/feature_flag_registry.ml"
ERRORS=0

echo "=== Feature Flag Consistency Check ==="

if [ ! -f "$REGISTRY" ]; then
  echo "ERROR: Feature_flag_registry not found at $REGISTRY"
  exit 1
fi

REGISTERED=$(sed -n \
  's/.*env_name = "\(MASC_[A-Z_]*\)".*/\1/p' \
  "$REGISTRY" | sort -u)

# Registry-backed reads exist in config modules and in runtime gates. Scan the
# complete library and accept the typed [get_bool*] accessor family so a strict
# security reader is not misreported as a stale registry entry.
#
# The reader is line-free: the formatter puts the flag name on the line after
# [get_bool] once the call sits deep enough (keeper_turn_driver_try_provider.ml
# after #36709), and a line-at-a-time scan then reported a live consumer as a
# stale entry and failed every PR.
read_consumers() {
  python3 - "$1" <<'PYEOF'
import os, re, sys

root = sys.argv[1]
call = re.compile(r'Feature_flag_registry\.get_bool[A-Za-z_]*\s*(?:\(\s*)?"(MASC_[A-Z_]+)"')
found = set()
for directory, _subdirs, files in os.walk(root):
    for name in files:
        if not name.endswith((".ml", ".mli")):
            continue
        with open(os.path.join(directory, name), encoding="utf-8", errors="replace") as handle:
            found.update(call.findall(handle.read()))
for flag in sorted(found):
    print(flag)
PYEOF
}

if [ "${1:-}" = "--self-test" ]; then
  fixture="$(mktemp -d)"
  trap 'rm -rf "$fixture"' EXIT
  cat > "$fixture/same_line.ml" <<'EOF'
let a = Feature_flag_registry.get_bool "MASC_SAME_LINE"
EOF
  cat > "$fixture/next_line.ml" <<'EOF'
let b =
  if
    Feature_flag_registry.get_bool
      "MASC_NEXT_LINE"
  then 1
  else 0
EOF
  cat > "$fixture/typed_reader.ml" <<'EOF'
let c = Feature_flag_registry.get_bool_strict "MASC_TYPED_READER"
EOF
  actual="$(read_consumers "$fixture" | tr '\n' ' ')"
  expected="MASC_NEXT_LINE MASC_SAME_LINE MASC_TYPED_READER "
  if [ "$actual" = "$expected" ]; then
    echo "self-test: the reader finds a flag on the call line, on the next line, and through a typed accessor (PASS)"
    exit 0
  fi
  echo "self-test FAIL: expected [$expected] got [$actual]"
  exit 1
fi

CONSUMED=$(read_consumers "$LIB_DIR" | sort -u)

echo ""
echo "--- Checking consumer coverage ---"
MISSING=0
for var in $CONSUMED; do
  if ! echo "$REGISTERED" | grep -q "^${var}$"; then
    echo "UNREGISTERED: $var"
    MISSING=$((MISSING + 1))
  fi
done

if [ "$MISSING" -eq 0 ]; then
  echo "OK: All literal registry consumers are registered."
else
  ERRORS=$((ERRORS + MISSING))
fi

echo ""
echo "--- Checking for stale literal registry entries ---"
STALE=0
for var in $REGISTERED; do
  if ! echo "$CONSUMED" | grep -q "^${var}$"; then
    echo "STALE: $var"
    STALE=$((STALE + 1))
  fi
done

if [ "$STALE" -eq 0 ]; then
  echo "OK: Every literal registry entry has a runtime consumer."
else
  ERRORS=$((ERRORS + STALE))
fi

echo ""
TOTAL_CONSUMED=$(echo "$CONSUMED" | sed '/^$/d' | wc -l | tr -d ' ')
TOTAL_REGISTERED=$(echo "$REGISTERED" | sed '/^$/d' | wc -l | tr -d ' ')
echo "Summary: $TOTAL_CONSUMED literal consumers, $TOTAL_REGISTERED registry entries, $ERRORS error(s)"

if [ "$ERRORS" -gt 0 ]; then
  echo "FAIL: Feature flag consistency check failed."
  exit 1
fi

echo "PASS: Feature flag consistency check passed."
