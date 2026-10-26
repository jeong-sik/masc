#!/usr/bin/env bash
# Run every add-on test file in its own Python process.
#
# Each add-on worker is a top-level server.py that runs alone in its own
# container, and its tests import it by that name. A single interpreter for all
# files keeps whichever server module it imported first in sys.modules, so a
# later file reads another add-on's worker (#45181, #45465). One process per
# file gives each file the import state its add-on has in production.
#
# Usage: scripts/ci/addon-tests-each-file.sh [unittest options, e.g. -v]
set -euo pipefail
cd "$(dirname "$0")/../.."

failed=()
for file in addons/tests/test_*.py; do
  name=$(basename "$file")
  python3 -m unittest discover -s addons/tests -p "$name" "$@" || failed+=("$name")
done

if [ "${#failed[@]}" -gt 0 ]; then
  printf 'add-on test files failed: %s\n' "${failed[*]}" >&2
  exit 1
fi
