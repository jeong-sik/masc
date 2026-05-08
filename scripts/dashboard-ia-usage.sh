#!/usr/bin/env bash
# RFC-0049 PR-2 / RFC-0048 PR-C input: scrape dashboard nav telemetry
# counters from masc-mcp's /metrics endpoint and emit a Markdown report
# ranking surfaces and sections by open count.
#
# The counters are cumulative since the last masc-mcp restart, not
# windowed — this script does not pretend to do PromQL rate(). The
# `--since` flag is accepted but only printed in the report header so
# the operator knows what window the snapshot is meant to represent.
# Real time-windowed analysis belongs in Grafana / Prometheus server,
# not here.
#
# RFC-0048 §4.2 threshold proposal (placeholder, subject to data):
#   - section < 5 opens / week  → mark hidden=true
#   - section stayed hidden 7d with zero redirect target hits → delete
#   - section > 40% of surface's opens → promote to default
#   - two sections both < 20 opens / week, > 60% operator overlap →
#     merge (operator overlap is not measurable from these counters;
#     ad-hoc proposal)
#
# Usage:
#   scripts/dashboard-ia-usage.sh [--since=DURATION] [--metrics-url=URL]
#
#   --since=DURATION    Free-form label printed in report header (e.g. 7d).
#                       Default: "since-restart" — counters are cumulative,
#                       not windowed.
#   --metrics-url=URL   /metrics endpoint. Default: env MASC_METRICS_URL
#                       or http://127.0.0.1:8935/metrics.
#   --token=TOKEN       Bearer token for the metrics endpoint when it
#                       requires auth. Default: env MASC_METRICS_TOKEN
#                       (unset → no Authorization header sent).

set -euo pipefail

since="since-restart"
metrics_url="${MASC_METRICS_URL:-http://127.0.0.1:8935/metrics}"
token="${MASC_METRICS_TOKEN:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --since=*) since="${1#--since=}" ;;
    --metrics-url=*) metrics_url="${1#--metrics-url=}" ;;
    --token=*) token="${1#--token=}" ;;
    -h|--help)
      sed -n '2,35p' "$0"
      exit 0
      ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

curl_args=(-fsS --max-time 5)
if [ -n "$token" ]; then
  curl_args+=(-H "Authorization: Bearer $token")
fi

scrape="$(curl "${curl_args[@]}" "$metrics_url")" || {
  echo "error: failed to scrape $metrics_url (set --token or MASC_METRICS_TOKEN if 401)" >&2
  exit 1
}

# Surface counters: dashboard_surface_open_total{surface="<id>"} <count>
surface_lines="$(printf '%s\n' "$scrape" \
  | awk '/^dashboard_surface_open_total\{/' \
  | sed -E 's/dashboard_surface_open_total\{surface="([^"]+)"\} ([0-9.eE+-]+)/\1\t\2/' \
  | sort -t$'\t' -k2,2 -nr)"

# Section counters: dashboard_section_open_total{surface="<id>",section="<id>",redirected_from="<key>"} <count>
section_raw="$(printf '%s\n' "$scrape" \
  | awk '/^dashboard_section_open_total\{/' \
  | sed -E 's/dashboard_section_open_total\{surface="([^"]+)",section="([^"]+)",redirected_from="([^"]+)"\} ([0-9.eE+-]+)/\1\t\2\t\3\t\4/')"

# Aggregate by (surface, section) ignoring redirected_from for the
# top-line ranking; keep the redirected_from breakdown separate so the
# threshold reader can distinguish bookmark-driven hits from organic
# navigation (RFC-0048 §4.4 + §5.3).
section_lines="$(printf '%s\n' "$section_raw" \
  | awk -F'\t' 'NF==4 { key=$1"\t"$2; sum[key]+=$4 } END { for (k in sum) printf "%s\t%s\n", k, sum[k] }' \
  | sort -t$'\t' -k3,3 -nr)"

redirect_lines="$(printf '%s\n' "$section_raw" \
  | awk -F'\t' 'NF==4 && $3 != "none" { printf "%s\t%s\t%s\t%s\n", $3, $1, $2, $4 }' \
  | sort -t$'\t' -k4,4 -nr)"

now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

cat <<EOF
# Dashboard IA Usage Report

- Generated: $now
- Window label: $since (counters are cumulative since last restart)
- Source: $metrics_url

## Surface opens

| Surface | Opens |
|---|---:|
EOF

if [ -z "$surface_lines" ]; then
  echo "| _(no data — counters not yet incremented)_ | — |"
else
  printf '%s\n' "$surface_lines" | awk -F'\t' '{ printf "| %s | %s |\n", $1, $2 }'
fi

cat <<EOF

## Section opens (aggregated across redirected_from)

| Surface | Section | Opens |
|---|---|---:|
EOF

if [ -z "$section_lines" ]; then
  echo "| _(no data)_ | — | — |"
else
  printf '%s\n' "$section_lines" | awk -F'\t' '{ printf "| %s | %s | %s |\n", $1, $2, $3 }'
fi

cat <<EOF

## Redirect-driven hits (RFC-0048 §4.4 deletion threshold input)

\`redirected_from\` distinguishes bookmark / external-link hits from
organic in-app navigation. Sections kept alive solely by these hits
are deletion candidates after the soak window.

| Original key | Resolved surface | Resolved section | Hits |
|---|---|---|---:|
EOF

if [ -z "$redirect_lines" ]; then
  echo "| _(no redirected traffic)_ | — | — | — |"
else
  printf '%s\n' "$redirect_lines" | awk -F'\t' '{ printf "| %s | %s | %s | %s |\n", $1, $2, $3, $4 }'
fi

cat <<EOF

## Threshold readout (RFC-0048 §4.2)

> Placeholders — revise once a full week of data is observed.

- **Mark \`hidden: true\`**: sections with < 5 opens for the window.
- **Delete component + redirect**: section was hidden for 7d AND its
  redirect target shows zero hits in the redirect table above.
- **Promote to default**: a section accounts for > 40% of its
  surface's opens.
- **Merge candidates**: two sections under the same surface, each
  < 20 opens, with > 60% operator overlap (overlap not measurable
  from these counters — file an ad-hoc proposal).
EOF
