#!/usr/bin/env bash
# Phase 1a-2: toggle sangsu's cascade between live mode and ollama_bench.
#
# Mutates ~/me/.masc/config/keepers/sangsu.toml in place. Backup written
# alongside as sangsu.toml.bench-bak. Hot-reload is mtime-based so no
# server restart needed.
#
# Usage:
#   ./sangsu_bench_toggle.sh on              # backup + switch to ollama_bench
#   ./sangsu_bench_toggle.sh off             # restore from backup
#   ./sangsu_bench_toggle.sh status          # print current cascade_name
#   ./sangsu_bench_toggle.sh model qwen3.6:35b-a3b-mlx-bf16
#                                            # mutate ollama_bench profile's
#                                            # single model slot in cascade.toml
#
# The "model" subcommand updates cascade.toml's [ollama_bench].models and
# triggers materializer re-run via mtime touch.

set -euo pipefail

BASE_PATH="${MASC_BASE_PATH:-$HOME/me}"
SANGSU_TOML="${BASE_PATH}/.masc/config/keepers/sangsu.toml"
SANGSU_BAK="${SANGSU_TOML}.bench-bak"
CASCADE_TOML="${BASE_PATH}/.masc/config/cascade.toml"

cmd="${1:-status}"
arg="${2:-}"

current_cascade() {
  awk -F' *= *' '/^cascade_name *=/ {gsub(/"/,"",$2); print $2; exit}' "$SANGSU_TOML"
}

current_bench_model() {
  python3 - "$CASCADE_TOML" << 'PY'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r'\[ollama_bench\][^\[]*?models\s*=\s*\[(.*?)\]', src, re.DOTALL)
if not m:
    print("(not found)")
    sys.exit(0)
mm = re.search(r'model\s*=\s*"([^"]+)"', m.group(1))
print(mm.group(1) if mm else "(empty)")
PY
}

case "$cmd" in
  status)
    printf 'sangsu cascade_name: %s\n' "$(current_cascade)"
    printf 'ollama_bench model:  %s\n' "$(current_bench_model)"
    if [ -f "$SANGSU_BAK" ]; then
      printf 'backup:              %s (exists)\n' "$SANGSU_BAK"
    fi
    ;;
  on)
    cur="$(current_cascade)"
    if [ "$cur" = "ollama_bench" ]; then
      echo "already on ollama_bench"
      exit 0
    fi
    cp "$SANGSU_TOML" "$SANGSU_BAK"
    # shellcheck disable=SC2016
    sed -E -i '' 's|^cascade_name *= *"[^"]+"|cascade_name = "ollama_bench"|' "$SANGSU_TOML"
    new="$(current_cascade)"
    if [ "$new" != "ollama_bench" ]; then
      echo "FAIL: sed did not switch cascade_name (got: $new). Restoring from backup." >&2
      mv "$SANGSU_BAK" "$SANGSU_TOML"
      exit 1
    fi
    printf 'sangsu cascade_name: %s -> ollama_bench (backup at %s)\n' "$cur" "$SANGSU_BAK"
    ;;
  off)
    if [ ! -f "$SANGSU_BAK" ]; then
      echo "no backup at $SANGSU_BAK — refusing to restore blindly" >&2
      exit 1
    fi
    mv "$SANGSU_BAK" "$SANGSU_TOML"
    printf 'sangsu cascade_name restored to: %s\n' "$(current_cascade)"
    ;;
  model)
    if [ -z "$arg" ]; then
      echo "usage: sangsu_bench_toggle.sh model <ollama:model:tag>" >&2
      exit 2
    fi
    # Match the [ollama_bench] section's first models = [ ... ] block,
    # rewrite the single entry. Idempotent for our 1-slot profile.
    python3 - "$CASCADE_TOML" "$arg" << 'PY'
import re, sys, time

path, model = sys.argv[1], sys.argv[2]
src = open(path).read()
pat = re.compile(
    r'(\[ollama_bench\][^\[]*?models\s*=\s*\[)[^\]]*?(\])',
    re.DOTALL,
)
new_block = '\n  { model = "%s", weight = 1 },\n' % model
out, n = pat.subn(lambda m: m.group(1) + new_block + m.group(2), src, count=1)
if n != 1:
    print("FAIL: could not find [ollama_bench] models block", file=sys.stderr)
    sys.exit(1)
open(path, 'w').write(out)
print(f"ollama_bench model -> {model}")
PY
    # Touch mtime to force loader cache invalidation.
    touch "$CASCADE_TOML"
    printf 'cascade.toml mtime: %s\n' "$(stat -f %Sm "$CASCADE_TOML" 2>/dev/null || stat -c %y "$CASCADE_TOML")"
    ;;
  *)
    echo "usage: $0 {status|on|off|model <ollama:model:tag>}" >&2
    exit 2
    ;;
esac
