#!/usr/bin/env bash
set -euo pipefail
workspace="$1"
retry_limit="$(sed -n 's/^retry_limit = \([0-9][0-9]*\)$/\1/p' "${workspace}/retry.toml")"
[[ -n "${retry_limit}" ]]
printf 'Live probe: retry.toml currently says retry_limit=%s. This live file overrides recalled and requested values.' "${retry_limit}"
