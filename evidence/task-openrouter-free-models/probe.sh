#!/usr/bin/env bash
# Live probe of OpenRouter's free (":free") ids before they get catalog rows.
# Three cases per model, the ones the lane-end fallback needs:
#   basic     - "Reply with exactly: OK", max_tokens 64
#   toolcall  - one get_weather tool, tool_choice "required"
#               ("auto" for ids whose metadata omits tool_choice: inkling*)
#   nothink   - reasoning_effort "none", the wire value masc sends to turn
#               thinking off, max_tokens 200
#
# Usage (from the repo root, on the host that holds the key):
#   OPENROUTER_API_KEY=... bash evidence/task-openrouter-free-models/probe.sh
# With no arguments it probes every tool-capable free id in
# models-snapshot.json. Pass ids to probe only those.
#
# Free ids cost no credit, but the account and providers are rate-limited,
# so requests are spaced by $GAP seconds (default 3.5). A model the
# account's privacy settings exclude answers 404 "No endpoints found matching
# your data policy"; that is recorded as a result, not retried.
#
# Output: probe-<slug>-<case>.json per request and status.txt, one line per
# request: <id> <case> <http> <verdict>. Paste status.txt into the PR.
#
# Account limits: GET /api/v1/key is read before the first and after the last
# request, and its `limit` and `free_model_daily_requests` are written raw to
# status.txt ("key-before" / "key-after"). The PR quotes these values, not the
# docs table, whose numbers did not survive extraction (Board p-e1e984f7).
#
# A 429 is split by origin. With error.metadata.provider_error_code (or provider_code) the provider was
# congested (provider_429): the request is retried once after 10 s and the
# retry decides the case. An explicit platform limit is
# platform_429; absent origin metadata is unknown_429. Either stops the probe,
# and every case not yet run is written as
# "unmeasured", never as a failure.
set -u
cd "$(dirname "$0")"
: "${OPENROUTER_API_KEY:?set OPENROUTER_API_KEY}"
URL=https://openrouter.ai/api/v1/chat/completions
GAP=${GAP:-3.5}
TOOLS='[{"type":"function","function":{"name":"get_weather","description":"Get the current weather for a city","parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}}]'

if [ "$#" -gt 0 ]; then
  ids=("$@")
else
  ids=()
  while IFS= read -r id; do
    ids+=("$id")
  done < <(jq -r '.[] | select(.supported_parameters | index("tools")) | .id' models-snapshot.json)
fi

post() { # out-file json-body -> prints http code
  sleep "$GAP"
  curl -s -m 240 -o "$1" -w '%{http_code}' "$URL" \
    -H "Authorization: Bearer $OPENROUTER_API_KEY" -H 'Content-Type: application/json' \
    -H 'HTTP-Referer: https://github.com/jeong-sik/masc' -H 'X-Title: MASC' -d "$2"
}

key_read() { # label
  printf '%s %s\n' "$1" "$(curl -s -m 30 -H "Authorization: Bearer $OPENROUTER_API_KEY" \
    https://openrouter.ai/api/v1/key | jq -c '{limit: .data.limit, limit_remaining: .data.limit_remaining, free_model_daily_requests: .data.free_model_daily_requests}')" \
    | tee -a status.txt
}

origin_429() { # file -> provider_429 | platform_429 | unknown_429
  jq -r '
    .error.metadata as $m |
    if ($m.provider_error_code // $m.provider_code) != null
       or $m.limit_source == "upstream_provider_shared_pool" then "provider_429"
    elif $m.limit_source == "platform" then "platform_429"
    else "unknown_429" end' "$1"
}

verdict() { # case file http
  local f=$2 http=$3
  if [ "$http" != 200 ]; then
    jq -r '.error.message // "no error body"' "$f" 2>/dev/null | head -c 160 | tr '\n' ' '
    return
  fi
  case $1 in
    basic) jq -r '"content=" + ((.choices[0].message.content // "null") | tostring | .[0:40]) + " finish=" + (.choices[0].finish_reason // "?")' "$f" ;;
    toolcall) jq -r 'if (.choices[0].message.tool_calls // []) | length > 0 then "tool=" + .choices[0].message.tool_calls[0].function.name else "NO_TOOL_CALL finish=" + (.choices[0].finish_reason // "?") end' "$f" ;;
    nothink) jq -r '"reasoning_tokens=" + ((.usage.completion_tokens_details.reasoning_tokens // "unreported") | tostring) + " content=" + ((.choices[0].message.content // "null") | tostring | .[0:20])' "$f" ;;
  esac
}

: > status.txt
key_read key-before
stopped=""
for id in "${ids[@]}"; do
  slug=$(printf '%s' "$id" | tr '/:.' '---')
  choice='"required"'
  jq -e --arg id "$id" '.[] | select(.id == $id) | .supported_parameters | index("tool_choice")' models-snapshot.json >/dev/null || choice='"auto"'
  for case in basic toolcall nothink; do
    f="probe-$slug-$case.json"
    case $case in
      basic) body="{\"model\":\"$id\",\"max_tokens\":64,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: OK\"}]}" ;;
      toolcall) body="{\"model\":\"$id\",\"max_tokens\":512,\"tool_choice\":$choice,\"tools\":$TOOLS,\"messages\":[{\"role\":\"user\",\"content\":\"What is the weather in Seoul right now? Use the tool.\"}]}" ;;
      nothink) body="{\"model\":\"$id\",\"reasoning_effort\":\"none\",\"max_tokens\":200,\"messages\":[{\"role\":\"user\",\"content\":\"What is 17*23? Answer with the number.\"}]}" ;;
    esac
    if [ -n "$stopped" ]; then
      printf '%s %s - unmeasured (probe stopped: %s)\n' "$id" "$case" "$stopped" | tee -a status.txt
      continue
    fi
    http=$(post "$f" "$body")
    note=""
    if [ "$http" = 429 ]; then
      origin=$(origin_429 "$f")
      if [ "$origin" = provider_429 ]; then
        sleep 10
        http=$(post "$f" "$body")
        note=" [provider_429 on first try; this is the retry]"
      else
        stopped="$origin at $id $case"
        printf '%s %s 429 %s — stopping\n' "$id" "$case" "$origin" | tee -a status.txt
        continue
      fi
    fi
    printf '%s %s %s %s%s\n' "$id" "$case" "$http" "$(verdict "$case" "$f" "$http")" "$note" | tee -a status.txt
  done
done
key_read key-after
