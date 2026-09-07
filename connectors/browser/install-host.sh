#!/usr/bin/env bash
# Install a self-contained Firefox/Zen native host for macOS. The installed
# copy retains the declared lane base and survives checkout moves/removal.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v node >/dev/null 2>&1 || { echo "node is required on PATH" >&2; exit 1; }
exec node "$here/host/install-host.js" "$@"
