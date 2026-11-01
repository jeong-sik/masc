#!/bin/zsh
# Watches ego task spaces once a minute to catch the next agent-space death
# with its surrounding context (ego app pid, MASC ego worker pid, inventory).
# ego's console.log goes to stderr at process exit, so stderr is the pipe.
R="${MASC_EGO_PROBE_DIR:-${TMPDIR:-/tmp}/masc-ego-probe-20261030-fLER}"
EGO_BIN="${EGO_BROWSER:-ego-browser}"
mkdir -p "$R"
LOG="$R/watcher.jsonl"
while true; do
  ts=$(date -u +%FT%TZ)
  ego=$(pgrep -f "ego lite.app/Contents/MacOS" | head -1)
  worker=$(pgrep -f "masc-browser-addon-worker.*--backend ego" | head -1)
  inv=$(printf 'const n=await listTaskSpaces();console.log(JSON.stringify(n.map(s=>({i:s.id,o:s.ownership}))));' | "$EGO_BIN" nodejs 2>&1 >/dev/null | grep '^\[' | head -1)
  printf '{"ts":"%s","ego":"%s","worker":"%s","spaces":%s}\n' "$ts" "${ego:-gone}" "${worker:-gone}" "${inv:-null}" >> "$LOG"
  sleep 60
done
