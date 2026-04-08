#!/usr/bin/env bash
set -euo pipefail

SCRIPT_VERSION="local-review-v2"
DEFAULT_MODEL="qwen3.5-35b-a3b-ud-q4-xl"
DEFAULT_URL=""
DEFAULT_CACHE_SUBDIR=".masc/review-cache/local-review"
DEFAULT_PROMPT_VERSION="v1"
DEFAULT_CHUNK_BYTES=40000
DEFAULT_MAX_TOKENS=400
DEFAULT_MAX_TIME=120
DEFAULT_STALE_SECS=120
DEFAULT_TEMPERATURE="0.1"

BASE_REF="origin/main"
HEAD_REF="HEAD"
MODEL="${MASC_LOCAL_REVIEW_MODEL:-$DEFAULT_MODEL}"
REVIEW_URL="${MASC_LOCAL_REVIEW_URL:-$DEFAULT_URL}"
CACHE_DIR="${MASC_LOCAL_REVIEW_CACHE_DIR:-}"
PROMPT_VERSION="${MASC_LOCAL_REVIEW_PROMPT_VERSION:-$DEFAULT_PROMPT_VERSION}"
CHUNK_BYTES="${MASC_LOCAL_REVIEW_CHUNK_BYTES:-$DEFAULT_CHUNK_BYTES}"
MAX_TOKENS="${MASC_LOCAL_REVIEW_MAX_TOKENS:-$DEFAULT_MAX_TOKENS}"
MAX_TIME="${MASC_LOCAL_REVIEW_MAX_TIME:-$DEFAULT_MAX_TIME}"
STALE_SECS="${MASC_LOCAL_REVIEW_STALE_SECS:-$DEFAULT_STALE_SECS}"
TEMPERATURE="${MASC_LOCAL_REVIEW_TEMPERATURE:-$DEFAULT_TEMPERATURE}"
FORMAT="json"
PRINT_CACHE_KEY=0
NO_CACHE=0
REVIEW_COMMAND="${MASC_LOCAL_REVIEW_COMMAND:-}"
declare -a PATH_FILTERS=()
declare -a CHANGED_PATHS=()
declare -a CHUNK_FILES=()
CHANGED_PATH_COUNT=0
CHUNK_FILE_COUNT=0

usage() {
  cat <<'EOF'
Usage: scripts/review/local-review.sh [options]

Options:
  --base <ref>         Base ref for diff (default: origin/main)
  --head <ref>         Head ref for diff (default: HEAD)
  --path <path>        Restrict review to one path (repeatable)
  --model <model>      Reviewer model id
  --format <fmt>       json | text | markdown (default: json)
  --print-cache-key    Print resolved cache key and exit
  --no-cache           Skip cache lookup/write for this invocation
  -h, --help           Show help

Environment:
  MASC_LOCAL_REVIEW_COMMAND   Optional local command override. Receives prompt on stdin.
  MASC_LOCAL_REVIEW_URL       Optional OAS/OpenAI-compatible review endpoint.
  MASC_LOCAL_REVIEW_CACHE_DIR Cache root (default: <shared-repo-root>/.masc/review-cache/local-review)
  MASC_LOCAL_REVIEW_CHUNK_BYTES
  MASC_LOCAL_REVIEW_MAX_TOKENS
  MASC_LOCAL_REVIEW_MAX_TIME
  MASC_LOCAL_REVIEW_STALE_SECS
EOF
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing command: $1" >&2
    exit 1
  }
}

hash_text() {
  if [ $# -gt 0 ]; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

now_epoch() {
  date +%s
}

now_iso() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

path_mtime_epoch() {
  if stat -f %m "$1" >/dev/null 2>&1; then
    stat -f %m "$1"
  else
    stat -c %Y "$1"
  fi
}

trim() {
  awk '{$1=$1; print}'
}

json_bool() {
  if [ "$1" = "true" ]; then
    printf 'true'
  else
    printf 'false'
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE_REF="$2"; shift 2 ;;
    --head) HEAD_REF="$2"; shift 2 ;;
    --path) PATH_FILTERS+=("$2"); shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --format) FORMAT="$2"; shift 2 ;;
    --print-cache-key) PRINT_CACHE_KEY=1; shift ;;
    --no-cache) NO_CACHE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

require_cmd git
require_cmd jq
require_cmd shasum
if [ -z "$REVIEW_COMMAND" ]; then
  require_cmd curl
fi

if [ -z "$REVIEW_COMMAND" ] && [ -z "$REVIEW_URL" ]; then
  echo "set MASC_LOCAL_REVIEW_COMMAND or MASC_LOCAL_REVIEW_URL (OAS/OpenAI-compatible endpoint)" >&2
  exit 1
fi

resolve_shared_repo_root() {
  local common_dir
  common_dir="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || git rev-parse --git-common-dir 2>/dev/null || true)"
  if [ -n "$common_dir" ] && [ -d "$common_dir" ]; then
    (cd "$common_dir/.." && pwd -P)
  else
    pwd -P
  fi
}

default_cache_dir() {
  printf '%s/%s\n' "$(resolve_shared_repo_root)" "$DEFAULT_CACHE_SUBDIR"
}

if [ -z "$CACHE_DIR" ]; then
  CACHE_DIR="$(default_cache_dir)"
fi

case "$FORMAT" in
  json|text|markdown) ;;
  *) echo "invalid format: $FORMAT" >&2; exit 1 ;;
esac

BASE_SHA="$(git rev-parse "$BASE_REF")"
HEAD_SHA="$(git rev-parse "$HEAD_REF")"

if [ ${#PATH_FILTERS[@]} -gt 0 ]; then
  while IFS= read -r line; do
    CHANGED_PATHS+=("$line")
    CHANGED_PATH_COUNT=$((CHANGED_PATH_COUNT + 1))
  done < <(git diff --name-only "${BASE_REF}...${HEAD_REF}" -- "${PATH_FILTERS[@]}")
else
  while IFS= read -r line; do
    CHANGED_PATHS+=("$line")
    CHANGED_PATH_COUNT=$((CHANGED_PATH_COUNT + 1))
  done < <(git diff --name-only "${BASE_REF}...${HEAD_REF}")
fi

if [ "$CHANGED_PATH_COUNT" -gt 0 ]; then
  PATHSET_HASH="$(printf '%s\n' "${CHANGED_PATHS[@]}" | LC_ALL=C sort | hash_text)"
else
  PATHSET_HASH="$(printf '' | hash_text)"
fi
CACHE_KEY="$(
  printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
    "$SCRIPT_VERSION" "$MODEL" "$PROMPT_VERSION" "$BASE_SHA" "$HEAD_SHA" \
    "$FORMAT" "$PATHSET_HASH" \
  | hash_text
)"

if [ "$PRINT_CACHE_KEY" -eq 1 ]; then
  printf '%s\n' "$CACHE_KEY"
  exit 0
fi

LOCK_ROOT="$CACHE_DIR/locks"
INDEX_ROOT="$CACHE_DIR/index"
RESULT_ROOT="$CACHE_DIR/results"
LOCK_DIR="$LOCK_ROOT/$CACHE_KEY.lock"
PENDING_FILE="$INDEX_ROOT/$CACHE_KEY.pending.json"
RESULT_FILE="$RESULT_ROOT/$CACHE_KEY.json"

mkdir -p "$LOCK_ROOT" "$INDEX_ROOT" "$RESULT_ROOT"

HAVE_LOCK=0
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/masc-local-review.XXXXXX")"
cleanup() {
  if [ "$HAVE_LOCK" -eq 1 ]; then
    rm -f "$PENDING_FILE"
    rmdir "$LOCK_DIR" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

print_cached_result() {
  local cache_hit="$1"
  case "$FORMAT" in
    json)
      jq --argjson cache_hit "$(json_bool "$cache_hit")" \
        '.cache_hit = $cache_hit' "$RESULT_FILE"
      ;;
    text)
      jq -r '.result' "$RESULT_FILE"
      ;;
    markdown)
      jq -r '.markdown' "$RESULT_FILE"
      ;;
  esac
}

pending_is_stale_or_dead() {
  if [ ! -f "$PENDING_FILE" ]; then
    if [ -d "$LOCK_DIR" ]; then
      local lock_mtime now age
      lock_mtime="$(path_mtime_epoch "$LOCK_DIR")"
      now="$(now_epoch)"
      age=$((now - lock_mtime))
      if [ "$age" -ge "$STALE_SECS" ]; then
        return 0
      fi
      return 1
    fi
    return 0
  fi
  local pid started_at age now
  pid="$(jq -r '.pid // 0' "$PENDING_FILE")"
  started_at="$(jq -r '.started_at_epoch // 0' "$PENDING_FILE")"
  now="$(now_epoch)"
  age=$((now - started_at))
  if ! kill -0 "$pid" >/dev/null 2>&1; then
    return 0
  fi
  if [ "$age" -ge "$STALE_SECS" ]; then
    return 0
  fi
  return 1
}

reap_pending_if_needed() {
  if [ ! -d "$LOCK_DIR" ] && [ ! -f "$PENDING_FILE" ]; then
    return 0
  fi
  if ! pending_is_stale_or_dead; then
    return 1
  fi
  if [ -f "$PENDING_FILE" ]; then
    local pid started_at age now
    pid="$(jq -r '.pid // 0' "$PENDING_FILE")"
    started_at="$(jq -r '.started_at_epoch // 0' "$PENDING_FILE")"
    now="$(now_epoch)"
    age=$((now - started_at))
    if kill -0 "$pid" >/dev/null 2>&1 && [ "$age" -ge "$STALE_SECS" ]; then
      kill "$pid" >/dev/null 2>&1 || true
    fi
  fi
  rm -f "$PENDING_FILE"
  rm -rf "$LOCK_DIR"
  return 0
}

wait_for_existing_result() {
  while true; do
    if [ -f "$RESULT_FILE" ]; then
      print_cached_result true
      exit 0
    fi
    if reap_pending_if_needed; then
      return 1
    fi
    sleep 1
  done
}

if [ "$NO_CACHE" -eq 0 ]; then
  if [ -f "$RESULT_FILE" ]; then
    print_cached_result true
    exit 0
  fi

  while true; do
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      HAVE_LOCK=1
      jq -n \
        --arg key "$CACHE_KEY" \
        --arg model "$MODEL" \
        --arg pid "$$" \
        --argjson started_at_epoch "$(now_epoch)" \
        --arg started_at "$(now_iso)" \
        --arg base_ref "$BASE_REF" \
        --arg head_ref "$HEAD_REF" \
        --arg base_sha "$BASE_SHA" \
        --arg head_sha "$HEAD_SHA" \
        --arg version "$SCRIPT_VERSION" \
        '{key:$key,model:$model,pid:($pid|tonumber),started_at_epoch:$started_at_epoch,started_at:$started_at,base_ref:$base_ref,head_ref:$head_ref,base_sha:$base_sha,head_sha:$head_sha,script_version:$version}' \
        > "$PENDING_FILE"
      break
    fi
    wait_for_existing_result || true
    if [ -f "$RESULT_FILE" ]; then
      print_cached_result true
      exit 0
    fi
  done
fi

build_chunks() {
  local chunk_index=0
  local current=""
  local file diff path
  CHUNK_FILES=()
  CHUNK_FILE_COUNT=0

  if [ "$CHANGED_PATH_COUNT" -eq 0 ]; then
    return 0
  fi

  for file in "${CHANGED_PATHS[@]}"; do
    if [ -n "$file" ]; then
      diff="$(git diff --unified=2 "${BASE_REF}...${HEAD_REF}" -- "$file")"
    else
      diff=""
    fi
    if [ -z "$diff" ]; then
      continue
    fi
    diff="${diff}"$'\n'
    if [ -n "$current" ] && [ $(( ${#current} + ${#diff} )) -gt "$CHUNK_BYTES" ]; then
      chunk_index=$((chunk_index + 1))
      path="$TMP_DIR/chunk-$chunk_index.diff"
      printf '%s' "$current" > "$path"
      CHUNK_FILES+=("$path")
      CHUNK_FILE_COUNT=$((CHUNK_FILE_COUNT + 1))
      current="$diff"
    else
      current="${current}${diff}"
    fi
  done

  if [ -n "$current" ]; then
    chunk_index=$((chunk_index + 1))
    path="$TMP_DIR/chunk-$chunk_index.diff"
    printf '%s' "$current" > "$path"
    CHUNK_FILES+=("$path")
    CHUNK_FILE_COUNT=$((CHUNK_FILE_COUNT + 1))
  fi
}

build_prompt() {
  local chunk_path="$1"
  cat <<EOF
Review this git diff against ${BASE_REF}...${HEAD_REF} with fresh context only. Do not assume tickets, design intent, or prior discussion.
Focus only on bugs, regressions, stale compatibility assumptions, structural contract violations, and missing tests.
Return only \`No findings.\` or a flat list of findings with file paths and concise reasoning.

$(cat "$chunk_path")
EOF
}

run_reviewer() {
  local prompt="$1"
  if [ -n "$REVIEW_COMMAND" ]; then
    printf '%s' "$prompt" | bash -lc "$REVIEW_COMMAND"
    return 0
  fi
  local request_json
  request_json="$(
    jq -n \
      --arg model "$MODEL" \
      --arg system_prompt "You are a strict fresh-context code reviewer. Review the patch for bugs, regressions, stale compatibility assumptions, structural contract violations, and missing tests. Return only \`No findings.\` or a flat list of findings with file paths and concise reasoning." \
      --arg user_prompt "$prompt" \
      --argjson max_tokens "$MAX_TOKENS" \
      --argjson temperature "$TEMPERATURE" \
      '{model:$model,messages:[{role:"system",content:$system_prompt},{role:"user",content:$user_prompt}],temperature:$temperature,max_tokens:$max_tokens,stream:false}'
  )"
  curl -s --show-error --max-time "$MAX_TIME" "$REVIEW_URL" \
    -H 'Content-Type: application/json' \
    --data-binary "$request_json" \
    | jq -r '.choices[0].message.content // empty'
}

build_chunks

if [ "$CHUNK_FILE_COUNT" -eq 0 ]; then
  RESULT_TEXT="No findings."
  CHUNK_COUNT=0
else
  declare -a CHUNK_RESULTS=()
  for chunk_path in "${CHUNK_FILES[@]}"; do
    chunk_result="$(run_reviewer "$(build_prompt "$chunk_path")" | trim)"
    if [ -z "$chunk_result" ]; then
      echo "reviewer returned empty output" >&2
      exit 1
    fi
    CHUNK_RESULTS+=("$chunk_result")
  done

  CHUNK_COUNT="${#CHUNK_FILES[@]}"
  has_findings=0
  for item in "${CHUNK_RESULTS[@]}"; do
    if [ "$item" != "No findings." ]; then
      has_findings=1
      break
    fi
  done

  if [ "$has_findings" -eq 0 ]; then
    RESULT_TEXT="No findings."
  else
    RESULT_TEXT="$(
      printf '%s\n' "${CHUNK_RESULTS[@]}" \
        | awk 'NF && $0 != "No findings." { print }' \
        | awk '!seen[$0]++'
    )"
    if [ -z "$RESULT_TEXT" ]; then
      RESULT_TEXT="No findings."
    fi
  fi
fi

if [ -n "$REVIEW_COMMAND" ]; then
  REVIEW_TARGET_DESC="custom command"
else
  REVIEW_TARGET_DESC="OAS/OpenAI-compatible endpoint \`${REVIEW_URL}\`"
fi

MARKDOWN_RESULT="$(
  cat <<EOF
Cross-model review evidence

- Reviewer model: \`${MODEL}\`
- Reviewer target: ${REVIEW_TARGET_DESC}
- Timestamp: $(now_iso)
- Prompt version: \`${PROMPT_VERSION}\`
- Cache: $([ "$NO_CACHE" -eq 0 ] && printf 'miss' || printf 'disabled')
- Chunk count: ${CHUNK_COUNT}
- Scope: \`${BASE_REF}...${HEAD_REF}\`
- Result:
\`\`\`
${RESULT_TEXT}
\`\`\`
EOF
)"

if [ "$CHANGED_PATH_COUNT" -gt 0 ]; then
  PATHS_JSON="$(
    printf '%s\n' "${CHANGED_PATHS[@]}" | jq -R . | jq -s .
  )"
else
  PATHS_JSON="[]"
fi

TMP_RESULT="$TMP_DIR/result.json"
jq -n \
  --arg status "ok" \
  --arg key "$CACHE_KEY" \
  --arg version "$SCRIPT_VERSION" \
  --arg model "$MODEL" \
  --arg prompt_version "$PROMPT_VERSION" \
  --arg base_ref "$BASE_REF" \
  --arg head_ref "$HEAD_REF" \
  --arg base_sha "$BASE_SHA" \
  --arg head_sha "$HEAD_SHA" \
  --argjson cache_hit false \
  --argjson chunk_count "$CHUNK_COUNT" \
  --argjson paths "$PATHS_JSON" \
  --arg result "$RESULT_TEXT" \
  --arg markdown "$MARKDOWN_RESULT" \
  --arg created_at "$(now_iso)" \
  '{status:$status,cache_key:$key,script_version:$version,model:$model,prompt_version:$prompt_version,base_ref:$base_ref,head_ref:$head_ref,base_sha:$base_sha,head_sha:$head_sha,cache_hit:$cache_hit,chunk_count:$chunk_count,paths:$paths,result:$result,markdown:$markdown,created_at:$created_at}' \
  > "$TMP_RESULT"

if [ "$NO_CACHE" -eq 0 ]; then
  mv "$TMP_RESULT" "$RESULT_FILE"
fi

case "$FORMAT" in
  json)
    if [ "$NO_CACHE" -eq 0 ]; then
      cat "$RESULT_FILE"
    else
      cat "$TMP_RESULT"
    fi
    ;;
  text)
    printf '%s\n' "$RESULT_TEXT"
    ;;
  markdown)
    printf '%s\n' "$MARKDOWN_RESULT"
    ;;
esac
