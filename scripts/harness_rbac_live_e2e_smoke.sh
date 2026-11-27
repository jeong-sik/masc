#!/usr/bin/env bash
# Deterministic, repeatable Live RBAC E2E Smoke runner across real built
# main_eio.exe servers (single-user auth_off, single-user auth_on loopback,
# single-user auth_on strict, multi-account), real built assets/dashboard
# bundle (Playwright), and real masc_tui.exe binary (PTY).
#
# Usage:
#   scripts/harness_rbac_live_e2e_smoke.sh [--screenshot-dir <dir>] [--assets-dir <dir>] [--tui-bin <path>] [--skip-build] [--only all|http|dashboard|tui]
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DASHBOARD_DIR="${ROOT_DIR}/dashboard"
DEFAULT_ASSETS_DIR="${ROOT_DIR}/assets"
DEFAULT_TUI_BIN="${ROOT_DIR}/_build/default/bin/masc_tui.exe"
ASSETS_DIR="${RBAC_ASSETS_DIR:-${DEFAULT_ASSETS_DIR}}"
MAIN_BIN="${ROOT_DIR}/_build/default/bin/main_eio.exe"
TUI_BIN="${RBAC_TUI_BIN:-${DEFAULT_TUI_BIN}}"
SEED_BIN="${ROOT_DIR}/_build/default/test/rbac_live_e2e_seed.exe"
READY_TIMEOUT_SEC="${RBAC_E2E_READY_TIMEOUT_SEC:-45}"

SCREENSHOT_DIR="${RBAC_SCREENSHOT_DIR:-}"
SKIP_BUILD=0
ONLY="all"

require_arg() {
  if [[ "$2" -lt 2 ]]; then
    printf 'missing value for argument: %s\n' "$1" >&2
    exit 2
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --screenshot-dir)
      require_arg "$1" "$#"
      SCREENSHOT_DIR="$2"
      shift 2
      ;;
    --skip-build)
      SKIP_BUILD=1
      shift
      ;;
    --assets-dir)
      require_arg "$1" "$#"
      ASSETS_DIR="$2"
      shift 2
      ;;
    --tui-bin)
      require_arg "$1" "$#"
      TUI_BIN="$2"
      shift 2
      ;;
    --only)
      require_arg "$1" "$#"
      ONLY="$2"
      shift 2
      ;;
    *)
      printf 'unknown argument: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

case "${ONLY}" in
  all|http|dashboard|tui) ;;
  *)
    printf 'invalid --only value %s (expected all|http|dashboard|tui)\n' "${ONLY}" >&2
    exit 2
    ;;
esac

NEED_TUI=0
NEED_DASHBOARD=0
if [[ "${ONLY}" == "all" || "${ONLY}" == "tui" ]]; then
  NEED_TUI=1
fi
if [[ "${ONLY}" == "all" || "${ONLY}" == "dashboard" ]]; then
  NEED_DASHBOARD=1
fi

if [[ "${SKIP_BUILD}" -eq 0 ]]; then
  DUNE_TARGETS=("bin/main_eio.exe" "test/rbac_live_e2e_seed.exe")
  if [[ "${NEED_TUI}" -eq 1 && "${TUI_BIN}" == "${DEFAULT_TUI_BIN}" ]]; then
    DUNE_TARGETS+=("bin/masc_tui.exe")
  fi
  printf '[harness] building OCaml targets: %s\n' "${DUNE_TARGETS[*]}"
  (cd "${ROOT_DIR}" && dune build --root . "${DUNE_TARGETS[@]}")

  if [[ "${NEED_DASHBOARD}" -eq 1 && "${ASSETS_DIR}" == "${DEFAULT_ASSETS_DIR}" ]]; then
    printf '[harness] building production dashboard bundle\n'
    pnpm --dir "${DASHBOARD_DIR}" build
  fi
fi

REQUIRED_BINS=("${MAIN_BIN}" "${SEED_BIN}")
if [[ "${NEED_TUI}" -eq 1 ]]; then
  REQUIRED_BINS+=("${TUI_BIN}")
fi
for bin in "${REQUIRED_BINS[@]}"; do
  if [[ ! -x "${bin}" ]]; then
    printf '[harness] missing executable: %s\n' "${bin}" >&2
    exit 2
  fi
done
if [[ "${NEED_DASHBOARD}" -eq 1 && ! -f "${ASSETS_DIR}/dashboard/index.html" ]]; then
  printf '[harness] missing built dashboard bundle under %s/dashboard\n' "${ASSETS_DIR}" >&2
  exit 2
fi

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/masc-rbac-live-e2e.XXXXXX")"
SERVER_PIDS=()

stop_servers() {
  local pid attempt
  for pid in "${SERVER_PIDS[@]:-}"; do
    [[ -n "${pid}" ]] || continue
    kill -TERM "${pid}" 2>/dev/null || true
  done
  for pid in "${SERVER_PIDS[@]:-}"; do
    [[ -n "${pid}" ]] || continue
    for ((attempt = 0; attempt < 40; attempt++)); do
      if ! kill -0 "${pid}" 2>/dev/null; then
        break
      fi
      sleep 0.1
    done
    if kill -0 "${pid}" 2>/dev/null; then
      kill -KILL "${pid}" 2>/dev/null || true
    fi
    wait "${pid}" 2>/dev/null || true
  done
}

cleanup() {
  trap '' HUP INT QUIT TERM
  stop_servers
  if [[ "${RBAC_E2E_KEEP_TMP:-0}" -eq 0 ]]; then
    rm -rf "${TMP_ROOT}"
  else
    printf '[harness] preserved temp root at %s\n' "${TMP_ROOT}" >&2
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

MANIFEST_PATH="$("${SEED_BIN}" --root "${TMP_ROOT}")"
if [[ ! -f "${MANIFEST_PATH}" ]]; then
  printf '[harness] seeder did not create manifest\n' >&2
  exit 1
fi

read_manifest_field() {
  python3 - "$MANIFEST_PATH" "$1" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
cur = data
for part in sys.argv[2].split("."):
    cur = cur[part]
print(cur)
PY
}

allocate_free_ports() {
  python3 - <<'PY'
import socket
socks = []
ports = []
try:
    for _ in range(4):
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.bind(("127.0.0.1", 0))
        ports.append(s.getsockname()[1])
        socks.append(s)
finally:
    for s in socks:
        s.close()
print(" ".join(str(p) for p in ports))
PY
}

read -r SU_OFF_PORT SU_AUTH_PORT SU_STRICT_PORT MA_PORT <<<"$(allocate_free_ports)"
SU_OFF_BASE="$(read_manifest_field su_off.base_path)"
SU_AUTH_BASE="$(read_manifest_field su_auth.base_path)"
SU_STRICT_BASE="$(read_manifest_field su_strict.base_path)"
MA_BASE="$(read_manifest_field ma.base_path)"
MA_XDG="$(read_manifest_field ma.xdg_config_home)"
MA_HOME="$(read_manifest_field ma.home)"

SU_OFF_HOME="${TMP_ROOT}/su_off_home"
SU_AUTH_HOME="${TMP_ROOT}/su_auth_home"
SU_STRICT_HOME="${TMP_ROOT}/su_strict_home"
mkdir -p "${SU_OFF_HOME}/xdg" "${SU_AUTH_HOME}/xdg" "${SU_STRICT_HOME}/xdg" "${TMP_ROOT}/logs"

start_server() {
  local label="$1" base_path="$2" port="$3" home_dir="$4" xdg_dir="$5" strict="$6"
  local log_file="${TMP_ROOT}/logs/${label}.log"
  env -i \
    PATH="${PATH}" \
    HOME="${home_dir}" \
    XDG_CONFIG_HOME="${xdg_dir}" \
    TMPDIR="${TMPDIR:-/tmp}" \
    MASC_BASE_PATH="${base_path}" \
    MASC_ASSETS_DIR="${ASSETS_DIR}" \
    MASC_OTEL_ENABLED=0 \
    MASC_HTTPS_PORT=0 \
    MASC_HTTP_BASE_URL="" \
    MASC_USE_H2=auto \
    MASC_HTTP_AUTH_STRICT="${strict}" \
    MASC_ALLOW_ANONYMOUS_MUTATIONS=0 \
    "${MAIN_BIN}" --base-path "${base_path}" --host 127.0.0.1 --port "${port}" \
    >"${log_file}" 2>&1 &
  local pid="$!"
  SERVER_PIDS+=("${pid}")
  printf '[harness] started %s on 127.0.0.1:%s (pid=%s)\n' "${label}" "${port}" "${pid}"
}

wait_ready() {
  local label="$1" port="$2" pid="$3"
  local log_file="${TMP_ROOT}/logs/${label}.log"
  local deadline=$((SECONDS + READY_TIMEOUT_SEC))
  while ((SECONDS < deadline)); do
    if ! kill -0 "${pid}" 2>/dev/null; then
      printf '[harness] %s exited before becoming ready\n' "${label}" >&2
      tail -n 50 "${log_file}" >&2 || true
      return 1
    fi
    if curl -fsS --max-time 2 "http://127.0.0.1:${port}/health/ready" >/dev/null 2>&1; then
      printf '[harness] ready: %s (127.0.0.1:%s)\n' "${label}" "${port}"
      return 0
    fi
    sleep 0.2
  done
  printf '[harness] timed out waiting for %s on :%s\n' "${label}" "${port}" >&2
  tail -n 50 "${log_file}" >&2 || true
  return 1
}

start_server "su_off" "${SU_OFF_BASE}" "${SU_OFF_PORT}" "${SU_OFF_HOME}" "${SU_OFF_HOME}/xdg" "0"
SU_OFF_PID="${SERVER_PIDS[0]}"
start_server "su_auth" "${SU_AUTH_BASE}" "${SU_AUTH_PORT}" "${SU_AUTH_HOME}" "${SU_AUTH_HOME}/xdg" "0"
SU_AUTH_PID="${SERVER_PIDS[1]}"
start_server "su_strict" "${SU_STRICT_BASE}" "${SU_STRICT_PORT}" "${SU_STRICT_HOME}" "${SU_STRICT_HOME}/xdg" "1"
SU_STRICT_PID="${SERVER_PIDS[2]}"
start_server "ma" "${MA_BASE}" "${MA_PORT}" "${MA_HOME}" "${MA_XDG}" "0"
MA_PID="${SERVER_PIDS[3]}"

wait_ready "su_off" "${SU_OFF_PORT}" "${SU_OFF_PID}"
wait_ready "su_auth" "${SU_AUTH_PORT}" "${SU_AUTH_PID}"
wait_ready "su_strict" "${SU_STRICT_PORT}" "${SU_STRICT_PID}"
wait_ready "ma" "${MA_PORT}" "${MA_PID}"

export RBAC_E2E_MANIFEST="${MANIFEST_PATH}"
export RBAC_SU_OFF_URL="http://127.0.0.1:${SU_OFF_PORT}"
export RBAC_SU_AUTH_URL="http://127.0.0.1:${SU_AUTH_PORT}"
export RBAC_SU_STRICT_URL="http://127.0.0.1:${SU_STRICT_PORT}"
export RBAC_MA_URL="http://127.0.0.1:${MA_PORT}"
export RBAC_TUI_BIN="${TUI_BIN}"
export RBAC_SCREENSHOT_DIR="${SCREENSHOT_DIR}"

if [[ "${ONLY}" == "all" || "${ONLY}" == "http" || "${ONLY}" == "dashboard" ]]; then
  pnpm --dir "${DASHBOARD_DIR}" exec playwright --version >/dev/null
  RBAC_E2E_ONLY="${ONLY}" pnpm --dir "${DASHBOARD_DIR}" exec node e2e/rbac-live-smoke.mjs
fi

if [[ "${ONLY}" == "all" || "${ONLY}" == "tui" ]]; then
  python3 "${ROOT_DIR}/test/test_rbac_tui_pty_e2e.py"
fi

printf '[harness] Live RBAC E2E smoke passed (%s)\n' "${ONLY}"
