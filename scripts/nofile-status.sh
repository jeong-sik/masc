#!/usr/bin/env bash
set -euo pipefail

kill_bare_dune="${MASC_NOFILE_KILL_BARE_DUNE:-0}"
kill_repo_scans="${MASC_NOFILE_KILL_REPO_SCANS:-0}"
watch_mode=0
watch_interval="${MASC_NOFILE_WATCH_INTERVAL:-5}"

usage() {
  cat <<'USAGE'
Usage: scripts/nofile-status.sh [options]

Options:
  --kill-bare-dune    SIGTERM unwrapped Dune processes reported as bypasses.
  --kill-repo-scans   SIGTERM broad find/bfs scans over ~/me or masc-mcp.
  --kill-risky        Enable both kill options above.
  --watch [seconds]   Repeat until interrupted. Defaults to 5 seconds.
  --once              Run one snapshot even when invoked from watch mode.
  -h, --help          Show this help.

Environment:
  MASC_NOFILE_KILL_BARE_DUNE=1
  MASC_NOFILE_KILL_REPO_SCANS=1
  MASC_NOFILE_WATCH_INTERVAL=5
  MASC_NOFILE_COMMAND_MAX=240
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kill-bare-dune)
      kill_bare_dune=1
      ;;
    --kill-repo-scans)
      kill_repo_scans=1
      ;;
    --kill-risky)
      kill_bare_dune=1
      kill_repo_scans=1
      ;;
    --watch)
      watch_mode=1
      if [[ "${2:-}" =~ ^[0-9]+$ ]]; then
        watch_interval="$2"
        shift
      fi
      ;;
    --once)
      watch_mode=0
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      printf 'nofile-status: unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

if [[ "${watch_mode}" -eq 1 ]]; then
  if [[ ! "${watch_interval}" =~ ^[1-9][0-9]*$ ]]; then
    printf 'nofile-status: --watch interval must be a positive integer, got %q\n' \
      "${watch_interval}" >&2
    exit 2
  fi
  while true; do
    printf '\n# nofile-status %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    MASC_NOFILE_KILL_BARE_DUNE="${kill_bare_dune}" \
      MASC_NOFILE_KILL_REPO_SCANS="${kill_repo_scans}" \
      MASC_NOFILE_WATCH_INTERVAL="${watch_interval}" \
      "$0" --once
    sleep "${watch_interval}"
  done
fi

printf 'soft open files: %s\n' "$(ulimit -n 2>/dev/null || printf '?')"

truncate_rows() {
  local max="${MASC_NOFILE_COMMAND_MAX:-240}"
  awk -v max="${max}" '{
    if (max > 0 && length($0) > max) {
      print substr($0, 1, max) "..."
    } else {
      print
    }
  }'
}

bool_enabled() {
  case "${1:-0}" in
    1 | true | TRUE | yes | YES | on | ON)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

terminate_rows() {
  local label="$1"
  local rows="$2"
  local enabled="$3"
  local pids

  if [[ -z "${rows}" ]] || ! bool_enabled "${enabled}"; then
    return
  fi

  pids="$(
    printf '%s\n' "${rows}" \
      | awk '$1 ~ /^[0-9]+$/ {print $1}' \
      | sort -n \
      | tr '\n' ' '
  )"
  if [[ -z "${pids// }" ]]; then
    return
  fi

  printf '%s remediation: SIGTERM pid(s): %s\n' "${label}" "${pids}"
  for pid in ${pids}; do
    kill "${pid}" 2>/dev/null || true
  done
}

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
          ps -p "${pid}" -o pid=,ppid=,stat=,etime=,command= 2>/dev/null \
            | truncate_rows || true
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
if [[ "${ps_available}" -eq 1 ]]; then
  dune_rows="$(
    ps ax -o pid=,ppid=,stat=,etime=,command= 2>/dev/null \
      | awk '
          /dune-local[.]sh/ ||
          /me-dune-local[.]lock/ ||
          /(^|[[:space:]\/])dune([[:space:]]|$)/ ||
          /(^|[[:space:]\/])opam[[:space:]]+exec[[:space:]].*([[:space:]\/])dune([[:space:]]|$)/ {
            print
          }' || true
  )"
  if [[ -n "${dune_rows}" ]]; then
    printf '%s\n' "${dune_rows}" | truncate_rows
  else
    printf 'none\n'
  fi
else
  printf 'dune/local-build processes: unavailable (pgrep and ps failed)\n'
fi

printf 'orphaned dune-local lock waiters:\n'
if [[ "${ps_available}" -eq 1 ]]; then
  orphan_waiters="$(
    ps ax -o pid=,ppid=,stat=,etime=,command= 2>/dev/null \
      | awk '
          $2 == 1 &&
          /dune-local[.]sh/ &&
          /me-dune-local[.]lock/ &&
          /(^|[[:space:]\/])(lockf|flock)([[:space:]]|$)/ {
            print
          }' || true
  )"
  if [[ -n "${orphan_waiters}" ]]; then
    printf '%s\n' "${orphan_waiters}" | truncate_rows
  else
    printf 'none\n'
  fi
else
  printf 'orphaned dune-local lock waiters: unavailable (ps failed)\n'
fi

printf 'repo-wide scan processes:\n'
if [[ "${ps_available}" -eq 1 ]]; then
  scan_rows="$(
    ps ax -o pid=,ppid=,stat=,etime=,command= 2>/dev/null \
      | awk '
          /(^|[[:space:]])(bfs|find)[[:space:]]/ &&
          (/\/Users\/dancer([[:space:]]|\/|$)/ ||
           /\/Users\/dancer\/me([[:space:]]|\/|$)/ ||
           /masc-mcp/ ||
           /~\/me/ ||
           /[[:space:]]~([[:space:]]|\/|$)/) {
            print
          }' || true
  )"
  if [[ -n "${scan_rows}" ]]; then
    printf '%s\n' "${scan_rows}" | truncate_rows
    terminate_rows "repo-wide scan processes" "${scan_rows}" "${kill_repo_scans}"
  else
    printf 'none\n'
  fi
else
  printf 'repo-wide scan processes: unavailable (ps failed)\n'
fi

printf 'potential bare dune bypasses:\n'
if [[ "${ps_available}" -eq 1 ]]; then
  bare_dune_rows="$(
    ps ax -o pid=,ppid=,stat=,etime=,command= 2>/dev/null \
      | awk '
          /^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+/ {
            pid = $1
            ppid = $2
            stat = $3
            etime = $4
            $1 = ""
            $2 = ""
            $3 = ""
            $4 = ""
            sub(/^[[:space:]]+/, "", $0)
            parent[pid] = ppid
            state[pid] = stat
            elapsed[pid] = etime
            cmd[pid] = $0
          }

          function has_wrapper_ancestor(pid, cur, depth) {
            cur = pid
            depth = 0
            while ((cur in cmd) && depth < 64) {
              if (cmd[cur] ~ /dune-local[.]sh/ ||
                  cmd[cur] ~ /me-dune-local[.]lock/ ||
                  cmd[cur] ~ /MASC_DUNE_LOCK_HELD=1/) {
                return 1
              }
              cur = parent[cur]
              depth++
            }
            return 0
          }

          function basename(token, parts, n) {
            n = split(token, parts, "/")
            return parts[n]
          }

          function is_dune_subcommand(token) {
            return token == "build" || token == "test" || token == "exec" || token == "runtest" || token == "clean"
          }

          function is_dune_option(token) {
            return token ~ /^--[[:alnum:]][[:alnum:]_-]*(=.*)?$/ ||
                   token ~ /^-[[:alnum:]][[:alnum:]_-]*$/
          }

          function dune_subcommand_index(argc, argv, dune_index, i, token) {
            i = dune_index + 1
            while (i <= argc) {
              token = argv[i]
              if (is_dune_subcommand(token)) {
                return i
              } else if (token ~ /^--[[:alnum:]][[:alnum:]_-]*=/) {
                i++
              } else if (is_dune_option(token) && i + 1 <= argc && !is_dune_subcommand(argv[i + 1]) && argv[i + 1] !~ /^-/) {
                i += 2
              } else if (is_dune_option(token)) {
                i++
              } else {
                return 0
              }
            }
            return 0
          }

          function is_dune_command(text, argv, argc, i) {
            argc = split(text, argv, /[[:space:]]+/)
            if (argc < 2) {
              return 0
            }
            if (basename(argv[1]) == "dune") {
              return dune_subcommand_index(argc, argv, 1) > 0
            }
            if (basename(argv[1]) == "opam" && argv[2] == "exec") {
              for (i = 3; i <= argc; i++) {
                if (basename(argv[i]) == "dune") {
                  return dune_subcommand_index(argc, argv, i) > 0
                }
              }
            }
            return 0
          }

          END {
            for (pid in cmd) {
              if (is_dune_command(cmd[pid]) && !has_wrapper_ancestor(pid)) {
                printf "%s %s %s %s %s\n", pid, parent[pid], state[pid], elapsed[pid], cmd[pid]
              }
            }
          }' || true
  )"
  if [[ -n "${bare_dune_rows}" ]]; then
    printf '%s\n' "${bare_dune_rows}" | truncate_rows
    terminate_rows "potential bare dune bypasses" "${bare_dune_rows}" \
      "${kill_bare_dune}"
  else
    printf 'none\n'
  fi
else
  printf 'potential bare dune bypasses: unavailable (ps failed)\n'
fi

printf 'docker playground hotspot:\n'
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
docker_status_script="${script_dir}/docker-playground-fd-status.sh"
docker_root="${MASC_DOCKER_PLAYGROUND_ROOT:-}"
if [[ -z "${docker_root}" && -n "${MASC_BASE_PATH:-}" ]]; then
  docker_root="${MASC_BASE_PATH%/}/.masc/playground/docker"
fi
if [[ -z "${docker_root}" && -d "$(pwd)/.masc/playground/docker" ]]; then
  docker_root="$(pwd)/.masc/playground/docker"
fi

if [[ -z "${docker_root}" ]]; then
  printf 'docker playground hotspot: skipped (set MASC_BASE_PATH or MASC_DOCKER_PLAYGROUND_ROOT)\n'
elif [[ ! -d "${docker_root}" ]]; then
  printf 'docker playground hotspot: skipped (root missing: %s)\n' "${docker_root}"
elif [[ -x "${docker_status_script}" ]]; then
  "${docker_status_script}" --root "${docker_root}" --limit 5 || true
else
  printf 'docker playground hotspot: unavailable (%s missing or not executable)\n' "${docker_status_script}"
fi
