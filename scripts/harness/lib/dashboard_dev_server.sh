#!/usr/bin/env bash
# Start and stop the dashboard's Vite dev server for a harness script.
#
# `pnpm exec vite` puts pnpm, and on some installs a shell shim, in front of
# the server. The pid `$!` then names the front of that chain: a signal to it
# ends the shim, and the server is adopted by init and keeps the port. The
# next run on that port starts a Vite that exits under `--strictPort`, its
# readiness probe is answered by the server left behind, and the run tests
# whatever that server serves.
#
# So the server is started as `node_modules/.bin/vite`, the launcher that
# `pnpm exec vite` itself runs. It replaces itself with node, which makes `$!`
# the server: a signal to it ends the server, and esbuild exits with it. The
# server stays in the script's process group, so a signal sent to the group
# reaches it without the script's help. SIGKILL sent to the script alone still
# leaves the server running.
#
# An answer counts only while the server this run started is the one process
# that listens on the port. `lsof` reports the listeners it may see; another
# user's process is not among them.
#
# Usage, from a script that runs without job control. The shell that starts
# the server is the one that stops it:
#   source "${ROOT_DIR}/scripts/harness/lib/dashboard_dev_server.sh"
#   trap harness_dashboard_dev_server_stop EXIT
#   MASC_DASHBOARD_PROXY_TARGET="${PROXY_TARGET}" \
#     harness_dashboard_dev_server_start "${DASHBOARD_DIR}" "${HOST}" "${PORT}" "${READY_URL}" "${SERVER_LOG}"

# The server gets this long to listen, and a request this long to be answered.
HARNESS_DASHBOARD_DEV_SERVER_READY_TIMEOUT_SEC=20
HARNESS_DASHBOARD_DEV_SERVER_READY_INTERVAL_SEC=0.25
# The server gets 50 x 0.1 s to exit after each signal.
HARNESS_DASHBOARD_DEV_SERVER_STOP_ATTEMPTS=50
HARNESS_DASHBOARD_DEV_SERVER_STOP_INTERVAL_SEC=0.1

# Pid of the server this shell started last; empty before the first start.
harness_dashboard_dev_server_pid=""

# True while that server has not exited. Bash lists the children it has not
# seen exit. The pid alone does not tell: once the server is gone, the number
# can name another process.
harness_dashboard_dev_server_runs() {
  local job
  for job in $(jobs -pr); do
    if [[ "${job}" == "${harness_dashboard_dev_server_pid}" ]]; then
      return 0
    fi
  done
  return 1
}

# Starts Vite in DASHBOARD_DIR and returns once READY_URL answers. Returns 1,
# with nothing left running, when the server exits, does not answer in time,
# or shares the port with another process.
harness_dashboard_dev_server_start() {
  local dashboard_dir="$1" host="$2" port="$3" ready_url="$4" server_log="$5"
  local deadline listener listening
  local failure="the server did not answer ${ready_url} in time"
  if ! command -v lsof >/dev/null 2>&1; then
    printf 'dashboard dev server: lsof is needed to tell which process listens on port %s\n' "${port}" >&2
    return 1
  fi
  (cd "${dashboard_dir}" && exec node_modules/.bin/vite --host "${host}" --port "${port}" --strictPort) \
    >"${server_log}" 2>&1 &
  harness_dashboard_dev_server_pid="$!"
  deadline=$((SECONDS + HARNESS_DASHBOARD_DEV_SERVER_READY_TIMEOUT_SEC))
  while ((SECONDS < deadline)); do
    if ! harness_dashboard_dev_server_runs; then
      failure="the server exited before it answered ${ready_url}"
      break
    fi
    listening=0
    for listener in $(lsof -nP -iTCP:"${port}" -sTCP:LISTEN -t 2>/dev/null); do
      if [[ "${listener}" != "${harness_dashboard_dev_server_pid}" ]]; then
        failure="process ${listener} listens on port ${port}, and this run did not start it"
        break 2
      fi
      listening=1
    done
    if ((listening)) && curl -fsS --max-time "${HARNESS_DASHBOARD_DEV_SERVER_READY_TIMEOUT_SEC}" \
      "${ready_url}" >/dev/null 2>&1; then
      return 0
    fi
    sleep "${HARNESS_DASHBOARD_DEV_SERVER_READY_INTERVAL_SEC}"
  done
  printf 'dashboard dev server: %s\n' "${failure}" >&2
  cat "${server_log}" >&2
  harness_dashboard_dev_server_stop
  return 1
}

# Ends the server: SIGTERM, then SIGKILL when it is still running. Returns
# once it is gone. Does nothing when no server is running.
harness_dashboard_dev_server_stop() {
  local pid="${harness_dashboard_dev_server_pid}"
  local signal attempt
  if ! harness_dashboard_dev_server_runs; then
    return 0
  fi
  # The subshell ignores the signals that end a script. A second one, sent
  # while this waits, then cannot end the stop between SIGTERM and SIGKILL.
  (
    trap '' HUP INT TERM
    for signal in TERM KILL; do
      kill "-${signal}" "${pid}" 2>/dev/null || true
      for ((attempt = 0; attempt < HARNESS_DASHBOARD_DEV_SERVER_STOP_ATTEMPTS; attempt++)); do
        if ! kill -0 "${pid}" 2>/dev/null; then
          exit 0
        fi
        sleep "${HARNESS_DASHBOARD_DEV_SERVER_STOP_INTERVAL_SEC}"
      done
    done
    printf 'dashboard dev server: process %s is still running after SIGKILL\n' "${pid}" >&2
  )
}
