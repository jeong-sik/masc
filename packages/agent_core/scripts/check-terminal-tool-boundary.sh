#!/usr/bin/env bash
set -euo pipefail

SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="${TERMINAL_BOUNDARY_ROOT:-$SOURCE_ROOT}"
PLANNER="$ROOT/lib/agent/agent_tool_batch_plan.ml"
BOUNDARY="$ROOT/lib/agent/agent_tool_terminal_boundary.ml"
PIPELINE="$ROOT/lib/pipeline/pipeline_terminal_tool.ml"
TOOL_MLI="$ROOT/lib/base/tool.mli"
CONTRACT_MLI="$ROOT/lib/base/tool_contract.mli"
ERROR_MLI="$ROOT/lib/base/error.mli"
HOOKS_MLI="$ROOT/lib/base/hooks.mli"
RECEIPT_ML="$ROOT/lib/terminal_tool_receipt.ml"
RECEIPT_MLI="$ROOT/lib/terminal_tool_receipt.mli"
PIPELINE_MLI="$ROOT/lib/pipeline/pipeline.mli"
AGENT_MLI="$ROOT/lib/agent/agent.mli"
EVENT="$ROOT/lib/execution_event.ml"
RESPONSE_SNAPSHOT="$ROOT/lib/execution_provider_response_snapshot.ml"

fail() {
  printf 'terminal-tool boundary violation: %s\n' "$1" >&2
  exit 1
}

matches_pattern() {
  local case_mode="$1"
  local pattern="$2"
  shift 2
  local backend="${TERMINAL_BOUNDARY_SEARCH_BACKEND:-auto}"
  if [[ "$backend" == "auto" ]]; then
    if command -v rg >/dev/null 2>&1; then
      backend="rg"
    elif command -v perl >/dev/null 2>&1; then
      backend="perl"
    else
      fail "requires either rg or perl; refusing to skip the boundary check"
    fi
  fi

  if [[ "$backend" == "rg" ]]; then
    command -v rg >/dev/null 2>&1 \
      || fail "requested rg search backend is unavailable"
    local args=(-q --multiline)
    if [[ "$case_mode" == "insensitive" ]]; then
      args+=(-i)
    fi
    if rg "${args[@]}" "$pattern" "$@"; then
      return 0
    else
      local status=$?
      if [[ $status -eq 1 ]]; then
        return 1
      fi
      fail "rg failed while evaluating the boundary"
    fi
  elif [[ "$backend" == "perl" ]]; then
    command -v perl >/dev/null 2>&1 \
      || fail "requested perl search backend is unavailable"
    if perl -e '
      use strict;
      use warnings;

      my ($case_mode, $pattern, @paths) = @ARGV;
      my $regex = eval {
        $case_mode eq "insensitive" ? qr/$pattern/mi : qr/$pattern/m
      };
      if ($@) {
        print STDERR "cannot compile boundary pattern: $@\n";
        exit 2;
      }

      sub io_error {
        my ($detail) = @_;
        print STDERR "$detail\n";
        exit 2;
      }

      sub visit {
        my ($path) = @_;
        my @metadata = stat $path;
        @metadata or io_error("cannot stat $path: $!");
        if (-d _) {
          opendir my $directory, $path
            or io_error("cannot open directory $path: $!");
          my @entries = sort grep { $_ ne "." && $_ ne ".." } readdir $directory;
          closedir $directory
            or io_error("cannot close directory $path: $!");
          visit("$path/$_") for @entries;
          return;
        }
        return unless -f _;

        open my $handle, "<", $path
          or io_error("cannot open $path: $!");
        my $content = "";
        while (1) {
          my $count = read $handle, my $chunk, 65_536;
          defined $count or io_error("cannot read $path: $!");
          last if $count == 0;
          $content .= $chunk;
        }
        close $handle or io_error("cannot close $path: $!");
        exit 0 if $content =~ $regex;
      }

      visit($_) for @paths;
      exit 1;
    ' "$case_mode" "$pattern" "$@"; then
      return 0
    else
      local status=$?
      if [[ $status -eq 1 ]]; then
        return 1
      fi
      fail "perl failed while evaluating the boundary"
    fi
  else
    fail "unsupported search backend: $backend"
  fi
}

require_pattern() {
  local pattern="$1"
  local file="$2"
  local detail="$3"
  matches_pattern sensitive "$pattern" "$file" || fail "$detail"
}

check_boundary() {
  if matches_pattern insensitive \
    'provider|model|tier|pricing|price|parallel[_ -]?tool|parallel[_ -]?call' \
    "$PLANNER"; then
    fail "the admission planner must remain provider, pricing, and parallel-flag neutral"
  fi

  if matches_pattern sensitive \
    'String\.(equal|starts_with|ends_with)|Str\.|Re\.' \
    "$PLANNER"; then
    fail "the admission planner must not infer completion from tool-name strings"
  fi

  if matches_pattern sensitive \
    '(String\.(equal|starts_with|ends_with).*(terminal|Terminal)|(terminal|Terminal).*String\.(equal|starts_with|ends_with)|terminal.*parallel|parallel.*terminal)' \
    "$ROOT/lib/agent" "$ROOT/lib/pipeline"; then
    fail "terminal control flow must use typed metadata only"
  fi

  require_pattern \
    'Terminal_after_success of failure_effect_disposition' \
    "$CONTRACT_MLI" \
    "terminal completion and failure-effect disposition must remain one closed value"
  require_pattern \
    'terminal_descriptor : Tool_contract\.failure_effect_disposition -> descriptor' \
    "$TOOL_MLI" \
    "terminal descriptors must require an explicit failure-effect disposition"
  require_pattern \
    'completion:completion[[:space:]]*->[[:space:]]*t' \
    "$CONTRACT_MLI" \
    "immutable invocations must require completion at construction"
  require_pattern \
    'invocation : Tool_contract\.Invocation\.t' \
    "$ERROR_MLI" \
    "terminal durability errors must depend on the canonical invocation leaf"
  require_pattern \
    'type closed_terminal_effect' \
    "$ERROR_MLI" \
    "terminal errors must carry an opaque closed-effect proof"
  if matches_pattern sensitive \
    'type (execution_mode|failure_effect_disposition|completion|schedule)|module Invocation' \
    "$TOOL_MLI"; then
    fail "Tool must not expose a second invocation-contract type family"
  fi
  if matches_pattern sensitive \
    'type terminal_effect_disposition|invocation : Tool\.Invocation\.t' \
    "$ERROR_MLI"; then
    fail "Error must not duplicate disposition or depend on the Tool handler module"
  fi
  if matches_pattern sensitive 'type tool_schedule' "$HOOKS_MLI"; then
    fail "Hooks must use the canonical schedule without a second type alias"
  fi
  require_pattern \
    'invocation : Tool_contract\.Invocation\.t' \
    "$RECEIPT_MLI" \
    "terminal success receipts must carry the canonical invocation"
  require_pattern \
    'TerminalToolCompleted of Terminal_tool_receipt\.t' \
    "$PIPELINE_MLI" \
    "Pipeline must expose the canonical terminal receipt"
  require_pattern \
    'TerminalToolCompleted of Terminal_tool_receipt\.t' \
    "$AGENT_MLI" \
    "Agent must expose the canonical terminal receipt"
  require_pattern \
    '; receipt : Terminal_tool_receipt\.t' \
    "$AGENT_MLI" \
    "Advanced terminal completion must compose the canonical receipt"
  if matches_pattern sensitive \
    'type terminal_tool_(turn_)?completion' \
    "$ROOT/lib"; then
    fail "terminal success receipts must not be redeclared"
  fi
  local receipt_consumers=()
  while IFS= read -r source; do
    receipt_consumers+=("$source")
  done < <(
    find "$ROOT/lib" \
      -type f \
      \( -name '*.ml' -o -name '*.mli' \) \
      ! -path "$RECEIPT_ML" \
      ! -path "$RECEIPT_MLI" \
      -print
  )
  if ((${#receipt_consumers[@]} > 0)) \
    && matches_pattern sensitive \
      'type[[:space:]]+[A-Za-z0-9_]+[[:space:]]*=[[:space:]]*\{[^}]*(invocation[[:space:]]*:[[:space:]]*Tool_contract\.Invocation\.t[^}]*checkpoint_stage[[:space:]]*:[^;}]+[^}]*response[[:space:]]*:[[:space:]]*Types\.api_response|invocation[[:space:]]*:[[:space:]]*Tool_contract\.Invocation\.t[^}]*response[[:space:]]*:[[:space:]]*Types\.api_response[^}]*checkpoint_stage[[:space:]]*:[^;}]+|checkpoint_stage[[:space:]]*:[^;}]+[^}]*invocation[[:space:]]*:[[:space:]]*Tool_contract\.Invocation\.t[^}]*response[[:space:]]*:[[:space:]]*Types\.api_response|checkpoint_stage[[:space:]]*:[^;}]+[^}]*response[[:space:]]*:[[:space:]]*Types\.api_response[^}]*invocation[[:space:]]*:[[:space:]]*Tool_contract\.Invocation\.t|response[[:space:]]*:[[:space:]]*Types\.api_response[^}]*invocation[[:space:]]*:[[:space:]]*Tool_contract\.Invocation\.t[^}]*checkpoint_stage[[:space:]]*:[^;}]+|response[[:space:]]*:[[:space:]]*Types\.api_response[^}]*checkpoint_stage[[:space:]]*:[^;}]+[^}]*invocation[[:space:]]*:[[:space:]]*Tool_contract\.Invocation\.t)[^}]*\}' \
      "${receipt_consumers[@]}"; then
    fail "canonical invocation/response/checkpoint-stage receipt fields must not be redeclared"
  fi
  require_pattern \
    '; completion : Tool_contract\.completion' \
    "$EVENT" \
    "Tool_invocation events must persist completion"
  require_pattern \
    'required:\[[^]]*"completion"' \
    "$EVENT" \
    "the current event decoder must require persisted completion"
  require_pattern \
    '; "schedule"[[:space:]]*; "completion"' \
    "$EVENT" \
    "the common strict decoder whitelist must admit required completion"
  require_pattern \
    'schema_version_current = 3' \
    "$EVENT" \
    "execution events must reject pre-completion schema versions"
  require_pattern \
    'Provider_response_snapshot of Llm_provider\.Types\.api_response' \
    "$EVENT" \
    "provider attempts must persist one full response snapshot"
  require_pattern \
    '~required:\[[^]]*"id"[^]]*"model"[^]]*"stop_reason"[^]]*"content"[^]]*"usage"[^]]*"telemetry"' \
    "$RESPONSE_SNAPSHOT" \
    "the current response snapshot decoder must require full response provenance"
  if matches_pattern sensitive \
    'Provider_response_id_snapshot|provider_response_id_snapshot' \
    "$ROOT/lib"; then
    fail "legacy provider response ID-only snapshots must not survive"
  fi
  require_pattern \
    'Tool_contract\.Invocation\.completion invocation' \
    "$BOUNDARY" \
    "durable terminal recovery must use persisted invocation completion"

  if matches_pattern \
    sensitive \
    'Tool_set|find_tool|Tool\.completion[[:space:]]|let response agent tool_uses' \
    "$PIPELINE"; then
    fail "pipeline recovery must not reconstruct completion or provider responses"
  fi

  if matches_pattern \
    sensitive \
    'find_tool|Tool_set|tool_name.*completion|completion.*tool_name' \
    "$BOUNDARY"; then
    fail "terminal recovery must remain catalog- and tool-name-independent"
  fi

  printf 'terminal-tool boundary: OK\n'
}

self_test() {
  local fixture
  command -v perl >/dev/null 2>&1 \
    || fail "self-test requires perl to exercise the fallback backend"
  fixture="$(mktemp -d)"
  trap "rm -rf '$fixture'" EXIT
  mkdir -p \
    "$fixture/lib/agent" \
    "$fixture/lib/pipeline" \
    "$fixture/lib/base"
  cp "$PLANNER" "$fixture/lib/agent/agent_tool_batch_plan.ml"
  cp "$BOUNDARY" "$fixture/lib/agent/agent_tool_terminal_boundary.ml"
  cp "$PIPELINE" "$fixture/lib/pipeline/pipeline_terminal_tool.ml"
  cp "$TOOL_MLI" "$fixture/lib/base/tool.mli"
  cp "$CONTRACT_MLI" "$fixture/lib/base/tool_contract.mli"
  cp "$ERROR_MLI" "$fixture/lib/base/error.mli"
  cp "$HOOKS_MLI" "$fixture/lib/base/hooks.mli"
  cp "$RECEIPT_MLI" "$fixture/lib/terminal_tool_receipt.mli"
  cp "$PIPELINE_MLI" "$fixture/lib/pipeline/pipeline.mli"
  cp "$AGENT_MLI" "$fixture/lib/agent/agent.mli"
  cp "$EVENT" "$fixture/lib/execution_event.ml"
  cp "$RESPONSE_SNAPSHOT" "$fixture/lib/execution_provider_response_snapshot.ml"

  printf '\nlet _forbidden = Tool_set.to_list\n' \
    >> "$fixture/lib/pipeline/pipeline_terminal_tool.ml"
  if TERMINAL_BOUNDARY_SEARCH_BACKEND=perl \
    TERMINAL_BOUNDARY_ROOT="$fixture" \
    "$0" --check >/dev/null 2>&1; then
    fail "negative self-test failed to detect current-catalog reconstruction"
  fi
  cp "$PIPELINE" "$fixture/lib/pipeline/pipeline_terminal_tool.ml"

  mkdir -p "$fixture/lib/pipeline/nested/deeper"
  printf 'let terminal_parallel = ()\n' \
    > "$fixture/lib/pipeline/nested/deeper/forbidden.ml"
  if TERMINAL_BOUNDARY_SEARCH_BACKEND=perl \
    TERMINAL_BOUNDARY_ROOT="$fixture" \
    "$0" --check >/dev/null 2>&1; then
    fail "negative self-test failed to recurse into nested directories"
  fi
  rm -rf "$fixture/lib/pipeline/nested"

  sed -i.bak '/; "completion"/d' "$fixture/lib/execution_event.ml"
  rm -f "$fixture/lib/execution_event.ml.bak"
  if TERMINAL_BOUNDARY_SEARCH_BACKEND=perl \
    TERMINAL_BOUNDARY_ROOT="$fixture" \
    "$0" --check >/dev/null 2>&1; then
    fail "negative self-test failed to detect completion missing from the common whitelist"
  fi
  cp "$EVENT" "$fixture/lib/execution_event.ml"

  sed -i.bak \
    's/schema_version_current = 3/schema_version_current = 2/' \
    "$fixture/lib/execution_event.ml"
  rm -f "$fixture/lib/execution_event.ml.bak"
  if TERMINAL_BOUNDARY_SEARCH_BACKEND=perl \
    TERMINAL_BOUNDARY_ROOT="$fixture" \
    "$0" --check >/dev/null 2>&1; then
    fail "negative self-test failed to detect a legacy schema decoder"
  fi
  cp "$EVENT" "$fixture/lib/execution_event.ml"

  printf '\nlet _legacy = Provider_response_id_snapshot ""\n' \
    >> "$fixture/lib/execution_event.ml"
  if TERMINAL_BOUNDARY_SEARCH_BACKEND=perl \
    TERMINAL_BOUNDARY_ROOT="$fixture" \
    "$0" --check >/dev/null 2>&1; then
    fail "negative self-test failed to detect an ID-only provider response snapshot"
  fi
  cp "$EVENT" "$fixture/lib/execution_event.ml"

  printf '\nlet response agent tool_uses = agent, tool_uses\n' \
    >> "$fixture/lib/pipeline/pipeline_terminal_tool.ml"
  if TERMINAL_BOUNDARY_SEARCH_BACKEND=perl \
    TERMINAL_BOUNDARY_ROOT="$fixture" \
    "$0" --check >/dev/null 2>&1; then
    fail "negative self-test failed to detect synthetic provider response recovery"
  fi
  cp "$PIPELINE" "$fixture/lib/pipeline/pipeline_terminal_tool.ml"

  cat >> "$fixture/lib/agent/agent.mli" <<'EOF'

type duplicate_terminal_receipt =
  { invocation : Tool_contract.Invocation.t
  ; response : Types.api_response
  ; checkpoint_stage : Agent_types.checkpoint_stage
  }
EOF
  if TERMINAL_BOUNDARY_SEARCH_BACKEND=perl \
    TERMINAL_BOUNDARY_ROOT="$fixture" \
    "$0" --check >/dev/null 2>&1; then
    fail "negative self-test failed to detect a duplicate terminal receipt record"
  fi
  cp "$AGENT_MLI" "$fixture/lib/agent/agent.mli"

  local backend_output
  if backend_output="$(
    TERMINAL_BOUNDARY_SEARCH_BACKEND=invalid \
      TERMINAL_BOUNDARY_ROOT="$fixture" \
      "$0" --check 2>&1
  )"; then
    fail "negative self-test accepted an invalid search backend"
  elif [[ "$backend_output" != *"unsupported search backend"* ]]; then
    fail "negative self-test did not surface the invalid backend error"
  fi

  mv "$fixture/lib/execution_event.ml" "$fixture/lib/execution_event.ml.missing"
  local read_output
  if read_output="$(
    TERMINAL_BOUNDARY_SEARCH_BACKEND=perl \
      TERMINAL_BOUNDARY_ROOT="$fixture" \
      "$0" --check 2>&1
  )"; then
    fail "negative self-test accepted a missing source path"
  elif [[ "$read_output" != *"perl failed while evaluating the boundary"* ]]; then
    fail "negative self-test did not surface the Perl read failure"
  fi
  mv "$fixture/lib/execution_event.ml.missing" "$fixture/lib/execution_event.ml"

  printf 'terminal-tool boundary self-test: OK\n'
}

case "${1:---check}" in
  --check) check_boundary ;;
  --self-test) self_test ;;
  *) fail "usage: $0 [--check|--self-test]" ;;
esac
