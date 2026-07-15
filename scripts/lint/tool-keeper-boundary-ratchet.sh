#!/usr/bin/env bash
# Tool -> Keeper dependency-direction ratchet.
#
# Principle: the generic tool surface must not reference the keeper subsystem.
# Keeper depends on the tool surface (Tool_dispatch / Tool_catalog / Tool_name),
# never the reverse. A tool module that mentions keeper-owned runtime modules
# such as `Agent_tool_dispatch_runtime`, `Keeper_types_profile`, or
# `Task_keeper_backend` is a boundary violation.
#
# RFC status: RFC-0084 enforced this direction for the dispatch PATH
# (tool_dispatch.ml, done). No existing RFC owns the surface-WIDE reverse-
# dependency invariant this gate enforces; a dedicated RFC should adopt it.
# Plan + per-file severance: docs/audit/2026-05-31-tool-keeper-boundary-severance.md.
#
# masc is one flat library ((include_subdirs unqualified)), so the compiler
# cannot enforce this direction. This ratchet is the deterministic substitute:
# the existing debt (baseline `.callers`) may shrink but must not grow. Each
# severance PR removes a file from the baseline (regenerate in the same PR).
# The structural root fix is splitting the tool surface into its own dune
# sub-library; until then this gate holds the line.
#
# Scope:
#   - Subjects: every lib/**/tool_*.ml{i} found recursively, plus
#     lib/tools.ml{i}, EXCLUDING
#     tool_keeper*.ml{i}. The tool_keeper* modules are keeper-purpose handlers
#     (keeper IS their domain); they are tracked separately, not by this gate.
#   - Violation: a keeper-owned module token or a real
#     `Keeper_<Word>.<lowercase>` module call. Comments (incl. nested and odoc
#     `[Keeper_x.y]`) and string literals are stripped before matching, so doc
#     references and prose do not count.
#   - Keeper subsystem only. Masc_* coupling (Masc_domain is shared vocabulary)
#     is a separate axis, not covered here.
#
# Usage:
#   bash scripts/lint/tool-keeper-boundary-ratchet.sh            # check (exit!=0 on drift up)
#   bash scripts/lint/tool-keeper-boundary-ratchet.sh --fail     # same (explicit)
#   bash scripts/lint/tool-keeper-boundary-ratchet.sh --print    # show current vs baseline
#   bash scripts/lint/tool-keeper-boundary-ratchet.sh --regenerate  # rewrite baseline

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BASELINE="${ROOT}/scripts/lint/tool-keeper-boundary-ratchet.callers"

for tool in rg sort comm mktemp wc perl; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "[tool-keeper-boundary-ratchet] required tool missing: $tool" >&2
    exit 1
  }
done

# Strip OCaml comments (nested-aware) and string literals from stdin, then
# report whether a keeper-owned module token remains.
# A char-state scanner is used because OCaml comments nest and a regex cannot
  # strip them reliably. Newlines are preserved in stripped
# regions so the scan stays line-faithful.
keeper_call_in_file() {
  # Strip comments+strings into a variable, then match with a here-string.
  # A pipe (perl | rg -q) is avoided on purpose: rg -q closes the pipe on the
  # first match, perl then takes SIGPIPE, and under `set -o pipefail` the
  # pipeline status flips nonzero intermittently (buffering-dependent) — a
  # match would be silently dropped. Capturing first removes that race.
  local stripped
  stripped="$(perl -0777 -e '
    local $/; my $s = <STDIN>;
    my @o; my $i = 0; my $n = length $s; my $depth = 0; my $str = 0;
    while ($i < $n) {
      my $c  = substr($s, $i, 1);
      my $c2 = substr($s, $i, 2);
      if (!$str && $c2 eq "(*") { $depth++; $i += 2; next; }
      if (!$str && $c2 eq "*)" && $depth > 0) { $depth--; $i += 2; next; }
      if ($depth > 0) { push @o, "\n" if $c eq "\n"; $i++; next; }
      if (!$str && $c eq chr(34)) { $str = 1; $i++; next; }
      if ($str && $c eq "\\") { $i += 2; next; }
      if ($str && $c eq chr(34)) { $str = 0; $i++; next; }
      if ($str) { push @o, "\n" if $c eq "\n"; $i++; next; }
      push @o, $c; $i++;
    }
    print join("", @o);
  ' < "$1")"
  rg -q '\b(Agent_tool_descriptor|Agent_tool_descriptor_resolution|Agent_tool_dispatch_runtime|Keeper_tool_alias|Keeper_types_profile|Task_keeper_backend)\b|\bKeeper_[A-Za-z_]+\.[a-z]|\b(open|include)[[:space:]]+(Masc\.)?(Agent_tool_descriptor|Agent_tool_descriptor_resolution|Agent_tool_dispatch_runtime|Keeper_[A-Za-z_]+|Task_keeper_backend)\b|\bmodule[[:space:]]+[A-Z][A-Za-z0-9_]*(\x27)?[[:space:]]*=[[:space:]]*(Masc\.)?(Agent_tool_descriptor|Agent_tool_descriptor_resolution|Agent_tool_dispatch_runtime|Keeper_[A-Za-z_]+|Task_keeper_backend)\b' <<<"$stripped"
}

current_callers() {
  (
    cd "$ROOT"
    while IFS= read -r f; do
      case "$(basename "$f")" in tool_keeper*) continue ;; esac
      if keeper_call_in_file "$f"; then
        printf '%s\n' "$f"
      fi
    done < <(
      {
        find lib \( -name 'tool_*.ml' -o -name 'tool_*.mli' \) ! -name '*test*'
        for f in lib/tools.ml lib/tools.mli; do
          [[ -f "$f" ]] && printf '%s\n' "$f"
        done
      } | sort -u
    )
  ) | sort -u
}

baseline_callers() {
  sed -E 's/#.*//; s/[[:space:]]+$//; /^$/d' "$BASELINE" | sort -u
}

print_counts() {
  local cur base
  cur="$(current_callers | wc -l | tr -d ' ')"
  base="$(baseline_callers | wc -l | tr -d ' ')"
  printf "%-28s %8s  %8s\n" "metric" "current" "baseline"
  echo "--------------------------------------------------"
  printf "%-28s %8s  %8s\n" "tool_keeper_callers" "$cur" "$base"
  echo
  echo "current callers:"
  current_callers | sed 's/^/  - /'
}

regenerate() {
  current_callers >"$BASELINE.body"
  {
    echo "# Tool -> Keeper boundary ratchet baseline (frozen debt list)."
    echo "# Files here still call a Keeper_<module> from the tool surface."
    echo "# This list may SHRINK (severance PRs remove entries) but must NOT GROW."
    echo "# Regenerate with: bash scripts/lint/tool-keeper-boundary-ratchet.sh --regenerate"
    echo "# See: docs/audit/2026-05-31-tool-keeper-boundary-severance.md"
    echo "#"
    cat "$BASELINE.body"
  } >"$BASELINE"
  rm -f "$BASELINE.body"
  echo "[tool-keeper-boundary-ratchet] regenerated baseline ($(baseline_callers | wc -l | tr -d ' ') entries)"
}

check() {
  local cur_tmp base_tmp new_tmp stale_tmp drift=0
  cur_tmp="$(mktemp -t tk-boundary.current.XXXXXX)"
  base_tmp="$(mktemp -t tk-boundary.baseline.XXXXXX)"
  new_tmp="$(mktemp -t tk-boundary.new.XXXXXX)"
  stale_tmp="$(mktemp -t tk-boundary.stale.XXXXXX)"
  trap 'rm -f "$cur_tmp" "$base_tmp" "$new_tmp" "$stale_tmp"' RETURN

  current_callers >"$cur_tmp"
  baseline_callers >"$base_tmp"
  comm -13 "$base_tmp" "$cur_tmp" >"$new_tmp"    # in current, not in baseline = NEW violation
  comm -23 "$base_tmp" "$cur_tmp" >"$stale_tmp"  # in baseline, not in current = SEVERED but stale

  if [[ -s "$new_tmp" ]]; then
    echo "[tool-keeper-boundary-ratchet] DRIFT UP: new tool->Keeper boundary violation(s):" >&2
    sed 's/^/  - /' "$new_tmp" >&2
    echo "  A tool surface module must not mention keeper-owned modules. Inject the" >&2
    echo "  keeper-facing behaviour at the boundary, or move the handler into the" >&2
    echo "  keeper domain. Do not add it to the baseline." >&2
    drift=1
  fi
  if [[ -s "$stale_tmp" ]]; then
    echo "[tool-keeper-boundary-ratchet] STALE BASELINE: severed file(s) still listed:" >&2
    sed 's/^/  - /' "$stale_tmp" >&2
    echo "  These no longer call a Keeper_<module>. Remove them from the baseline" >&2
    echo "  in the SAME PR that severed them: run --regenerate and commit the result." >&2
    drift=1
  fi
  return "$drift"
}

case "${1:-}" in
  --print)
    print_counts
    ;;
  --regenerate)
    regenerate
    ;;
  ""|--fail)
    if check; then
      echo "[tool-keeper-boundary-ratchet] OK ($(baseline_callers | wc -l | tr -d ' ') baselined, 0 new)."
      exit 0
    else
      echo >&2
      echo "[tool-keeper-boundary-ratchet] FAIL - tool->Keeper boundary grew." >&2
      exit 2
    fi
    ;;
  *)
    echo "Usage: $0 [--fail|--print|--regenerate]" >&2
    exit 1
    ;;
esac
