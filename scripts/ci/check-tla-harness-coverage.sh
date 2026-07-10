#!/usr/bin/env bash
# Ensure cfg-backed TLA+ specs are either checked by scripts/tla-check.sh or
# explicitly recorded as known unchecked debt.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

known_unchecked_specs() {
  cat <<'EOF'
# RFC-0065 cfg-backed specs are design/projection coverage and are not wired
# into scripts/tla-check.sh yet.
specs/keeper-state-machine/KeeperRuntimeAttemptFSM.tla
specs/keeper-state-machine/KeeperRuntimeRouting.tla
specs/keeper-state-machine/KeeperPostTurnOrchestration.tla
specs/keeper-state-machine/KeeperRolloverDecision.tla
specs/boundary/ContinuationGated.tla
EOF
}

has_cfg() {
  local spec="$1"
  local dir="${spec%/*}"
  local file="${spec##*/}"
  local stem="${file%.tla}"

  [[ -f "$dir/$stem.cfg" ]] && return 0
  [[ -f "$dir/$stem-buggy.cfg" ]] && return 0
  compgen -G "$dir/$stem-*.cfg" >/dev/null
}

is_known_unchecked() {
  local spec="$1"
  known_unchecked_specs | grep -Fxq "$spec"
}

is_checked() {
  local spec="$1"
  local dir="${spec%/*}"
  local file="${spec##*/}"
  local tla_dir_arg
  local line

  # scripts/tla-check.sh dynamically runs every non-symlink spec in bug-models
  # that has a matching clean or -buggy cfg.
  if [[ "$dir" == "specs/bug-models" ]]; then
    return 0
  fi

  # Match both directory and file on the same harness invocation. A basename-only
  # grep can false-pass if another directory later adds a spec with the same
  # file name.
  tla_dir_arg="\$REPO_ROOT/$dir"
  while IFS= read -r line; do
    if [[ "$line" == *"\"$tla_dir_arg\""* && "$line" == *"\"$file\""* ]]; then
      return 0
    fi
  done < scripts/tla-check.sh
  return 1
}

missing=()
known=()

while IFS= read -r spec; do
  [[ -n "$spec" ]] || continue
  has_cfg "$spec" || continue

  if is_checked "$spec"; then
    continue
  fi
  if is_known_unchecked "$spec"; then
    known+=("$spec")
    continue
  fi
  missing+=("$spec")
done < <(find specs -name '*.tla' -type f | sort)

if ((${#missing[@]} > 0)); then
  echo "FAIL: cfg-backed TLA+ specs not covered by scripts/tla-check.sh:" >&2
  printf '  %s\n' "${missing[@]}" >&2
  echo >&2
  echo "Either wire the spec into scripts/tla-check.sh or add it to the known_unchecked_specs list with an audit note." >&2
  exit 1
fi

echo "=== TLA harness coverage: PASS ==="
if ((${#known[@]} > 0)); then
  echo "Known unchecked cfg-backed specs (${#known[@]}):"
  printf '  %s\n' "${known[@]}"
fi
