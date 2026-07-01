#!/usr/bin/env bash
# monitor-system-health.sh — 60s 반복 시스템 헬스 모니터.
# 시스템 전체 FD / swap / free RAM / loadavg / disk 사용량을 측정하고
# 임계치 위반 시 macOS notification + terminal bell 을 띄운다.
# Docker playground FD hotspot 은 기존 docker-playground-fd-status.sh 를 위임 호출한다.
#
# Trigger background (default):
#   nohup scripts/monitor-system-health.sh >/dev/null 2>&1 & disown
#
# One-shot for debugging:
#   scripts/monitor-system-health.sh --once
#
# Stop:
#   pkill -f monitor-system-health.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ONCE=0
NOTIFY=1
INTERVAL="${MASC_SYSMON_INTERVAL:-60}"
LOG_DIR="${MASC_SYSMON_LOG_DIR:-$REPO_ROOT/.masc/logs}"

FD_PCT_WARN="${MASC_SYSMON_FD_PCT_WARN:-30}"
FD_PCT_CRIT="${MASC_SYSMON_FD_PCT_CRIT:-50}"
FD_PROC_WARN="${MASC_SYSMON_FD_PROC_WARN:-5000}"
FD_PROC_CRIT="${MASC_SYSMON_FD_PROC_CRIT:-15000}"
SWAP_GB_WARN="${MASC_SYSMON_SWAP_GB_WARN:-4}"
SWAP_GB_CRIT="${MASC_SYSMON_SWAP_GB_CRIT:-8}"
FREE_GB_WARN="${MASC_SYSMON_FREE_GB_WARN:-4}"
FREE_GB_CRIT="${MASC_SYSMON_FREE_GB_CRIT:-1}"
LOAD_WARN="${MASC_SYSMON_LOAD_WARN:-50}"
LOAD_CRIT="${MASC_SYSMON_LOAD_CRIT:-100}"
DISK_PCT_WARN="${MASC_SYSMON_DISK_PCT_WARN:-90}"
DISK_PCT_CRIT="${MASC_SYSMON_DISK_PCT_CRIT:-95}"
ALERT_COOLDOWN="${MASC_SYSMON_ALERT_COOLDOWN:-300}"

# Pressure flag file. masc server (future) is expected to poll this
# and engage Keeper_fd_pressure when level=CRIT. We always rewrite it
# atomically so a reader sees a consistent snapshot.
DEFAULT_MASC_BASE_PATH="${MASC_BASE_PATH:-$REPO_ROOT}"
PRESSURE_STATE_DEFAULT="$DEFAULT_MASC_BASE_PATH/.masc/masc-host-pressure.state"
PRESSURE_EVENTS_DEFAULT="$DEFAULT_MASC_BASE_PATH/.masc/masc-host-pressure.events.jsonl"
PRESSURE_STATE_FILE="${MASC_HOST_FD_PRESSURE_STATE_FILE:-${MASC_SYSMON_PRESSURE_STATE:-$PRESSURE_STATE_DEFAULT}}"
PRESSURE_EVENTS_FILE="${MASC_SYSMON_PRESSURE_EVENTS:-$PRESSURE_EVENTS_DEFAULT}"

usage() {
  cat <<'EOF'
monitor-system-health.sh - Recurring system FD/OOM/Disk monitor with macOS alerts.

Usage:
  scripts/monitor-system-health.sh [--once] [--interval SEC] [--no-notify] [--log-dir DIR]

Options:
  --once          Run a single iteration and exit (for debug/cron).
  --interval SEC  Sleep between iterations. Default: 60. Env: MASC_SYSMON_INTERVAL
  --no-notify     Skip macOS notifications (still writes log + alert log).
  --log-dir DIR   Log directory. Default: <repo>/.masc/logs. Env: MASC_SYSMON_LOG_DIR

Thresholds (env override, defaults shown):
  MASC_SYSMON_FD_PCT_WARN=30    MASC_SYSMON_FD_PCT_CRIT=50
  MASC_SYSMON_FD_PROC_WARN=5000 MASC_SYSMON_FD_PROC_CRIT=15000
  MASC_SYSMON_SWAP_GB_WARN=4    MASC_SYSMON_SWAP_GB_CRIT=8
  MASC_SYSMON_FREE_GB_WARN=4    MASC_SYSMON_FREE_GB_CRIT=1
  MASC_SYSMON_LOAD_WARN=50      MASC_SYSMON_LOAD_CRIT=100
  MASC_SYSMON_DISK_PCT_WARN=90  MASC_SYSMON_DISK_PCT_CRIT=95
  MASC_SYSMON_ALERT_COOLDOWN=300

Logs:
  <log-dir>/sysmon.log         per-iteration metrics
  <log-dir>/sysmon-alerts.log  one line per fired alert

Pressure flag (for masc server integration, future):
  <base-path>/.masc/masc-host-pressure.state
                                   latest snapshot when level != OK;
                                   removed when system is OK.
  <base-path>/.masc/masc-host-pressure.events.jsonl
                                   append-only history.
  Override state path via MASC_HOST_FD_PRESSURE_STATE_FILE.
  Override events path via MASC_SYSMON_PRESSURE_EVENTS.
  Reader contract: parse JSON line for level/kinds/summary/ts/pid.
  Server polls this file (e.g. once per second) and invokes
  Keeper_fd_pressure.engage when level=CRIT. Wiring is RFC-pending
  (Keeper subsystem RFC area).

Platform:
  macOS only (sysctl, vm_stat, osascript, lsof). On Linux this script exits early.

Related:
  scripts/docker-playground-fd-status.sh   one-shot docker FD hotspot (called on FD warn)
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --once) ONCE=1; shift;;
    --no-notify) NOTIFY=0; shift;;
    --interval) INTERVAL="$2"; shift 2;;
    --log-dir) LOG_DIR="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "unknown arg: $1" >&2; usage; exit 2;;
  esac
done

if [ "$(uname)" != "Darwin" ]; then
  echo "monitor-system-health.sh: macOS only (uname=$(uname))" >&2
  exit 0
fi

mkdir -p "$LOG_DIR"
mkdir -p "$(dirname "$PRESSURE_STATE_FILE")" "$(dirname "$PRESSURE_EVENTS_FILE")" 2>/dev/null || true
LOG="$LOG_DIR/sysmon.log"
ALERT_LOG="$LOG_DIR/sysmon-alerts.log"
COOLDOWN_DIR="${TMPDIR:-/tmp}/masc-sysmon-cooldown.$$"
mkdir -p "$COOLDOWN_DIR"
trap 'rm -rf "$COOLDOWN_DIR" 2>/dev/null; echo "$(date +%FT%T) sysmon stopped pid=$$" >> "$LOG"; exit 0' INT TERM EXIT

FD_MAX=$(sysctl -n kern.maxfiles)
FD_PER_PROC_MAX=$(sysctl -n kern.maxfilesperproc)

notify() {
  local key="$1" level="$2" title="$3" msg="$4"
  local now last=0
  now=$(date +%s)
  local f="$COOLDOWN_DIR/$key"
  [ -f "$f" ] && last=$(cat "$f" 2>/dev/null || echo 0)
  if [ $(( now - last )) -lt "$ALERT_COOLDOWN" ]; then return; fi
  echo "$now" > "$f"

  echo "$(date '+%FT%T') [$level] $title — $msg" >> "$ALERT_LOG"
  if [ "$NOTIFY" -eq 1 ]; then
    local sound="Sosumi"
    [ "$level" = "CRIT" ] && sound="Basso"
    osascript -e "display notification \"$msg\" with title \"[$level] $title\" sound name \"$sound\"" 2>/dev/null || true
    for tty in /dev/ttys*; do
      [ -w "$tty" ] && printf '\a' > "$tty" 2>/dev/null || true
    done
  fi
}

fd_top1() {
  lsof -nP 2>/dev/null \
    | awk 'NR>1 {fd[$2]++; cmd[$2]=$1} END {for (p in fd) print fd[p], cmd[p], p}' \
    | sort -rn | head -1
}

fd_top5() {
  lsof -nP 2>/dev/null \
    | awk 'NR>1 {fd[$2]++; cmd[$2]=$1} END {for (p in fd) print fd[p], cmd[p], p}' \
    | sort -rn | head -5 | awk '{printf "%s[%s]:%d ", $2, $3, $1}'
}

docker_playground_summary() {
  local helper="$REPO_ROOT/scripts/docker-playground-fd-status.sh"
  [ -x "$helper" ] || return 0
  "$helper" --limit 3 2>/dev/null | head -20 | tr '\n' ' ' || true
}

json_string_escape() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/ }
  s=${s//$'\r'/ }
  printf '%s' "$s"
}

write_pressure_state() {
  # Args: level (OK|WARN|CRIT), kinds_csv ("fd,swap,..."), summary
  local level="$1" kinds="$2" summary="$3"
  local ts=$(date '+%FT%T%z')
  local payload
  payload=$(printf '{"level":"%s","kinds":"%s","summary":"%s","ts":"%s","pid":%d}' \
            "$(json_string_escape "$level")" \
            "$(json_string_escape "$kinds")" \
            "$(json_string_escape "$summary")" \
            "$(json_string_escape "$ts")" "$$")
  if [ "$level" = "OK" ]; then
    rm -f "$PRESSURE_STATE_FILE" 2>/dev/null || true
  else
    printf '%s\n' "$payload" > "${PRESSURE_STATE_FILE}.tmp" 2>/dev/null \
      && mv -f "${PRESSURE_STATE_FILE}.tmp" "$PRESSURE_STATE_FILE" 2>/dev/null || true
  fi
  printf '%s\n' "$payload" >> "$PRESSURE_EVENTS_FILE" 2>/dev/null || true
}

iteration() {
  local ts num_files fd_pct swap_used_mb swap_gb free_pages free_gb load root_pct data_pct
  local docker_n ollama_n keeper_n
  local pressure_level="OK"
  local pressure_kinds=""
  local pressure_summary=""
  ts=$(date '+%FT%T')

  num_files=$(sysctl -n kern.num_files)
  fd_pct=$(( num_files * 100 / FD_MAX ))

  swap_used_mb=$(sysctl -n vm.swapusage | sed -nE 's/.*used = ([0-9.]+)M.*/\1/p')
  swap_gb=$(awk -v m="${swap_used_mb:-0}" 'BEGIN{printf "%d", m/1024}')

  free_pages=$(vm_stat | awk '/Pages free/ {gsub("\\.",""); print $3; exit}')
  free_gb=$(( ${free_pages:-0} * 16384 / 1024 / 1024 / 1024 ))

  load=$(sysctl -n vm.loadavg | awk '{print int($2)}')

  root_pct=$(df / | awk 'NR==2 {gsub("%",""); print $5}')
  data_pct=$(df /System/Volumes/Data 2>/dev/null | awk 'NR==2 {gsub("%",""); print $5}')

  docker_n=$({ pgrep -f 'com.docker' 2>/dev/null || true; } | wc -l | tr -d ' ')
  ollama_n=$({ pgrep -f 'ollama|llama-server' 2>/dev/null || true; } | wc -l | tr -d ' ')
  keeper_n=$({ pgrep -f 'masc|keeper' 2>/dev/null || true; } | wc -l | tr -d ' ')

  echo "$ts fd=${num_files}(${fd_pct}%) swap=${swap_gb}G free=${free_gb}G load=${load} root=${root_pct}% data=${data_pct}% docker=${docker_n} ollama=${ollama_n} keeper=${keeper_n}" >> "$LOG"

  if [ "$fd_pct" -ge "$FD_PCT_CRIT" ]; then
    notify fd_total CRIT "FD ${fd_pct}%" "${num_files}/${FD_MAX} top: $(fd_top5) | docker-playground: $(docker_playground_summary)"
    pressure_level="CRIT"; pressure_kinds="${pressure_kinds}fd_total,"
    pressure_summary="${pressure_summary}fd=${fd_pct}% "
  elif [ "$fd_pct" -ge "$FD_PCT_WARN" ]; then
    notify fd_total WARN "FD ${fd_pct}%" "${num_files}/${FD_MAX} top: $(fd_top5)"
    [ "$pressure_level" = "OK" ] && pressure_level="WARN"
    pressure_kinds="${pressure_kinds}fd_total,"
    pressure_summary="${pressure_summary}fd=${fd_pct}% "
  fi

  local top_line top_fd top_cmd top_pid
  top_line=$(fd_top1)
  top_fd=$(echo "$top_line" | awk '{print $1}')
  top_cmd=$(echo "$top_line" | awk '{print $2}')
  top_pid=$(echo "$top_line" | awk '{print $3}')
  if [ "${top_fd:-0}" -ge "$FD_PROC_CRIT" ]; then
    notify "fd_proc_${top_pid}" CRIT "FD storm ${top_cmd}" "pid=${top_pid} fds=${top_fd} (max/proc=${FD_PER_PROC_MAX})"
    pressure_level="CRIT"; pressure_kinds="${pressure_kinds}fd_proc,"
    pressure_summary="${pressure_summary}${top_cmd}[${top_pid}]=${top_fd}fds "
  elif [ "${top_fd:-0}" -ge "$FD_PROC_WARN" ]; then
    notify "fd_proc_${top_pid}" WARN "FD elevated ${top_cmd}" "pid=${top_pid} fds=${top_fd}"
    [ "$pressure_level" = "OK" ] && pressure_level="WARN"
    pressure_kinds="${pressure_kinds}fd_proc,"
    pressure_summary="${pressure_summary}${top_cmd}[${top_pid}]=${top_fd}fds "
  fi

  if [ "$swap_gb" -ge "$SWAP_GB_CRIT" ]; then
    local top_mem
    top_mem=$(ps -A -o pid,rss,comm | sort -rk2 -n | head -3 | awk '{printf "%s(%dM) ", $3, $2/1024}')
    notify swap CRIT "Swap ${swap_gb}GB" "OOM risk. top RSS: $top_mem"
    pressure_level="CRIT"; pressure_kinds="${pressure_kinds}swap,"
    pressure_summary="${pressure_summary}swap=${swap_gb}G "
  elif [ "$swap_gb" -ge "$SWAP_GB_WARN" ]; then
    notify swap WARN "Swap ${swap_gb}GB" "memory growth"
    [ "$pressure_level" = "OK" ] && pressure_level="WARN"
    pressure_kinds="${pressure_kinds}swap,"
    pressure_summary="${pressure_summary}swap=${swap_gb}G "
  fi

  if [ "$free_gb" -le "$FREE_GB_CRIT" ]; then
    notify free CRIT "Free RAM ${free_gb}GB" "imminent compressor/swap"
    pressure_level="CRIT"; pressure_kinds="${pressure_kinds}free,"
    pressure_summary="${pressure_summary}free=${free_gb}G "
  elif [ "$free_gb" -le "$FREE_GB_WARN" ]; then
    notify free WARN "Free RAM ${free_gb}GB" "memory pressure approaching"
    [ "$pressure_level" = "OK" ] && pressure_level="WARN"
    pressure_kinds="${pressure_kinds}free,"
    pressure_summary="${pressure_summary}free=${free_gb}G "
  fi

  if [ "$load" -ge "$LOAD_CRIT" ]; then
    notify load CRIT "Load avg ${load}" "system saturated"
    pressure_level="CRIT"; pressure_kinds="${pressure_kinds}load,"
    pressure_summary="${pressure_summary}load=${load} "
  elif [ "$load" -ge "$LOAD_WARN" ]; then
    notify load WARN "Load avg ${load}" "high parallelism"
    [ "$pressure_level" = "OK" ] && pressure_level="WARN"
    pressure_kinds="${pressure_kinds}load,"
    pressure_summary="${pressure_summary}load=${load} "
  fi

  if [ "${root_pct:-0}" -ge "$DISK_PCT_CRIT" ]; then
    notify disk_root CRIT "/ at ${root_pct}%" "sealed system volume full"
    pressure_level="CRIT"; pressure_kinds="${pressure_kinds}disk_root,"
    pressure_summary="${pressure_summary}/=${root_pct}% "
  elif [ "${root_pct:-0}" -ge "$DISK_PCT_WARN" ]; then
    notify disk_root WARN "/ at ${root_pct}%" ""
    [ "$pressure_level" = "OK" ] && pressure_level="WARN"
    pressure_kinds="${pressure_kinds}disk_root,"
    pressure_summary="${pressure_summary}/=${root_pct}% "
  fi
  if [ "${data_pct:-0}" -ge "$DISK_PCT_CRIT" ]; then
    notify disk_data CRIT "/Data at ${data_pct}%" "user volume nearly full"
    pressure_level="CRIT"; pressure_kinds="${pressure_kinds}disk_data,"
    pressure_summary="${pressure_summary}/Data=${data_pct}% "
  elif [ "${data_pct:-0}" -ge "$DISK_PCT_WARN" ]; then
    notify disk_data WARN "/Data at ${data_pct}%" ""
    [ "$pressure_level" = "OK" ] && pressure_level="WARN"
    pressure_kinds="${pressure_kinds}disk_data,"
    pressure_summary="${pressure_summary}/Data=${data_pct}% "
  fi

  pressure_kinds="${pressure_kinds%,}"
  write_pressure_state "$pressure_level" "$pressure_kinds" "${pressure_summary% }"
}

echo "$(date '+%FT%T') sysmon started pid=$$ FD_MAX=$FD_MAX FD_PER_PROC_MAX=$FD_PER_PROC_MAX interval=${INTERVAL}s once=${ONCE} notify=${NOTIFY}" >> "$LOG"
if [ "$ONCE" -eq 1 ]; then
  iteration
  exit 0
fi
while true; do
  iteration
  sleep "$INTERVAL"
done
