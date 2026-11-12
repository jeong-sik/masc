#!/usr/bin/env bash
# What a dashboard harness leaves behind when it ends: no process and a free
# port. And whose server it tests: the one it started. A fake
# `node_modules/.bin/vite` stands in for Vite here. Like the launcher a package
# manager writes, it replaces itself with the server.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/harness/lib/dashboard_dev_server.sh
source "${SCRIPT_DIR}/harness/lib/dashboard_dev_server.sh"

fixture="$(mktemp -d)"
pids="${fixture}/pids"
: >"${pids}"
other_pid=""
bystander_pid=""
harness_pid=""

# Recorded pids that still run. A zombie waiting for its parent does not.
running() {
  local pid state
  while read -r pid; do
    state="$(ps -o stat= -p "${pid}" 2>/dev/null || true)"
    case "${state}" in
      '' | Z*) ;;
      *) printf '%s ' "${pid}" ;;
    esac
  done <"${pids}"
}

finish() {
  local pid
  harness_dashboard_dev_server_stop
  # A check that fails leaves the processes it is about. End what this test
  # started, so a failed run does not keep a port either.
  for pid in ${harness_pid} $(running); do
    kill -KILL "${pid}" 2>/dev/null || true
  done
  for pid in ${other_pid} ${bystander_pid}; do
    kill "${pid}" 2>/dev/null || true
    wait "${pid}" 2>/dev/null || true
  done
  rm -rf "${fixture}"
}
trap finish EXIT

dashboard="${fixture}/dashboard"
mkdir -p "${dashboard}/node_modules/.bin" "${fixture}/empty"

cat >"${dashboard}/node_modules/.bin/vite" <<'LAUNCHER'
#!/bin/sh
echo "$$" >>"${FAKE_VITE_PIDS}"
if [ -n "${FAKE_VITE_EXITS:-}" ]; then
  echo "fake vite: exits before it serves"
  exit 3
fi
host=""
port=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --host) host="$2"; shift 2 ;;
    --port) port="$2"; shift 2 ;;
    *) shift ;;
  esac
done
exec python3 "$(dirname "$0")/server.py" "${host}" "${port}"
LAUNCHER
chmod +x "${dashboard}/node_modules/.bin/vite"

cat >"${dashboard}/node_modules/.bin/server.py" <<'SERVER'
import http.server
import os
import signal
import socket
import sys
import time

host, port = sys.argv[1], int(sys.argv[2])
if os.environ.get("FAKE_VITE_IGNORES_SIGNALS"):
    # A server that is stuck: it does not exit when it is told to.
    for name in ("SIGHUP", "SIGINT", "SIGTERM"):
        signal.signal(getattr(signal, name), signal.SIG_IGN)
else:
    # Vite exits with a status when it is told to end.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
if os.environ.get("FAKE_VITE_NEVER_ANSWERS"):
    # Connections are taken by the kernel and no request gets an answer.
    listener = socket.socket()
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind((host, port))
    listener.listen()
    time.sleep(600)
else:
    http.server.ThreadingHTTPServer((host, port), http.server.SimpleHTTPRequestHandler).serve_forever()
SERVER

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

recorded() {
  wc -l <"${pids}" | tr -d ' '
}

# Waits up to $2 quarter seconds for the command in $1 to succeed.
await() {
  local check="$1" tries="$2" attempt
  for ((attempt = 0; attempt < tries; attempt++)); do
    if "${check}"; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}
nothing_runs() { [[ -z "$(running)" ]]; }
harness_started() { [[ -e "${fixture}/started" ]]; }
harness_ended() { ! kill -0 "${harness_pid}" 2>/dev/null; }

port="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
ready_url="http://127.0.0.1:${port}/"

start() {
  FAKE_VITE_PIDS="${pids}" \
    harness_dashboard_dev_server_start "${dashboard}" "${1:-127.0.0.1}" "${port}" "${ready_url}" "${fixture}/server.log"
}

# A harness can exit before it starts the server.
harness_dashboard_dev_server_stop
printf 'ok: stop before any start does nothing\n'

start || fail "the server did not start"
[[ "$(recorded)" == 1 ]] || fail "expected the launcher to become the server, recorded $(recorded) processes"
harness_dashboard_dev_server_stop
nothing_runs || fail "processes outlive the stop: $(running)"
start || fail "the port was not free for a second server"
harness_dashboard_dev_server_stop
nothing_runs || fail "processes outlive the second stop: $(running)"
printf 'ok: a stopped server leaves no process and frees the port\n'

: >"${pids}"
if FAKE_VITE_EXITS=1 start 2>"${fixture}/start.err"; then
  fail "start succeeded although the server exited"
fi
[[ "$(cat "${fixture}/start.err")" == *"fake vite: exits before it serves"* ]] ||
  fail "the log of the server that exited was not printed"
printf 'ok: a server that exits before answering fails the start and shows its log\n'

: >"${pids}"
FAKE_VITE_IGNORES_SIGNALS=1 start || fail "the server that ignores signals did not start"
stop_attempts="${HARNESS_DASHBOARD_DEV_SERVER_STOP_ATTEMPTS}"
HARNESS_DASHBOARD_DEV_SERVER_STOP_ATTEMPTS=3
harness_dashboard_dev_server_stop
HARNESS_DASHBOARD_DEV_SERVER_STOP_ATTEMPTS="${stop_attempts}"
nothing_runs || fail "a server that ignores SIGTERM outlives the stop: $(running)"
printf 'ok: a server that ignores SIGTERM is killed\n'

# A server that exits during the run leaves a pid that can name another
# process by the time the script ends. The script has another child running
# then, which is not the server either.
: >"${pids}"
start || fail "the server did not start"
sleep 600 &
bystander_pid="$!"
kill -KILL "$(cat "${pids}")"
await nothing_runs 20 || fail "the server that was killed is still running: $(running)"
signals="${fixture}/signals"
: >"${signals}"
# shellcheck disable=SC2329 # the helper's stop calls it
kill() {
  printf '%s\n' "$*" >>"${signals}"
  builtin kill "$@"
}
harness_dashboard_dev_server_stop
unset -f kill
[[ ! -s "${signals}" ]] || fail "stop signalled the pid of a server that had exited: $(tr '\n' ';' <"${signals}")"
kill -0 "${bystander_pid}" 2>/dev/null || fail "stop ended a child that is not the server"
kill "${bystander_pid}"
wait "${bystander_pid}" 2>/dev/null || true
bystander_pid=""
printf 'ok: stop sends nothing to the pid of a server that exited during the run\n'

: >"${pids}"
# shellcheck disable=SC2016 # the new shell expands them from its arguments
if PATH="${fixture}/empty" FAKE_VITE_PIDS="${pids}" "${BASH}" -c '
  source "$1"
  harness_dashboard_dev_server_start "$2" 127.0.0.1 "$3" "$4" "$5"
' bash "${SCRIPT_DIR}/harness/lib/dashboard_dev_server.sh" "${dashboard}" "${port}" "${ready_url}" \
  "${fixture}/server.log" 2>/dev/null; then
  fail "start succeeded without lsof"
fi
[[ "$(recorded)" == 0 ]] || fail "without lsof, start ran a server it could not tell from another one"
printf 'ok: without lsof nothing is started\n'

# lsof reports only the listeners it may see, so it can come back empty. An
# answer on the port then has no known sender.
mkdir -p "${fixture}/blind"
printf '%s\n' '#!/bin/sh' 'exit 1' >"${fixture}/blind/lsof"
chmod +x "${fixture}/blind/lsof"
: >"${pids}"
ready_timeout="${HARNESS_DASHBOARD_DEV_SERVER_READY_TIMEOUT_SEC}"
HARNESS_DASHBOARD_DEV_SERVER_READY_TIMEOUT_SEC=2
if PATH="${fixture}/blind:${PATH}" start 2>/dev/null; then
  fail "start accepted an answer although lsof showed no listener"
fi
HARNESS_DASHBOARD_DEV_SERVER_READY_TIMEOUT_SEC="${ready_timeout}"
nothing_runs || fail "processes outlive the start that failed: $(running)"
printf 'ok: an answer is not accepted while lsof shows no listener\n'

# A script that does what the harness scripts do: start the server, keep the
# stop for its exit, and go on with its own work. That work is one long step,
# or short ones when SHORT_STEPS is set.
cat >"${fixture}/harness.sh" <<HARNESS
#!/usr/bin/env bash
set -euo pipefail
source "${SCRIPT_DIR}/harness/lib/dashboard_dev_server.sh"
if [[ -n "\${READY_TIMEOUT_SEC:-}" ]]; then
  HARNESS_DASHBOARD_DEV_SERVER_READY_TIMEOUT_SEC="\${READY_TIMEOUT_SEC}"
fi
trap harness_dashboard_dev_server_stop EXIT
harness_dashboard_dev_server_start "${dashboard}" 127.0.0.1 "${port}" "${ready_url}" "${fixture}/server.log"
: >"${fixture}/started"
while [[ -n "\${SHORT_STEPS:-}" ]]; do sleep 0.2; done
sleep 600
HARNESS

# Runs the script as a terminal or a supervisor does: in a process group of
# its own, with the signals that end a script left to end it. A background
# command starts with SIGINT ignored, and so does everything this test starts
# when the test itself was started that way; a shell cannot undo that for its
# children. Variables set for this call reach the script.
run_harness() {
  : >"${pids}"
  rm -f "${fixture}/started"
  FAKE_VITE_PIDS="${pids}" python3 -c '
import os, signal, sys
os.setpgid(0, 0)
for name in ("SIGHUP", "SIGINT", "SIGQUIT", "SIGTERM"):
    signal.signal(getattr(signal, name), signal.SIG_DFL)
os.execv(sys.argv[1], sys.argv[1:])
' "${BASH}" "${fixture}/harness.sh" >/dev/null 2>&1 &
  harness_pid="$!"
  disown "${harness_pid}"
}

for ending in 'INT to its process group, as Ctrl-C sends it' \
  'HUP to its process group, as a closing terminal sends it' 'TERM to the script alone' \
  'KILL to its process group, as a supervisor that gives up sends it'; do
  case "${ending}" in
    # Bash acts on a signal sent to it alone once its foreground command ends.
    TERM*) SHORT_STEPS=1 run_harness ;;
    *) run_harness ;;
  esac
  await harness_started 120 || fail "the script never started its server"
  case "${ending}" in
    INT*) kill -INT -- "-${harness_pid}" ;;
    HUP*) kill -HUP -- "-${harness_pid}" ;;
    TERM*) kill -TERM "${harness_pid}" ;;
    KILL*) kill -KILL -- "-${harness_pid}" ;;
  esac
  await harness_ended 120 || fail "a script ended by ${ending} is still running"
  harness_pid=""
  await nothing_runs 20 || fail "processes outlive a script ended by ${ending}: $(running)"
done
printf 'ok: a script that is ended leaves no server\n'

# The server is stuck and the script is told to end again while it waits for
# the server to exit.
FAKE_VITE_IGNORES_SIGNALS=1 run_harness
await harness_started 120 || fail "the script never started the server that ignores signals"
for _ in 1 2 3 4; do
  kill -INT -- "-${harness_pid}" 2>/dev/null || true
  sleep 0.5
done
await nothing_runs 60 || fail "a second signal ended the stop before the server was killed: $(running)"
await harness_ended 20 || fail "the script is still running after its server was killed"
harness_pid=""
printf 'ok: a second signal does not keep a stuck server from being killed\n'

FAKE_VITE_NEVER_ANSWERS=1 READY_TIMEOUT_SEC=2 run_harness
if ! await harness_ended 80; then
  harness_started && fail "start accepted a server that never answered"
  fail "the script still waits for a server that never answers"
fi
harness_pid=""
await nothing_runs 20 || fail "the server that never answered outlives the script: $(running)"
printf 'ok: a server that never answers fails the start in time\n'

# Another server on the port answers the probe in place of the one this run
# starts: a server an earlier run left behind, or a run that started at the
# same moment on the same port.
python3 -m http.server "${port}" --bind 127.0.0.1 --directory "${fixture}" >/dev/null 2>&1 &
other_pid="$!"
other_answers() { curl -fsS "${ready_url}" >/dev/null 2>&1; }
await other_answers 80 || fail "the other server did not come up"

# On the other server's address this run's server cannot bind. On every
# address it can, where the system lets the two share the port, and the other
# server still answers the probe.
for host in 127.0.0.1 0.0.0.0; do
  : >"${pids}"
  if start "${host}" 2>/dev/null; then
    fail "start on ${host} accepted the answer of a server this run did not start"
  fi
  nothing_runs || fail "processes outlive the failed start on ${host}: $(running)"
  kill -0 "${other_pid}" 2>/dev/null || fail "the failed start on ${host} ended a server this run did not start"
done
printf 'ok: the answer of another server on the port is not taken for this run'"'"'s server\n'

printf 'harness dashboard dev server test passed\n'
