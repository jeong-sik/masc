#!/bin/bash

set -euo pipefail

fail() {
    echo "[deploy-cutover-gates] $*" >&2
    exit 1
}

fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/deploy-cutover-gates.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT

mkdir -p \
    "$fixture_root/scripts" \
    "$fixture_root/_build/default/bin" \
    "$fixture_root/base/.masc"
cp "$(dirname "${BASH_SOURCE[0]}")/deploy.sh" "$fixture_root/scripts/deploy.sh"

cat >"$fixture_root/_build/default/bin/main_eio.exe" <<'EOF'
#!/bin/bash
exit 0
EOF

cat >"$fixture_root/_build/default/bin/keeper_event_queue_v15_cutover_helper.exe" <<'EOF'
#!/bin/bash
exit 0
EOF

cat >"$fixture_root/scripts/check-keeper-event-queue-v15-cutover.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
printf 'event_queue\n' >>"$CUTOVER_TRACE"
EOF

cat >"$fixture_root/_build/default/bin/keeper_board_cursor_cutover_check.exe" <<'EOF'
#!/bin/bash
set -euo pipefail
printf 'board_cursor\n' >>"$CUTOVER_TRACE"
if [ "${BOARD_CURSOR_CUTOVER_FAIL:-0}" = "1" ]; then
    exit 2
fi
EOF

chmod +x \
    "$fixture_root/scripts/deploy.sh" \
    "$fixture_root/scripts/check-keeper-event-queue-v15-cutover.sh" \
    "$fixture_root/_build/default/bin/main_eio.exe" \
    "$fixture_root/_build/default/bin/keeper_event_queue_v15_cutover_helper.exe" \
    "$fixture_root/_build/default/bin/keeper_board_cursor_cutover_check.exe"

trace_path="$fixture_root/cutover.trace"
export CUTOVER_TRACE="$trace_path"
MASC_BASE_PATH="$fixture_root/base" \
MASC_EVENT_QUEUE_V15_CUTOVER_LEASE_OWNER_PID="$$" \
    "$fixture_root/scripts/deploy.sh" \
    --skip-build \
    --prepare-under-cutover-lease

expected_trace=$'event_queue\nboard_cursor'
actual_trace="$(cat "$trace_path")"
[ "$actual_trace" = "$expected_trace" ] \
    || fail "cutover gates ran out of order: $actual_trace"
[ -x "$fixture_root/releases/main_eio.exe" ] \
    || fail "release was not installed after both cutover gates passed"

rm -f "$fixture_root/releases/main_eio.exe" "$trace_path"
if BOARD_CURSOR_CUTOVER_FAIL=1 \
    MASC_BASE_PATH="$fixture_root/base" \
    MASC_EVENT_QUEUE_V15_CUTOVER_LEASE_OWNER_PID="$$" \
    "$fixture_root/scripts/deploy.sh" \
    --skip-build \
    --prepare-under-cutover-lease; then
    fail "deployment continued after the Board cursor cutover gate failed"
fi
[ ! -e "$fixture_root/releases/main_eio.exe" ] \
    || fail "release was installed after the Board cursor cutover gate failed"

printf '[deploy-cutover-gates] self-test OK\n'
