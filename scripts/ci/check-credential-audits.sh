#!/usr/bin/env bash
# CI gate: keeper credential audit scripts self-test.
#
# Verifies that the two read-only audit scripts merged in #10706 and
# #10718 still detect the violations they document. This guards
# against silent regressions in the audit logic itself — a refactor
# of either script that breaks detection would otherwise go unnoticed
# until production drift accumulates again.
#
# Tests (each fixture is a synthetic .masc/auth/agents/ tree):
#   1. clean       — bare+canonical stubs both redirect to the same
#                    well-formed UUID file.
#                    drift     → exit 0 (converged)
#                    integrity → exit 0 (no violations)
#
#   2. split-brain — bare stub redirects to UUID-A, canonical stub
#                    redirects to UUID-B. Two real UUID files.
#                    drift     → exit 1 (split-brain detected)
#
#   3. dangling    — bare stub redirects to a UUID file that does
#                    not exist on disk.
#                    integrity → exit 1 (dangling redirect detected)
#
#   4. orphan      — a UUID file with no inbound redirect stub.
#                    integrity → exit 1 (orphan UUID detected)
#
# All fixtures are built inline; nothing under repo control is
# modified or read.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

DRIFT="scripts/audit-keeper-credential-drift.sh"
INTEG="scripts/audit-keeper-credential-uuid-integrity.sh"

if [[ ! -x "$DRIFT" || ! -x "$INTEG" ]]; then
  chmod +x "$DRIFT" "$INTEG"
fi

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

write_uuid_file() {
  # write_uuid_file <agents_dir> <uuid> <agent_name>
  local dir="$1" uuid="$2" name="$3"
  cat > "${dir}/${uuid}.json" <<EOF
{
  "id": "${uuid}",
  "agent_name": "${name}",
  "token": "test-token-${uuid:0:8}",
  "role": "worker",
  "admin": false,
  "created_at": "2026-04-26T00:00:00Z"
}
EOF
}

write_stub() {
  # write_stub <agents_dir> <stem> <target_uuid>
  local dir="$1" stem="$2" target="$3"
  printf '{ "redirect_to": "%s.json" }\n' "$target" > "${dir}/${stem}.json"
}

build_clean() {
  local base="$1"
  local agents="${base}/.masc/auth/agents"
  mkdir -p "$agents"
  local uuid="11111111-1111-4111-8111-111111111111"
  write_uuid_file "$agents" "$uuid" "keeper-alpha-agent"
  write_stub "$agents" "alpha" "$uuid"
  write_stub "$agents" "keeper-alpha-agent" "$uuid"
}

build_split_brain() {
  local base="$1"
  local agents="${base}/.masc/auth/agents"
  mkdir -p "$agents"
  local uuid_a="22222222-2222-4222-8222-222222222222"
  local uuid_b="33333333-3333-4333-8333-333333333333"
  write_uuid_file "$agents" "$uuid_a" "keeper-beta-agent"
  write_uuid_file "$agents" "$uuid_b" "keeper-beta-agent"
  write_stub "$agents" "beta" "$uuid_a"
  write_stub "$agents" "keeper-beta-agent" "$uuid_b"
}

build_dangling() {
  local base="$1"
  local agents="${base}/.masc/auth/agents"
  mkdir -p "$agents"
  write_stub "$agents" "gamma" "44444444-4444-4444-8444-444444444444"
}

build_orphan() {
  local base="$1"
  local agents="${base}/.masc/auth/agents"
  mkdir -p "$agents"
  local uuid="55555555-5555-4555-8555-555555555555"
  write_uuid_file "$agents" "$uuid" "keeper-delta-agent"
}

run_with_expect() {
  # run_with_expect <label> <expected_exit> <script> <base>
  local label="$1" expected="$2" script="$3" base="$4"
  local actual
  set +e
  bash "$script" --base-path "$base" --json >/dev/null 2>&1
  actual=$?
  set -e
  if [[ "$actual" -ne "$expected" ]]; then
    printf '  FAIL  %s: expected exit %d, got %d\n' "$label" "$expected" "$actual" >&2
    return 1
  fi
  printf '  ok    %s (exit %d)\n' "$label" "$actual"
  return 0
}

echo "=== Credential audit self-test ==="

clean="${tmpdir}/clean"
split="${tmpdir}/split-brain"
dangling="${tmpdir}/dangling"
orphan="${tmpdir}/orphan"
build_clean "$clean"
build_split_brain "$split"
build_dangling "$dangling"
build_orphan "$orphan"

failed=0
run_with_expect "drift on clean"               0 "$DRIFT" "$clean"    || failed=1
run_with_expect "drift on split-brain"         1 "$DRIFT" "$split"    || failed=1
run_with_expect "integrity on clean"           0 "$INTEG" "$clean"    || failed=1
run_with_expect "integrity on dangling"        1 "$INTEG" "$dangling" || failed=1
run_with_expect "integrity on orphan"          1 "$INTEG" "$orphan"   || failed=1

if [[ "$failed" -ne 0 ]]; then
  echo "credential audit self-test: FAILED" >&2
  exit 1
fi

echo "credential audit self-test: ok"
