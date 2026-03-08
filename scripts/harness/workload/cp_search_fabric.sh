#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

exec dune exec --root "${REPO_ROOT}" ./test/test_cp_search_fabric_benchmark.exe "$@"
