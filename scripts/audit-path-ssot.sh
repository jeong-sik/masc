#!/usr/bin/env bash
# RFC-0121 Configuration Path SSOT gate.
#
# Single SSOT: all .masc/<sub> paths derive from
# [Config_dir_resolver.<accessor> ~base_path] (or the Common helpers it
# forwards to in host_config's case). Inline direct-concat is forbidden.
#
# The gate scans for four classes of regression:
#   1. lib/ Filename.concat <x> ".masc/<sub>" inline construction
#   2. shell home-anchored .masc fallback
#   3. python Path(...).expanduser() on base_path arguments
#   4. non-canonical MASC env vars: MASC_HOME, MASC_DIR, MASC_ROOT
#
# An allowlist file (`.ci/path-ssot-allowlist.txt`) carries intentional
# exceptions (each line: `<file>:<rg-match-substring>`). Run from repo
# root.
#
# Exit codes:
#   0  clean
#   1  violations found
#   2  ripgrep missing

set -u

cd "$(git rev-parse --show-toplevel)" 2>/dev/null || cd "$(dirname "$0")/.."

if ! command -v rg >/dev/null 2>&1; then
  echo "audit-path-ssot: ripgrep (rg) is required" >&2
  exit 2
fi

ALLOWLIST=".ci/path-ssot-allowlist.txt"
[ -f "$ALLOWLIST" ] || ALLOWLIST=/dev/null

VIOLATIONS=0

# Filter hits against the allowlist. Each allowlist line is a substring
# that must appear in the rg output line for the hit to be suppressed.
filter_allowed() {
  if [ "$ALLOWLIST" = "/dev/null" ]; then
    cat
  else
    grep -vFf <(grep -vE '^[[:space:]]*(#|$)' "$ALLOWLIST") || true
  fi
}

scan() {
  local label="$1" pattern="$2"; shift 2
  local hits
  hits=$(rg -n "$pattern" "$@" 2>/dev/null | filter_allowed)
  if [ -n "$hits" ]; then
    echo "=== [FAIL] $label ===" >&2
    echo "$hits" >&2
    echo >&2
    VIOLATIONS=$((VIOLATIONS + 1))
  fi
}

# 1. OCaml: Filename.concat <x> ".masc/<sub>"
scan "lib resolver-bypass (inline .masc/<sub> concat)" \
  'Filename\.concat[^"]+"\.masc/' \
  lib/

# 2. Shell: home-anchored .masc fallback
scan "shell HOME-anchored .masc fallback" \
  '\$\{?HOME[}]?[^"]*\.masc|HOME/me/\.masc' \
  scripts/ start-masc.sh .githooks/ 2>/dev/null

# 3. Python: Path(...).expanduser() on script base_path arguments.
scan "python expanduser on base_path arg" \
  'args\.base_path[^)]*expanduser' \
  scripts/

# 4. Non-canonical MASC env vars. (Only MASC_HOME and MASC_ROOT are
#    distinctive enough; MASC_DIR collides with reasonable local shell
#    variable names and is excluded to keep the gate signal-only.)
scan "non-canonical MASC env var" \
  '\bMASC_HOME\b|\bMASC_ROOT\b' \
  lib/ scripts/ docs/ start-masc.sh

if [ "$VIOLATIONS" -eq 0 ]; then
  echo "audit-path-ssot: OK (0 violations)"
  exit 0
fi

cat >&2 <<'EOM'
audit-path-ssot: violations found.

Layout SSOT lives in lib/config_dir_resolver. Migrate callers to the
named accessors documented in
docs/rfc/RFC-0121-config-dir-resolution-single-active-root.md.

If a hit is intentional (sandbox-internal path, audit-only legacy
detector, etc.), add a precise substring to .ci/path-ssot-allowlist.txt
and link the rationale in the file.
EOM

exit 1
