#!/usr/bin/env bash
# Live probe of OpenRouter ids that have no catalog row yet, in the shape of
# evidence/task-openrouter-support (2026-09-10): basic, stream, tool_choice
# required, reasoning shape, reasoning_split, the seven-rung effort ladder, and
# the declared output ceiling sent as max_tokens.
#
# Usage: OPENROUTER_API_KEY=... bash probe.sh <id>:<slug>:<declared_max_output> ...
# Stops before a model when the key has less than $MIN_REMAINING left, because
# the same key serves a live runtime.
set -u
cd "$(dirname "$0")"
URL=https://openrouter.ai/api/v1/chat/completions
MIN_REMAINING=${MIN_REMAINING:-0.5}
TOOLS='[{"type":"function","function":{"name":"get_weather","description":"Get the current weather for a city","parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}}]'

post() { # out-file json-body
  curl -s -m 240 -o "$1" -w '%{http_code}' "$URL" \
    -H "Authorization: Bearer $OPENROUTER_API_KEY" -H 'Content-Type: application/json' \
    -H 'HTTP-Referer: https://github.com/jeong-sik/masc' -H 'X-Title: MASC' -d "$2"
}

remaining() {
  curl -s -m 30 -H "Authorization: Bearer $OPENROUTER_API_KEY" https://openrouter.ai/api/v1/key \
    | jq -r '.data.limit_remaining'
}

for spec in "$@"; do
  IFS=: read -r id slug ceiling <<< "$spec"
  left=$(remaining)
  if awk -v l="$left" -v m="$MIN_REMAINING" 'BEGIN{exit !(l < m)}'; then
    echo "STOP before $id: limit_remaining=$left < $MIN_REMAINING" | tee -a status.log
    break
  fi
  echo "== $id (limit_remaining=$left)" | tee -a status.log
  q17='What is 17*23? Answer with the number.'
  c=$(post "probe-$slug-basic.json" "{\"model\":\"$id\",\"max_tokens\":64,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: OK\"}]}")
  echo "basic $c" >> status.log
  c=$(curl -s -m 240 -o "probe-$slug-stream.sse" -w '%{http_code}' "$URL" \
    -H "Authorization: Bearer $OPENROUTER_API_KEY" -H 'Content-Type: application/json' \
    -d "{\"model\":\"$id\",\"stream\":true,\"reasoning_effort\":\"high\",\"max_tokens\":400,\"messages\":[{\"role\":\"user\",\"content\":\"$q17\"}]}")
  echo "stream $c" >> status.log
  c=$(post "probe-$slug-toolcall.json" "{\"model\":\"$id\",\"max_tokens\":512,\"tool_choice\":\"required\",\"tools\":$TOOLS,\"messages\":[{\"role\":\"user\",\"content\":\"What is the weather in Seoul right now?\"}]}")
  echo "toolcall $c" >> status.log
  c=$(post "probe-$slug-reasoning.json" "{\"model\":\"$id\",\"reasoning_effort\":\"high\",\"max_tokens\":400,\"messages\":[{\"role\":\"user\",\"content\":\"What is 17*23? Think it through, then give the number.\"}]}")
  echo "reasoning $c" >> status.log
  c=$(post "probe-$slug-reasoning-split.json" "{\"model\":\"$id\",\"reasoning_effort\":\"high\",\"reasoning_split\":true,\"max_tokens\":400,\"messages\":[{\"role\":\"user\",\"content\":\"$q17\"}]}")
  echo "reasoning-split $c" >> status.log
  for rung in none minimal low medium high xhigh max; do
    c=$(post "probe-$slug-effort-$rung.json" "{\"model\":\"$id\",\"reasoning_effort\":\"$rung\",\"max_tokens\":200,\"messages\":[{\"role\":\"user\",\"content\":\"$q17\"}]}")
    echo "effort-$rung $c" >> status.log
  done
  c=$(post "probe-$slug-ceiling.json" "{\"model\":\"$id\",\"reasoning_effort\":\"low\",\"max_tokens\":$ceiling,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: OK\"}]}")
  echo "ceiling($ceiling) $c" >> status.log
done
echo "remaining after run: $(remaining)" | tee -a status.log
echo DONE >> status.log
