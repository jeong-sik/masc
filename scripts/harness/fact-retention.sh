#!/usr/bin/env bash
# RFC-0228 P2 — fact-retention harness, live half.
#
# Deterministic half (CI): test/test_fact_retention_reachability.ml
# proves every planted fact is mechanically reachable through the
# paged pull. This script measures the non-deterministic half: does a
# LIVE keeper actually walk history (keeper_surface_read before-paging)
# to recover facts that scrolled past its window?
#
# Modes:
#   gen    --out FILE [--pages N]
#          Write a fixture lane JSONL to FILE and a facts manifest to
#          FILE.facts (tab-separated: key<TAB>token<TAB>page_depth).
#          NEVER writes into the runtime root (<base-path>/.masc) — the
#          operator decides where to place the fixture (e.g. a scratch keeper's lane file, server
#          stopped, then restart).
#   recall --keeper NAME --facts FILE.facts [--server URL]
#          For each fact, ask the keeper for the value via
#          POST /api/v1/gate/message and grep the reply for the token.
#          Prints per-depth recall JSON. Auth: $FACT_HARNESS_TOKEN as
#          Bearer when set.
#
# Recall semantics: a hit means the keeper produced the exact planted
# token. The fixture pads facts deeper than one window, so a keeper
# that never pages cannot score above the page-1 bucket — that gap is
# the metric.
set -euo pipefail

SERVER="${MASC_SERVER:-http://localhost:8935}"
PAGES=11

mode="${1:-}"; shift || true

case "$mode" in
  gen)
    OUT=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --out) OUT="$2"; shift 2 ;;
        --pages) PAGES="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
      esac
    done
    [ -n "$OUT" ] || { echo "gen requires --out FILE" >&2; exit 2; }
    total=$(( PAGES * 100 ))
    # Facts at tail page 1, middle, and the oldest page. Plain case
    # functions, not declare -A: macOS ships bash 3.2.
    mid_page=$(( (PAGES + 1) / 2 ))
    fact_line() {
      case "$1" in
        ALPHA) echo $(( total - 50 )) ;;
        BRAVO) echo $(( total - (mid_page - 1) * 100 - 50 )) ;;
        CHARLIE) echo 50 ;;
      esac
    }
    fact_page() {
      case "$1" in
        ALPHA) echo 1 ;;
        BRAVO) echo "$mid_page" ;;
        CHARLIE) echo "$PAGES" ;;
      esac
    }
    : > "$OUT"
    for (( i=1; i<=total; i++ )); do
      role=$([ $(( i % 2 )) -eq 1 ] && echo user || echo assistant)
      content="filler chatter $(printf '%04d' "$i")"
      for key in ALPHA BRAVO CHARLIE; do
        if [ "$(fact_line "$key")" -eq "$i" ]; then
          content="the $(echo "$key" | tr 'A-Z' 'a-z') deployment token is FACT-${key}-7319"
        fi
      done
      printf '{"role":"%s","content":"%s","ts":%d.0,"source":"discord"}\n' \
        "$role" "$content" "$i" >> "$OUT"
    done
    : > "${OUT}.facts"
    for key in ALPHA BRAVO CHARLIE; do
      printf '%s\tFACT-%s-7319\t%d\n' "$key" "$key" "$(fact_page "$key")" >> "${OUT}.facts"
    done
    echo "fixture: $OUT ($total lines, $PAGES pages); manifest: ${OUT}.facts"
    ;;

  recall)
    KEEPER="" FACTS=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --keeper) KEEPER="$2"; shift 2 ;;
        --facts) FACTS="$2"; shift 2 ;;
        --server) SERVER="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
      esac
    done
    [ -n "$KEEPER" ] && [ -f "$FACTS" ] || {
      echo "recall requires --keeper NAME --facts FILE.facts" >&2; exit 2; }
    auth=()
    [ -n "${FACT_HARNESS_TOKEN:-}" ] && auth=(-H "Authorization: Bearer ${FACT_HARNESS_TOKEN}")
    hits=0; misses=0; rows=()
    while IFS=$'\t' read -r key token page; do
      lc_key=$(echo "$key" | tr 'A-Z' 'a-z')
      question="What is the ${lc_key} deployment token mentioned earlier in this channel? It may be far back - walk the history with keeper_surface_read using its before parameter until you find it. Reply with the exact token."
      body=$(jq -n \
        --arg keeper "$KEEPER" --arg content "$question" --arg idem "fact-$key-$$" \
        '{channel:"discord", channel_user_id:"fact-harness", channel_user_name:"fact-harness",
          channel_workspace_id:"fact-harness", keeper_name:$keeper, content:$content,
          idempotency_key:$idem, metadata:{}}')
      reply=$(curl -sS -X POST "${SERVER}/api/v1/gate/message" \
        -H 'Content-Type: application/json' ${auth[@]+"${auth[@]}"} -d "$body" \
        | jq -r '.reply // ""')
      if [[ "$reply" == *"$token"* ]]; then verdict=hit; hits=$((hits+1));
      else verdict=miss; misses=$((misses+1)); fi
      rows+=("{\"fact\":\"$key\",\"page_depth\":$page,\"verdict\":\"$verdict\"}")
      echo "[$verdict] $key (page $page)" >&2
    done < "$FACTS"
    total=$((hits + misses))
    printf '{"keeper":"%s","recall":%s,"hits":%d,"total":%d,"facts":[%s]}\n' \
      "$KEEPER" "$(jq -n --argjson h "$hits" --argjson t "$total" '$h / ([$t,1]|max)')" \
      "$hits" "$total" "$(IFS=,; echo "${rows[*]}")"
    ;;

  *)
    sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
