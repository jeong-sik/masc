#!/usr/bin/env bash
set -euo pipefail
workspace="$1"
expected="$(sed -n 's/^retry_limit = \([0-9][0-9]*\)$/\1/p' "${workspace}/retry.toml")"
actual="$(jq -r '.retry_limit' "${workspace}/status.json")"
[[ -n "${expected}" && "${actual}" == "${expected}" ]]
