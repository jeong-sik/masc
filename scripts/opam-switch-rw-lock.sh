#!/usr/bin/env bash
set -euo pipefail

# Exit 75 is reserved for lease-admission rejection. After admission, the
# wrapped command's status (including 75) is forwarded unchanged; callers that
# need to distinguish them must also inspect the explicit admission diagnostic.

usage() {
  echo "usage: scripts/opam-switch-rw-lock.sh read|write -- command [args...]" >&2
  exit 2
}

mode="${1:-}"
shift
case "${mode}" in
  read|write)
    [[ "${1:-}" = "--" ]] || usage
    shift
    [[ "$#" -gt 0 ]] || usage
    ;;
  __run_read)
    reader_path="${1:-}"
    shift
    [[ -n "${reader_path}" && "${1:-}" = "--" ]] || usage
    shift
    [[ "$#" -gt 0 ]] || usage
    ;;
  __run_write)
    [[ "${1:-}" = "--" ]] || usage
    shift
    [[ "$#" -gt 0 ]] || usage
    ;;
  __admit_read)
    reader_path="${1:-}"
    reader_identity="${2:-}"
    [[ -n "${reader_path}" && -n "${reader_identity}" && "$#" -eq 2 ]] || usage
    ;;
  __admit_write)
    [[ "$#" -eq 0 ]] || usage
    ;;
  *)
    usage
    ;;
esac

switch_identity="${OPAM_SWITCH_PREFIX:-}"
if [[ -z "${switch_identity}" ]] && command -v opam >/dev/null 2>&1; then
  switch_identity="$(opam var prefix 2>/dev/null || true)"
fi
[[ -n "${switch_identity}" ]] || {
  echo "[opam-rw-lock] cannot resolve the active opam switch prefix" >&2
  exit 69
}

switch_key="$(printf '%s' "${switch_identity}" | cksum | awk '{print $1}')"
lock_base="${MASC_OPAM_LOCK_PATH:-${TMPDIR:-/tmp}/masc-opam-switch-${UID:-$(id -u)}-${switch_key}}"
gate_path="${lock_base}.gate"
state_dir="${lock_base}.state"
readers_dir="${state_dir}/readers"
writer_path="${state_dir}/writer"
script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
readonly gate_timeout_seconds=5

prepare_state_dir() {
  mkdir -p "${readers_dir}"
  chmod 700 "${state_dir}" "${readers_dir}"
}

lock_backend() {
  if command -v lockf >/dev/null 2>&1; then
    printf 'lockf\n'
  elif command -v flock >/dev/null 2>&1; then
    printf 'flock\n'
  else
    echo "[opam-rw-lock] neither lockf nor flock is available" >&2
    return 69
  fi
}

with_gate() {
  local backend=""
  local status=0
  backend="$(lock_backend)" || return $?
  set +e
  case "${backend}" in
    lockf)
      lockf -k -t "${gate_timeout_seconds}" "${gate_path}" "$@"
      status=$?
      ;;
    flock)
      flock -w "${gate_timeout_seconds}" -E 75 "${gate_path}" "$@"
      status=$?
      ;;
    *)
      echo "[opam-rw-lock] unknown lock backend ${backend}" >&2
      status=69
      ;;
  esac
  set -e
  if [[ "${status}" -eq 75 ]]; then
    echo "[opam-rw-lock] gate acquisition or lease admission rejected within ${gate_timeout_seconds}s" >&2
  fi
  return "${status}"
}

exec_holder() {
  local holder_mode="$1"
  local holder_path="$2"
  local backend=""
  shift 2
  backend="$(lock_backend)" || return $?
  case "${backend}" in
    lockf)
      exec lockf -k -t 0 "${holder_path}" "$@"
      ;;
    flock)
      exec flock -n -E 75 "${holder_path}" "$@"
      ;;
    *)
      echo "[opam-rw-lock] unknown lock backend ${backend}" >&2
      return 69
      ;;
  esac
}

probe_lock_state() {
  local path="$1"
  local backend=""
  local status=0
  backend="$(lock_backend)" || return $?
  set +e
  case "${backend}" in
    lockf)
      lockf -k -t 0 "${path}" true >/dev/null 2>&1
      status=$?
      ;;
    flock)
      flock -n -E 75 "${path}" true >/dev/null 2>&1
      status=$?
      ;;
    *) status=69 ;;
  esac
  set -e
  case "${status}" in
    0) printf 'free\n' ;;
    75) printf 'held\n' ;;
    *)
      echo "[opam-rw-lock] lock probe failed path=${path} exit=${status}" >&2
      return 69
      ;;
  esac
}

file_identity() {
  local path="$1"
  if stat -f '%d:%i' "${path}" >/dev/null 2>&1; then
    stat -f '%d:%i' "${path}"
  elif stat -c '%d:%i' "${path}" >/dev/null 2>&1; then
    stat -c '%d:%i' "${path}"
  else
    return 1
  fi
}

clean_stale_readers() {
  local reader_path=""
  local state=""
  for reader_path in "${readers_dir}"/*; do
    [[ -f "${reader_path}" ]] || continue
    state="$(probe_lock_state "${reader_path}")"
    if [[ "${state}" = "free" ]]; then
      rm -f "${reader_path}"
    fi
  done
}

active_reader_paths() {
  local reader_path=""
  local state=""
  for reader_path in "${readers_dir}"/*; do
    [[ -f "${reader_path}" ]] || continue
    state="$(probe_lock_state "${reader_path}")"
    if [[ "${state}" = "held" ]]; then
      printf '%s\n' "${reader_path}"
    fi
  done
}

admit_read() {
  local reader_path="$1"
  local expected_reader_identity="$2"
  local current_reader_identity=""
  local reader_state="free"
  local writer_state="free"
  clean_stale_readers
  current_reader_identity="$(file_identity "${reader_path}" 2>/dev/null || true)"
  if [[ -z "${current_reader_identity}" || "${current_reader_identity}" != "${expected_reader_identity}" ]]; then
    echo "[opam-rw-lock] reader lease path no longer names its locked inode; read lease rejected" >&2
    return 75
  fi
  reader_state="$(probe_lock_state "${reader_path}")"
  if [[ "${reader_state}" != "held" ]]; then
    echo "[opam-rw-lock] reader lease path is not held; read lease rejected" >&2
    return 75
  fi
  if [[ -f "${writer_path}" ]]; then
    writer_state="$(probe_lock_state "${writer_path}")"
    if [[ "${writer_state}" = "held" ]]; then
      echo "[opam-rw-lock] switch mutation is active; read lease rejected" >&2
      return 75
    fi
  fi
}

admit_write() {
  local readers=""
  clean_stale_readers
  readers="$(active_reader_paths)"
  if [[ -n "${readers}" ]]; then
    echo "[opam-rw-lock] switch readers are active holders=$(printf '%s' "${readers}" | tr '\n' ',')" >&2
    return 75
  fi
}

prepare_state_dir
case "${mode}" in
  read)
    reader_path="$(mktemp "${readers_dir%/}/reader.XXXXXX")"
    chmod 600 "${reader_path}"
    exec_holder read "${reader_path}" "${script_path}" __run_read "${reader_path}" -- "$@"
    ;;
  write)
    exec_holder write "${writer_path}" "${script_path}" __run_write -- "$@"
    ;;
  __run_read)
    reader_identity="$(file_identity "${reader_path}" 2>/dev/null || true)"
    if [[ -z "${reader_identity}" ]]; then
      echo "[opam-rw-lock] reader lease path disappeared before admission; read lease rejected" >&2
      exit 75
    fi
    with_gate "${script_path}" __admit_read "${reader_path}" "${reader_identity}"
    export MASC_OPAM_READ_LEASE_HELD=1
    exec "$@"
    ;;
  __run_write)
    with_gate "${script_path}" __admit_write
    export MASC_OPAM_WRITE_LEASE_HELD=1
    exec "$@"
    ;;
  __admit_read)
    admit_read "${reader_path}" "${reader_identity}"
    ;;
  __admit_write)
    admit_write
    ;;
esac
