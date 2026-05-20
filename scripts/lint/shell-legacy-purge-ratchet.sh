#!/usr/bin/env bash
# Shell legacy purge ratchet.
#
# The Shell IR Phase 5 cleanup target is to remove the remaining legacy
# string-tokenizer/path-scanner markers from lib/ and test/. This guard
# freezes the current debt while deletion PRs drive the baselines down to 0.
#
# Usage:
#   bash scripts/lint/shell-legacy-purge-ratchet.sh
#   bash scripts/lint/shell-legacy-purge-ratchet.sh --print
#   bash scripts/lint/shell-legacy-purge-ratchet.sh --regenerate

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COUNT_BASELINE="${ROOT}/scripts/lint/shell-legacy-purge-ratchet.baseline"
FILE_BASELINE="${ROOT}/scripts/lint/shell-legacy-purge-ratchet.files"
NEEDLES=(
  "tokenize_path_args"
  "path_validation_tokens"
  "forbidden_shell_chars"
  "raw_keeper_bash_shape_block"
)
SCOPE=(lib test)

for tool in awk comm mktemp rg sed sort tr wc; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "[shell-legacy-purge-ratchet] required tool missing: $tool" >&2
    exit 1
  }
done

current_count() {
  local needle="$1"
  (
    set +o pipefail
    cd "$ROOT"
    rg --fixed-strings -n "$needle" "${SCOPE[@]}" 2>/dev/null \
      | wc -l \
      | tr -d ' '
  )
}

baseline_count() {
  local needle="$1"
  awk -v needle="$needle" '
    $0 ~ /^[[:space:]]*#/ || NF == 0 { next }
    $1 == needle { print $2; found = 1 }
    END { if (!found) print 0 }
  ' "$COUNT_BASELINE"
}

current_files() {
  local needle="$1"
  (
    set +o pipefail
    cd "$ROOT"
    rg --fixed-strings -l "$needle" "${SCOPE[@]}" 2>/dev/null \
      | sort -u
  )
}

baseline_files() {
  local needle="$1"
  awk -v needle="$needle" '
    $0 ~ /^[[:space:]]*#/ || NF == 0 { next }
    $1 == needle { print $2 }
  ' "$FILE_BASELINE" | sort -u
}

print_counts() {
  printf "%-34s %9s  %9s\n" "needle" "current" "baseline"
  echo "--------------------------------------------------------"
  local needle
  for needle in "${NEEDLES[@]}"; do
    printf "%-34s %9s  %9s\n" \
      "$needle" \
      "$(current_count "$needle")" \
      "$(baseline_count "$needle")"
  done
}

regenerate() {
  {
    echo "# Shell legacy purge ratchet baseline."
    echo "#"
    echo "# Format: <needle> <max-hit-count>"
    echo "# Scope: lib/ and test/"
    echo "# The long-term target for every row is 0. Cleanup PRs may lower these"
    echo "# counts; no PR may raise them."
    local needle
    for needle in "${NEEDLES[@]}"; do
      printf "%s %s\n" "$needle" "$(current_count "$needle")"
    done
  } >"$COUNT_BASELINE"

  {
    echo "# Shell legacy purge ratchet file baseline."
    echo "#"
    echo "# Format: <needle> <repo-relative-path>"
    echo "# New files may not gain these legacy markers. Deletion PRs should remove"
    echo "# rows as they remove the corresponding markers."
    local needle path
    for needle in "${NEEDLES[@]}"; do
      while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        printf "%s %s\n" "$needle" "$path"
      done < <(current_files "$needle")
    done
  } >"$FILE_BASELINE"

  echo "[shell-legacy-purge-ratchet] regenerated baselines"
}

check() {
  local needle current baseline current_tmp baseline_tmp new_tmp drift=0
  current_tmp="$(mktemp -t shell-legacy-current.XXXXXX)"
  baseline_tmp="$(mktemp -t shell-legacy-baseline.XXXXXX)"
  new_tmp="$(mktemp -t shell-legacy-new.XXXXXX)"
  trap 'rm -f "$current_tmp" "$baseline_tmp" "$new_tmp"' RETURN

  for needle in "${NEEDLES[@]}"; do
    current="$(current_count "$needle")"
    baseline="$(baseline_count "$needle")"
    if (( current > baseline )); then
      echo "[shell-legacy-purge-ratchet] DRIFT UP: ${needle} current=${current} baseline=${baseline}" >&2
      echo "  remove the new legacy marker or lower the existing debt first." >&2
      drift=1
    elif (( current < baseline )); then
      echo "[shell-legacy-purge-ratchet] SHRANK: ${needle} current=${current} baseline=${baseline}"
      echo "  update scripts/lint/shell-legacy-purge-ratchet.baseline in the cleanup PR."
    fi

    current_files "$needle" >"$current_tmp"
    baseline_files "$needle" >"$baseline_tmp"
    comm -13 "$baseline_tmp" "$current_tmp" >"$new_tmp"
    if [[ -s "$new_tmp" ]]; then
      echo "[shell-legacy-purge-ratchet] DRIFT UP: new files contain ${needle}" >&2
      sed 's/^/  - /' "$new_tmp" >&2
      echo "  do not move or expand legacy shell tokenizer/path-scanner code." >&2
      drift=1
    fi
  done

  return "$drift"
}

case "${1:-}" in
  --print)
    print_counts
    ;;
  --regenerate)
    regenerate
    ;;
  "")
    print_counts
    if check; then
      echo
      echo "[shell-legacy-purge-ratchet] OK"
      exit 0
    else
      echo
      echo "[shell-legacy-purge-ratchet] FAIL - current exceeds baseline" >&2
      exit 2
    fi
    ;;
  *)
    echo "Usage: $0 [--print|--regenerate]" >&2
    exit 1
    ;;
esac
