#!/usr/bin/env bash
# RFC-0049 PR-2 — Dashboard IA usage report.
#
# Scrapes the MASC server's Prometheus /metrics endpoint and produces a
# Markdown report ranking dashboard surfaces and sections by open count.
# Splits direct opens from redirect-driven opens (the redirected_from=none
# vs everything-else distinction RFC-0048 §4.4 needs for deletion thresholds).
#
# Usage:
#   scripts/dashboard-ia-usage.sh                          # default endpoint, full ranking
#   scripts/dashboard-ia-usage.sh --endpoint URL           # override server
#   scripts/dashboard-ia-usage.sh --metrics-url URL        # alias for --endpoint
#   scripts/dashboard-ia-usage.sh --output FILE            # write to file
#   scripts/dashboard-ia-usage.sh --threshold N            # flag rows below N as candidates
#   scripts/dashboard-ia-usage.sh --since DURATION         # window label in report header (e.g. 7d)
#   scripts/dashboard-ia-usage.sh --token TOKEN            # Bearer token for auth
#
# Exit codes:
#   0  report produced
#   1  CLI / network error
#   2  no relevant counters present (server has no traffic yet)
#
# Environment variables (CLI flags take precedence):
#   MASC_METRICS_ENDPOINT   endpoint URL (takes priority over MASC_METRICS_URL)
#   MASC_METRICS_URL        endpoint URL alias (back-compat; lower priority)
#   MASC_METRICS_TOKEN      Bearer token (same as --token)
#
# Notes:
#   - Counters are cumulative since process start. The "--since" label is
#     printed in the report header but does NOT perform windowed queries;
#     real time-windowed analysis via PromQL is deferred to PR-2.5.
#   - Compatible with bash 3.2 (macOS default) and bash 4+. All aggregation
#     happens inside awk so no associative arrays in shell.

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
ENDPOINT="${MASC_METRICS_ENDPOINT:-${MASC_METRICS_URL:-http://127.0.0.1:8935/metrics}}"
OUTPUT=""
HIDE_THRESHOLD=5
SINCE="since-restart"
TOKEN="${MASC_METRICS_TOKEN:-}"

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while (($#)); do
  case "$1" in
    --endpoint)
      ENDPOINT="$2"; shift 2 ;;
    --endpoint=*)
      ENDPOINT="${1#*=}"; shift ;;
    --metrics-url)
      ENDPOINT="$2"; shift 2 ;;
    --metrics-url=*)
      ENDPOINT="${1#*=}"; shift ;;
    --output)
      OUTPUT="$2"; shift 2 ;;
    --output=*)
      OUTPUT="${1#*=}"; shift ;;
    --threshold)
      HIDE_THRESHOLD="$2"; shift 2 ;;
    --threshold=*)
      HIDE_THRESHOLD="${1#*=}"; shift ;;
    --since)
      SINCE="$2"; shift 2 ;;
    --since=*)
      SINCE="${1#*=}"; shift ;;
    --token)
      TOKEN="$2"; shift 2 ;;
    --token=*)
      TOKEN="${1#*=}"; shift ;;
    -h|--help)
      usage 0 ;;
    *)
      echo "$SCRIPT_NAME: unknown argument: $1" >&2
      usage 1 ;;
  esac
done

if ! command -v curl >/dev/null 2>&1; then
  echo "$SCRIPT_NAME: curl is required" >&2
  exit 1
fi

curl_args=(--silent --show-error --max-time 10 --fail)
if [[ -n "$TOKEN" ]]; then
  curl_args+=(-H "Authorization: Bearer $TOKEN")
fi

tmp_metrics="$(mktemp -t masc-metrics.XXXXXX)"
report="$(mktemp -t masc-ia-report.XXXXXX)"
trap 'rm -f "$tmp_metrics" "$report"' EXIT

if ! curl "${curl_args[@]}" "$ENDPOINT" >"$tmp_metrics" 2>/dev/null; then
  echo "$SCRIPT_NAME: failed to fetch $ENDPOINT" >&2
  exit 1
fi

generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

awk -v endpoint="$ENDPOINT" \
    -v generated_at="$generated_at" \
    -v threshold="$HIDE_THRESHOLD" \
    -v since="$SINCE" '
  function extract_label(line, name,    pattern, start, len) {
    pattern = name "=\"[^\"]*\""
    if (match(line, pattern) == 0) return ""
    start = RSTART + length(name) + 2
    len = RLENGTH - length(name) - 3
    return substr(line, start, len)
  }

  /^dashboard_surface_open_total\{/ {
    surface = extract_label($0, "surface")
    if (surface == "") next
    n = split($0, parts, /[ \t]+/)
    val = parts[n] + 0
    surface_total[surface] += int(val + 0.5)
    surface_present = 1
    next
  }

  /^dashboard_section_open_total\{/ {
    surface = extract_label($0, "surface")
    section = extract_label($0, "section")
    redirected = extract_label($0, "redirected_from")
    if (redirected == "") redirected = "none"
    if (surface == "" || section == "") next
    n = split($0, parts, /[ \t]+/)
    val = parts[n] + 0
    val_int = int(val + 0.5)
    key = surface "/" section
    section_total[key] += val_int
    if (redirected == "none") {
      section_direct[key] += val_int
    } else {
      rkey = surface "/" section "/" redirected
      section_redirected[rkey] += val_int
    }
    section_seen[key] = 1
    section_present = 1
    next
  }

  END {
    if (!surface_present && !section_present) exit 2

    print "# Dashboard IA usage report"
    print ""
    printf "_Source: `%s`_  \n", endpoint
    printf "_Generated: %s_  \n", generated_at
    printf "_Window: %s (counters are cumulative since last restart)_  \n", since
    printf "_Hide threshold (RFC-0048 §4.2): `< %d` opens_\n", threshold
    print ""

    print "## Surfaces (top-level)"
    print ""
    print "| Surface | Opens |"
    print "|---|---:|"
    n = 0
    for (s in surface_total) {
      n++
      surf_keys[n] = s
      surf_vals[n] = surface_total[s]
    }
    sort_desc(surf_keys, surf_vals, n)
    for (i = 1; i <= n; i++) {
      printf "| %s | %d |\n", surf_keys[i], surf_vals[i]
    }
    print ""

    print "## Sections (direct opens)"
    print ""
    print "| Surface | Section | Direct opens | Total (incl. redirects) | Below threshold? |"
    print "|---|---|---:|---:|:---:|"
    m = 0
    for (k in section_seen) {
      m++
      sec_keys[m] = k
      sec_totals[m] = section_total[k] + 0
    }
    sort_desc(sec_keys, sec_totals, m)
    for (i = 1; i <= m; i++) {
      key = sec_keys[i]
      split(key, sp, "/")
      surface = sp[1]
      section = sp[2]
      direct = section_direct[key] + 0
      total = section_total[key] + 0
      flag = ""
      if (direct < threshold) flag = "⚠️ candidate"
      printf "| %s | %s | %d | %d | %s |\n", surface, section, direct, total, flag
    }
    print ""

    print "## Redirect provenance"
    print ""
    print "| Surface | Section | Redirected from | Opens |"
    print "|---|---|---|---:|"
    r = 0
    for (rk in section_redirected) {
      r++
      red_keys[r] = rk
      red_vals[r] = section_redirected[rk]
    }
    sort_desc(red_keys, red_vals, r)
    if (r == 0) {
      print "| _(none)_ | | | |"
    } else {
      for (i = 1; i <= r; i++) {
        split(red_keys[i], sp, "/")
        printf "| %s | %s | %s | %d |\n", sp[1], sp[2], sp[3], red_vals[i]
      }
    }
    print ""

    print "## Notes"
    print ""
    print "- **Direct opens** (`redirected_from=none`) are the deletion-threshold metric per RFC-0048 §4.4."
    print "- A section with high **Total** but low **Direct** is alive only because of legacy bookmarks; the redirect can stay, the section component can be deleted."
    print "- Counters are cumulative since process start. Range queries (`--since=7d`) require Prometheus + PR-2.5."
  }

  function sort_desc(keys, vals, n,    i, j, tk, tv) {
    for (i = 2; i <= n; i++) {
      tk = keys[i]; tv = vals[i]
      j = i - 1
      while (j >= 1 && vals[j] < tv) {
        keys[j+1] = keys[j]; vals[j+1] = vals[j]
        j--
      }
      keys[j+1] = tk; vals[j+1] = tv
    }
  }
' "$tmp_metrics" >"$report" && awk_exit=0 || awk_exit=$?

if [[ $awk_exit -eq 2 ]]; then
  echo "$SCRIPT_NAME: no dashboard_*_open_total counters present at $ENDPOINT" >&2
  echo "  (server has not seen any dashboard navigation since start, or PR-1 is not deployed)" >&2
  exit 2
elif [[ $awk_exit -ne 0 ]]; then
  echo "$SCRIPT_NAME: awk failed (exit $awk_exit)" >&2
  exit 1
fi

if [[ -n "$OUTPUT" ]]; then
  cp "$report" "$OUTPUT"
  echo "$SCRIPT_NAME: wrote $OUTPUT" >&2
else
  cat "$report"
fi
