#!/usr/bin/env bash
set -euo pipefail
workspace="$1"
region="$(sed -n 's/^region = "\([^"]*\)"$/\1/p' "${workspace}/service.toml")"
[[ -n "${region}" ]]
printf 'Live probe: service.toml currently says region=%s. This live file overrides recalled region.' "${region}"
