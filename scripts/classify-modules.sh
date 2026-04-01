#!/usr/bin/env bash
# classify-modules.sh — Post-process migration audit with domain knowledge.
# Reads: reports/migration-audit-YYYYMMDD.tsv
# Writes: reports/migration-classification-YYYYMMDD.tsv
#
# Classification strategy:
#   - Subsystem-based bulk classification (not time-based)
#   - Core infra: always active
#   - Experimental subsystems (trpg, voice, a2a): archive
#   - OAS-integrated: active
#   - Remaining: classified by ref count + category

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TODAY="$(date +%Y%m%d)"
INPUT="${1:-$REPO_ROOT/reports/migration-audit-${TODAY}.tsv}"
OUTPUT="$REPO_ROOT/reports/migration-classification-${TODAY}.tsv"

if [ ! -f "$INPUT" ]; then
  echo "Error: Input file not found: $INPUT" >&2
  exit 1
fi

# Header
printf "file\tlines\tcategory\taction\treason\thas_oas\tref_count\n" > "$OUTPUT"

total=0; active=0; archive=0; delete_count=0
active_loc=0; archive_loc=0; delete_loc=0

while IFS=$'\t' read -r file lines last_date days_since has_oas ref_count category _action _reason; do
  [ "$file" = "file" ] && continue  # skip header
  base="${file%.ml}"

  action="active"
  reason="core"

  # === ARCHIVE: Experimental subsystems ===
  case "$base" in
    trpg_*)
      action="archive"; reason="experimental_trpg" ;;
    voice_*)
      action="archive"; reason="experimental_voice" ;;
    a2a_*)
      action="archive"; reason="experimental_a2a" ;;
  esac

  # === ARCHIVE: Dashboard proof/mission (heavy render, can be lazy-loaded) ===
  case "$base" in
    dashboard_proof*|dashboard_mission_assembly*|dashboard_mission_briefing*)
      action="archive"; reason="dashboard_heavy_render" ;;
    dashboard_execution_builders*|dashboard_execution_fixture*)
      action="archive"; reason="dashboard_builder" ;;
    dashboard_governance*|dashboard_operator_judge*)
      action="archive"; reason="dashboard_governance" ;;
  esac

  # === ACTIVE: Core infrastructure (always needed) ===
  case "$base" in
    backend|backend_eio|server_*|mcp_server_*|config|env_config|masc_mcp)
      action="active"; reason="core_server" ;;
    tool_dispatch|tool_tag_init|tool_catalog|tool_inline_dispatch|tool_inline_dispatch_extra)
      action="active"; reason="core_dispatch" ;;
    room|room_*|task_*|agent_*)
      action="active"; reason="core_coordination" ;;
    masc_pb)
      action="active"; reason="generated_protobuf" ;;
  esac

  # === ACTIVE: OAS-integrated modules ===
  if [ "$has_oas" = "yes" ] && [ "$action" != "active" ]; then
    action="active"; reason="oas_integrated"
  fi

  # === ACTIVE: Types and config always needed ===
  case "$category" in
    types|config)
      action="active"; reason="types_or_config" ;;
  esac

  # === ACTIVE: High-dependency modules ===
  if [ "$ref_count" -ge 8 ] && [ "$action" != "active" ]; then
    action="active"; reason="high_dependency_${ref_count}"
  fi

  # === ARCHIVE: tool_schemas_* (can be auto-generated) ===
  case "$base" in
    tool_schemas_*|tool_command_plane_schemas_*)
      action="archive"; reason="schema_codegen_candidate" ;;
    tool_schemas_inline)
      action="active"; reason="primary_schema" ;;
  esac

  # === DELETE: Known dead/duplicate code ===
  # model_client was already deleted; check for leftover stubs
  case "$base" in
    model_client_core|model_client_providers|model_transport)
      action="delete"; reason="replaced_by_oas" ;;
  esac

  # === ARCHIVE: Low-ref tools that aren't core dispatch ===
  if [ "$action" = "active" ] && [ "$reason" = "core" ]; then
    # Not yet classified — check if it's a low-value tool
    case "$category" in
      tool)
        if [ "$ref_count" -le 1 ] && [ "$lines" -gt 500 ]; then
          action="archive"; reason="low_ref_large_tool"
        elif [ "$ref_count" -eq 0 ]; then
          action="archive"; reason="unreferenced_tool"
        fi
        ;;
      keeper)
        # Keepers are mostly active (heartbeat system)
        action="active"; reason="keeper_system"
        ;;
      autonomy)
        action="active"; reason="autonomy_system"
        ;;
      command_plane)
        action="active"; reason="command_plane"
        ;;
      lifecycle)
        action="active"; reason="lifecycle_system"
        ;;
      team_session)
        action="active"; reason="team_session"
        ;;
      agent_swarm)
        action="active"; reason="agent_swarm"
        ;;
      dashboard)
        action="active"; reason="dashboard_core"
        ;;
      context)
        action="active"; reason="context_system"
        ;;
      oas_bridge)
        action="active"; reason="oas_bridge"
        ;;
      infrastructure)
        if [ "$ref_count" -eq 0 ]; then
          action="archive"; reason="unreferenced_infra"
        else
          action="active"; reason="referenced_infra"
        fi
        ;;
    esac
  fi

  printf "%s\t%d\t%s\t%s\t%s\t%s\t%d\n" \
    "$file" "$lines" "$category" "$action" "$reason" "$has_oas" "$ref_count" \
    >> "$OUTPUT"

  total=$((total + 1))
  case "$action" in
    active) active=$((active + 1)); active_loc=$((active_loc + lines)) ;;
    archive) archive=$((archive + 1)); archive_loc=$((archive_loc + lines)) ;;
    delete) delete_count=$((delete_count + 1)); delete_loc=$((delete_loc + lines)) ;;
  esac
done < "$INPUT"

cat >&2 <<EOF

============================================
  MASC-MCP Module Classification
  Date: $(date +%Y-%m-%d)
  Input: $INPUT
============================================

Total files:     $total
  Active:        $active  ($active_loc LOC)
  Archive:       $archive  ($archive_loc LOC)
  Delete:        $delete_count  ($delete_loc LOC)

Reduction:       $((archive_loc + delete_loc)) LOC ($((( (archive_loc + delete_loc) * 100) / (active_loc + archive_loc + delete_loc) ))%)

=== Archive Subsystems ===
EOF

for subsys in trpg voice a2a dashboard_heavy dashboard_builder dashboard_governance schema_codegen low_ref_large unreferenced; do
  count=$(awk -F'\t' -v s="$subsys" 'NR>1 && $5 ~ s {n++; loc+=$2} END {printf "%d files, %d LOC", n+0, loc+0}' "$OUTPUT")
  printf "  %-30s %s\n" "$subsys" "$count" >&2
done

echo "" >&2
echo "=== Active by Reason ===" >&2
awk -F'\t' 'NR>1 && $4=="active" {r[$5]++; loc[$5]+=$2} END {for(k in r) printf "  %-30s %3d files  %6d LOC\n", k, r[k], loc[k]}' "$OUTPUT" | sort -t' ' -k4 -rn >&2

echo "" >&2
echo "=== God Files (850+) by Action ===" >&2
awk -F'\t' 'NR>1 && $2>=850 {printf "  %-45s %5d  [%-8s] %s\n", $1, $2, $4, $5}' "$OUTPUT" | sort -t'[' >&2

echo "" >&2
echo "Output: $OUTPUT" >&2
