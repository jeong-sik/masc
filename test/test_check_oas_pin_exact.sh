#!/usr/bin/env bash
# Regression test: a descendant agent_sdk commit is not necessarily API-compatible.
# The local preflight must require the repository's exact SSOT pin before Dune.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

test_root="$(mktemp -d -t check-oas-pin-exact.XXXXXX)"
trap 'rm -rf "${test_root}"' EXIT
mkdir -p "${test_root}/bin"

cat >"${test_root}/bin/opam" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  env)
    ;;
  list)
    printf '%s\n' 'agent_sdk 0.231.11'
    ;;
  show)
    printf '%s\n' '0.231.11'
    ;;
  pin)
    printf '%s\n' 'agent_sdk.0.231.11 git git+https://github.com/jeong-sik/oas.git (at ffffffffffffffffffffffffffffffffffffffff)'
    ;;
  *)
    exit 2
    ;;
esac
EOF
chmod +x "${test_root}/bin/opam"

set +e
output="$(PATH="${test_root}/bin:${PATH}" \
  bash "${REPO_ROOT}/scripts/check-oas-pin.sh" --local-only 2>&1)"
status=$?
set -e

if [[ ${status} -eq 0 ]]; then
  echo "FAIL: mismatched descendant pin was accepted" >&2
  exit 1
fi
if [[ "${output}" != *"agent_sdk pin checkout is ffffffffffffffffffffffffffffffffffffffff, expected"* ]]; then
  echo "FAIL: exact-pin rejection diagnostic missing" >&2
  printf '%s\n' "${output}" >&2
  exit 1
fi
if [[ "${output}" == *"accepting"* ]]; then
  echo "FAIL: forward-drift acceptance path is still reachable" >&2
  exit 1
fi

echo "[check-oas-pin-exact test] PASS"
