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
# Use when a regression lock targets a file that may be legitimately
# deleted by a later PR.
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
roadmap_published_release="$(extract_single '^> Latest published GitHub release: v\([^ ]*\).*$' ROADMAP.md)"
product_package_version="$(extract_single '^> Current package version: v\([^ ]*\).*$' docs/PRODUCT-OPERATING-PLAN.md)"
product_changelog_entry="$(extract_single '^> Latest changelog entry: v\([^ ]*\).*$' docs/PRODUCT-OPERATING-PLAN.md)"
product_published_release="$(extract_single '^> Latest published GitHub release: v\([^ ]*\).*$' docs/PRODUCT-OPERATING-PLAN.md)"
spec_baseline="$(extract_single '^> Snapshot baseline: `dune-project` version `\([^`]*\)`$' docs/spec/SPEC-INDEX.md)"
changelog_latest_release="$(sed -n 's/^## \[\([0-9][^]]*\)\].*/\1/p' CHANGELOG.md | head -n1)"

[[ -n "$product_package_version" ]] || fail "missing current package version in docs/PRODUCT-OPERATING-PLAN.md"
[[ -n "$product_changelog_entry" ]] || fail "missing latest changelog entry in docs/PRODUCT-OPERATING-PLAN.md"
[[ -n "$roadmap_published_release" ]] || fail "missing latest published GitHub release in ROADMAP.md"
[[ -n "$product_published_release" ]] || fail "missing latest published GitHub release in docs/PRODUCT-OPERATING-PLAN.md"
[[ -n "$spec_baseline" ]] || fail "missing snapshot baseline in docs/spec/SPEC-INDEX.md"

[[ "$package_version" == "$product_package_version" ]] || \
  fail "ROADMAP current package version ($package_version) != PRODUCT-OPERATING-PLAN current package version ($product_package_version)"
[[ "$product_changelog_entry" == "$changelog_latest_release" ]] || \
  fail "PRODUCT-OPERATING-PLAN latest changelog entry ($product_changelog_entry) != CHANGELOG latest release ($changelog_latest_release)"
[[ "$product_published_release" == "$roadmap_published_release" ]] || \
  fail "PRODUCT-OPERATING-PLAN latest published release ($product_published_release) != ROADMAP latest published release ($roadmap_published_release)"
[[ "$spec_baseline" == "$package_version" ]] || \
  fail "SPEC-INDEX snapshot baseline ($spec_baseline) != current package version ($package_version)"

require_contains docs/MCP-TEMPLATE.md '"command": "masc-stdio"'
require_not_contains docs/MCP-TEMPLATE.md '"args": ["--stdio"]'

require_not_contains docs/TUI-GUIDE.md './start-masc.sh --tui'

require_contains docs/QUICK-START.md '"method":"initialize"'
require_contains docs/QUICK-START.md 'Mcp-Session-Id: ${SESSION_ID}'
require_contains docs/QUICK-START.md '수동 제어가 필요해도 기본 온보딩은 `masc_start(path=...)` 를 유지한다.'
require_contains docs/QUICK-START.md '운영 기준은 항상 `<base-path>/.masc`다.'
require_contains docs/QUICK-START.md 'scripts/release-evidence.sh _build/default/bin/main_eio.exe .release-evidence/local-release-evidence.md'

require_contains README.md 'docs/RELEASE-EVIDENCE.md'
require_not_contains README.md '/api/v1/command-plane'
require_contains README.md 'dashboard#monitoring?section=journey'
require_contains README.md 'dashboard#command?section=operations'
require_contains README.md 'dashboard#connectors?section=connector-status'
require_contains README.md 'dashboard#workspace?section=verification'
require_not_contains README.md 'dashboard#monitoring/sessions'
require_not_contains README.md 'dashboard#command/intervene'

require_contains docs/PRODUCT-OPERATING-PLAN.md 'Release evidence and local proof'
require_contains docs/PRODUCT-OPERATING-PLAN.md 'Retired surfaces and proposal-only research material are deletion targets'

require_contains docs/DASHBOARD-INTEGRATION.md '- `monitoring`'
require_contains docs/DASHBOARD-INTEGRATION.md '- `connectors`'
require_contains docs/DASHBOARD-INTEGRATION.md '- `#workspace?section=verification`'
require_contains docs/DASHBOARD-INTEGRATION.md '- `command:intervene -> command:operations`'
require_not_contains docs/DASHBOARD-INTEGRATION.md '- `mission`: what needs attention now'
require_not_contains docs/DASHBOARD-INTEGRATION.md '- `intervene`: mutating operator actions'

require_contains docs/spec/A-existing-doc-index.md '`docs/RELEASE-EVIDENCE.md` | Canonical'
require_not_contains docs/spec/A-existing-doc-index.md '`docs/COMMAND-PLANE-RUNBOOK.md` | Canonical'

require_contains docs/spec/SPEC-INDEX.md 'Retired orchestration surfaces and internal references remain only as migration context.'
require_contains docs/spec/SPEC-INDEX.md '`06-command-plane.md` | Command Plane v2 | Internal command-plane reference and migration context | Historical |'
require_not_contains docs/spec/SPEC-INDEX.md 'Keeper 자율 에이전트, Command Plane 오케스트레이션을 제공하며'

require_contains docs/spec/06-command-plane.md '| Status | Retired Historical Reference |'
require_contains docs/spec/06-command-plane.md '삭제된 subsystem의 historical reference'

require_contains docs/spec/01-system-overview.md 'MASC의 현재 canonical front door는 3가지다.'
require_contains docs/spec/01-system-overview.md '### 7.3 Dashboard and Operator Read Visibility'
require_contains docs/spec/01-system-overview.md 'Retired team-session / command-plane HTTP surfaces는 migration context로만 남아 있으며, supported front door로 취급하지 않는다.'

require_contains docs/spec/09-server-transport.md 'GET /api/v1/activity/events'
require_contains docs/spec/09-server-transport.md '`MASC_USE_H2` | `auto`'
require_contains docs/spec/09-server-transport.md '`MASC_GRPC_ENABLED` | 0'
require_not_contains docs/spec/09-server-transport.md '| `server_command_plane_http.ml` |'
require_not_contains docs/spec/09-server-transport.md 'GET /api/v1/activity/feed'
require_not_contains docs/spec/09-server-transport.md '| Workspace | `/api/v1/workspace/*`'
require_not_contains docs/spec/09-server-transport.md '| Command Plane (R) |'

require_contains docs/spec/10-dashboard.md '| `/api/v1/keepers/:name/config` | POST | Keeper config 수정 (PATCH semantic) |'
require_contains docs/spec/10-dashboard.md 'command-plane.ts         -- Retired command-plane type snapshots'
require_contains docs/spec/10-dashboard.md '#monitoring?section=journey'
require_contains docs/spec/10-dashboard.md '#command?section=operations'
require_contains docs/spec/10-dashboard.md '#connectors?section=connector-status'
require_contains docs/spec/10-dashboard.md '#workspace?section=verification'
require_contains docs/spec/10-dashboard.md '| `/api/v1/verification/requests` | GET | Workspace > 검증 read model |'
require_contains docs/spec/10-dashboard.md '| `/api/v1/gate/connectors` | GET | Connectors surface descriptor + live status |'
require_not_contains docs/spec/10-dashboard.md '| `/api/v1/keepers/:name/config` | PATCH |'
require_not_contains docs/spec/10-dashboard.md '| `/api/v1/command-plane` | GET |'
require_not_contains docs/spec/10-dashboard.md 'command-plane.ts         -- Command plane types'
require_not_contains docs/spec/10-dashboard.md '#monitoring?section=sessions'
require_not_contains docs/spec/10-dashboard.md '#command?section=intervene'

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
      rg -o '(docs/[A-Za-z0-9._/-]+\.md|lib/[A-Za-z0-9._/-]+\.(ml|mli)|scripts/[A-Za-z0-9._/-]+\.sh|test/[A-Za-z0-9._/-]+\.ml|dune-project|[A-Za-z0-9._-]+\.opam|ROADMAP\.md|CHANGELOG\.md)' "$file"
    } | sort -u
  )
done

if ((${#missing_refs[@]} > 0)); then
  printf 'doc truth check failed: missing local references detected\n' >&2
  printf '  %s\n' "${missing_refs[@]}" >&2
  exit 1
fi

printf 'Doc truth OK: front-door docs and key specs are aligned with current repo truth\n'

scripts/check-doc-code-refs.sh
