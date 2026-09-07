#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
repo_lock_key="$(printf '%s' "${repo_root}" | cksum | awk '{print $1}')"
lock_path="${DUNE_LOCAL_LOCK:-${TMPDIR:-/tmp}/masc-dune-${UID:-$(id -u)}-${repo_lock_key}.lock}"

usage() {
  cat <<'USAGE'
Usage: scripts/dune-local.sh [dune-subcommand] [args...]

Local Dune wrapper for multi-agent development:
  - serializes Dune invocations only inside the same worktree
  - shares one read lease across builds while excluding opam switch mutations
  - defaults local concurrency to DUNE_JOBS, or 2
  - disables the shared Dune artifact cache by default for local builds
  - injects --root <repo-root> unless --root is already present
  - asserts the shell and opam resolve one coherent toolchain
  - asserts required findlib libraries are installed in the active switch
  - asserts OCaml exactly matches the repo version declared in dune-project

Set MASC_DUNE_THROTTLE=0 to bypass the local lock.
Set MASC_DUNE_CACHE=enabled or enabled-except-user-rules to opt into the shared Dune cache.
Set MASC_DUNE_LOCK_DIAG=0 to suppress best-effort lock holder diagnostics.
Set MASC_DUNE_DRY_RUN=1 to print the command without running it.
Set MASC_DUNE_ALLOW_LIVE_BUILD_LOCK=1 to wait behind a live _build/.lock holder.
Set MASC_SKIP_DEPS_CHECK=1 to skip the required-findlib guard.
Set MASC_SKIP_OCAML_VERSION_CHECK=1 to skip the exact OCaml toolchain guard.
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

# This throttle is scoped by the canonical worktree path. Dune already gives
# each worktree its own build directory, so unrelated Keepers do not queue here.
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

_needs_opam_read_lease() {
  [[ "${GITHUB_ACTIONS:-}" != "true" ]] || return 1
  [[ "${MASC_DUNE_DRY_RUN:-0}" != "1" ]] || return 1
  [[ "${_subcommand}" != "clean" ]] || return 1
  [[ "${MASC_OPAM_READ_LEASE_HELD:-0}" != "1" ]] || return 1
  command -v opam >/dev/null 2>&1 || return 1
  return 0
}

if _needs_opam_read_lease; then
  exec "$(dirname "${script_path}")/opam-switch-rw-lock.sh" \
    read -- "${ENV_CMD:-/usr/bin/env}" MASC_OPAM_READ_LEASE_HELD=1 \
    "${script_path}" "$@"
fi

if [[ "${GITHUB_ACTIONS:-}" != "true" ]]; then
  # DUNE_LOCAL_JOBS was retired (masc#25123 Wave 2): DUNE_JOBS is the single
  # concurrency knob (CI sets it directly; start-masc.sh derives it from
  # MASC_DUNE_JOBS).
  if [[ -n "${DUNE_LOCAL_JOBS:-}" && -z "${DUNE_JOBS:-}" ]]; then
    echo "[dune-local] DUNE_LOCAL_JOBS is retired and ignored; set DUNE_JOBS" >&2
  fi
  export DUNE_JOBS="${DUNE_JOBS:-2}"
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
# It runs after the worktree-local wrapper lock is acquired. Other worktrees
# use independent build directories and do not participate in this decision.
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

# --- exact OCaml toolchain guard ---------------------------------------
# MASC supports one compiler version.  Verify both the version and the
# identity of the active opam prefix before any findlib or pin inspection.
# This catches split-brain shells where `opam switch show` names one switch
# while PATH/OPAM_SWITCH_PREFIX still point at another.
if [[ "${GITHUB_ACTIONS:-}" != "true" \
      && "${MASC_SKIP_OCAML_VERSION_CHECK:-0}" != "1" \
      && "${MASC_DUNE_DRY_RUN:-0}" != "1" \
      && "${_subcommand}" != "clean" ]]; then
  _required_version="$(sed -nE '/^[[:space:]]*\(ocaml[[:space:]]+\(=[[:space:]]+([0-9]+\.[0-9]+\.[0-9]+)\)\).*$/ { s//\1/; p; q; }' \
    "${repo_root}/dune-project")"
  if [[ -z "${_required_version}" ]]; then
    printf '[dune-local] unable to read exact OCaml version from %s\n' \
      "${repo_root}/dune-project" >&2
    exit 1
  fi

  if ! command -v opam >/dev/null 2>&1; then
    printf '[dune-local] opam is unavailable; MASC requires an opam-managed OCaml %s switch\n' \
      "${_required_version}" >&2
    exit 1
  fi
  _opam_switch="$(opam switch show 2>/dev/null || true)"
  _opam_prefix="$(opam var prefix 2>/dev/null || true)"
  if [[ -z "${_opam_switch}" || -z "${_opam_prefix}" ]]; then
    printf '[dune-local] unable to resolve the active opam switch and prefix\n' >&2
    exit 1
  fi
  if [[ -n "${OPAM_SWITCH_PREFIX:-}" \
        && "${OPAM_SWITCH_PREFIX%/}" != "${_opam_prefix%/}" ]]; then
    printf '[dune-local] split opam environment: switch %s uses %s but OPAM_SWITCH_PREFIX=%s\n' \
      "${_opam_switch}" "${_opam_prefix}" "${OPAM_SWITCH_PREFIX}" >&2
    printf '%s\n' \
      "[dune-local] repair: eval \"\$(opam env --switch=${_required_version} --set-switch)\"" >&2
    exit 1
  fi
  for _tool in ocamlc dune ocamlfind; do
    _tool_path="$(command -v "${_tool}" 2>/dev/null || true)"
    if [[ -z "${_tool_path}" || "${_tool_path}" != "${_opam_prefix%/}/bin/"* ]]; then
      printf '[dune-local] split opam environment: %s resolves to %s, expected %s/bin/%s\n' \
        "${_tool}" "${_tool_path:-<missing>}" "${_opam_prefix%/}" "${_tool}" >&2
      printf '%s\n' \
        "[dune-local] repair: eval \"\$(opam env --switch=${_required_version} --set-switch)\"" >&2
      exit 1
    fi
  done

  if ! command -v ocamlc >/dev/null 2>&1; then
    printf '[dune-local] ocamlc is unavailable; this repo requires OCaml %s\n' \
      "${_required_version}" >&2
    exit 1
  fi
  _ocaml_v="$(ocamlc -version 2>/dev/null || true)"
  if [[ "${_ocaml_v}" != "${_required_version}" ]]; then
    printf '[dune-local] OCaml %s detected; this repo requires exactly %s (dune-project)\n' \
      "${_ocaml_v:-unknown}" "${_required_version}" >&2
    printf '[dune-local] repair (run each line in turn):\n' >&2
    printf '[dune-local]   opam switch create %s ocaml-base-compiler.%s\n' \
      "${_required_version}" "${_required_version}" >&2
    printf '%s\n' \
      "[dune-local]   eval \"\$(opam env --switch=${_required_version} --set-switch)\"" >&2
    printf '[dune-local]   bash scripts/opam-pin-external-deps.sh --install\n' >&2
    printf '[dune-local]   opam install . --deps-only --with-test -y\n' >&2
    printf '[dune-local] set MASC_SKIP_OCAML_VERSION_CHECK=1 to bypass this guard\n' >&2
    exit 1
  fi
fi
# -----------------------------------------------------------------------

# --- external pin guard ------------------------------------------------
# A pin added to scripts/opam-pin-external-deps.sh reaches a switch only when
# someone re-runs that script, and nothing told them to. cohttp-eio was
# pinned on 2026-09-05 (#33206) to stop a body flow that copies partial
# deliveries from offset 0 and silently corrupts SSE payloads; two days
# later the machine this guard was written on still carried the stock build,
# with every other pin in place. The findlib guard below cannot see it: the
# library resolves, it is just the wrong build of it.
#
# One `opam pin list` under the read lease this script already holds.
if [[ "${GITHUB_ACTIONS:-}" != "true" \
      && "${MASC_SKIP_DEPS_CHECK:-0}" != "1" \
      && "${MASC_DUNE_DRY_RUN:-0}" != "1" \
      && "${_subcommand}" != "clean" ]]; then
  _pin_script="$(dirname "${script_path}")/opam-pin-external-deps.sh"
  if [[ -f "${_pin_script}" ]] && command -v opam >/dev/null 2>&1; then
    if ! _pin_report="$(bash "${_pin_script}" --check 2>&1)"; then
      printf '%s\n' "${_pin_report}" >&2
      printf '[dune-local] set MASC_SKIP_DEPS_CHECK=1 to bypass this guard\n' >&2
      exit 1
    fi
  fi
fi
# -----------------------------------------------------------------------

# --- required findlib libraries guard ----------------------------------
# Catch absent packages and incompatible package API layouts before Dune
# emits a wall of cryptic library-resolution or abstract-cmi errors:
#
#   Error: Library "opentelemetry.client" not found
#   Error: Library "piaf.stream" not found
#   Error: Unbound module Httpun
#   Type Httpun.Method.t is abstract because no corresponding cmi file
#   was found in path.
#
# Query the actual findlib names consumed by Dune instead of only checking
# opam package names.  Package existence alone did not catch
# opentelemetry.0.91.1, which is installed successfully but does not expose
# the [opentelemetry.client] library consumed by MASC.
#
# Skipped under the same envelope as the pin guard plus
# MASC_SKIP_DEPS_CHECK=1.
if [[ "${GITHUB_ACTIONS:-}" != "true" \
      && "${MASC_SKIP_DEPS_CHECK:-0}" != "1" \
      && "${MASC_DUNE_DRY_RUN:-0}" != "1" \
      && "${_subcommand}" != "clean" ]]; then
  if command -v opam >/dev/null 2>&1; then
    _required_findlib=(
      httpun
      httpun-eio
      httpun-ws
      piaf
      piaf.stream
      opentelemetry.client
    )
    _missing=()
    for _library in "${_required_findlib[@]}"; do
      _library_path="$(opam exec -- ocamlfind query "${_library}" 2>/dev/null || true)"
      if [[ -z "${_library_path}" ]]; then
        _missing+=("${_library}")
      fi
    done
    if [[ ${#_missing[@]} -gt 0 ]]; then
      printf '[dune-local] missing or incompatible findlib libraries in switch %s: %s\n' \
        "$(opam switch show 2>/dev/null || echo '?')" \
        "${_missing[*]}" >&2
      printf '[dune-local] symptom you would otherwise see:\n' >&2
      printf '[dune-local]   Error: Library "<name>" not found\n' >&2
      printf '[dune-local] repair (run each line in turn):\n' >&2
      printf '[dune-local]   bash scripts/opam-pin-external-deps.sh --install\n' >&2
      printf '[dune-local]   opam install . --deps-only --with-test -y\n' >&2
      printf '[dune-local] set MASC_SKIP_DEPS_CHECK=1 to bypass this guard\n' >&2
      exit 1
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
