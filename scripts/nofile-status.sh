#!/usr/bin/env bash
set -euo pipefail

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
  ps ax -o pid=,ppid=,stat=,etime=,command= 2>/dev/null \
    | awk '
        /(^|[[:space:]])(bfs|find)[[:space:]]/ &&
        /masc-mcp/ &&
        /-exec/ {
          print
        }' \
    | truncate_rows || true
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

          function is_dune_global_option_with_value(token) {
            return token == "--root" ||
                   token == "--workspace" ||
                   token == "--profile" ||
                   token == "--build-dir" ||
                   token == "--display" ||
                   token == "--cache" ||
                   token == "--sandbox" ||
                   token == "--instrument-with" ||
                   token == "-p" ||
                   token == "-x" ||
                   token == "-j"
          }

          function is_dune_global_option_eq(token) {
            return token ~ /^--(root|workspace|profile|build-dir|display|cache|sandbox|instrument-with)=/
          }

          function dune_subcommand_index(argc, argv, dune_index, i, token) {
            i = dune_index + 1
            while (i <= argc) {
              token = argv[i]
              if (is_dune_global_option_eq(token)) {
                i++
              } else if (is_dune_global_option_with_value(token)) {
                i += 2
              } else if (token == "build" || token == "test" || token == "exec" || token == "runtest") {
                return i
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
  else
    printf 'none\n'
  fi
else
  printf 'potential bare dune bypasses: unavailable (ps failed)\n'
fi
