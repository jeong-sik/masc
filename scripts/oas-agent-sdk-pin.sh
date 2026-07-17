#!/usr/bin/env bash

readonly OAS_AGENT_SDK_URL="https://github.com/jeong-sik/oas.git"
readonly OAS_AGENT_SDK_BASE_VERSION="v0.215.0"
# Pinned to the v0.215.0 release (tracks main). On top of 0.214.1:
# - BREAKING (oas#2631): Tool.handler_kind gains WithInvocation so handlers
#   can receive the exact turn/index occurrence for each tool call. MASC uses
#   Tool.create and does not exhaustively match handler_kind, so its existing
#   tool bridge remains source-compatible.
# - Recursive work ownership is bound to the exact Tool_attempt occurrence
#   instead of tool-call id alone (oas#2637).
# The reachability guard in check-oas-pin.sh tracks main; oas-drift-check.sh
# reports the public-surface delta at pin-bump time.
readonly OAS_AGENT_SDK_TRACK_REF="main"
readonly OAS_AGENT_SDK_SHA="a7ea83fbbfeb8ff0b79b13f911c134be3895270a"
readonly OAS_AGENT_SDK_MIN_VERSION="0.215.0"
