#!/usr/bin/env bash
# Vibe 3.1.0 L0 measurements for RFC-vibe-official-client-lane.
# Usage: run-l0.sh <output-root>
# Every run gets an empty work dir and its own output dir. Runs drop
# MISTRAL_API_KEY unless the run is about that variable.
set -u
root=$1
mkdir -p "$root"
root=$(cd "$root" && pwd)
summary="$root/summary.tsv"
printf 'run\texit\tseconds\tenv_key\n' > "$summary"

probe() {
  local name=$1 env_key=$2; shift 2
  local dir="$root/$name"
  mkdir -p "$dir/work" "$dir/out"
  local start end status
  start=$(python3 -c 'import time; print(time.time())')
  if [ "$env_key" = keep ]; then
    (cd "$dir/work" && vibe --workdir "$dir/work" --output-dir "$dir/out" "$@" > "$dir/stdout" 2> "$dir/stderr")
  else
    (cd "$dir/work" && env -u MISTRAL_API_KEY vibe --workdir "$dir/work" --output-dir "$dir/out" "$@" > "$dir/stdout" 2> "$dir/stderr")
  fi
  status=$?
  ls -A "$dir/work" > "$dir/work.ls"
  end=$(python3 -c 'import time; print(time.time())')
  printf '%s\t%s\t%.1f\t%s\n' "$name" "$status" "$(python3 -c "print($end-$start)")" "$env_key" >> "$summary"
}

common=(--trust --agent ask --max-turns 3 --time-limit 120)

probe m1-streaming drop "${common[@]}" --output streaming -p "Reply with exactly: ok"
probe m2-unknown-flag drop --no-such-flag -p "Reply with exactly: ok"
probe m3-unknown-model drop "${common[@]}" --output json --model no-such-model-alias -p "Reply with exactly: ok"
probe m4-env-api-key keep "${common[@]}" --output json -p "Reply with exactly: ok"
probe m5-time-limit drop --trust --agent ask --time-limit 1 --output json -p "Write the numbers from 1 to 400, one per line."
probe m6-max-price drop "${common[@]}" --max-price 0.000001 --output json -p "Write the numbers from 1 to 50, one per line."
probe m7-max-tokens drop "${common[@]}" --max-tokens 200 --output json -p "Write the numbers from 1 to 400, one per line."
probe m8-ask-tool-refusal drop "${common[@]}" --output json -p "Use your bash tool to run the command: echo hi. Then report exactly what it printed."
probe m9-whoami drop "${common[@]}" --output json -p "/whoami"
probe m10-ask-write drop "${common[@]}" --output json -p "Use your bash tool to run exactly this command: touch probe-created.txt && chmod 600 probe-created.txt. Then report what happened."
probe m11-disabled-bash drop "${common[@]}" --disabled-tools file_system.bash --output json -p "Use your bash tool to run exactly this command: touch probe-created.txt. Then report what happened."

cat "$summary"
