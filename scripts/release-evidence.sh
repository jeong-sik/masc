#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/release-evidence.sh [PATH_TO_BINARY] [OUTPUT_MARKDOWN]

Captures a reproducible release-evidence bundle for a built masc binary.
The bundle includes:
  - artifact install smoke (`--version` from an installed location)
  - local boot + /health capture
  - MCP initialize + tools/list + masc_status captures
  - dashboard read-path captures for briefing + project snapshot
  - Keeper V01-V15 compile/regression conformance logs + correlated bundle
  - RW01-RW16 real-world multi-Keeper bundle is verified separately after an isolated runtime run

Raw files are written next to OUTPUT_MARKDOWN.
EOF
}

if (($# > 2)); then
  usage >&2
  exit 1
fi

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

readonly BINARY="${1:-_build/default/bin/main_eio.exe}"
readonly OUTFILE="${2:-.release-evidence/release-evidence.md}"
readonly BOOT_WAIT_SEC="${BOOT_WAIT_SEC:-20}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

[[ -x "$BINARY" ]] || { echo "release-evidence: binary not executable: $BINARY" >&2; exit 1; }
[[ -f config/agent-core-models-overlay.toml ]] || { echo "release-evidence: config/agent-core-models-overlay.toml missing" >&2; exit 1; }

readonly SMOKE_FIXTURE_DIR="$repo_root/scripts/fixtures/release-evidence"
for smoke_fixture in runtime.toml agent-core-models-overlay.toml; do
  [[ -f "$SMOKE_FIXTURE_DIR/$smoke_fixture" ]] || {
    echo "release-evidence: smoke fixture missing: scripts/fixtures/release-evidence/$smoke_fixture" >&2
    exit 1
  }
done

mkdir -p "$(dirname "$OUTFILE")"
out_dir="$(cd "$(dirname "$OUTFILE")" && pwd)"

tmp="$(mktemp -d -t masc-release-evidence.XXXXXX)"
base_path="$tmp/base"
prefix_dir="$tmp/prefix"
installed_bin="$prefix_dir/masc"
server_log="$out_dir/server.log"
health_json="$out_dir/health.json"
initialize_headers="$out_dir/initialize.headers"
initialize_body="$out_dir/initialize.body"
initialize_json="$out_dir/initialize.json"
tools_headers="$out_dir/tools-list.headers"
tools_body="$out_dir/tools-list.body"
tools_json="$out_dir/tools-list.json"
status_headers="$out_dir/masc-status.headers"
status_body="$out_dir/masc-status.body"
status_json="$out_dir/masc-status.json"
briefing_headers="$out_dir/dashboard-briefing.headers"
briefing_body="$out_dir/dashboard-briefing.body"
briefing_json="$out_dir/dashboard-briefing.json"
project_snapshot_headers="$out_dir/project-snapshot.headers"
project_snapshot_body="$out_dir/project-snapshot.body"
project_snapshot_json="$out_dir/project-snapshot.json"
dev_token_json="$out_dir/dashboard-dev-token.json"
install_version_stdout="$out_dir/install-version.stdout"
install_version_stderr="$out_dir/install-version.stderr"
lifecycle_dir="$out_dir/keeper-full-lifecycle"
lifecycle_bundle_json="$lifecycle_dir/bundle.json"
lifecycle_bundle_md="$lifecycle_dir/bundle.md"

stop_server() {
  if [[ -n "${SERVER_PID:-}" ]]; then
    kill "${SERVER_PID}" >/dev/null 2>&1 || true
    wait "${SERVER_PID}" 2>/dev/null || true
    SERVER_PID=""
  fi
}

cleanup() {
  stop_server
  # WORKAROUND (#33157): best-effort teardown. The server can still be writing
  # tool assets under $tmp/.masc/config/tools after stop_server's kill and
  # wait return, so a concurrent write can leave a directory non-empty as rm
  # walks it -- "rm: cannot remove ...: Directory not empty", seen on the
  # slower arm64 runner while linux-x64 passed the same script. A teardown
  # race must not fail an evidence run that already verified; the CI runner
  # reclaims the temp dir regardless. Root fix: the server joins its writer
  # fibers on shutdown, so nothing writes once the process has exited; when
  # that lands, drop the "2>/dev/null || true" and let an rm failure fail.
  rm -rf "$tmp" 2>/dev/null || true
}
trap cleanup EXIT

pick_free_port() {
  python3 <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

normalize_json() {
  local src="$1"
  local dest="$2"
  python3 - "$src" "$dest" <<'PY'
import json
import sys

src, dest = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()
payload = None
stripped = text.lstrip()
if stripped.startswith("{") or stripped.startswith("["):
    payload = text
else:
    for line in text.splitlines():
        if line.startswith("data: "):
            payload = line[6:]
if payload is None:
    raise SystemExit(f"no JSON payload found in {src}")
obj = json.loads(payload)
with open(dest, "w", encoding="utf-8") as fh:
    json.dump(obj, fh, indent=2, ensure_ascii=False, sort_keys=True)
    fh.write("\n")
PY
}

status_code() {
  local header_file="$1"
  awk 'toupper($1) ~ /^HTTP\/[0-9.]+$/ { code=$2 } END { print code }' "$header_file"
}

normalize_http_json() {
  local headers="$1"
  local body="$2"
  local dest="$3"
  local label="$4"
  local code
  code="$(status_code "$headers")"
  case "$code" in
    2*) ;;
    *)
      echo "release-evidence: ${label} returned HTTP ${code:-<missing>}" >&2
      head -c 400 "$body" >&2 || true
      echo >&2
      exit 1
      ;;
  esac
  normalize_json "$body" "$dest"
}

header_value() {
  local header_file="$1"
  local key="$2"
  awk -v k="$key" '
    tolower($0) ~ "^" tolower(k) ":" {
      sub(/^[^:]+:[[:space:]]*/, "", $0)
      sub(/\r$/, "", $0)
      print $0
      exit
    }
  ' "$header_file"
}

wait_for_http() {
  local url="$1"
  local deadline=$(( $(date +%s) + BOOT_WAIT_SEC ))
  while [[ "$(date +%s)" -lt "$deadline" ]]; do
    if curl -fsS --max-time 2 "$url" >"$health_json" 2>/dev/null; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

wait_for_initialize_ready() {
  local payload="$1"
  local deadline=$(( $(date +%s) + BOOT_WAIT_SEC ))
  while [[ "$(date +%s)" -lt "$deadline" ]]; do
    : >"$initialize_headers"
    : >"$initialize_body"
    if post_json "$MCP_URL" "$payload" "$initialize_headers" "$initialize_body" \
      -H 'Accept: application/json, text/event-stream' \
      -H "Authorization: Bearer ${auth_token}"; then
      local code
      code="$(status_code "$initialize_headers")"
      if [[ "$code" == "200" ]]; then
        return 0
      fi
    fi
    sleep 1
  done
  return 1
}

post_json() {
  local url="$1"
  local body="$2"
  local headers="$3"
  local output="$4"
  shift 4
  curl -sS -D "$headers" -o "$output" \
    -X POST "$url" \
    -H 'Content-Type: application/json' \
    "$@" \
    -d "$body"
}

extract_dev_token() {
  python3 - "$dev_token_json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    token = json.load(fh).get("token", "")
if not token:
    raise SystemExit(1)
print(token)
PY
}

wait_for_loopback_dev_token() {
  local deadline=$(( $(date +%s) + BOOT_WAIT_SEC ))
  local token
  while [[ "$(date +%s)" -lt "$deadline" ]]; do
    if curl -fsS -H 'Accept: application/json' \
      "${BASE_URL}/api/v1/dashboard/dev-token" >"$dev_token_json" 2>/dev/null \
      && token="$(extract_dev_token)"; then
      printf '%s\n' "$token"
      return 0
    fi
    sleep 1
  done
  return 1
}

copy_install_smoke() {
  mkdir -p "$prefix_dir" "$base_path/.masc/config"
  cp "$BINARY" "$installed_bin"
  chmod +x "$installed_bin"
  # The smoke config is a checked-in fixture, not a heredoc. A heredoc is
  # invisible to the compiler and to every test, so a new startup requirement —
  # such as the mandatory exact-output lanes added in #25671 — drifts silently
  # and only fails here, on a step that runs on push-to-main and never on a PR
  # (#25663). As files, these are checked against
  # Server_runtime_bootstrap.mandatory_exact_output_lane_ids by
  # test_runtime_config_validity, which runs in every PR.
  cp "$SMOKE_FIXTURE_DIR/runtime.toml" "$base_path/.masc/config/runtime.toml"
  cp "$SMOKE_FIXTURE_DIR/agent-core-models-overlay.toml" \
    "$base_path/.masc/config/agent-core-models-overlay.toml"
}

capture_installed_version() {
  : >"$install_version_stdout"
  : >"$install_version_stderr"
  if ! MASC_BASE_PATH="$base_path" \
    "$installed_bin" --version >"$install_version_stdout" 2>"$install_version_stderr"; then
    echo "release-evidence: installed binary --version failed" >&2
    cat "$install_version_stderr" >&2 || true
    exit 1
  fi

  local version
  version="$(tail -n1 "$install_version_stdout")"
  if [[ -z "$version" ]]; then
    echo "release-evidence: installed binary --version produced no output" >&2
    cat "$install_version_stderr" >&2 || true
    exit 1
  fi
  printf '%s\n' "$version"
}

PORT="${SMOKE_PORT:-$(pick_free_port)}"
BASE_URL="http://127.0.0.1:${PORT}"
MCP_URL="${BASE_URL}/mcp"

copy_install_smoke
installed_version="$(capture_installed_version)"

env \
  MASC_BASE_PATH="$base_path" \
  MASC_ADMIN_TOKEN= \
  MASC_INTERNAL_MCP_TOKEN= \
  MASC_TOKEN= \
  MASC_GRPC_ENABLED=0 \
  MASC_WS_ENABLED=0 \
  MASC_KEEPER_BOOTSTRAP_ENABLED=false \
  "$BINARY" --base-path "$base_path" --port "$PORT" >"$server_log" 2>&1 &
SERVER_PID=$!

if ! wait_for_http "${BASE_URL}/health"; then
  echo "release-evidence: server did not become healthy at ${BASE_URL}" >&2
  tail -n 40 "$server_log" >&2 || true
  exit 1
fi

auth_token="${MASC_RELEASE_EVIDENCE_TOKEN:-}"
if [[ -z "$auth_token" ]]; then
  if ! auth_token="$(wait_for_loopback_dev_token)"; then
    echo "release-evidence: failed to fetch loopback dashboard dev-token" >&2
    cat "$dev_token_json" >&2 || true
    tail -n 40 "$server_log" >&2 || true
    exit 1
  fi
fi

init_payload='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"release-evidence","version":"1.0"}}}'
if ! wait_for_initialize_ready "$init_payload"; then
  echo "release-evidence: initialize did not become ready at ${MCP_URL}" >&2
  cat "$initialize_headers" >&2 || true
  cat "$initialize_body" >&2 || true
  tail -n 40 "$server_log" >&2 || true
  exit 1
fi
normalize_json "$initialize_body" "$initialize_json"

session_id="$(header_value "$initialize_headers" "Mcp-Session-Id")"
protocol_version="$(header_value "$initialize_headers" "Mcp-Protocol-Version")"
[[ -n "$session_id" ]] || { echo "release-evidence: missing Mcp-Session-Id header" >&2; exit 1; }
[[ -n "$protocol_version" ]] || { echo "release-evidence: missing Mcp-Protocol-Version header" >&2; exit 1; }

tools_payload='{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
post_json "$MCP_URL" "$tools_payload" "$tools_headers" "$tools_body" \
  -H 'Accept: application/json, text/event-stream' \
  -H "Authorization: Bearer ${auth_token}" \
  -H "Mcp-Session-Id: ${session_id}" \
  -H "Mcp-Protocol-Version: ${protocol_version}"
normalize_json "$tools_body" "$tools_json"

status_payload='{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"masc_status","arguments":{}}}'
post_json "$MCP_URL" "$status_payload" "$status_headers" "$status_body" \
  -H 'Accept: application/json, text/event-stream' \
  -H "Authorization: Bearer ${auth_token}" \
  -H "Mcp-Session-Id: ${session_id}" \
  -H "Mcp-Protocol-Version: ${protocol_version}"
normalize_json "$status_body" "$status_json"

curl -sS -D "$briefing_headers" -o "$briefing_body" \
  -H 'Accept: application/json' \
  "${BASE_URL}/api/v1/dashboard/briefing"
normalize_http_json "$briefing_headers" "$briefing_body" "$briefing_json" \
  "/api/v1/dashboard/briefing"

curl -sS -D "$project_snapshot_headers" -o "$project_snapshot_body" \
  -H 'Accept: application/json' \
  "${BASE_URL}/api/v1/dashboard/project-snapshot"
normalize_http_json "$project_snapshot_headers" "$project_snapshot_body" "$project_snapshot_json" \
  "/api/v1/dashboard/project-snapshot"

# The live smoke has completed. Stop its isolated server before executing the
# lifecycle matrix so process/port-sensitive scenarios observe a clean host.
stop_server
python3 scripts/keeper-full-lifecycle-evidence.py --output-dir "$lifecycle_dir"
python3 scripts/keeper-full-lifecycle-evidence.py \
  --verify \
  --output-dir "$lifecycle_dir"

python3 - \
  "$OUTFILE" \
  "$installed_version" \
  "$BINARY" \
  "$installed_bin" \
  "$BASE_URL" \
  "$session_id" \
  "$protocol_version" \
  "$health_json" \
  "$tools_json" \
  "$status_json" \
  "$briefing_json" \
  "$project_snapshot_json" \
  "$initialize_json" \
  "$server_log" \
  "$lifecycle_bundle_json" \
  "$lifecycle_bundle_md" <<'PY'
import json
import pathlib
import sys
from datetime import datetime, timezone

(
    outfile,
    installed_version,
    binary_path,
    installed_bin,
    base_url,
    session_id,
    protocol_version,
    health_json,
    tools_json,
    status_json,
    briefing_json,
    project_snapshot_json,
    initialize_json,
    server_log,
    lifecycle_bundle_json,
    lifecycle_bundle_md,
) = sys.argv[1:]

def load(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)

health = load(health_json)
tools = load(tools_json)
status = load(status_json)
briefing = load(briefing_json)
project_snapshot = load(project_snapshot_json)
initialize = load(initialize_json)
lifecycle = load(lifecycle_bundle_json)

tool_count = len(tools.get("result", {}).get("tools", []))
status_text = None
content = status.get("result", {}).get("content", [])
for item in content:
    if item.get("type") == "text":
      status_text = item.get("text", "")
      break

briefing_keys = sorted(briefing.keys())[:10]
project_snapshot_keys = sorted(project_snapshot.keys())[:10]
health_keys = sorted(health.keys())[:10]
generated_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

md = f"""# Release Evidence Bundle

- Generated at: `{generated_at}`
- Binary under test: `{binary_path}`
- Installed smoke path: `{installed_bin}`
- Base URL: `{base_url}`
- Session ID: `{session_id}`
- Protocol version: `{protocol_version}`

## Artifact Install Smoke

- Installed binary responds to `--version`: `{installed_version}`
- Minimum config was seeded into an isolated base path before boot.

## Local Boot + Health

- `/health` responded successfully from the isolated boot.
- Health top-level keys: `{", ".join(health_keys)}`
- Reported version: `{health.get("version", "<missing>")}`

## MCP Handshake + Tool Discovery

- `initialize` succeeded and returned a stable session/protocol pair.
- `tools/list` returned `{tool_count}` tools on the default surface.
- Initialize response keys: `{", ".join(sorted(initialize.keys()))}`

## Repo Workspace Read Path

- `masc_status` completed through MCP after initialization.

```text
{(status_text or "<no text content returned>").strip()}
```

## Dashboard Read Paths

- `/api/v1/dashboard/briefing` returned HTTP-shaped JSON with keys: `{", ".join(briefing_keys)}`
- `/api/v1/dashboard/project-snapshot` returned keys: `{", ".join(project_snapshot_keys)}`

## Keeper Full-Lifecycle Conformance

- Evidence schema: `{lifecycle.get("schema", "<missing>")}`
- Source SHA: `{lifecycle.get("source_sha", "<missing>")}`
- Correlation bundle: `{lifecycle.get("bundle_id", "<missing>")}`
- Result: `{lifecycle.get("status", "<missing>")}` ({lifecycle.get("passed_count", 0)}/{lifecycle.get("scenario_count", 0)})
- Human-readable matrix: `{pathlib.Path(lifecycle_bundle_md).resolve().relative_to(pathlib.Path(outfile).resolve().parent)}`

## Raw Captures

- `install-version.stdout`
- `install-version.stderr`
- `health.json`
- `initialize.headers`
- `initialize.json`
- `tools-list.json`
- `masc-status.json`
- `dashboard-briefing.json`
- `project-snapshot.json`
- `server.log`
- `keeper-full-lifecycle/bundle.json`
- `keeper-full-lifecycle/bundle.md`
- `keeper-full-lifecycle/v01-*.log` through `v15-*.log`

## Re-run

```bash
scripts/release-evidence.sh {binary_path} {outfile}
```
"""

path = pathlib.Path(outfile)
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(md, encoding="utf-8")
PY

echo "release-evidence: wrote ${OUTFILE}"
