#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
lock_path="${DUNE_LOCAL_LOCK:-/tmp/me-dune-local.lock}"

usage() {
  cat <<'USAGE'
Usage: scripts/dune-local.sh [dune-subcommand] [args...]

Local Dune wrapper for multi-agent development:
  - serializes local Dune invocations with a machine-wide lock
  - defaults local concurrency to DUNE_LOCAL_JOBS, or 2
  - injects --root <repo-root> unless --root is already present
  - asserts agent_sdk opam pin matches the repo SSOT before each build
  - asserts core opam dependencies are installed in the active switch
  - asserts OCaml is at or above the repo floor (5.4)

Set MASC_DUNE_THROTTLE=0 to bypass the local lock.
Set MASC_DUNE_DRY_RUN=1 to print the command without running it.
Set MASC_SKIP_PIN_CHECK=1 to skip the agent_sdk pin guard.
Set MASC_SKIP_DEPS_CHECK=1 to skip the core-deps installed guard.
Set MASC_SKIP_OCAML_VERSION_CHECK=1 to skip the OCaml minimum version guard.
USAGE
}

args=("$@")
if [[ "${#args[@]}" -eq 0 ]]; then
  args=(build)
fi

case "${args[0]}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

has_root=0
for arg in "${args[@]}"; do
  case "$arg" in
    --root|--root=*)
      has_root=1
      break
      ;;
  esac
done
if [[ -n "${DUNE_ROOT:-}" ]]; then
  has_root=1
fi

cmd=(dune)
if [[ "$has_root" -eq 0 && "${args[0]}" != -* ]]; then
  cmd+=("${args[0]}" --root "$repo_root")
  if [[ "${#args[@]}" -gt 1 ]]; then
    cmd+=("${args[@]:1}")
  fi
else
  cmd+=("${args[@]}")
fi

# Detect the actual dune subcommand by skipping global options and their
# values.  PR #13117 review (P2): `args[0]` misclassified valid invocations
# like `scripts/dune-local.sh --root . clean` as non-clean, making the
# guards below fire on a clean target that never compiles.  The subcommand
# is the first positional token after any leading global-option flags.
#
# Two follow-up reviews (codex-connector P2, 2026-05-05):
#   - `--auto-promote` is a boolean flag, NOT value-taking (per
#     `dune build --help` common options).  Removed from value list.
#   - `-p PACKAGES` and `-x VAL` ARE value-taking short options
#     (also common options).  Added to value list — the prior
#     fallback `[[ "$a" == -* ]]` consumed only the flag and then
#     misread the value as the subcommand.
#   - `--cache-storage-mode VAL` and `--cache-check-probability VAL`
#     are value-taking Dune cache options; do not treat their values
#     as subcommands.
_value_taking_flags=(--root --workspace --profile --build-dir --display \
                     --default-target -j --jobs -p --only-packages \
                     -x --config-file --cache --cache-check-probability \
                     --cache-storage-mode \
                     --diff-command --error-reporting \
                     --terminal-persistence)
_detect_subcommand() {
  local i=0
  while (( i < ${#args[@]} )); do
    local a="${args[i]}"
    # `--flag=value` form: single token, skip it.
    if [[ "$a" == --*=* ]]; then
      i=$((i + 1)); continue
    fi
    # Known value-taking flag: skip flag + its value.
    local _value_taking=0
    for _vf in "${_value_taking_flags[@]}"; do
      if [[ "$a" == "$_vf" ]]; then _value_taking=1; break; fi
    done
    if [[ "$_value_taking" -eq 1 ]]; then
      i=$((i + 2)); continue
    fi
    # Other option-shaped tokens: skip just the flag.
    if [[ "$a" == -* ]]; then
      i=$((i + 1)); continue
    fi
    # First non-option token = subcommand.
    printf '%s\n' "$a"
    return
  done
  printf 'build\n'
}
_subcommand="$(_detect_subcommand)"

if [[ "${GITHUB_ACTIONS:-}" != "true" ]]; then
  export DUNE_JOBS="${DUNE_JOBS:-${DUNE_LOCAL_JOBS:-2}}"
  export DUNE_BUILD_DIR="${DUNE_BUILD_DIR:-$repo_root/_build}"
fi

# --- agent_sdk pin guard -----------------------------------------------
# Assert the local opam switch is pinned to the SSOT SHA before each local
# build.  Multiple concurrent sessions that share one opam switch can
# silently repin agent_sdk to a different SHA, producing non-deterministic
# CMI mismatches (e.g. "inconsistent assumptions over interface Types").
# This guard catches drift before Dune starts and prints actionable repair
# guidance.
#
# Skipped when:
#   GITHUB_ACTIONS=true     – CI pins via workflow; no local switch to check
#   MASC_SKIP_PIN_CHECK=1   – operator opt-out for known-good environments
#   MASC_DUNE_DRY_RUN=1     – dry-run never mutates or validates state
#   subcommand == clean     – clean does not compile; pin irrelevant
#   opam absent from PATH   – switch not managed here; nothing to assert
if [[ "${GITHUB_ACTIONS:-}" != "true" \
      && "${MASC_SKIP_PIN_CHECK:-0}" != "1" \
      && "${MASC_DUNE_DRY_RUN:-0}" != "1" \
      && "${_subcommand}" != "clean" ]]; then
  _pin_check="${repo_root}/scripts/check-oas-pin.sh"
  if [[ -x "${_pin_check}" ]] && command -v opam >/dev/null 2>&1; then
    printf '[dune-local] checking agent_sdk pin...\n' >&2
    if ! "${_pin_check}" --local-only >/dev/null; then
      printf '[dune-local] agent_sdk pin drift detected — aborting build\n' >&2
      printf '[dune-local] repair: bash scripts/opam-pin-external-deps.sh --install\n' >&2
      printf '[dune-local] set MASC_SKIP_PIN_CHECK=1 to bypass this guard\n' >&2
      exit 1
    fi
    printf '[dune-local] agent_sdk pin OK\n' >&2
  fi
fi
# -----------------------------------------------------------------------

# --- core opam-deps installed guard ------------------------------------
# Catch the "deps declared but not installed" failure mode before Dune
# emits a wall of cryptic abstract-cmi errors:
#
#   Error: Unbound module Httpun
#   Type Httpun.Method.t is abstract because no corresponding cmi file
#   was found in path.
#
# Pin guard above checks that agent_sdk *would resolve to* the right
# SHA, but does not catch the case where the operator added a new opam
# switch and forgot `opam install . --deps-only -y`.  Hardcoded list
# covers the four packages whose absence produces the worst error
# spew; full validation belongs to opam itself (the wrapper deliberately
# stays cheap).
#
# Skipped under the same envelope as the pin guard plus
# MASC_SKIP_DEPS_CHECK=1.
if [[ "${GITHUB_ACTIONS:-}" != "true" \
      && "${MASC_SKIP_DEPS_CHECK:-0}" != "1" \
      && "${MASC_DUNE_DRY_RUN:-0}" != "1" \
      && "${_subcommand}" != "clean" ]]; then
  if command -v opam >/dev/null 2>&1; then
    _core_deps=(httpun httpun-eio httpun-ws agent_sdk)
    _missing=()
    for _pkg in "${_core_deps[@]}"; do
      if ! opam list --installed --short "${_pkg}" 2>/dev/null \
           | grep -qx "${_pkg}"; then
        _missing+=("${_pkg}")
      fi
    done
    if [[ ${#_missing[@]} -gt 0 ]]; then
      printf '[dune-local] missing opam packages in switch %s: %s\n' \
        "$(opam switch show 2>/dev/null || echo '?')" \
        "${_missing[*]}" >&2
      printf '[dune-local] symptom you would otherwise see:\n' >&2
      printf '[dune-local]   Error: Unbound module <Pkg>\n' >&2
      printf '[dune-local]   Type <Pkg>.<T>.t is abstract because no corresponding cmi file...\n' >&2
      printf '[dune-local] repair: opam install . --deps-only -y\n' >&2
      printf '[dune-local] set MASC_SKIP_DEPS_CHECK=1 to bypass this guard\n' >&2
      exit 1
    fi
  fi
fi
# -----------------------------------------------------------------------

# --- OCaml minimum version guard ---------------------------------------
# dune-project line 28 and masc_mcp.opam line 14 both declare a 5.4
# floor.  Older switches build the early lib/ deps fine but fail later
# during opam dependency resolution or in stdlib calls added between
# 5.1 and 5.4.  Catch the mismatch up-front so the error mentions the
# real floor rather than the trailing symptom (e.g. an "Unbound value"
# from a 5.4-only stdlib API).
if [[ "${GITHUB_ACTIONS:-}" != "true" \
      && "${MASC_SKIP_OCAML_VERSION_CHECK:-0}" != "1" \
      && "${MASC_DUNE_DRY_RUN:-0}" != "1" \
      && "${_subcommand}" != "clean" ]]; then
  if command -v ocaml >/dev/null 2>&1; then
    _ocaml_v="$(ocaml -version 2>/dev/null \
                | sed -nE 's/.*version ([0-9]+\.[0-9]+).*/\1/p')"
    if [[ -n "${_ocaml_v}" ]]; then
      _major="${_ocaml_v%%.*}"
      _minor="${_ocaml_v##*.}"
      if [[ "${_major}" -lt 5 \
            || ( "${_major}" -eq 5 && "${_minor}" -lt 4 ) ]]; then
        printf '[dune-local] OCaml %s detected; this repo requires >= 5.4 (dune-project:28, masc_mcp.opam:14)\n' \
          "${_ocaml_v}" >&2
        printf '[dune-local] symptom under older switch: opam dep resolution fails or stdlib API missing\n' >&2
        printf '[dune-local] repair (run each line in turn):\n' >&2
        printf '[dune-local]   opam switch create 5.4.1\n' >&2
        printf '[dune-local]   eval $(opam env)\n' >&2
        printf '[dune-local]   opam install . --deps-only -y\n' >&2
        printf '[dune-local] set MASC_SKIP_OCAML_VERSION_CHECK=1 to bypass this guard\n' >&2
        exit 1
      fi
    fi
  fi
fi
# -----------------------------------------------------------------------

printf '[dune-local] DUNE_JOBS=%s DUNE_BUILD_DIR=%s\n' \
  "${DUNE_JOBS:-auto}" "${DUNE_BUILD_DIR:-_build}" >&2
printf '[dune-local] command:' >&2
printf ' %q' "${cmd[@]}" >&2
printf '\n' >&2

if [[ "${MASC_DUNE_DRY_RUN:-0}" = "1" ]]; then
  exit 0
fi

if [[ "${GITHUB_ACTIONS:-}" = "true" || "${MASC_DUNE_THROTTLE:-1}" = "0" ]]; then
  exec "${cmd[@]}"
fi

printf '[dune-local] waiting for lock %s\n' "$lock_path" >&2
if command -v lockf >/dev/null 2>&1; then
  exec lockf "$lock_path" "${cmd[@]}"
elif command -v flock >/dev/null 2>&1; then
  exec flock "$lock_path" "${cmd[@]}"
else
  printf '[dune-local] warning: neither lockf nor flock found; running unlocked\n' >&2
  exec "${cmd[@]}"
fi
