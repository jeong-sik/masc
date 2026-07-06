#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
lock_path="${DUNE_LOCAL_LOCK:-/tmp/me-dune-local.lock}"
opam_lock_path="${MASC_OPAM_LOCK_PATH:-/tmp/me-opam-switch.lock}"

usage() {
  cat <<'USAGE'
Usage: scripts/dune-local.sh [dune-subcommand] [args...]

Local Dune wrapper for multi-agent development:
  - serializes local Dune invocations with a machine-wide lock
  - serializes opam switch validation with opam pin mutations
  - defaults local concurrency to DUNE_LOCAL_JOBS, or 2
  - disables the shared Dune artifact cache by default for local builds
  - injects --root <repo-root> unless --root is already present
  - asserts agent_sdk opam pin matches the repo SSOT before each build
  - asserts core opam dependencies are installed in the active switch
  - asserts OCaml is at or above the repo floor (5.5)

Set MASC_DUNE_THROTTLE=0 to bypass the local lock.
Set MASC_DUNE_CACHE=enabled or enabled-except-user-rules to opt into the shared Dune cache.
Set MASC_OPAM_LOCK=0 or MASC_SKIP_OPAM_LOCK=1 to bypass the shared opam switch lock.
Set MASC_OPAM_LOCK_PATH=/path/to/lock to override the shared opam lock path.
Set MASC_OPAM_LOCK_AFTER_DUNE_TIMEOUT=seconds to bound opam-lock wait after the Dune lock (0 = wait forever).
Set MASC_DUNE_LOCK_DIAG=0 to suppress best-effort lock holder diagnostics.
Set MASC_DUNE_DRY_RUN=1 to print the command without running it.
Set MASC_DUNE_ALLOW_LIVE_BUILD_LOCK=1 to wait behind a live _build/.lock holder.
Set MASC_DUNE_ALLOW_BARE_DUNE=1 to run despite a live Dune process outside this wrapper.
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
# Two follow-up reviews (P2, 2026-05-05):
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
script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
dune_lock_warning_emitted=0

_needs_dune_lock() {
  [[ "${GITHUB_ACTIONS:-}" != "true" ]] || return 1
  [[ "${MASC_DUNE_THROTTLE:-1}" != "0" ]] || return 1
  [[ "${MASC_DUNE_DRY_RUN:-0}" != "1" ]] || return 1
  [[ "${MASC_DUNE_LOCK_HELD:-0}" != "1" ]] || return 1
  return 0
}

_print_lock_holders() {
  local lock_file="$1"
  local label="$2"
  [[ "${MASC_DUNE_LOCK_DIAG:-1}" != "0" ]] || return 0
  command -v lsof >/dev/null 2>&1 || return 0
  command -v ps >/dev/null 2>&1 || return 0

  local pids
  pids="$(lsof -t "$lock_file" 2>/dev/null | sort -u || true)"
  [[ -n "$pids" ]] || return 0

  printf '[dune-local] %s lock holder(s):\n' "$label" >&2
  local pid row
  while IFS= read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    row="$(ps -p "$pid" -o pid=,ppid=,stat=,etime=,command= 2>/dev/null || true)"
    if [[ -n "$row" ]]; then
      printf '[dune-local]   %s\n' "$row" >&2
    else
      printf '[dune-local]   pid=%s (process exited before ps snapshot)\n' "$pid" >&2
    fi
  done <<< "$pids"
}

_list_unwrapped_dune_processes() {
  command -v ps >/dev/null 2>&1 || return 0

  ps ax -o pid=,ppid=,command= 2>/dev/null \
    | awk '
        /^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+/ {
          pid = $1
          ppid = $2
          $1 = ""
          $2 = ""
          sub(/^[[:space:]]+/, "", $0)
          parent[pid] = ppid
          cmd[pid] = $0
        }

        function has_wrapper_ancestor(pid, cur, depth) {
          cur = pid
          depth = 0
          while ((cur in cmd) && depth < 64) {
            if (cmd[cur] ~ /dune-local[.]sh/ ||
                cmd[cur] ~ /me-dune-local[.]lock/ ||
                cmd[cur] ~ /MASC_DUNE_LOCK_HELD=1/) {
              return 1
            }
            cur = parent[cur]
            depth++
          }
          return 0
        }

        function basename(token, parts, n) {
          n = split(token, parts, "/")
          return parts[n]
        }

        function is_dune_subcommand(token) {
          return token == "build" || token == "test" || token == "exec" || token == "runtest" || token == "clean"
        }

        function is_dune_option(token) {
          return token ~ /^--[[:alnum:]][[:alnum:]_-]*(=.*)?$/ ||
                 token ~ /^-[[:alnum:]][[:alnum:]_-]*$/
        }

        function dune_subcommand_index(argc, argv, dune_index, i, token) {
          i = dune_index + 1
          while (i <= argc) {
            token = argv[i]
            if (is_dune_subcommand(token)) {
              return i
            } else if (token ~ /^--[[:alnum:]][[:alnum:]_-]*=/) {
              i++
            } else if (is_dune_option(token) && i + 1 <= argc && !is_dune_subcommand(argv[i + 1]) && argv[i + 1] !~ /^-/) {
              i += 2
            } else if (is_dune_option(token)) {
              i++
            } else {
              return 0
            }
          }
          return 0
        }

        function is_dune_command(text, argv, argc, i) {
          argc = split(text, argv, /[[:space:]]+/)
          if (argc < 2) {
            return 0
          }
          if (basename(argv[1]) == "dune") {
            return dune_subcommand_index(argc, argv, 1) > 0
          }
          if (basename(argv[1]) == "opam" && argv[2] == "exec") {
            for (i = 3; i <= argc; i++) {
              if (basename(argv[i]) == "dune") {
                return dune_subcommand_index(argc, argv, i) > 0
              }
            }
          }
          return 0
        }

        END {
          for (pid in cmd) {
            if (is_dune_command(cmd[pid]) && !has_wrapper_ancestor(pid)) {
              printf "%s %s %s\n", pid, parent[pid], cmd[pid]
            }
          }
        }'
}

_check_unwrapped_dune_processes() {
  [[ "${GITHUB_ACTIONS:-}" != "true" ]] || return 0
  [[ "${MASC_DUNE_DRY_RUN:-0}" != "1" ]] || return 0
  [[ "${MASC_DUNE_ALLOW_BARE_DUNE:-0}" != "1" ]] || return 0
  [[ "${_subcommand}" != "clean" ]] || return 0

  local rows
  rows="$(_list_unwrapped_dune_processes || true)"
  [[ -n "$rows" ]] || return 0

  printf '[dune-local] live Dune process outside scripts/dune-local.sh detected:\n' >&2
  printf '%s\n' "$rows" | sed 's/^/[dune-local]   /' >&2
  printf '[dune-local] refusing to start another local build while the machine-wide Dune lock is bypassed\n' >&2
  printf '[dune-local] stop the bare Dune process, rerun it via scripts/dune-local.sh, or set MASC_DUNE_ALLOW_BARE_DUNE=1 to proceed anyway\n' >&2
  exit 75
}

_check_unwrapped_dune_processes

# Acquire the build throttle before the opam-switch lock.  The opam lock is
# intentionally held while the active build uses the shared switch, but queued
# builds must not hold it while waiting for the Dune throttle; otherwise stale
# worktrees can block pin repair before they are actually compiling.
if _needs_dune_lock; then
  printf '[dune-local] waiting for lock %s\n' "$lock_path" >&2
  _print_lock_holders "$lock_path" "Dune"
  env_cmd="${ENV_CMD:-/usr/bin/env}"
  if command -v lockf >/dev/null 2>&1; then
    exec lockf -k "$lock_path" "$env_cmd" MASC_DUNE_LOCK_HELD=1 "$script_path" "$@"
  elif command -v flock >/dev/null 2>&1; then
    exec flock "$lock_path" "$env_cmd" MASC_DUNE_LOCK_HELD=1 "$script_path" "$@"
  else
    printf '[dune-local] warning: neither lockf nor flock found; running unlocked\n' >&2
    dune_lock_warning_emitted=1
  fi
fi

_check_unwrapped_dune_processes

_needs_opam_lock() {
  [[ "${GITHUB_ACTIONS:-}" != "true" ]] || return 1
  [[ "${MASC_OPAM_LOCK:-1}" != "0" ]] || return 1
  [[ "${MASC_SKIP_OPAM_LOCK:-0}" != "1" ]] || return 1
  [[ "${MASC_DUNE_DRY_RUN:-0}" != "1" ]] || return 1
  [[ "${_subcommand}" != "clean" ]] || return 1
  [[ "${MASC_OPAM_LOCK_HELD:-0}" != "1" ]] || return 1
  command -v opam >/dev/null 2>&1 || return 1
  return 0
}

if _needs_opam_lock; then
  printf '[dune-local] waiting for opam switch lock %s\n' "$opam_lock_path" >&2
  _print_lock_holders "$opam_lock_path" "opam switch"
  # Apply the bounded-wait deadlock guard whenever this invocation is
  # already holding the Dune lock AND the operator opted in by setting
  # MASC_OPAM_LOCK_AFTER_DUNE_TIMEOUT=<positive integer>. Default is
  # unset, which preserves the historical "wait indefinitely" semantics
  # so existing operators are not surprised by builds that suddenly
  # fail under long-lived opam lock holders.
  opam_bounded_wait=0
  opam_lock_timeout=""
  if [[ "${MASC_DUNE_LOCK_HELD:-0}" = "1" \
        && -n "${MASC_OPAM_LOCK_AFTER_DUNE_TIMEOUT:-}" ]]; then
    opam_lock_timeout="${MASC_OPAM_LOCK_AFTER_DUNE_TIMEOUT}"
    if ! [[ "$opam_lock_timeout" =~ ^[0-9]+$ ]]; then
      printf '[dune-local] invalid MASC_OPAM_LOCK_AFTER_DUNE_TIMEOUT=%q; expected non-negative integer seconds\n' \
        "$opam_lock_timeout" >&2
      exit 2
    fi
    opam_lock_timeout="$((10#$opam_lock_timeout))"
    if (( opam_lock_timeout > 0 )); then
      opam_bounded_wait=1
    fi
  fi
  if command -v lockf >/dev/null 2>&1; then
    if [[ "$opam_bounded_wait" = "1" ]]; then
      set +e
      env_cmd="${ENV_CMD:-/usr/bin/env}"
      lockf -k -t "$opam_lock_timeout" "$opam_lock_path" \
        "$env_cmd" MASC_OPAM_LOCK_HELD=1 "$script_path" "$@"
      status=$?
      set -e
      if [[ "$status" -eq 0 ]]; then
        exit 0
      fi
      if [[ "$status" -eq 75 ]]; then
        printf '[dune-local] opam switch lock stayed busy for %ss after acquiring Dune lock; releasing Dune lock to avoid mixed lock-order deadlock\n' \
          "$opam_lock_timeout" >&2
        printf '[dune-local] retry after older dune-local invocations drain, or unset MASC_OPAM_LOCK_AFTER_DUNE_TIMEOUT (or set =0) to wait indefinitely\n' >&2
      fi
      exit "$status"
    fi
    env_cmd="${ENV_CMD:-/usr/bin/env}"
    exec lockf -k "$opam_lock_path" "$env_cmd" MASC_OPAM_LOCK_HELD=1 "$script_path" "$@"
  elif command -v flock >/dev/null 2>&1; then
    if [[ "$opam_bounded_wait" = "1" ]]; then
      # flock(1) honors -w/--timeout to bound the wait; without it the
      # mixed-lock-order deadlock the lockf branch above already handles
      # would resurface on flock-only hosts (Linux without lockf).
      set +e
      env_cmd="${ENV_CMD:-/usr/bin/env}"
      flock -w "$opam_lock_timeout" "$opam_lock_path" \
        "$env_cmd" MASC_OPAM_LOCK_HELD=1 "$script_path" "$@"
      status=$?
      set -e
      if [[ "$status" -eq 0 ]]; then
        exit 0
      fi
      # flock returns 1 when the lock cannot be acquired within the
      # timeout (vs >1 for command failures). Match the lockf message
      # so operators see consistent diagnostics across hosts.
      if [[ "$status" -eq 1 ]]; then
        printf '[dune-local] opam switch lock stayed busy for %ss after acquiring Dune lock; releasing Dune lock to avoid mixed lock-order deadlock\n' \
          "$opam_lock_timeout" >&2
        printf '[dune-local] retry after older dune-local invocations drain, or unset MASC_OPAM_LOCK_AFTER_DUNE_TIMEOUT (or set =0) to wait indefinitely\n' >&2
      fi
      exit "$status"
    fi
    env_cmd="${ENV_CMD:-/usr/bin/env}"
    exec flock "$opam_lock_path" "$env_cmd" MASC_OPAM_LOCK_HELD=1 "$script_path" "$@"
  elif [[ "$dune_lock_warning_emitted" != "1" ]]; then
    # Skip the warning when the Dune-lock branch above already printed
    # an equivalent "neither lockf nor flock found" message in this
    # process. The Dune-lock branch tracks that via the local
    # [dune_lock_warning_emitted] flag (not MASC_DUNE_LOCK_HELD, which
    # is only set when the Dune lock was actually acquired); using the
    # flag avoids the case where opam is available but neither lock
    # tool is, where the env-var check would let both warnings print.
    printf '[dune-local] warning: neither lockf nor flock found; opam switch checks are unlocked\n' >&2
  fi
fi

if [[ "${GITHUB_ACTIONS:-}" != "true" ]]; then
  export DUNE_JOBS="${DUNE_JOBS:-${DUNE_LOCAL_JOBS:-2}}"
  export DUNE_BUILD_DIR="${DUNE_BUILD_DIR:-$repo_root/_build}"
  # The shared Dune cache can return native artifacts compiled against an
  # older local opam pin, which then link with fresh CMIs and fail with
  # "make inconsistent assumptions over interface". Local wrapper builds
  # favor deterministic rebuilds; operators can opt back in explicitly.
  export DUNE_CACHE="${MASC_DUNE_CACHE:-disabled}"
fi

# --- stale Dune lock/RPC cleanup ----------------------------------------
# Dune uses `_build/.lock` (0-byte) for exclusive build-dir access and
# `~/.local/share/dune/rpc/<pid>.csexp` sockets for RPC daemon
# communication.  When Dune crashes or is killed, both can linger and
# cause subsequent builds to hang (scheduler event-loop wait on a dead
# socket, or exclusive-lock spin on a stale file).
#
# This guard removes stale artifacts when no live Dune process holds them.
# It runs after the machine-wide dune-local lock is acquired, so no other
# dune-local.sh wrapper is active — but a bare `dune` invocation outside
# the wrapper could still hold them.
#
# Skipped when:
#   GITHUB_ACTIONS=true     – CI builds are clean-workspace
#   MASC_DUNE_DRY_RUN=1     – dry-run never mutates state
#   subcommand == clean     – clean removes everything anyway
#   MASC_SKIP_STALE_CLEANUP=1 – operator opt-out
#   MASC_DUNE_ALLOW_LIVE_BUILD_LOCK=1 – operator opts into waiting
#       behind a live build-dir lock holder (usually bare `dune`)
if [[ "${GITHUB_ACTIONS:-}" != "true" \
      && "${MASC_DUNE_DRY_RUN:-0}" != "1" \
      && "${MASC_SKIP_STALE_CLEANUP:-0}" != "1" \
      && "${_subcommand}" != "clean" ]]; then
  _build_lock="${DUNE_BUILD_DIR:-$repo_root/_build}/.lock"
  if [[ -f "${_build_lock}" ]]; then
    _lock_holders=""
    _lock_probe=0
    if command -v lsof >/dev/null 2>&1; then
      _lock_probe=1
      _lock_holders="$(lsof -t "${_build_lock}" 2>/dev/null | sort -u || true)"
    fi
    if [[ "${_lock_probe}" -eq 1 && -n "${_lock_holders}" ]]; then
      printf '[dune-local] live Dune build-dir lock holder(s) on %s\n' \
        "${_build_lock}" >&2
      _print_lock_holders "${_build_lock}" "Dune build-dir"
      if [[ "${MASC_DUNE_ALLOW_LIVE_BUILD_LOCK:-0}" != "1" ]]; then
        printf '[dune-local] refusing to wait behind a live _build/.lock holder outside the local wrapper\n' >&2
        printf '[dune-local] stop the bare `dune` process or set MASC_DUNE_ALLOW_LIVE_BUILD_LOCK=1 to wait anyway\n' >&2
        exit 75
      fi
      printf '[dune-local] continuing because MASC_DUNE_ALLOW_LIVE_BUILD_LOCK=1\n' >&2
    elif [[ "${_lock_probe}" -eq 1 ]]; then
      printf '[dune-local] removing stale _build/.lock (no dune process running)\n' >&2
      rm -f "${_build_lock}"
    else
      _has_dune=0
      if command -v pgrep >/dev/null 2>&1; then
        if pgrep -x dune >/dev/null 2>&1; then _has_dune=1; fi
      elif command -v ps >/dev/null 2>&1; then
        if ps aux 2>/dev/null | grep -q '[d]une'; then _has_dune=1; fi
      fi
      if [[ "${_has_dune}" -eq 0 ]]; then
        printf '[dune-local] removing stale _build/.lock (no dune process running)\n' >&2
        rm -f "${_build_lock}"
      fi
    fi
  fi
  # Stale RPC daemon sockets: ~/.local/share/dune/rpc/<pid>.csexp
  # If the PID in the filename is not a running process, the daemon is dead.
  _rpc_dir="${HOME}/.local/share/dune/rpc"
  if [[ -d "${_rpc_dir}" ]]; then
    for _socket in "${_rpc_dir}"/*.csexp; do
      [[ -f "${_socket}" ]] || continue
      _rpc_pid="${_socket##*/}"
      _rpc_pid="${_rpc_pid%.csexp}"
      if [[ -n "${_rpc_pid}" ]] && ! kill -0 "${_rpc_pid}" 2>/dev/null; then
        printf '[dune-local] removing stale RPC socket %s (pid %s dead)\n' \
          "${_socket}" "${_rpc_pid}" >&2
        rm -f "${_socket}"
      fi
    done
  fi
fi
# -----------------------------------------------------------------------

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

# --- auto-clean stale _build on agent_sdk pin change -------------------
# Dune does not track opam pin identity in its incremental cache.  When
# agent_sdk is repinned (e.g. by another worktree's build), the .cmx
# artifacts in _build/ still reference the old pin's CMI signatures.
# This produces "inconsistent assumptions over implementation" errors.
#
# Compare the SSOT pin SHA against a marker file in _build/.  On
# mismatch, auto-clean before the build proceeds.  The marker is written
# after every successful pin guard pass so it stays current.
#
# Skipped when:
#   GITHUB_ACTIONS=true     – CI builds are clean-workspace
#   MASC_DUNE_DRY_RUN=1     – dry-run never mutates _build
#   subcommand == clean     – clean already removes everything
#   MASC_SKIP_PIN_CHECK=1   – without pin check, marker is meaningless
if [[ "${GITHUB_ACTIONS:-}" != "true" \
      && "${MASC_DUNE_DRY_RUN:-0}" != "1" \
      && "${MASC_SKIP_PIN_CHECK:-0}" != "1" \
      && "${_subcommand}" != "clean" ]]; then
  _pin_sha_source="${repo_root}/scripts/oas-agent-sdk-pin.sh"
  if [[ -f "${_pin_sha_source}" ]]; then
    # shellcheck source=/dev/null
    source "${_pin_sha_source}" 2>/dev/null || true
    if [[ -n "${OAS_AGENT_SDK_SHA:-}" ]]; then
      _build_marker="${DUNE_BUILD_DIR:-$repo_root/_build}/.last-agent-sdk-sha"
      if [[ -f "${_build_marker}" ]]; then
        _last_sha="$(cat "${_build_marker}")"
        if [[ "${_last_sha}" != "${OAS_AGENT_SDK_SHA}" ]]; then
          printf '[dune-local] agent_sdk pin changed (%.8s → %.8s) — cleaning stale _build artifacts\n' \
            "${_last_sha}" "${OAS_AGENT_SDK_SHA}" >&2
          if [[ -d "${DUNE_BUILD_DIR:-$repo_root/_build}" ]]; then
            rm -rf "${DUNE_BUILD_DIR:-$repo_root/_build}"
          fi
        fi
      fi
      mkdir -p "$(dirname "${_build_marker}")" 2>/dev/null || true
      printf '%s' "${OAS_AGENT_SDK_SHA}" > "${_build_marker}"
    fi
  fi
fi
# -----------------------------------------------------------------------

# --- auto-clean stale _build on installed agent_sdk interface change ----
# The pin guard can be intentionally bypassed during local surgery with
# MASC_SKIP_PIN_CHECK=1.  Even then, the shared opam switch may have moved
# from one agent_sdk build to another while _build still contains CMIs
# compiled against the previous Llm_provider interfaces.  Track the actual
# installed Provider_config and Provider_kind CMI checksums and clear _build
# when they change, before Dune can produce a cascade of stale alias or
# "inconsistent assumptions" diagnostics.
#
# This guard is intentionally independent of MASC_SKIP_PIN_CHECK.  It does
# not prove the pin is correct; it only keeps the current build directory
# internally consistent with whatever agent_sdk is installed right now.
_current_agent_sdk_llm_provider_crc() {
  local module_name="$1"
  local unit_name="Llm_provider__${module_name}"
  command -v ocamlobjinfo >/dev/null 2>&1 || return 1

  local llm_provider_dir cmi_path
  if command -v ocamlfind >/dev/null 2>&1; then
    llm_provider_dir="$(ocamlfind query agent_sdk.llm_provider 2>/dev/null || true)"
  elif command -v opam >/dev/null 2>&1; then
    llm_provider_dir="$(opam exec -- ocamlfind query agent_sdk.llm_provider 2>/dev/null || true)"
  else
    return 1
  fi

  [[ -n "${llm_provider_dir}" ]] || return 1
  cmi_path="${llm_provider_dir%/}/llm_provider__${module_name}.cmi"
  [[ -r "${cmi_path}" ]] || return 1

  ocamlobjinfo "${cmi_path}" 2>/dev/null \
    | awk -v unit="${unit_name}" '$2 == unit { print $1; found = 1; exit }
           END { if (!found) exit 1 }'
}

if [[ "${GITHUB_ACTIONS:-}" != "true" \
      && "${MASC_DUNE_DRY_RUN:-0}" != "1" \
      && "${_subcommand}" != "clean" ]]; then
  _agent_sdk_interface_build_dir="${DUNE_BUILD_DIR:-$repo_root/_build}"
  _agent_sdk_interface_markers=()
  _agent_sdk_interface_crcs=()
  _agent_sdk_interface_changed=0
  for _agent_sdk_interface in Provider_config Provider_kind; do
    _agent_sdk_interface_crc="$(_current_agent_sdk_llm_provider_crc "${_agent_sdk_interface}" || true)"
    [[ -n "${_agent_sdk_interface_crc}" ]] || continue
    case "${_agent_sdk_interface}" in
      Provider_config)
        _agent_sdk_interface_marker="${_agent_sdk_interface_build_dir}/.last-agent-sdk-provider-config-crc"
        ;;
      Provider_kind)
        _agent_sdk_interface_marker="${_agent_sdk_interface_build_dir}/.last-agent-sdk-provider-kind-crc"
        ;;
      *)
        continue
        ;;
    esac
    _agent_sdk_interface_markers+=("${_agent_sdk_interface_marker}")
    _agent_sdk_interface_crcs+=("${_agent_sdk_interface_crc}")
    if [[ -f "${_agent_sdk_interface_marker}" ]]; then
      _last_agent_sdk_interface_crc="$(cat "${_agent_sdk_interface_marker}" 2>/dev/null || true)"
      if [[ -n "${_last_agent_sdk_interface_crc}" \
            && "${_last_agent_sdk_interface_crc}" != "${_agent_sdk_interface_crc}" ]]; then
        printf '[dune-local] agent_sdk %s interface changed (%.8s -> %.8s) - cleaning stale _build artifacts\n' \
          "${_agent_sdk_interface}" \
          "${_last_agent_sdk_interface_crc}" \
          "${_agent_sdk_interface_crc}" >&2
        _agent_sdk_interface_changed=1
      fi
    fi
  done
  if [[ "${_agent_sdk_interface_changed}" -eq 1 ]]; then
    rm -rf "${_agent_sdk_interface_build_dir}"
  fi
  if [[ "${#_agent_sdk_interface_markers[@]}" -gt 0 ]]; then
    mkdir -p "${_agent_sdk_interface_build_dir}" 2>/dev/null || true
    for _agent_sdk_interface_i in "${!_agent_sdk_interface_markers[@]}"; do
      printf '%s' "${_agent_sdk_interface_crcs[${_agent_sdk_interface_i}]}" \
        > "${_agent_sdk_interface_markers[${_agent_sdk_interface_i}]}"
    done
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
# dune-project line 28 and masc.opam line 14 both declare a 5.5
# floor.  Older switches build the early lib/ deps fine but fail later
# during opam dependency resolution or in stdlib calls added between
# 5.1 and 5.5.  Catch the mismatch up-front so the error mentions the
# real floor rather than the trailing symptom (e.g. an "Unbound value"
# from a 5.5-only stdlib API).
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
        printf '[dune-local] OCaml %s detected; this repo requires >= 5.5 (dune-project:28, masc.opam:14)\n' \
          "${_ocaml_v}" >&2
        printf '[dune-local] symptom under older switch: opam dep resolution fails or stdlib API missing\n' >&2
        printf '[dune-local] repair (run each line in turn):\n' >&2
        printf '[dune-local]   opam switch create 5.5.0\n' >&2
        printf '[dune-local]   eval $(opam env)\n' >&2
        printf '[dune-local]   opam install . --deps-only -y\n' >&2
        printf '[dune-local] set MASC_SKIP_OCAML_VERSION_CHECK=1 to bypass this guard\n' >&2
        exit 1
      fi
    fi
  fi
fi
# -----------------------------------------------------------------------

printf '[dune-local] DUNE_JOBS=%s DUNE_BUILD_DIR=%s DUNE_CACHE=%s\n' \
  "${DUNE_JOBS:-auto}" "${DUNE_BUILD_DIR:-_build}" "${DUNE_CACHE:-default}" >&2
printf '[dune-local] command:' >&2
printf ' %q' "${cmd[@]}" >&2
printf '\n' >&2

if [[ "${MASC_DUNE_DRY_RUN:-0}" = "1" ]]; then
  exit 0
fi

if [[ "${GITHUB_ACTIONS:-}" = "true" \
      || "${MASC_DUNE_THROTTLE:-1}" = "0" \
      || "${MASC_DUNE_LOCK_HELD:-0}" = "1" ]]; then
  exec "${cmd[@]}"
fi

if [[ "$dune_lock_warning_emitted" -eq 0 ]]; then
  printf '[dune-local] warning: neither lockf nor flock found; running unlocked\n' >&2
fi
exec "${cmd[@]}"
