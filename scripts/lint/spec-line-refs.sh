#!/usr/bin/env bash
# spec-line-refs.sh
#
# Validates (path:line  snippet) references embedded in TLA+ spec comments.
#
# The specs/ tree carries pointers into the OCaml codebase of the form:
#
#   (* lib/cascade/cascade_fsm.mli:37  accept_on_exhaustion:bool -> *)
#
# When upstream shifts line 37, the reference drifts silently. This gate
# parses those tuples, reads the target source, and checks that the
# referenced line still contains the recorded snippet.
#
# Exit codes:
#   0 — all refs match (or no refs found)
#   1 — at least one drift detected (line exists, snippet mismatch)
#   2 — at least one dangling path (file missing, or line out of range)
#
# `path:SYMBOL` style references (where `:` is followed by a non-numeric
# identifier, e.g. `cascade_fsm.ml:decide`) are symbol-anchored by design
# and are resolved via `grep`, not line number. They are included in the
# check but never trigger drift — only dangling-path.
#
# Invocation:
#   bash scripts/lint/spec-line-refs.sh              # full repo scan
#   SPEC_ROOT=specs bash scripts/lint/spec-line-refs.sh
#
# Opt-out for a single spec file:
#   Add `# spec-line-refs: ignore` anywhere in the first 20 lines.

set -u

SPEC_ROOT="${SPEC_ROOT:-specs}"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

if [[ ! -d "$SPEC_ROOT" ]]; then
  echo "spec-line-refs: no $SPEC_ROOT directory, nothing to check"
  exit 0
fi

ALLOWLIST="${ALLOWLIST:-scripts/lint/spec-line-refs.allowlist}"

drift_count=0
dangle_count=0
ok_count=0
sym_count=0
allowlisted_count=0
# Track which allowlist entries were exercised this run so we can flag stale
# entries that no longer correspond to a real drift.
detected_keys_file="$(mktemp -t spec-line-refs.XXXXXX)"
trap 'rm -f "$detected_keys_file"' EXIT

in_allowlist() {
  local key="$1"
  [[ -f "$ALLOWLIST" ]] || return 1
  grep -Fxq "$key" <(grep -v '^#' "$ALLOWLIST" | grep -v '^[[:space:]]*$') 2>/dev/null
}

# Iterate .tla files; portable across bash 3.2 (macOS) and 4+ (CI).
while IFS= read -r -d '' f; do
  if head -20 "$f" | grep -q 'spec-line-refs: ignore'; then
    continue
  fi

  # Extract (path, line_or_sym, rest) tuples from every comment line.
  # Match path like  lib/.../file.ml  or  lib/.../file.mli.
  # Token after ':' is either digits (line) or identifier (symbol).
  # Rest = everything after the ref, for snippet compare.
  while IFS=$'\t' read -r lineno path ref rest; do
    # Symbol-anchored reference — just check the file contains it.
    if [[ "$ref" =~ ^[0-9]+$ ]]; then
      line_num="$ref"
    else
      if [[ ! -f "$path" ]]; then
        printf '::error file=%s,line=%s::dangling path: %s (file not found; ref :%s)\n' \
          "$f" "$lineno" "$path" "$ref"
        dangle_count=$((dangle_count + 1))
        continue
      fi
      if ! grep -qE "(^|[^a-zA-Z0-9_])${ref}([^a-zA-Z0-9_]|$)" "$path"; then
        printf '::error file=%s,line=%s::dangling symbol %s not found in %s\n' \
          "$f" "$lineno" "$ref" "$path"
        dangle_count=$((dangle_count + 1))
        continue
      fi
      sym_count=$((sym_count + 1))
      continue
    fi

    if [[ ! -f "$path" ]]; then
      printf '::error file=%s,line=%s::dangling path: %s (ref %s:%s)\n' \
        "$f" "$lineno" "$path" "$path" "$line_num"
      dangle_count=$((dangle_count + 1))
      continue
    fi

    total_lines=$(wc -l < "$path")
    if (( line_num > total_lines )); then
      printf '::error file=%s,line=%s::out-of-range: %s:%s (file has %d lines)\n' \
        "$f" "$lineno" "$path" "$line_num" "$total_lines"
      dangle_count=$((dangle_count + 1))
      continue
    fi

    # Trim leading range-tail (e.g. "-68" from "N-M"), comment closer, and
    # leading/trailing whitespace from the snippet text.
    snippet=$(printf '%s' "$rest" | sed -E '
      s/^-[0-9]+//
      s/^[[:space:]]*\*\)?[[:space:]]*//
      s/^[[:space:]]+//
      s/[[:space:]]+$//
    ')
    if [[ -z "$snippet" ]]; then
      # Bare ref with no snippet — nothing to check beyond path:line existence.
      ok_count=$((ok_count + 1))
      continue
    fi

    src_line=$(sed -n "${line_num}p" "$path")
    # Take the first 24 chars of snippet as a signature — enough to identify,
    # tolerant of trailing drift.
    sig="${snippet:0:24}"
    # Skip pure comment tokens that would false-negative (e.g. "*/").
    if [[ "$sig" == "*/" || "$sig" == "*" ]]; then
      ok_count=$((ok_count + 1))
      continue
    fi

    if [[ "$src_line" == *"$sig"* ]]; then
      ok_count=$((ok_count + 1))
    else
      key="$f  $path:$line_num"
      printf '%s\n' "$key" >> "$detected_keys_file"
      if in_allowlist "$key"; then
        allowlisted_count=$((allowlisted_count + 1))
        continue
      fi
      suggestion=$(grep -nF "$sig" "$path" 2>/dev/null | head -1 | cut -d: -f1)
      if [[ -n "$suggestion" ]]; then
        printf '::error file=%s,line=%s::drift: %s:%s expected %q; now at line %s\n' \
          "$f" "$lineno" "$path" "$line_num" "$sig" "$suggestion"
      else
        printf '::error file=%s,line=%s::drift: %s:%s snippet %q not found in file\n' \
          "$f" "$lineno" "$path" "$line_num" "$sig"
      fi
      drift_count=$((drift_count + 1))
    fi
  done < <(awk '
    {
      line = $0
      while (match(line, /(lib|test|src|scripts|docs)\/[A-Za-z0-9_\/\-]+\.(ml|mli)\:/)) {
        ref_start = RSTART
        ref_end = RSTART + RLENGTH
        path = substr(line, ref_start, RLENGTH - 1)
        rest = substr(line, ref_end)
        # Extract token after the colon.
        # Forms: N (line), N-M (range — anchor at N), symbol (identifier).
        if (match(rest, /^[0-9]+(-[0-9]+)?/)) {
          tok = substr(rest, 1, RLENGTH)
          after = substr(rest, RLENGTH + 1)
          # For ranges, keep only the starting line as the anchor token.
          dash = index(tok, "-")
          if (dash > 0) {
            tok = substr(tok, 1, dash - 1)
          }
        } else if (match(rest, /^[A-Za-z_][A-Za-z0-9_]*/)) {
          tok = substr(rest, 1, RLENGTH)
          after = substr(rest, RLENGTH + 1)
        } else {
          line = substr(line, ref_end)
          continue
        }
        print NR "\t" path "\t" tok "\t" after
        line = substr(line, ref_end + length(tok))
      }
    }
  ' "$f")
done < <(find "$SPEC_ROOT" -name '*.tla' -type f -print0 | sort -z)

total=$((ok_count + sym_count + drift_count + dangle_count + allowlisted_count))
printf 'spec-line-refs: %d refs checked (%d line-anchored ok, %d symbol-anchored ok, %d drift, %d dangling, %d allowlisted)\n' \
  "$total" "$ok_count" "$sym_count" "$drift_count" "$dangle_count" "$allowlisted_count"

# Self-verify: allowlist entries that no drift matched this run are stale.
stale_count=0
if [[ "${SKIP_ALLOWLIST_VERIFY:-}" != "1" && -f "$ALLOWLIST" ]]; then
  while IFS= read -r entry || [[ -n "$entry" ]]; do
    [[ -z "$entry" || "$entry" =~ ^[[:space:]]*# ]] && continue
    if ! grep -Fxq "$entry" "$detected_keys_file" 2>/dev/null; then
      printf '::error file=%s::stale allowlist entry — no matching drift detected: %q\n' \
        "$ALLOWLIST" "$entry"
      stale_count=$((stale_count + 1))
    fi
  done < "$ALLOWLIST"
fi

if (( stale_count > 0 )); then
  exit 2
fi
if (( dangle_count > 0 )); then
  exit 2
fi
if (( drift_count > 0 )); then
  exit 1
fi
exit 0
