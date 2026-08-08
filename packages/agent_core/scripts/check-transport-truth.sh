#!/usr/bin/env bash
# check-transport-truth.sh
# Drift gate for OAS CLI transports
# (transport_cli_tool_{a,b,c,d}).
#
# Background
# ----------
# Each CLI transport exposes a `type config = { ... }` record in its .mli.
# The corresponding .ml is expected to either:
#   - wire the field to a CLI flag in build_args, OR
#   - mark it as a parity-only field and warn via warn_unsupported_once.
#
# Prior audits (see planning/task-118/origin-report.md, 2026-04-16) found
# that the Gemini/Codex CLI transport mli files declared
# fields (allowed_tools / mcp_config) whose
# behavior only existed as a warn-and-drop. The .mli comments claimed
# "Gemini has no equivalent flag" — a claim that was false by 2026-04
# (Gemini CLI 0.38+ exposes --allowed-mcp-server-names, --approval-mode,
# etc.). This drift gate aims to prevent re-introduction of silent drops.
#
# Invariants
# ----------
# 1. Every field declared in `type config = { ... }` of a transport .mli
#    must be referenced at least once in the corresponding .ml. A field
#    that disappears entirely from the implementation is silent drift.
#
# 2. If a transport's .mli contains the phrase "Accepted for parity",
#    the .ml must contain a `warn_unsupported_once` function. A parity
#    claim without a warning is a silent drop dressed as a contract.
#
# Scope limitations
# -----------------
# This gate does NOT verify that a field is actually wired to a CLI flag
# in build_args; it only checks that the field is referenced somewhere.
# A semantic check (wired vs. warn-only vs. deprecated) is left to
# per-transport integration tests.
#
# See memory/feedback_policy-runtime-drift-gate.md —
# "정책 선언만으론 부족. 같은 PR 에서 runtime 검증 스크립트를 함께."

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

check_mli_modules=("$ROOT"/lib/llm_provider/transport_*.mli)
if [[ ${#check_mli_modules[@]} -eq 1 && "${check_mli_modules[0]}" == "$ROOT/lib/llm_provider/transport_*.mli" ]]; then
  check_mli_modules=()
fi

# Extract field names from the `type config = { ... }` record block.
# Supports both compact and ocamlformat-split forms:
#   type config = {
#   type config =
#     {
extract_config_fields() {
  awk '
    /^type[[:space:]]+config[[:space:]]*=/ {
      seen = 1
      if ($0 ~ /\{/) {
        in_record = 1
        sub(/^.*\{/, "")
        if ($0 ~ /\}/) {
          sub(/\}.*/, "")
          print
          exit
        }
        print
      }
      next
    }
    seen && !in_record && /^[[:space:]]*\{/ {
      in_record = 1
      sub(/^[^{]*\{/, "")
      print
      next
    }
    in_record && /^[[:space:]]*\}/ { exit }
    in_record { print }
  ' "$1" \
    | sed -n 's/^[[:space:]]*;[[:space:]]*\([a-z_][a-zA-Z0-9_]*\)[[:space:]]*:.*/\1/p; s/^[[:space:]]*\([a-z_][a-zA-Z0-9_]*\)[[:space:]]*:.*/\1/p'
}

if [[ ${#check_mli_modules[@]} -eq 0 ]]; then
  echo "OK: no transport_*.mli modules found under $ROOT/lib/llm_provider; drift gate vacuously passes"
  exit 0
fi

fail=0
for mli in "${check_mli_modules[@]}"; do
  prefix="${mli%.mli}"
  base="$(basename "$prefix")"
  name="${base#transport_}"
  ml="$prefix.ml"

  if [[ ! -f "$ml" ]]; then
    echo "FAIL: $name: .mli/.ml mismatch ($mli, $ml)" >&2
    fail=1
    continue
  fi

  fields=$(extract_config_fields "$mli")
  if [[ -z "$fields" ]]; then
    echo "FAIL: $name: no config fields extracted from $mli" >&2
    fail=1
    continue
  fi

  # Invariant 1: each field referenced in .ml
  for f in $fields; do
    if ! grep -qE "\\b$f\\b" "$ml"; then
      echo "FAIL: $name: field '$f' declared in .mli but not referenced in .ml" >&2
      fail=1
    fi
  done

  # Invariant 2: "Accepted for parity" → warn_unsupported_once
  if grep -q "Accepted for parity" "$mli"; then
    if ! grep -q "warn_unsupported_once" "$ml"; then
      echo "FAIL: $name: .mli claims 'Accepted for parity' but .ml has no warn_unsupported_once" >&2
      fail=1
    fi
  fi
done

if [[ $fail -ne 0 ]]; then
  exit 1
fi

echo "OK: transport drift gate passed (4 transports, invariants 1–2)"
