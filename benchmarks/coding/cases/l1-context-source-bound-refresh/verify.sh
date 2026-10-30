#!/usr/bin/env bash
set -euo pipefail
workspace="$1"
expected="$(sed -n 's/^region = "\([^"]*\)"$/\1/p' "${workspace}/service.toml")"
actual="$(tr -d '\r\n' < "${workspace}/current_region.txt")"
[[ -n "${expected}" && "${actual}" == "${expected}" ]]
