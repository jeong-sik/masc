#!/usr/bin/env bash

readonly OAS_AGENT_SDK_URL="https://github.com/jeong-sik/oas.git"
readonly OAS_AGENT_SDK_BASE_VERSION="v0.208.20"
# Pinned to oas main a44267d6 (release 0.208.22, #2492). Advances from
# aad819bb (oas#2488 merge) and picks up the streaming empty-completion
# fail-close at the driver boundary (oas#2483 / #2491): an empty
# completion now fails closed inside lib/streaming.ml. No public .mli
# surface change vs aad819bb (verified: consumer contract unchanged).
# The reachability guard in check-oas-pin.sh tracks main.
readonly OAS_AGENT_SDK_TRACK_REF="main"
readonly OAS_AGENT_SDK_SHA="a44267d61bef1f8deb7df73bbe8d73e10cdc5397"
readonly OAS_AGENT_SDK_MIN_VERSION="0.208.22"
