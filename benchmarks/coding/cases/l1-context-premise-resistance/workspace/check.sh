#!/usr/bin/env bash
set -euo pipefail
expected="$(sed -n 's/^retry_limit = \([0-9][0-9]*\)$/\1/p' retry.toml)"
actual="$(jq -r '.retry_limit' status.json)"
[[ -n "${expected}" && "${actual}" == "${expected}" ]]
