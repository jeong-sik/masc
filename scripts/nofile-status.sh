#!/usr/bin/env bash
set -euo pipefail

printf 'soft open files: %s\n' "$(ulimit -n 2>/dev/null || printf '?')"

if command -v launchctl >/dev/null 2>&1; then
  printf 'launchctl maxfiles: '
  launchctl limit maxfiles 2>/dev/null | awk 'NR == 1 {print $2, $3}' || true
fi

sysctl_cmd=""
if command -v sysctl >/dev/null 2>&1; then
  sysctl_cmd="$(command -v sysctl)"
elif [[ -x /usr/sbin/sysctl ]]; then
  sysctl_cmd="/usr/sbin/sysctl"
fi
if [[ -n "${sysctl_cmd}" ]]; then
  if sysctl_out="$("${sysctl_cmd}" kern.num_files kern.maxfiles kern.maxfilesperproc 2>/dev/null)"; then
    printf '%s\n' "${sysctl_out}"
  else
    printf 'sysctl kern.num_files/kern.maxfiles: unavailable\n'
  fi
fi

ps_available=0
if ps -p "$$" -o pid= >/dev/null 2>&1; then
  ps_available=1
fi

if command -v lsof >/dev/null 2>&1; then
  tmp_lsof="$(mktemp "${TMPDIR:-/tmp}/masc-nofile-lsof.XXXXXX")"
  if lsof -nP >"${tmp_lsof}" 2>/dev/null; then
    total_rows="$(wc -l <"${tmp_lsof}" | tr -d ' ')"
    printf 'total lsof rows: %s\n' "${total_rows}"
    printf 'top fd holders:\n'
    awk 'NR > 1 {count[$2]++; name[$2]=$1} END {for (pid in count) print count[pid], pid, name[pid]}' \
      "${tmp_lsof}" \
      | sort -nr \
      | head -20
    if [[ "${ps_available}" -eq 1 ]]; then
      printf 'top fd holder commands:\n'
      awk 'NR > 1 {count[$2]++} END {for (pid in count) print count[pid], pid}' "${tmp_lsof}" \
        | sort -nr \
        | head -10 \
        | while read -r _count pid; do
          ps -p "${pid}" -o pid=,ppid=,stat=,etime=,command= 2>/dev/null || true
        done
    else
      printf 'top fd holder commands: unavailable (ps failed)\n'
    fi
  else
    printf 'total lsof rows: unavailable (lsof failed)\n'
  fi
  rm -f "${tmp_lsof}"
else
  printf 'total lsof rows: unavailable (lsof missing)\n'
fi

printf 'dune/local-build processes:\n'
if command -v pgrep >/dev/null 2>&1; then
  if ! pgrep -fl 'dune build|dune test|dune exec|dune-local.sh|me-dune-local.lock'; then
    if [[ "${ps_available}" -eq 1 ]]; then
      ps ax -o pid=,command= 2>/dev/null \
        | grep -E 'dune build|dune test|dune exec|dune-local.sh|me-dune-local.lock' \
        | grep -v grep || true
    else
      printf 'dune/local-build processes: unavailable (pgrep and ps failed)\n'
    fi
  fi
elif [[ "${ps_available}" -eq 1 ]]; then
  ps ax -o pid=,command= 2>/dev/null \
    | grep -E 'dune build|dune test|dune exec|dune-local.sh|me-dune-local.lock' \
    | grep -v grep || true
else
  printf 'dune/local-build processes: unavailable (pgrep and ps failed)\n'
fi

printf 'repo-wide scan processes:\n'
if [[ "${ps_available}" -eq 1 ]]; then
  ps ax -o pid=,ppid=,stat=,etime=,command= 2>/dev/null \
    | awk '
        /(^|[[:space:]])(bfs|find)[[:space:]]/ &&
        /masc-mcp/ &&
        /-exec/ {
          print
        }' || true
else
  printf 'repo-wide scan processes: unavailable (ps failed)\n'
fi

printf 'potential bare dune bypasses:\n'
if [[ "${ps_available}" -eq 1 ]]; then
  ps ax -o pid=,ppid=,stat=,etime=,command= 2>/dev/null \
    | awk '
        /dune (build|test|exec)/ &&
        $0 !~ /dune-local\.sh/ &&
        $0 !~ /me-dune-local\.lock/ &&
        $0 !~ /MASC_DUNE_LOCK_HELD=1/ {
          print
        }' || true
else
  printf 'potential bare dune bypasses: unavailable (ps failed)\n'
fi
