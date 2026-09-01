#!/usr/bin/env bash
# SSOT bypass guardrail.
#
# Ratchet-based: each rule has a baseline count. CI fails if the count grows.
# Baselines are lowered as SSOT-consolidation PRs land.
#
# See #8462 for the proposal and #8355/#8387/#8403/#8414/#8448/#8455 for
# the bypass class this rule set targets.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

if ! command -v rg >/dev/null 2>&1; then
  echo "ERROR: check-ssot.sh requires ripgrep (rg)." >&2
  exit 2
fi

fail=0

count_rule_excluding() {
  local pattern="$1"
  local exclude_regex="$2"
  shift 2
  # Keep file:count output even when a rule names exactly one file.
  # grep -Ev returns 1 when all lines are filtered; avoid tripping pipefail.
  if [ -n "$exclude_regex" ]; then
    { rg -c --with-filename --no-heading "$pattern" "$@" 2>/dev/null || true; } \
      | { grep -Ev "$exclude_regex" || true; } \
      | awk -F: '{sum += $2} END {print sum+0}'
  else
    { rg -c --with-filename --no-heading "$pattern" "$@" 2>/dev/null || true; } \
      | awk -F: '{sum += $2} END {print sum+0}'
  fi
}

check_rule() {
  local name="$1"
  local baseline="$2"
  local replacement_hint="$3"
  local pattern="$4"
  local exclude_regex="$5"
  shift 5
  local current
  current="$(count_rule_excluding "$pattern" "$exclude_regex" "$@")"

  if [ "$current" -gt "$baseline" ]; then
    echo "ERROR[$name]: $current occurrences (baseline $baseline) — SSOT bypass grew." >&2
    echo "  Replace with: $replacement_hint" >&2
    echo "  Offending lines:" >&2
    if [ -n "$exclude_regex" ]; then
      rg -n --no-heading "$pattern" "$@" 2>/dev/null | grep -Ev "$exclude_regex" | sed 's/^/    /' >&2
    else
      rg -n --no-heading "$pattern" "$@" 2>/dev/null | sed 's/^/    /' >&2
    fi
    fail=1
  elif [ "$current" -lt "$baseline" ]; then
    echo "NOTE[$name]: $current occurrences (baseline $baseline). Lower the baseline in scripts/check-ssot.sh."
  else
    echo "OK[$name]: $current occurrences (baseline $baseline)."
  fi
}

# A one-file rg invocation omits the filename unless --with-filename is
# explicit. The count parser consumes file:count records, so keep both the
# included and excluded single-file shapes covered (#30520).
count_rule_self_test_pattern='SSOT-count-rule-single-file-fixture'
count_rule_self_test_included="$(count_rule_excluding \
  "$count_rule_self_test_pattern" '' scripts/check-ssot.sh)"
count_rule_self_test_excluded="$(count_rule_excluding \
  "$count_rule_self_test_pattern" 'scripts/check-ssot\.sh' scripts/check-ssot.sh)"
if [ "$count_rule_self_test_included" -eq 1 ] \
  && [ "$count_rule_self_test_excluded" -eq 0 ]; then
  echo "OK[count-rule-self-test]: single-file include/exclude counts covered."
else
  echo "ERROR[count-rule-self-test]: expected include=1/exclude=0, got include=$count_rule_self_test_included/exclude=$count_rule_self_test_excluded." >&2
  fail=1
fi

# SSOT-R1 — .masc path concat bypasses Workspace_utils.masc_dir helper.
# Tracked: #8355 (37 files at filing; current ratchet from main).
# Excluded: the helper impl + backend setters where the literal IS the SSOT.
check_rule "R1-masc-path" 0 \
  "Workspace_utils.masc_dir <config>" \
  'Filename\.concat\s+[a-zA-Z_]+\s+"\.masc"' \
  'workspace_utils_paths_backend|workspace_utils_backend_setup|workspace_eio' \
  lib bin

# SSOT-R2 — loopback literal bypasses Masc_network_defaults.masc_http_default_host.
# Tracked: #8387.
# Excluded: helper definition + display-name mapping (server_auth) + URL prefix predicate.
check_rule "R2-loopback-literal" 1 \
  "Masc_network_defaults.masc_http_default_host" \
  '"127\.0\.0\.1"' \
  'masc_network_defaults|server_auth|graphql_endpoint' \
  lib

# SSOT-R4 — config filename literal.
# Tracked: #8414. Helper to be added (Config_filenames) in the fix.
# No exclusion — every site should eventually route through the helper.
check_rule "R4-config-filename" 0 \
  "Config_filenames.<name> (add helper per #8414)" \
  '"(runtime\.json|keeper_runtime\.toml|tool_policy\.toml)"' \
  '' \
  lib

# SSOT-R5 — health path literal bypasses Server_health_paths helper.
# Tracked: #8403. Helper already exists at lib/server/server_health_paths.ml.
# Baseline 0: new literals outside the helper module are immediate failures.
check_rule "R5-health-path" 0 \
  "Server_health_paths.liveness / .readiness" \
  '"/health/(live|ready)"' \
  'server_health_paths' \
  lib

# SSOT-R6 — no home-anchored MASC runtime root. Runtime state must resolve
# from an explicit base path and then append .masc.
#
# Immutable evidence bundles may quote external prompts, runtime paths, and
# session transcripts verbatim. Rewriting those captures to satisfy R6 would
# falsify the evidence and invalidate its digest, so exclude only
# [docs/evidence/] while continuing to scan all authored documentation.
check_rule "R6-home-masc-root" 0 \
  "<base-path>/.masc with explicit MASC_BASE_PATH or --base-path" \
  '(\$HOME|\$\{HOME[^}]*\}|~)/[^[:space:]`'\''"]*\.masc([/[:space:]`'\''".,)]|$)' \
  '^docs/evidence/' \
  bin lib scripts docs

# SSOT-R7 — OTel metric label key for keeper identity is "keeper".
# "keeper_name" in a metric label list splits the label vocabulary: Grafana
# template variables and panel group-bys query "keeper", so keeper_name-keyed
# series render as 0/No data (masc-keeper-full broke this way; the $keeper
# variable sourced label_values(masc_keeper_turns_total, keeper) and got an
# empty list). JSON codec fields named "keeper_name" are NOT affected — this
# rule only matches inside ~labels:[...] lists and let <name>labels = [...] bindings.
# Needs -U (multiline): label lists wrap across lines.
r7_pattern='(~labels:|let [a-z_]*labels\s*=\s*)\[[^\]]{0,400}"keeper_name"'
r7_count="$({ rg -U -c --no-heading "$r7_pattern" bin lib test 2>/dev/null || true; } \
  | awk -F: '{sum += $2} END {print sum+0}')"
if [ "$r7_count" -gt 0 ]; then
  echo "ERROR[R7-metric-label-keeper-name]: $r7_count occurrences (baseline 0)." >&2
  echo "  Replace with: \"keeper\" — the canonical metric label key (cf. Keeper_hooks_agent_core_types.label_keeper)." >&2
  echo "  Offending sites:" >&2
  rg -U -l "$r7_pattern" bin lib test 2>/dev/null | sed 's/^/    /' >&2
  fail=1
else
  echo "OK[R7-metric-label-keeper-name]: 0 occurrences (baseline 0)."
fi

# SSOT-R8 — TUI state colours are semantic Theme tokens, not renderer-local
# ANSI choices. test/test_tui_http_ast.ml enforces this with OCaml's parser and
# typed Longident traversal so comments and literal syntax cannot create a
# second, heuristic source grammar here.

# SSOT-R9 — conversation-role style is owned beside Theme. The renderer may
# branch on row kind, but it must not map a role directly to an ANSI style.
check_rule "R9-tui-chat-theme-owner" 0 \
  "Chat_theme.origin / Chat_theme.body" \
  '(Masc_tui_)?Message_layout\.(User|Keeper|Status|Error|Tool|Thinking).*-> (Ansi|Theme)\.' \
  '' \
  bin/masc_tui_render.ml

# SSOT-R10 — Theme is the only production owner of projected background SGR
# bytes. Existing diff backgrounds and the new RGB/indexed serializer remain
# literal in masc_tui_theme.ml; callers pass typed projected colours instead.
# The prefix is the owned surface: 48:25 is deliberately a match, as is split
# construction such as "48;" ^ "2". A completed mode is not required before
# the raw extended-background construction has already bypassed Theme.
r10_pattern='(^|[^0-9])48[;:]'
r10_self_test_failed=0
for fixture in '48;2' '48;5' '48:2' '48:5' '"48;" ^ "2"' '48:25'; do
  if ! printf '%s\n' "$fixture" | rg -q "$r10_pattern"; then
    echo "ERROR[R10-pattern-self-test]: did not match $fixture" >&2
    r10_self_test_failed=1
  fi
done
if printf '%s\n' '148;2' '47;2' '47:5' '49;2' '49:5' \
  | rg -q "$r10_pattern"; then
  echo "ERROR[R10-pattern-self-test]: matched a non-48 prefix" >&2
  r10_self_test_failed=1
fi
if [ "$r10_self_test_failed" -eq 0 ]; then
  echo "OK[R10-pattern-self-test]: owned prefixes and numeric boundary covered."
else
  fail=1
fi
check_rule "R10-tui-projected-background" 0 \
  "Masc_tui_theme.Sgr.background" \
  "$r10_pattern" \
  'bin/masc_tui_theme\.mli?:' \
  bin lib

# SSOT-R11 — Palette.For_testing can choose a level directly and therefore
# bypass the process-local stdout capability owner. Production code may use
# only Masc_tui_terminal_palette.best_color. The full module name catches
# direct calls and alias declarations; the narrow function name also catches
# calls through an alias such as X.best_color_for_level.
r11_pattern='Masc_tui_terminal_palette[[:space:]]*\.[[:space:]]*For_testing|best_color_for_level'
r11_self_test_failed=0
for fixture in \
  'Masc_tui_terminal_palette.For_testing.best_color_for_level' \
  'module X = Masc_tui_terminal_palette.For_testing' \
  'X.best_color_for_level'; do
  if ! printf '%s\n' "$fixture" | rg -q "$r11_pattern"; then
    echo "ERROR[R11-pattern-self-test]: did not match $fixture" >&2
    r11_self_test_failed=1
  fi
done
if printf '%s\n' \
  'Masc_tui_terminal_palette.best_color' \
  'module X = Masc_tui_terminal_palette' \
  'X.best_color' \
  | rg -q "$r11_pattern"; then
  echo "ERROR[R11-pattern-self-test]: matched the production API" >&2
  r11_self_test_failed=1
fi
if [ "$r11_self_test_failed" -eq 0 ]; then
  echo "OK[R11-pattern-self-test]: direct and alias bypasses covered."
else
  fail=1
fi
check_rule "R11-tui-palette-for-testing" 0 \
  "Masc_tui_terminal_palette.best_color" \
  "$r11_pattern" \
  'bin/masc_tui_terminal_palette\.mli?:' \
  bin lib

# SSOT-R12 — Theme.For_testing accepts injected environment/capability facts,
# so it is a test fixture rather than a second production styling authority.
# The full module name catches direct use. The member pattern catches use via
# a Masc_tui_theme alias, and the declaration pattern prevents hiding the
# fixture module behind another alias before the member is selected.
r12_owner_pattern='Masc_tui_theme[[:space:]]*\.[[:space:]]*For_testing'
r12_member_pattern='For_testing[[:space:]]*\.[[:space:]]*(colors_enabled|user_message_background|user_message_background_rgb)'
r12_alias_pattern="module[[:space:]]+[A-Z][A-Za-z0-9_']*[[:space:]]*=[[:space:]]*([A-Z][A-Za-z0-9_']*[[:space:]]*\.[[:space:]]*)+For_testing"
r12_scope_pattern="(open!?|include)[[:space:]]+([A-Z][A-Za-z0-9_']*[[:space:]]*\.[[:space:]]*)+For_testing"
r12_pattern="${r12_owner_pattern}|${r12_member_pattern}|${r12_alias_pattern}|${r12_scope_pattern}"
r12_self_test_failed=0
for fixture in \
  'Masc_tui_theme.For_testing.user_message_background' \
  'Theme.For_testing.user_message_background' \
  'Theme.For_testing.colors_enabled' \
  'module X = Masc_tui_theme.For_testing' \
  'module X = Theme.For_testing' \
  'open Theme.For_testing' \
  'include Theme.For_testing'; do
  if ! printf '%s\n' "$fixture" | rg -q "$r12_pattern"; then
    echo "ERROR[R12-pattern-self-test]: did not match $fixture" >&2
    r12_self_test_failed=1
  fi
done
if printf '%s\n' \
  'Masc_tui_theme.user_message_background' \
  'Theme.user_message_background' \
  'Masc_tui_theme.colors_enabled' \
  'Theme.colors_enabled' \
  'module Theme = Masc_tui_theme' \
  | rg -q "$r12_pattern"; then
  echo "ERROR[R12-pattern-self-test]: matched the production API" >&2
  r12_self_test_failed=1
fi
if [ "$r12_self_test_failed" -eq 0 ]; then
  echo "OK[R12-pattern-self-test]: direct, member, alias-declaration, and scope boundaries covered."
else
  fail=1
fi
check_rule "R12-tui-theme-for-testing" 0 \
  "Masc_tui_theme semantic production tokens" \
  "$r12_pattern" \
  'bin/masc_tui_theme\.mli?:' \
  bin lib

# SSOT-R13 — shared footer facts are rendered only by Masc_tui_footer. A
# surface supplies its local key hints and typed status items; spelling Port,
# Refresh, or Base inside another production string recreates the per-screen
# drift #30194 removed. Word boundaries keep lower-case [transport:] from
# reading as [port:], and the second arm catches the simplest split-literal
# bypass.
r13_pattern='"[^"\n]*(\b([Pp]ort|[Rr]efresh|[Bb]ase)[[:space:]]*:|\([Pp]ort[[:space:]]+%d\))|"([Pp]ort|[Rr]efresh|[Bb]ase)"[[:space:]]*\^[[:space:]]*":"'
r13_self_test_failed=0
for fixture in \
  '"Port: %d"' \
  '"port: %d"' \
  '"Refresh: %.0fs"' \
  '"Base: /tmp/masc"' \
  '"keys | Port: 8935"' \
  '"(port %d)"' \
  '"Port" ^ ":"'; do
  if ! printf '%s\n' "$fixture" | rg -q "$r13_pattern"; then
    echo "ERROR[R13-pattern-self-test]: did not match $fixture" >&2
    r13_self_test_failed=1
  fi
done
if printf '%s\n' \
  'Masc_tui_footer.Port port' \
  'Masc_tui_footer.Refresh_interval seconds' \
  'Masc_tui_footer.Server_base_path path' \
  '"Keeper chat transport: " ^ detail' \
  'footer_line state ~status' \
  | rg -q "$r13_pattern"; then
  echo "ERROR[R13-pattern-self-test]: matched the typed footer API" >&2
  r13_self_test_failed=1
fi
if [ "$r13_self_test_failed" -eq 0 ]; then
  echo "OK[R13-pattern-self-test]: direct, lower-case, and split footer fact literals covered."
else
  fail=1
fi
check_rule "R13-tui-footer-fact-literal" 0 \
  "Masc_tui_footer status_item projection" \
  "$r13_pattern" \
  'bin/masc_tui_footer\.mli?:' \
  bin

# SSOT-R3 (tool-name literal) is intentionally deferred to #8448's landing:
# the raw `"masc_..."` match is too noisy without the Tool_name.Keeper variant
# refactor in place. Add to this script once #8448 introduces a narrow dispatch
# pattern we can grep for.

echo ""
echo "SSOT snapshot (baselines tracked inline; lower them as SSOT PRs land):"
echo "  Script: scripts/check-ssot.sh"
echo "  Related issues: #8355 #8387 #8403 #8414 #8448 #8455 #8462 #30194 #30196 #30411 #30507 #30520"

exit "$fail"
