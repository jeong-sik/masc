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
# tests/test_driver_scripts.py compares this list with those sources.
BENCH_ENV_FILE_REFUSED_NAMES=(
  PATH
  GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN
  GH_CONFIG_DIR GIT_TERMINAL_PROMPT
)

# <NUL-separated environ file>: NAME=VALUE lines on stdout.
bench_endpoint_env_lines() {
  local environ="$1" entry name value refused written=":" newline=$'\n' cr=$'\r'
  while IFS= read -r -d '' entry; do
    [[ "${entry}" == *=* ]] || continue
    name="${entry%%=*}"
    value="${entry#*=}"
    if [[ ! "${name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      echo "[bootstrap] env_file: left out an entry whose name is not an environment variable name" >&2
      continue
    fi
    for refused in "${BENCH_ENV_FILE_REFUSED_NAMES[@]}"; do
      if [[ "${name}" == "${refused}" ]]; then
        echo "[bootstrap] env_file: left out ${name}, which the shim refuses" >&2
        continue 2
      fi
    done
    if [[ "${value}" == *"${newline}"* || "${value}" == *"${cr}" ]]; then
      echo "[bootstrap] env_file: left out ${name}, whose value is not one line" >&2
      continue
    fi
    if [[ "${written}" == *":${name}:"* ]]; then
      echo "[bootstrap] env_file: left out a second ${name}" >&2
      continue
    fi
    written="${written}${name}:"
    printf '%s=%s\n' "${name}" "${value}"
  done < "${environ}"
}
