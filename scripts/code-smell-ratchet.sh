#!/usr/bin/env bash
# Backward-compatible entrypoint for the RFC-0151 code-smell ratchet.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/code-smell/measure.sh" "$@"
