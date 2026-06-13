#!/usr/bin/env bash
set -euo pipefail

declare -a pin_args=()
if [ -n "${PIN_FLAGS:-}" ]; then
  read -r -a pin_args <<< "${PIN_FLAGS}"
fi

install_pinned="${PIN_INSTALL:-true}"
if [ "${install_pinned}" = "true" ]; then
  has_install=false
  for arg in "${pin_args[@]}"; do
    if [ "${arg}" = "--install" ]; then
      has_install=true
      break
    fi
  done
  if [ "${has_install}" = "false" ]; then
    pin_args+=(--install)
  fi
fi

scripts/opam-pin-external-deps.sh "${pin_args[@]}"
