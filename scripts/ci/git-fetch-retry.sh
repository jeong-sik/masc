#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "usage: $0 <remote> <refspec> [git-fetch-args...]" >&2
  exit 64
fi

attempts=${GIT_FETCH_RETRY_ATTEMPTS:-3}
delay=${GIT_FETCH_RETRY_DELAY_SECONDS:-2}
max_delay=${GIT_FETCH_RETRY_MAX_DELAY_SECONDS:-10}

for value_name in attempts delay max_delay; do
  value=${!value_name}
  if [[ -z "$value" || "$value" =~ [^0-9] ]]; then
    echo "invalid ${value_name}: ${value}" >&2
    exit 64
  fi
done

if (( attempts < 1 )); then
  echo "invalid attempts: ${attempts}" >&2
  exit 64
fi

attempt=1
while (( attempt <= attempts )); do
  if git fetch "$@"; then
    exit 0
  else
    status=$?
  fi

  if (( attempt == attempts )); then
    echo "git fetch failed after ${attempts} attempt(s)" >&2
    exit "$status"
  fi

  echo "::warning::git fetch attempt ${attempt}/${attempts} failed with exit ${status}; retrying in ${delay}s" >&2
  sleep "$delay"
  if (( delay < max_delay )); then
    delay=$(( delay * 2 ))
    if (( delay > max_delay )); then
      delay=$max_delay
    fi
  fi
  attempt=$(( attempt + 1 ))
done
