#!/usr/bin/env bash
# Classify OCaml catch-all arms across the tree.
#
# Motivation: the 2026-05-19 code-smell audit
# (memory/masc-mcp-code-smell-report-2026-05-19.html, Hotspot #5)
# counted 3,417 catch-all arms. The raw count mixes legitimate
# variant catch-alls (e.g. `| _ -> acc` in a fold) with the
# §AI 안티패턴 §4 (FSM Sparse Match) and §AI 안티패턴 §2
# (Unknown -> Permissive Default) cases.
#
# This script bucketises anonymous `_` arms by the right-hand-side shape so
# reviewers can ratchet-down the suspicious buckets without touching
# the legitimate ones. It can also classify bare lowercase catch-all
# bindings (`| value -> ...`) by whether the RHS actually references
# the binding.
#
# Categories (priority order — first match wins):
#   error-path           raise / failwith / Error _ / Exit / Invalid_argument
#   unknown-sentinel     identifier ending in _unknown / HL_unknown / SL_unknown
#                        / `Unknown _` / string "unknown"
#   permissive-empty     None / [] / () / "" / 0 / 0.0 / false
#                        — §AI §2 candidates
#   literal-positive     true / Some _ literal — assertion-style fallback
#   fallback-identifier  bare identifier (acc / default / result / state)
#                        — fold or identity continuation (usually legit)
#   other                everything else — needs manual audit
#
# Output modes:
#   default              per-category totals for anonymous `_` arms
#   --by-file            top files with anonymous `_` per-category counts
#   --uncategorised      dump every anonymous `_` `other` arm with file:line:body
#   --file <PATH>        dump a single file's anonymous `_` arms by category
#   --binding-use        per-category totals for bare catch-all bindings
#   --binding-use-by-file top files with binding-use counts
#   --unused-binding     dump catch-all bindings whose RHS ignores the binding
#
# Treat the report as informational. The script always exits 0
# unless `--strict` is given: in that case the `other` bucket must
# be zero (lockstep classification — CI ratchet candidate).

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

if ! command -v rg >/dev/null 2>&1; then
  echo "ripgrep (rg) is required" >&2
  exit 2
fi

MODE="totals"
TARGET="lib/"
STRICT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --by-file)       MODE="by-file"; shift ;;
    --uncategorised) MODE="uncategorised"; shift ;;
    --file)          MODE="single"; TARGET="$2"; shift 2 ;;
    --binding-use)   MODE="binding-use"; shift ;;
    --binding-use-by-file) MODE="binding-use-by-file"; shift ;;
    --unused-binding) MODE="unused-binding"; shift ;;
    --strict)        STRICT=1; shift ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      echo "unknown arg: $1" >&2
      exit 2 ;;
  esac
done

# Collect raw matches as file:line:body. The leading whitespace and
# the literal `| _ -> ` prefix are stripped to leave the RHS body.
# `--with-filename` is required because rg omits the path when given
# a single file as the search target.
collect_arms() {
  rg -nP --with-filename '^\s*\| _ -> ' "$1" 2>/dev/null \
    | sed -E 's/^([^:]+:[0-9]+:)[[:space:]]*\| _ -> /\1/'
}

# Collect bare catch-all bindings as tab-separated
# file, line, binding, body. This intentionally limits itself to single
# lowercase/underscore identifiers so constructors and structured
# patterns stay out of the audit.
collect_binding_arms() {
  rg -nP --with-filename '^\s*\|\s+(_|[a-z_][a-zA-Z0-9_]*)\s*->\s*' "$1" 2>/dev/null \
    | perl -ne 'if (/^([^:]+):([0-9]+):\s*\|\s+(_|[a-z_][A-Za-z0-9_]*)\s*->\s*(.*)$/) { print "$1\t$2\t$3\t$4\n" }'
}

# Echo the category for one RHS body. Stdin = body.
classify_body() {
  awk '
    {
      body = $0
      # Strip trailing close-parens, semicolons, comments
      gsub(/\)+[[:space:]]*$/, "", body)
      gsub(/;;[[:space:]]*$/, "", body)
      gsub(/\(\*.*\*\)/, "", body)
      sub(/^[[:space:]]+/, "", body)
      sub(/[[:space:]]+$/, "", body)

      # error-path
      if (body ~ /^(raise[[:space:]]|failwith[[:space:]]|Error[[:space:]]|Invalid_argument|assert false|exit[[:space:]])/) {
        print "error-path"; next
      }
      # unknown-sentinel
      if (body ~ /(^|[^a-zA-Z_])(Unknown[[:space:]]|HL_unknown|SL_unknown|[A-Za-z_]+_unknown\b)/ \
          || tolower(body) ~ /"unknown"/ \
          || tolower(body) ~ /"_other_"/ \
          || tolower(body) ~ /"other"/) {
        print "unknown-sentinel"; next
      }
      # permissive-empty
      if (body == "None"      \
          || body == "[]"     \
          || body == "()"     \
          || body == "\"\""   \
          || body == "0"      \
          || body == "0.0"    \
          || body == "false"  \
          || body == "0L"     \
          || body == "0l") {
        print "permissive-empty"; next
      }
      # literal-positive
      if (body == "true" || body ~ /^Some [A-Za-z0-9_"]+$/) {
        print "literal-positive"; next
      }
      # fallback-identifier (bare lowercase ident, no parens / no leading ctor)
      if (body ~ /^[a-z_][a-zA-Z0-9_]*$/) {
        print "fallback-identifier"; next
      }
      print "other"
    }
  '
}

binding_use_bucket() {
  awk -F '\t' '
    function trim(s) {
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }
    function regex_escape(s) {
      gsub(/[][\\.^$*+?(){}|]/, "\\\\&", s)
      return s
    }
    {
      binding = $3
      body = trim($4)
      if (binding == "_") {
        print "anonymous"
        next
      }

      if (body == "" || body == "(" || body == "begin") {
        print "binding-body-multiline"
        next
      }

      escaped = regex_escape(binding)
      re = "(^|[^A-Za-z0-9_])" escaped "([^A-Za-z0-9_]|$)"
      if (body ~ re) {
        print "binding-used"
        next
      }

      if (binding ~ /^_/) {
        print "ignored-named-binding"
        next
      }

      print "binding-unused"
    }
  '
}

case "$MODE" in
  totals)
    collect_arms "$TARGET" \
      | awk -F: '{ for (i=3; i<=NF; i++) printf "%s%s", $i, (i==NF? "\n":":") }' \
      | classify_body \
      | sort | uniq -c | sort -rn
    ;;

  by-file)
    tmp="$(mktemp)"
    collect_arms "$TARGET" > "$tmp"
    cut -d: -f1 "$tmp" | sort | uniq -c | sort -rn | awk 'NR <= 20' \
      | while read -r count file; do
          per=$(awk -F: -v f="$file" '$1==f { for (i=3;i<=NF;i++) printf "%s%s", $i, (i==NF? "\n":":") }' "$tmp" \
                  | classify_body | sort | uniq -c | sort -rn | tr '\n' ' ')
          printf '%5d  %-60s  %s\n' "$count" "$file" "$per"
        done
    rm -f "$tmp"
    ;;

  uncategorised)
    collect_arms "$TARGET" \
      | while IFS= read -r line; do
          body="${line#*:*:}"
          cat=$(printf '%s\n' "$body" | classify_body)
          [[ "$cat" == "other" ]] && printf '%s\n' "$line"
        done
    ;;

  single)
    collect_arms "$TARGET" \
      | while IFS= read -r line; do
          body="${line#*:*:}"
          cat=$(printf '%s\n' "$body" | classify_body)
          printf '%-20s %s\n' "$cat" "$line"
        done | sort
    ;;

  binding-use)
    collect_binding_arms "$TARGET" \
      | binding_use_bucket \
      | sort | uniq -c | sort -rn
    ;;

  binding-use-by-file)
    tmp="$(mktemp)"
    collect_binding_arms "$TARGET" > "$tmp"
    cut -f1 "$tmp" | sort | uniq -c | sort -rn | awk 'NR <= 20' \
      | while read -r count file; do
          per=$(awk -F '\t' -v f="$file" '$1==f { print }' "$tmp" \
                  | binding_use_bucket | sort | uniq -c | sort -rn | tr '\n' ' ')
          printf '%5d  %-60s  %s\n' "$count" "$file" "$per"
        done
    rm -f "$tmp"
    ;;

  unused-binding)
    collect_binding_arms "$TARGET" \
      | awk -F '\t' '
          function trim(s) {
            sub(/^[[:space:]]+/, "", s)
            sub(/[[:space:]]+$/, "", s)
            return s
          }
          function regex_escape(s) {
            gsub(/[][\\.^$*+?(){}|]/, "\\\\&", s)
            return s
          }
          {
            binding = $3
            body = trim($4)
            if (binding == "_" || body == "" || body == "(" || body == "begin") next
            escaped = regex_escape(binding)
            re = "(^|[^A-Za-z0-9_])" escaped "([^A-Za-z0-9_]|$)"
            if (body ~ re) next
            printf "%s:%s:%s:%s\n", $1, $2, binding, body
          }
        '
    ;;
esac

if [[ "$STRICT" -eq 1 ]]; then
  others=$(collect_arms "$TARGET" \
    | awk -F: '{ for (i=3; i<=NF; i++) printf "%s%s", $i, (i==NF? "\n":":") }' \
    | classify_body | grep -c '^other$' || true)
  if [[ "$others" -gt 0 ]]; then
    echo "STRICT FAIL: $others arms uncategorised" >&2
    exit 1
  fi
fi
