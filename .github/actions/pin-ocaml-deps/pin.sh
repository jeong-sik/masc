#!/usr/bin/env bash
set -euo pipefail

declare -a pin_args=()
if [ -n "${PIN_FLAGS:-}" ]; then
  read -r -a pin_args <<< "${PIN_FLAGS}"
fi

scripts/opam-pin-external-deps.sh "${pin_args[@]}"
