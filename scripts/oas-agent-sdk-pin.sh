#!/usr/bin/env bash

readonly OAS_AGENT_SDK_URL="https://github.com/jeong-sik/oas.git"
readonly OAS_AGENT_SDK_BASE_VERSION="v0.208.7"
# 0.208.7 is a tagged release on OAS main (commit below). It includes the typed
# reasoning-details projection and oas#2363's id-keyed streaming tool-call block
# fix, so providers that stamp parallel calls with duplicate index values no
# longer collapse distinct buffers. The reachability guard in check-oas-pin.sh
# tracks main.
readonly OAS_AGENT_SDK_TRACK_REF="main"
readonly OAS_AGENT_SDK_SHA="7e979c0b2ed6493c617ea1033ca9bb2e5bf52b1c"
readonly OAS_AGENT_SDK_MIN_VERSION="0.208.7"
