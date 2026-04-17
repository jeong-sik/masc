#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/check-doc-truth.sh

Checks minimal front-door documentation truth against current repo state.
EOF
}

if (($# > 0)); then
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

fail() {
  printf 'doc truth check failed: %s\n' "$1" >&2
  exit 1
}

require_contains() {
  local file="$1"
  local needle="$2"
  if ! grep -Fq -- "$needle" "$file"; then
    fail "$file is missing expected text: $needle"
  fi
}

require_not_contains() {
  local file="$1"
  local needle="$2"
  if grep -Fq -- "$needle" "$file"; then
    fail "$file still contains forbidden text: $needle"
  fi
}

# Like require_contains but silently skips when the file no longer exists.
# Use for regression locks that pin retired-surface markers: if a later PR
# chooses to delete the file entirely (rather than keep the archive banner),
# the lock becomes a no-op instead of a CI blocker. Prior cases: PR #7790
# (04-chain-engine.md archive banner) -> PR #7796 file deletion -> PR #7818
# reactive drop. A file-existence precheck would have made that churn
# unnecessary.
require_contains_if_exists() {
  local file="$1"
  local needle="$2"
  if [ -f "$file" ]; then
    require_contains "$file" "$needle"
  fi
}

extract_single() {
  local pattern="$1"
  local file="$2"
  sed -n "s/$pattern/\\1/p" "$file" | head -n1
}

scripts/check-version-truth.sh

package_version="$(extract_single '^> Current package version: v\([^ ]*\).*$' ROADMAP.md)"
product_package_version="$(extract_single '^> Current package version: v\([^ ]*\).*$' docs/PRODUCT-OPERATING-PLAN.md)"
product_latest_release="$(extract_single '^> Latest release: v\([^ ]*\).*$' docs/PRODUCT-OPERATING-PLAN.md)"
spec_baseline="$(extract_single '^> Snapshot baseline: `dune-project` version `\([^`]*\)`$' docs/spec/SPEC-INDEX.md)"
changelog_latest_release="$(sed -n 's/^## \[\([0-9][^]]*\)\].*/\1/p' CHANGELOG.md | head -n1)"

[[ -n "$product_package_version" ]] || fail "missing current package version in docs/PRODUCT-OPERATING-PLAN.md"
[[ -n "$product_latest_release" ]] || fail "missing latest release in docs/PRODUCT-OPERATING-PLAN.md"
[[ -n "$spec_baseline" ]] || fail "missing snapshot baseline in docs/spec/SPEC-INDEX.md"

[[ "$package_version" == "$product_package_version" ]] || \
  fail "ROADMAP current package version ($package_version) != PRODUCT-OPERATING-PLAN current package version ($product_package_version)"
[[ "$product_latest_release" == "$changelog_latest_release" ]] || \
  fail "PRODUCT-OPERATING-PLAN latest release ($product_latest_release) != CHANGELOG latest release ($changelog_latest_release)"
[[ "$spec_baseline" == "$package_version" ]] || \
  fail "SPEC-INDEX snapshot baseline ($spec_baseline) != current package version ($package_version)"

require_contains docs/MCP-TEMPLATE.md '"command": "masc-mcp-stdio"'
require_not_contains docs/MCP-TEMPLATE.md '"args": ["--stdio"]'

require_not_contains docs/TUI-GUIDE.md './start-masc-mcp.sh --tui'

require_contains docs/QUICK-START.md '"method":"initialize"'
require_contains docs/QUICK-START.md 'Mcp-Session-Id: ${SESSION_ID}'
require_contains docs/QUICK-START.md 'masc_join(agent_name="codex")'
require_contains docs/QUICK-START.md '명시적인 `MASC_BASE_PATH`가 없으면 `HOME`을 implicit base path로 사용한다.'
require_contains docs/QUICK-START.md 'scripts/release-evidence.sh _build/default/bin/main_eio.exe .release-evidence/local-release-evidence.md'

require_contains README.md 'docs/RELEASE-EVIDENCE.md'
require_not_contains README.md '/api/v1/command-plane'

require_contains docs/PRODUCT-OPERATING-PLAN.md 'Release evidence and local proof'
require_contains docs/PRODUCT-OPERATING-PLAN.md 'Retired compatibility lanes and research material remain in-tree for history'

require_contains docs/spec/A-existing-doc-index.md '`docs/RELEASE-EVIDENCE.md` | Canonical'
require_not_contains docs/spec/A-existing-doc-index.md '`docs/COMMAND-PLANE-RUNBOOK.md` | Canonical'

require_contains docs/spec/SPEC-INDEX.md 'Historical compatibility lane과 internal orchestration reference는 migration context로만 남긴다.'
require_contains docs/spec/SPEC-INDEX.md '`06-command-plane.md` | Command Plane v2 | Internal command-plane reference and migration context | Historical |'
require_not_contains docs/spec/SPEC-INDEX.md 'Keeper 자율 에이전트, Command Plane 오케스트레이션을 제공하며'

require_contains docs/spec/06-command-plane.md '| Status | Historical Reference |'
require_contains docs/spec/06-command-plane.md '현재 supported front door가 아닌 internal/historical reference subsystem'

require_contains docs/spec/01-system-overview.md 'MASC의 현재 canonical front door는 3가지다.'
require_contains docs/spec/01-system-overview.md '### 7.3 Dashboard and Operator Read Visibility'
require_contains docs/spec/01-system-overview.md 'Historical compatibility lane(team-session / command-plane HTTP)은 migration context로만 남아 있으며, supported front door로 취급하지 않는다.'

require_contains docs/spec/09-server-transport.md 'GET /api/v1/activity/events'
require_contains docs/spec/09-server-transport.md '`MASC_USE_H2` | `auto`'
require_contains docs/spec/09-server-transport.md '`MASC_GRPC_ENABLED` | 1'
require_contains docs/spec/09-server-transport.md '| `server_command_plane_http.ml` | 56 | Retired compatibility lane removed-surface responder |'
require_not_contains docs/spec/09-server-transport.md 'GET /api/v1/activity/feed'
require_not_contains docs/spec/09-server-transport.md '| Room | `/api/v1/room/*`'
require_not_contains docs/spec/09-server-transport.md '| Command Plane (R) |'

require_contains docs/spec/10-dashboard.md '| `/api/v1/keepers/:name/config` | POST | Keeper config 수정 (PATCH semantic) |'
require_contains docs/spec/10-dashboard.md 'command-plane.ts         -- Historical compatibility types'
require_not_contains docs/spec/10-dashboard.md '| `/api/v1/keepers/:name/config` | PATCH |'
require_not_contains docs/spec/10-dashboard.md '| `/api/v1/command-plane` | GET |'
require_not_contains docs/spec/10-dashboard.md 'command-plane.ts         -- Command plane types'

# Regression locks for retired surfaces (team_session / chain purge).
# Each lock pins an already-merged PR claim so future doc edits
# cannot silently re-introduce the stale description.

# PR #7773: Team Session glossary marked retired (module purged)
require_contains docs/spec/00-glossary.md '## Team Session (retired)'
require_contains docs/spec/00-glossary.md '**Team Session** (retired)'

# PR #7779: OAS-MASC boundary marks team-session bridge as Removed
require_contains docs/OAS-MASC-BOUNDARY.md '| Team-session swarm | Removed |'
require_not_contains docs/OAS-MASC-BOUNDARY.md '| `lib/team_session/team_session_oas_bridge.ml` | Acceptable'

docs_to_scan=(
  README.md
  ROADMAP.md
  docs/PRODUCT-OPERATING-PLAN.md
  docs/QUICK-START.md
  docs/MCP-TEMPLATE.md
  docs/TUI-GUIDE.md
  docs/spec/SPEC-INDEX.md
  docs/spec/01-system-overview.md
  docs/spec/06-command-plane.md
  docs/spec/09-server-transport.md
  docs/spec/10-dashboard.md
  docs/spec/A-existing-doc-index.md
  docs/KEEPER-USER-MANUAL.md
  docs/RELEASE-EVIDENCE.md
)

missing_refs=()
for file in "${docs_to_scan[@]}"; do
  while IFS= read -r ref; do
    [[ -n "$ref" ]] || continue
    [[ "$ref" == *"*"* ]] && continue
    [[ "$ref" == *"..."* ]] && continue
    [[ -e "$ref" ]] || missing_refs+=("$file -> $ref")
  done < <(
    {
      rg -o '\((docs/[^)# ]+|ROADMAP\.md|CHANGELOG\.md)\)' "$file" | sed 's/^('// | sed 's/)$//'
      rg -o '(docs/[A-Za-z0-9._/-]+\.md|lib/[A-Za-z0-9._/-]+\.(ml|mli)|scripts/[A-Za-z0-9._/-]+\.sh|test/[A-Za-z0-9._/-]+\.ml|dune-project|masc_mcp\.opam|ROADMAP\.md|CHANGELOG\.md)' "$file"
    } | sort -u
  )
done

if ((${#missing_refs[@]} > 0)); then
  printf 'doc truth check failed: missing local references detected\n' >&2
  printf '  %s\n' "${missing_refs[@]}" >&2
  exit 1
fi

printf 'Doc truth OK: front-door docs and key specs are aligned with current repo truth\n'
