#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ACTION_PATH="${REPO_ROOT}/.github/actions/setup-ocaml-toolchain/action.yml"

fail() {
  printf '[opam-cache-freshness] %s\n' "$*" >&2
  return 1
}

require_once() {
  local needle="$1"
  local target="$2"
  local count
  count="$(grep -F -c -- "${needle}" "${target}" || true)"
  [[ "${count}" -eq 1 ]] \
    || fail "expected exactly one ${needle@Q} in ${target}, found ${count}"
}

refresh_repository() {
  local exact_cache_hit="$1"
  case "${exact_cache_hit}" in
    true)
      echo "[opam-cache-freshness] exact dependency cache hit; repository refresh skipped"
      ;;
    false|"")
      echo "[opam-cache-freshness] fallback or empty dependency cache; refreshing repositories"
      opam update --repositories
      ;;
    *)
      printf '[opam-cache-freshness] invalid cache-hit value: %q\n' \
        "${exact_cache_hit}" >&2
      return 2
      ;;
  esac
}

check_wiring() {
  require_once "id: opam-toolchain-cache" "${ACTION_PATH}"
  require_once "scripts/opam-pin-external-deps.sh" "${ACTION_PATH}"
  require_once \
    'OPAM_CACHE_EXACT_HIT: ${{ steps.opam-toolchain-cache.outputs.cache-hit }}' \
    "${ACTION_PATH}"
  require_once \
    'bash scripts/ci/opam-cache-freshness.sh \' \
    "${ACTION_PATH}"
  require_once \
    '--refresh "${OPAM_CACHE_EXACT_HIT:-}"' \
    "${ACTION_PATH}"

  local branch_line refresh_line exit_line
  branch_line="$(
    grep -nF 'if opam switch list --short' "${ACTION_PATH}" \
      | cut -d: -f1
  )"
  refresh_line="$(
    grep -nF 'bash scripts/ci/opam-cache-freshness.sh' "${ACTION_PATH}" \
      | cut -d: -f1
  )"
  exit_line="$(
    awk -v start="${branch_line}" \
      'NR > start && /exit 0/ { print NR; exit }' \
      "${ACTION_PATH}"
  )"
  [[ -n "${branch_line}" && -n "${refresh_line}" && -n "${exit_line}" ]] \
    || fail "cache-hit refresh ordering anchors are incomplete"
  [[ "${branch_line}" -lt "${refresh_line}" && "${refresh_line}" -lt "${exit_line}" ]] \
    || fail "fallback-cache repository refresh must run before cache-hit exit"

  echo "[opam-cache-freshness] wiring OK"
}

self_test() {
  local fixture fake_bin log status
  fixture="$(mktemp -d "${TMPDIR:-/tmp}/opam-cache-freshness.XXXXXX")"
  trap 'rm -rf "${fixture}"' RETURN
  fake_bin="${fixture}/bin"
  log="${fixture}/opam.log"
  mkdir -p "${fake_bin}"
  cat >"${fake_bin}/opam" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${OPAM_FRESHNESS_TEST_LOG}"
exit "${OPAM_FRESHNESS_TEST_STATUS:-0}"
EOF
  chmod +x "${fake_bin}/opam"

  : >"${log}"
  PATH="${fake_bin}:${PATH}" OPAM_FRESHNESS_TEST_LOG="${log}" \
    "${SCRIPT_PATH}" --refresh true >/dev/null
  [[ ! -s "${log}" ]] \
    || fail "exact cache hit unexpectedly refreshed opam repositories"

  : >"${log}"
  PATH="${fake_bin}:${PATH}" OPAM_FRESHNESS_TEST_LOG="${log}" \
    "${SCRIPT_PATH}" --refresh false >/dev/null
  [[ "$(cat "${log}")" == "update --repositories" ]] \
    || fail "fallback cache did not refresh opam repositories exactly once"

  : >"${log}"
  PATH="${fake_bin}:${PATH}" OPAM_FRESHNESS_TEST_LOG="${log}" \
    "${SCRIPT_PATH}" --refresh "" >/dev/null
  [[ "$(cat "${log}")" == "update --repositories" ]] \
    || fail "empty cache did not refresh opam repositories exactly once"

  : >"${log}"
  set +e
  PATH="${fake_bin}:${PATH}" \
    OPAM_FRESHNESS_TEST_LOG="${log}" \
    OPAM_FRESHNESS_TEST_STATUS=17 \
    "${SCRIPT_PATH}" --refresh false >/dev/null 2>&1
  status=$?
  set -e
  [[ "${status}" -eq 17 ]] \
    || fail "repository refresh failure was not propagated (status=${status})"
  [[ "$(cat "${log}")" == "update --repositories" ]] \
    || fail "failed repository refresh did not invoke the canonical update"

  echo "[opam-cache-freshness:self-test] pass"
}

case "${1:-}" in
  --refresh)
    [[ "$#" -eq 2 ]] || {
      echo "usage: $0 --refresh <true|false|empty>" >&2
      exit 2
    }
    refresh_repository "$2"
    ;;
  --check)
    [[ "$#" -eq 1 ]] || {
      echo "usage: $0 --check" >&2
      exit 2
    }
    check_wiring
    ;;
  --self-test)
    [[ "$#" -eq 1 ]] || {
      echo "usage: $0 --self-test" >&2
      exit 2
    }
    self_test
    ;;
  *)
    echo "usage: $0 <--refresh value|--check|--self-test>" >&2
    exit 2
    ;;
esac
