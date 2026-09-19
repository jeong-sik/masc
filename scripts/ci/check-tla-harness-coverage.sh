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
specs/boundary/ContinuationCorrelation.tla
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

# A spec counts as covered when any harness line names it, which says nothing
# about which of its cfgs run. A spec wired with run_tlc alone passed above
# while its bug model never ran, and a bug model that never runs is the one
# check whose absence the clean run cannot reveal: a clean pass tells you
# nothing about whether the invariant is strong enough.
#
# So ask the same question of each buggy cfg. In specs/bug-models the harness
# globs <base>-*buggy.cfg, so every one of them runs; elsewhere the cfg is
# named on a run_tlc_buggy line, either by default or as its third argument.
# The spec a cfg belongs to, found the way specs/Makefile finds it: drop one
# trailing -segment at a time until a .tla of that name is beside it. Prints
# nothing when there is none.
spec_of_cfg() {
  local dir="$1" stem="${2%.cfg}" next
  while [[ -n "$stem" ]]; do
    [[ -f "$dir/$stem.tla" ]] && { printf '%s' "$stem"; return 0; }
    next="${stem%-*}"
    [[ "$next" == "$stem" ]] && return 1
    stem="$next"
  done
  return 1
}

# The harness one logical invocation per line: a call split over a backslash
# continuation puts its cfg argument on the next line, where a line-at-a-time
# reader never sees it beside the directory that selects it.
harness_lines() {
  local line held=""
  while IFS= read -r line; do
    if [[ "$line" == *\\ ]]; then
      held+="${line%\\} "
      continue
    fi
    printf '%s\n' "$held$line"
    held=""
  done < scripts/tla-check.sh
  [[ -n "$held" ]] && printf '%s\n' "$held"
  return 0
}

runs_buggy_cfg() {
  local dir="$1" cfg="$2" stem="$3"
  local line

  [[ "$dir" == "specs/bug-models" ]] && return 0

  while IFS= read -r line; do
    [[ "$line" == *run_tlc_buggy* ]] || continue
    [[ "$line" == *"\"\$REPO_ROOT/$dir\""* ]] || continue
    # named outright, or reached by the default <spec>-buggy.cfg
    [[ "$line" == *"\"$cfg\""* ]] && return 0
    [[ "$cfg" == "$stem-buggy.cfg" && "$line" == *"\"$stem.tla\""* ]] && return 0
  done < <(harness_lines)
  return 1
}

# The same question of the clean cfgs. A spec may state more than one model
# that must hold, and only <spec>.cfg is reached by a default run_tlc line or
# by the bug-models glob; any other clean cfg has to be named. Left unnamed it
# is as quiet as an unrun bug model, and quieter in its consequence: nobody
# even learns that the model it states was never checked.
runs_clean_cfg() {
  local dir="$1" cfg="$2" stem="$3"
  local line

  [[ "$cfg" == "$stem.cfg" ]] || {
    while IFS= read -r line; do
      [[ "$line" == *run_tlc* ]] || continue
      [[ "$line" == *"\"\$REPO_ROOT/$dir\""* ]] || continue
      [[ "$line" == *"\"$cfg\""* ]] && return 0
    done < <(harness_lines)
    return 1
  }

  [[ "$dir" == "specs/bug-models" ]] && return 0
  while IFS= read -r line; do
    [[ "$line" == *run_tlc* && "$line" != *run_tlc_buggy* ]] || continue
    [[ "$line" == *"\"\$REPO_ROOT/$dir\""* ]] || continue
    [[ "$line" == *"\"$stem.tla\""* ]] && return 0
  done < <(harness_lines)
  return 1
}

unrun=()
while IFS= read -r cfg; do
  [[ -n "$cfg" ]] || continue
  dir="${cfg%/*}"
  file="${cfg##*/}"
  [[ "$file" == *-buggy*.cfg ]] && continue
  stem="$(spec_of_cfg "$dir" "$file")" || continue
  is_known_unchecked "$dir/$stem.tla" && continue
  runs_clean_cfg "$dir" "$file" "$stem" || unrun+=("$cfg")
done < <(find specs -name '*.cfg' -type f | sort)

while IFS= read -r cfg; do
  [[ -n "$cfg" ]] || continue
  dir="${cfg%/*}"
  file="${cfg##*/}"
  # a cfg with no spec beside it is the orphan check's business, not this one
  stem="$(spec_of_cfg "$dir" "$file")" || continue
  is_known_unchecked "$dir/$stem.tla" && continue
  runs_buggy_cfg "$dir" "$file" "$stem" || unrun+=("$cfg")
done < <(find specs -name '*-buggy*.cfg' -type f | sort)

if ((${#unrun[@]} > 0)); then
  echo "FAIL: TLA+ cfgs that scripts/tla-check.sh never runs:" >&2
  printf '  %s\n' "${unrun[@]}" >&2
  echo >&2
  echo "A cfg that does not run states a model nobody checks, and a buggy one" >&2
  echo "that does not run proves nothing at all: the clean run passes either way." >&2
  echo "Add a run_tlc / run_tlc_cfg / run_tlc_buggy line naming the cfg, or record" >&2
  echo "the spec as known unchecked debt." >&2
  exit 1
fi

echo "=== TLA harness coverage: PASS ==="
if ((${#known[@]} > 0)); then
  echo "Known unchecked cfg-backed specs (${#known[@]}):"
  printf '  %s\n' "${known[@]}"
fi
