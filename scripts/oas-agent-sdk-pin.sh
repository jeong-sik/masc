#!/usr/bin/env bash

readonly OAS_AGENT_SDK_URL="https://github.com/jeong-sik/oas.git"
readonly OAS_AGENT_SDK_BASE_VERSION="v0.208.12"
# 0.208.12 is a tagged release on OAS main (commit below). It includes the
# default-unbounded agent turn budget release from oas#2423, so MASC inherits
# OAS's 0-as-unbounded max_turns contract instead of the older finite default.
# The reachability guard in check-oas-pin.sh tracks main.
readonly OAS_AGENT_SDK_TRACK_REF="main"
readonly OAS_AGENT_SDK_SHA="2f3d6846dde653ec7861a367f5b9ed5c6cae2314"
readonly OAS_AGENT_SDK_MIN_VERSION="0.208.12"
