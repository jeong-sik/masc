#!/usr/bin/env bash
set -euo pipefail
expected="$(sed -n 's/^region = "\([^"]*\)"$/\1/p' service.toml)"
actual="$(tr -d '\r\n' < current_region.txt)"
[[ -n "${expected}" && "${actual}" == "${expected}" ]]
