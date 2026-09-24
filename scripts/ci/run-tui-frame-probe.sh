#!/usr/bin/env bash
# Boot the release-profile server and run scripts/harness/perf/tui_latency_probe.py
# against it, then label the harness's own frame-timing flush one row per
# surface. This is the entry point lane-addon-native.yml calls after its
# build step. CI runs it end to end on a shared runner, so the numbers it
# prints are a ceiling under shared-runner load, never a baseline
# (goal-1790241467363-e42336c2 / task-1720, TUI part).
#
# Usage:
#   scripts/ci/run-tui-frame-probe.sh --binary _build/default/bin/masc_tui.exe \
#     --server _build/default/bin/main_eio.exe --output-dir <dir>
#
#   scripts/ci/run-tui-frame-probe.sh --self-test --output-dir <dir>
#
# Exit codes:
#   0 probe observation_complete=true and required surfaces observed
#   1 probe incomplete or required surface missing (artifacts kept)
#   5 argument / setup error
#   6 server did not reach its listening line within the boot window
set -euo pipefail

readonly EXIT_OK=0
readonly EXIT_PROBE=1
readonly EXIT_SETUP=5
readonly EXIT_LISTEN=6

binary=""
server=""
output_dir=""
port="18936"
boot_wait_sec="12"
self_test_only=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    --binary)        binary="${2:?}";          shift 2 ;;
    --server)        server="${2:?}";          shift 2 ;;
    --output-dir)    output_dir="${2:?}";      shift 2 ;;
    --port)          port="${2:?}";            shift 2 ;;
    --boot-wait-sec) boot_wait_sec="${2:?}";   shift 2 ;;
    --self-test)     self_test_only=true;      shift ;;
    *) echo "run-tui-frame-probe: unknown argument: $1" >&2; exit "$EXIT_SETUP" ;;
  esac
done

[ -n "$output_dir" ] || { echo "run-tui-frame-probe: --output-dir is required" >&2; exit "$EXIT_SETUP"; }
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[ -f "${repo_root}/config/runtime.toml" ] || {
  echo "run-tui-frame-probe: config/runtime.toml missing under ${repo_root}" >&2
  exit "$EXIT_SETUP"; }

probe="${repo_root}/scripts/harness/perf/tui_latency_probe.py"
[ -f "$probe" ] || {
  echo "run-tui-frame-probe: probe harness not found: $probe" >&2; exit "$EXIT_SETUP"; }

if [ "${self_test_only}" = false ]; then
  [ -n "$binary" ] && [ -x "$binary" ] || {
    echo "run-tui-frame-probe: --binary not executable: ${binary:-<empty>}" >&2
    exit "$EXIT_SETUP"; }
  [ -n "$server" ] && [ -x "$server" ] || {
    echo "run-tui-frame-probe: --server not executable: ${server:-<empty>}" >&2
    exit "$EXIT_SETUP"; }
fi

server_log="${output_dir}/server-boot.log"
mkdir -p "$output_dir"

cleanup() {
  if [ -n "${SERVER_PID:-}" ]; then
    if kill -0 "$SERVER_PID" 2>/dev/null; then server_alive=1; else server_alive=0; fi
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    SERVER_PID=""
    # Record how the server was doing at teardown, next to the verdict:
    # alive-at-kill vs already-dead are different failures (the release
    # smoke script learned this the hard way; see its BOOT_WAIT_SEC loop).
    echo "run-tui-frame-probe: server teardown: alive_at_kill=${server_alive}" >&2
  fi
  if [ -n "${base_path:-}" ]; then rm -rf -- "$base_path"; fi
  if [ -n "${self_test_probe:-}" ]; then rm -f -- "$self_test_probe"; fi
}
trap cleanup EXIT

# Scratch base path exists in both modes: the probe's argv contract takes it
# either way, and only the boot below turns it into a running server.
base_path="$(mktemp -d -t masc-frame-probe.XXXXXX)"
mkdir -p "${base_path}/.masc/config"
cp "${repo_root}/config/runtime.toml" "${base_path}/.masc/config/runtime.toml"

if [ "${self_test_only}" = false ]; then
  mkdir -p "$output_dir"
  MASC_BASE_PATH="$base_path" MASC_OTEL_ENABLED=0 \
    "$server" --base-path "$base_path" --port "$port" >"$server_log" 2>&1 &
  SERVER_PID=$!

  deadline=$(( $(date +%s) + boot_wait_sec ))
  state=pending
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if grep -q '\[FATAL\]\|Fatal ' "$server_log"; then state=fatal; break; fi
    if grep -q 'MASC MCP Server listening' "$server_log"; then state=listening; break; fi
    sleep 0.2
  done
  case "$state" in
    fatal)
      echo "run-tui-frame-probe: FATAL during server boot:" >&2
      tail -20 "$server_log" >&2
      exit "$EXIT_LISTEN"
      ;;
    pending)
      echo "run-tui-frame-probe: server did not reach listening within ${boot_wait_sec}s" >&2
      tail -30 "$server_log" >&2
      exit "$EXIT_LISTEN"
      ;;
  esac
  echo "run-tui-frame-probe: server listening on :${port} (base ${base_path})"
fi

# --self-test swaps the harness for a stub with the same argv contract. The
# mode flag is the gate, read at this one place and nowhere else: an
# inherited variable cannot redirect the real path, and the stub can never
# be what a normal run measured (the run-edited-tests.sh rule, #38591).
if [ "${self_test_only}" = true ]; then
  self_test_probe="$(mktemp -t tui-probe-selftest-stub.XXXXXX)"
  probe="$self_test_probe"
  cat >"$probe" <<'PYEOF'
#!/usr/bin/env python3
"""Self-test stub for run-tui-frame-probe.sh. Not a measurement."""
import argparse
import json
import sys
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--binary', type=Path, required=True)
parser.add_argument('--base-path', type=Path, required=True)
parser.add_argument('--output-dir', type=Path, required=True)
parser.add_argument('--port', type=int, default=8935)
parser.add_argument('--tabs', type=int, default=4)
parser.add_argument('--capture-screen', action='store_true')
args = parser.parse_args()
args.output_dir.mkdir(parents=True, exist_ok=False)
surfaces = ['overview', 'acting', 'keeper-list', 'lanes', 'memory',
            'board-list', 'planning-list', 'fusion-list', 'repositories', 'config']
timing = ['build frames=12 mean=0.85ms p50=0.80 p95=1.42 p99=1.61 max=1.92',
          'present frames=12 mean=0.62ms p50=0.58 p95=1.10 p99=1.20 max=1.30']
for surface in surfaces:
    timing.append(f'  build[{surface}] frames=1 mean=0.80ms p50=0.80 p95=0.80 p99=0.80 max=0.80')
    timing.append(f'  present[{surface}] frames=1 mean=0.50ms p50=0.50 p95=0.50 p99=0.50 max=0.50')
(args.output_dir / 'frame-timing.txt').write_text('\n'.join(timing) + '\n')
(args.output_dir / 'result.json').write_text(
    json.dumps({'observation_complete': True, 'observed_surfaces': surfaces,
                'source': 'tui-probe-selftest-stub'}) + '\n')
print(json.dumps({'observation_complete': True,
                  'source': 'tui-probe-selftest-stub',
                  'output_dir': str(args.output_dir)}))
sys.exit(0)
PYEOF
fi

# Keep the probe's raw output in the artifact, print the labeled timing table,
# and run the teardown trap even when the probe fails or the job is cancelled.
set +e
MASC_BASE_PATH="$base_path" MASC_OTEL_ENABLED=0 TERM=xterm-256color \
  python3 "$probe" \
  --binary "${binary:-$base_path}" --base-path "$base_path" \
  --output-dir "${output_dir}/probe" --port "$port" --tabs 11 \
  >"${output_dir}/probe-stdout.txt" 2>"${output_dir}/probe-stderr.txt"
probe_status=$?
set -e

# A successful PTY session alone does not prove the Tab walk reached the Board.
# The active top-level ring has ten unconditional stops; Approvals is optional.
if [ "$probe_status" -eq 0 ]; then
  if ! python3 - "${output_dir}/probe/result.json" <<'PYEOF'
import json
import sys
from pathlib import Path

required = {'overview', 'acting', 'keeper-list', 'lanes', 'memory',
            'board-list', 'planning-list', 'fusion-list', 'repositories', 'config'}
result = json.loads(Path(sys.argv[1]).read_text())
observed = set(result.get('observed_surfaces', []))
missing = sorted(required - observed)
print(f"run-tui-frame-probe: ring surfaces observed={len(required) - len(missing)}/{len(required)}")
if missing:
    print(f"run-tui-frame-probe: missing surfaces: {', '.join(missing)}", file=sys.stderr)
    sys.exit(1)
PYEOF
  then probe_status=1; fi
fi

if [ "$probe_status" -eq 0 ]; then
  echo "run-tui-frame-probe: probe observation_complete=true"
elif [ "$probe_status" -eq 1 ]; then
  echo "run-tui-frame-probe: probe incomplete or ring coverage missing" >&2
  tail -5 "${output_dir}/probe-stderr.txt" >&2 || true
else
  echo "run-tui-frame-probe: probe exited ${probe_status} before reporting" >&2
  tail -20 "${output_dir}/probe-stderr.txt" >&2 || true
  exit "$probe_status"
fi

probe_frames="${output_dir}/probe/frame-timing.txt"
if [ -f "$probe_frames" ]; then
  echo ""
  if [ "$self_test_only" = true ]; then
    echo "SELF-TEST STUB — synthetic frame timings, not a measurement:"
  else
    echo "per-surface frame timing (ms) — ceiling under shared-runner load, not a baseline:"
  fi
  # The harness's own flush, one label per line, into a table file. Nothing
  # here recomputes, rounds, or filters: lines that match no summary shape
  # pass through labeled raw, so new harness output stays visible.
  awk -v table="${output_dir}/probe-table.txt" '
    /^build /      { print "phase  " $0 > table; next }
    /^present /    { print "phase  " $0 > table; next }
    /^  build\[/   { print "surface" $0 > table; next }
    /^  present\[/ { print "surface" $0 > table; next }
    { print "raw     " $0 > table }
  ' "$probe_frames"
  cat "${output_dir}/probe-table.txt"
  echo ""
  echo "full probe output: ${output_dir}/probe/ (result.json, frame-timing.txt)"
else
  echo "run-tui-frame-probe: no frame-timing.txt retained — see ${output_dir}/probe/" >&2
fi

# The probe's verdict is the exit, not a line: a failure folded into a
# green table would let CI call an unobserved run a measurement.
exit "$probe_status"
