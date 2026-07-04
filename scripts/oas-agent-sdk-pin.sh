#!/usr/bin/env bash

readonly OAS_AGENT_SDK_URL="https://github.com/jeong-sik/oas.git"
readonly OAS_AGENT_SDK_BASE_VERSION="v0.208.19"
# Pinned to the OAS v0.208.19 release commit (oas#2474). Advances from
# 18680a61 (v0.208.18, oas#2468) and picks up, since that pin: the
# reasoning replay token-waste fix (oas#2470, released via oas#2473).
# The reachability guard in check-oas-pin.sh tracks main.
readonly OAS_AGENT_SDK_TRACK_REF="main"
readonly OAS_AGENT_SDK_SHA="64dd43c64b79d8d2243a8cf5d87087f07301596b"
readonly OAS_AGENT_SDK_MIN_VERSION="0.208.19"
