#!/usr/bin/env bash
# CI gate: logging-method consistency.
#
# Contract: docs/LOGGING.md
#
# Rationale
#   lib/masc_log/log.ml exposes one canonical logging surface:
#     Log.<Module>.{info,warn,error,debug}   (normal logs)
#     Log.<Module>.routine                   (routine/housekeeping)
#   Everything else (raw Printf.eprintf / prerr_*, the top-level
#   Log.{info,warn,error,debug} ~ctx form, the `Logs.*` library, the
#   Log.legacy_stderr/legacy_traceln RFC-0079 bridge, and bare Log.emit /
#   Log.emit_event) is a non-canonical way to write the same output. A mix of
#   ~6 styles makes severity, component naming, and dashboard routing
#   inconsistent. This gate scans lib/ and bin/ for the non-canonical styles,
#   minus a documented allowlist (ci/logging-consistency-allowlist.txt), and
#   fails if the count exceeds the baseline (ci/logging-consistency-baseline.txt).
#
# Mode
#   Ratchet against a baseline integer. Post-migration the baseline is 0, so any
#   newly introduced non-canonical site fails CI immediately. The baseline may
#   only be lowered (further cleanup), never raised to admit a new violation.
#
# Allowlist
#   Path-prefix file. A violation is suppressed when its path starts with an
#   allowlisted prefix. See ci/logging-consistency-allowlist.txt for the entries
#   and the reason each one cannot route through the canonical surface.
#
# Comment / multi-line caveat
#   OCaml format-string calls span 2-N lines and the codebase mentions
#   `Log.info` inside (* comments *). The top-level recognizer requires the
#   actual call shape — `Log.<lvl>` followed (possibly across a newline) by
#   either `~ctx` or a `"` string literal — which every real call has and no
#   comment does. The canonical recognizer `Log\.[A-Z][A-Za-z0-9_]*\.`
#   intentionally allows multi-segment module names (Dashboard_runtime,
#   H2_gateway, ModelClient).

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

ALLOWLIST="ci/logging-consistency-allowlist.txt"
BASELINE_FILE="ci/logging-consistency-baseline.txt"

if [ ! -f "$ALLOWLIST" ]; then
  echo "FAIL: allowlist file missing: $ALLOWLIST" >&2
  exit 2
fi
if [ ! -f "$BASELINE_FILE" ]; then
  echo "FAIL: baseline file missing: $BASELINE_FILE" >&2
  exit 2
fi

baseline=$(tr -d '[:space:]' < "$BASELINE_FILE")
case "$baseline" in
  ''|*[!0-9]*)
    echo "FAIL: baseline file must contain a single integer, got: '$baseline'" >&2
    exit 2
    ;;
esac

# Load allowlist path prefixes (skip blanks + comments).
allow_prefixes=()
while IFS= read -r line; do
  line="${line%%#*}"
  line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [ -z "$line" ] && continue
  allow_prefixes+=("$line")
done < "$ALLOWLIST"

is_allowlisted() {
  local path="$1" prefix
  for prefix in "${allow_prefixes[@]}"; do
    case "$path" in
      "$prefix"*) return 0 ;;
    esac
  done
  return 1
}

# Collect .ml files under lib/ and bin/ (exclude test/).
files=()
while IFS= read -r -d '' f; do
  files+=("$f")
done < <(rg --files -0 --type ml -g '!**/test/**' lib bin)

# Emit "file:line:tag:match" rows for every non-canonical logging site.
#
# Perl slurp mode: count regex matches directly (not rg -U output rows), so a
# match window that wraps unrelated lines is not over-counted. Comment bodies
# are stripped first so `(* ... Log.info ... *)` mentions never match.
scan_rows() {
  perl -0777 -ne '
    my $src = $_;
    # Blank out (* ... *) comments (incl. nested) so mentions inside comments
    # do not register as call sites. Replace comment bytes with spaces to keep
    # line numbers stable.
    my $depth = 0; my $out = "";
    my $i = 0; my $n = length($src);
    while ($i < $n) {
      if ($depth == 0 && substr($src,$i,2) eq "(*") { $depth=1; $out.="  "; $i+=2; next; }
      if ($depth > 0) {
        if (substr($src,$i,2) eq "(*") { $depth++; $out.="  "; $i+=2; next; }
        if (substr($src,$i,2) eq "*)") { $depth--; $out.="  "; $i+=2; next; }
        my $c = substr($src,$i,1); $out .= ($c eq "\n") ? "\n" : " "; $i++; next;
      }
      $out .= substr($src,$i,1); $i++;
    }
    $_ = $out;

    my @rules = (
      # tag, regex
      [ "eprintf",  qr/\b(Printf\.eprintf|prerr_(endline|string|newline|char|float|int))\b/ ],
      # top-level Log.<lvl> followed (across newline) by ~ctx or a string literal.
      # Negative lookahead on the segment after Log. excludes Log.<Module>.<lvl>.
      [ "toplevel", qr/\bLog\.(?!(?:[A-Z][A-Za-z0-9_]*)\.)(info|warn|error|debug)(?:\s+|\s*\n\s*)(?:~ctx|")/ ],
      # the Logs.* library (distinct from masc Log)
      [ "logs_lib", qr/\bLogs\.(info|warn|err|debug|app)\b/ ],
      # RFC-0079 legacy raw-stderr bridge
      [ "legacy",   qr/\bLog\.legacy_(stderr|traceln)\b/ ],
      # bare top-level Log.emit / Log.emit_event (emit_routine is the routine API,
      # intentionally not flagged)
      [ "emit",     qr/\bLog\.(emit|emit_event)(?!_routine)\b/ ],
    );
    # Match against the comment-stripped text ($_) so comments are excluded.
    for my $r (@rules) {
      my ($tag,$pat) = @$r;
      while (/$pat/g) {
        my $start = $-[0];
        my $prefix = substr($_, 0, $start);
        my $line = 1 + ($prefix =~ tr/\n//);
        my $m = substr($_, $start, $+[0] - $start);
        $m =~ s/\n.*\z//s;
        print "$ARGV:$line:$tag:$m\n";
      }
    }
  ' "$@"
}

violations=()
if [ "${#files[@]}" -gt 0 ]; then
  while IFS= read -r row; do
    [ -z "$row" ] && continue
    file="${row%%:*}"
    if is_allowlisted "$file"; then
      continue
    fi
    violations+=("$row")
  done < <(scan_rows "${files[@]}")
fi

count="${#violations[@]}"

echo "─── logging-consistency ───────────────────"
if [ "$count" -gt 0 ]; then
  printf '%s\n' "${violations[@]}" | sort
  echo
fi
echo "  current:  $count"
echo "  baseline: $baseline"

if [ "$count" -gt "$baseline" ]; then
  echo "  status: FAIL — $((count - baseline)) non-canonical logging site(s) over baseline"
  echo "          migrate to Log.<Module>.{info,warn,error,debug,routine}"
  echo "          or, if genuinely non-canonical, add a documented allowlist entry."
  echo "          see docs/LOGGING.md"
  exit 1
elif [ "$count" -lt "$baseline" ]; then
  echo "  status: OK — cleanup detected; lower baseline in $BASELINE_FILE to lock the gain"
  exit 0
else
  echo "  status: OK"
  exit 0
fi
