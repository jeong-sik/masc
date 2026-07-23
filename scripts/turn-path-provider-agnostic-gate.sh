#!/usr/bin/env bash
# Keeper turn-path provider-agnostic gate.
#
# Rule: no provider or vendor name may appear in the keeper turn path.
# The turn path decides what to send and how to recover; it must reach that
# decision from typed values and spec numbers (max_context, budgets, typed
# capability records), never from which vendor is on the other end.
#
# Background: the 2026-07-22 adversarial audit (masc#25550) applied one
# question to every turn step — does this step need to know provider IDENTITY,
# or does a spec number suffice? Every accusation against the masc turn path
# was refuted: the path was already agnostic, and all identity reads lived at
# the OAS serialization boundary, where they belong. That result is a property
# worth keeping, not a snapshot. Serialization needs identity; deciding a turn
# does not, and a single vendor branch here is how that separation erodes.
#
# The gate is deliberately a substring check rather than a typed-variant check.
# A typed `Provider_config.Glm` match in this layer is exactly as much of a
# violation as a "glm" string, and both carry the vendor name.
#
# Usage:
#   scripts/turn-path-provider-agnostic-gate.sh              # check
#   scripts/turn-path-provider-agnostic-gate.sh --self-test  # prove non-vacuous
#
# Exit codes:
#   0  no vendor name in the turn path (or self-test passed)
#   1  one or more hits (file:line printed for each), or self-test failed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Vendor and provider names. Extend when a provider joins the roster — the
# point is the name, not the spelling of any one vendor.
#
# Known limitation: this is a plain substring scan, so it reads comments as
# well as code. That is mostly wanted — a comment naming a vendor in the turn
# path usually marks logic nearby that depends on one. It also means the
# pattern cannot include a name that appears in existing prose without the
# gate failing on documentation. "claude" and "gpt-" are left out for exactly
# that reason: keeper_agent_run.ml carries a comment about a past pricing
# default that names them. If either ever appears in turn-path *logic*, the
# typed-capability rule still applies, but this gate will not be what catches
# it.
VENDOR_PATTERN='glm|deepseek|kimi|anthropic|openai|gemini|ollama|minimax|mimo|qwen|dashscope|zai'

# Turn-path surface. Globs, not a fixed file list, so a new file that joins the
# turn path is covered the moment it is named like its siblings.
TURN_PATH_GLOBS=(
  'keeper_agent_run*.ml'
  'keeper_run_prompt*.ml'
  'keeper_run_context*.ml'
  'keeper_unified_turn*.ml'
  'keeper_turn_*.ml'
  'keeper_post_turn*.ml'
)

collect_files() {
  local root="$1"
  local glob
  for glob in "${TURN_PATH_GLOBS[@]}"; do
    find "${root}/lib/keeper" -maxdepth 1 -name "${glob}" -type f 2>/dev/null || true
  done
}

# bash 3.2 (the macOS default) has no `mapfile`, so the file list travels as a
# NUL-delimited stream rather than an array.
scan() {
  local root="$1"
  local list
  list="$(collect_files "${root}" | sort -u)"
  if [ -z "${list}" ]; then
    echo "turn-path gate: no turn-path files found under ${root}/lib/keeper" >&2
    echo "the globs no longer match anything, so the gate would pass vacuously" >&2
    return 2
  fi
  printf '%s\n' "${list}" \
    | tr '\n' '\0' \
    | xargs -0 rg --ignore-case --line-number --with-filename "${VENDOR_PATTERN}" 2>/dev/null \
    || true
}

self_test() {
  # A gate that cannot fail is worth nothing. Plant a violation in a scratch
  # copy of the surface and require the scan to report it.
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "${tmp}/lib/keeper"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks are
  # OCaml polymorphic-variant syntax and must reach the file literally.
  printf 'let route ~kind = match kind with Glm -> `Special | _ -> `Normal\n' \
    >"${tmp}/lib/keeper/keeper_turn_selftest_fixture.ml"

  local planted
  planted="$(scan "${tmp}")"
  if [ -z "${planted}" ]; then
    rm -rf "${tmp}"
    echo "turn-path gate self-test FAILED: planted violation was not detected" >&2
    return 1
  fi

  # shellcheck disable=SC2016  # same: literal OCaml, no shell expansion wanted.
  printf 'let route ~budget = if budget > 0 then `Normal else `Degrade\n' \
    >"${tmp}/lib/keeper/keeper_turn_selftest_fixture.ml"
  local clean
  clean="$(scan "${tmp}")"
  rm -rf "${tmp}"
  if [ -n "${clean}" ]; then
    echo "turn-path gate self-test FAILED: clean fixture reported a hit:" >&2
    echo "${clean}" >&2
    return 1
  fi

  echo "turn-path gate self-test passed (detects a planted vendor branch, ignores a clean one)"
  return 0
}

main() {
  if [ "${1:-}" = "--self-test" ]; then
    self_test
    return $?
  fi

  local hits
  hits="$(scan "${REPO_ROOT}")"

  if [ -n "${hits}" ]; then
    echo "turn-path provider-agnostic gate: vendor name in the keeper turn path" >&2
    echo "${hits}" >&2
    echo >&2
    echo "The turn path decides a turn from typed values and spec numbers." >&2
    echo "If this step genuinely needs a per-provider fact, express it as a typed" >&2
    echo "capability the provider config carries, and read that instead." >&2
    echo "Serialization may know the vendor; deciding a turn may not." >&2
    return 1
  fi

  local count
  count="$(collect_files "${REPO_ROOT}" | sort -u | wc -l | tr -d ' ')"
  echo "turn-path provider-agnostic gate: clean (${count} files scanned)"
  return 0
}

main "$@"
