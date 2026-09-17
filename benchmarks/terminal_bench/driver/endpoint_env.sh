# shellcheck shell=bash
# The environment the task image declares, as the shim's env_file= lines.
#
# harbor's own agents run their commands with `docker exec`, which starts them
# in the image's environment. The shim builds every payload's environment
# afresh (exec_shim.mli), so without this file a keeper's commands miss the
# VIRTUAL_ENV, PYTHONPATH, LD_LIBRARY_PATH and service addresses the image
# declares (masc#36907).
#
# The source is PID 1's environment: the image's ENV as the container started
# with it. The run's API key is not there, because the agent hands it to each
# exec rather than to the container (measured 2026-09-17 on docker). The
# bootstrap's own environment is such an exec's, so it is not the source.
#
# The kernel lets a process read another's environ only as its owner or with
# CAP_SYS_PTRACE, which docker does not grant. A root exec therefore cannot read
# PID 1 of an image that runs as another user (terminal-bench/rs-archive-clone
# runs as agent, risk-scorer-replay as nobody), and setpriv takes PID 1's own
# uid and gid for the read.
#
# One line the shim will not take refuses the whole file, and with it every
# request (exec_shim.ml parse_env_file). Such entries are left out and their
# names written to stderr: PATH, which path= carries; the GitHub token names,
# which would make every keeper one GitHub login; the names the runner sets for
# each request. A value holding a newline cannot be one line, and a value ending
# in a carriage return would lose it to the shim's CRLF handling, so both are
# left out as well. A repeated name keeps its first value, as the shim refuses
# a name declared twice.

# The shim's refusals: "PATH" and Exec_ssh_protocol.github_token_env_names in
# parse_env_file, and Exec_shim.runtime_env_allowlist.
# tests/test_endpoint_env.py compares this list with those sources.
BENCH_ENV_FILE_REFUSED_NAMES=(
  PATH
  GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN
  GH_CONFIG_DIR GIT_TERMINAL_PROMPT
)

# PID 1's NUL-separated environment on stdout, read as PID 1's owner.
bench_pid1_environ() {
  setpriv --reuid "$(stat -c %u /proc/1)" --regid "$(stat -c %g /proc/1)" --clear-groups \
    cat /proc/1/environ
}

# <record file, or empty> <name> <reason>: one entry left out, named on stderr
# and, with a record file, appended to it as NAME<TAB>REASON.
bench_env_left_out() {
  echo "[bootstrap] env_file: left out ${2:-an entry} (${3})" >&2
  [[ -z "$1" ]] || printf '%s\t%s\n' "$2" "$3" >> "$1"
}

# NUL-separated environment on stdin: NAME=VALUE lines on stdout. An entry the
# input ends without a NUL is read too. What is left out is recorded in the file
# given, which collect_result.sh puts into result.json; the reasons are
# refused_by_shim, not_one_line, repeated and not_a_name (with no name, since it
# is not one).
# [record file]
bench_endpoint_env_lines() {
  local record="${1:-}" entry name value refused written=":" newline=$'\n' cr=$'\r'
  [[ -z "${record}" ]] || : > "${record}"
  while IFS= read -r -d '' entry || [[ -n "${entry}" ]]; do
    [[ "${entry}" == *=* ]] || continue
    name="${entry%%=*}"
    value="${entry#*=}"
    if [[ ! "${name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      bench_env_left_out "${record}" "" not_a_name
      continue
    fi
    for refused in "${BENCH_ENV_FILE_REFUSED_NAMES[@]}"; do
      if [[ "${name}" == "${refused}" ]]; then
        bench_env_left_out "${record}" "${name}" refused_by_shim
        continue 2
      fi
    done
    if [[ "${value}" == *"${newline}"* || "${value}" == *"${cr}" ]]; then
      bench_env_left_out "${record}" "${name}" not_one_line
      continue
    fi
    if [[ "${written}" == *":${name}:"* ]]; then
      bench_env_left_out "${record}" "${name}" repeated
      continue
    fi
    written="${written}${name}:"
    printf '%s=%s\n' "${name}" "${value}"
  done
}

# <record file>: its entries as a JSON array of {name, reason} on stdout; [] when
# the file is missing or empty. A bootstrap that never ran records nothing.
bench_env_left_out_json() {
  local record="$1"
  if [[ ! -s "${record}" ]]; then
    printf '[]\n'
    return 0
  fi
  jq -Rsc 'split("\n") | map(select(length > 0) | split("\t") | {name: .[0], reason: .[1]})' "${record}"
}
