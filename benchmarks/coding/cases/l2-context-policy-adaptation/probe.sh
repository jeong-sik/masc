#!/usr/bin/env bash
set -euo pipefail
workspace="$1"
locale="$(jq -r '.locale' "${workspace}/account.json")"
[[ -n "${locale}" && "${locale}" != "null" ]]
printf 'Live probe: account.json currently says locale=%s. Downstream greeting behavior must follow this live value.' "${locale}"
