#!/usr/bin/env bash
# Self-test for harness-connector-env-ratchet.sh.
#
# The ratchet's fixtures are real files under scripts/, so its answer changes
# whenever the harness tree changes — same reasoning that keeps
# test-suites-are-declared-as-tests.sh out of run_self_test_when_changed.
# This self-test pins the guard's behavior in a sandbox: a synthetic tree with
# one covered boot file, one uncovered boot file, and one non-booting file.
set -euo pipefail

ROOT="${HARNESS_RATCHET_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
# Same mis-root hazard as the ratchet itself: fail loudly if this file was
# resolved from outside the masc checkout.
if [ ! -d "${ROOT}/scripts/harness" ]; then
  echo "harness-connector-env-ratchet self-test ERROR: ROOT '${ROOT}' is not the masc checkout (set HARNESS_RATCHET_ROOT explicitly)" >&2
  exit 2
fi
RATCHET="${ROOT}/scripts/lint/harness-connector-env-ratchet.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/harness-ratchet-selftest.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/scripts/harness/lib" "$TMP/scripts/lint"
cp "$RATCHET" "$TMP/scripts/lint/harness-connector-env-ratchet.sh"

# 1) lib-only boot file: server bootstrap covers it (via harness_start_server).
cp "${ROOT}/scripts/harness/lib/server_bootstrap.sh" "$TMP/scripts/harness/lib/server_bootstrap.sh"

# 2) covered direct-boot file (unset before launch).
cat >"$TMP/scripts/harness_cov.sh" <<'EOF'
#!/usr/bin/env bash
unset SLACK_BOT_TOKEN SLACK_APP_TOKEN DISCORD_BOT_TOKEN
_build/default/bin/main_eio.exe --port 1 &
EOF

# 3) uncovered direct-boot file: the regression this guard exists for.
cat >"$TMP/scripts/harness_hole.sh" <<'EOF'
#!/usr/bin/env bash
_build/default/bin/main_eio.exe --port 1 &
EOF

# 4) non-booting harness file: must never count. main_eio.exe appears only
#    inside a comment — the comment stripper must erase it.
cat >"$TMP/scripts/harness_quiet.sh" <<'EOF'
#!/usr/bin/env bash
# docs say main_eio.exe boots the server; this file never does
echo "only a helper"
EOF

# The sandbox tree CONTAINS the hole by design, so the run must fail — with
# exactly the hole named, and only the hole.
fail() { echo "self-test FAILED: $1" >&2; exit 1; }

out="$(bash "$TMP/scripts/lint/harness-connector-env-ratchet.sh" 2>&1)" \
  && fail "hole fixture present, ratchet should exit 1"
grep -q "harness_hole.sh" <<<"$out" || fail "uncovered boot file not reported"
grep -q "harness_cov.sh" <<<"$out" && fail "covered file wrongly reported"
grep -q "harness_quiet.sh" <<<"$out" && fail "comment-only file wrongly reported"

# Now heal the hole the way a real fix would (delete it) — exit flips to 0.
rm "$TMP/scripts/harness_hole.sh"
out2="$(bash "$TMP/scripts/lint/harness-connector-env-ratchet.sh" 2>&1)" \
  || fail "healed tree should pass (got: $out2)"
grep -q "0 violations" <<<"$out2" || fail "healed tree should report 0 violations"

echo "harness-connector-env-ratchet self-test: pass"
