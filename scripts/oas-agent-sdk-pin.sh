#!/usr/bin/env bash

readonly OAS_AGENT_SDK_URL="https://github.com/jeong-sik/oas.git"
readonly OAS_AGENT_SDK_BASE_VERSION="v0.208.7"
# 0.208.7 is a tagged release on OAS main (commit below). Bumped from 0.208.5 to
# consume oas#2363: streaming tool-call blocks are keyed by tc_id so a provider
# that stamps every parallel call index:0 (minimax-m3 on Ollama Cloud) no longer
# collapses them into one buffer and fails the turn with
# malformed_tool_use_arguments; id-less continuations on a duplicated index fail
# loud instead of routing to the last writer. The reachability guard in
# check-oas-pin.sh tracks main.
readonly OAS_AGENT_SDK_TRACK_REF="main"
readonly OAS_AGENT_SDK_SHA="7e979c0b2ed6493c617ea1033ca9bb2e5bf52b1c"
readonly OAS_AGENT_SDK_MIN_VERSION="0.208.7"
