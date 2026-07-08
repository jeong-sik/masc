#!/usr/bin/env bash

readonly OAS_AGENT_SDK_URL="https://github.com/jeong-sik/oas.git"
readonly OAS_AGENT_SDK_BASE_VERSION="v0.208.20"
# Pinned to oas main 65c8cfea (oas#2487 merge). Advances from
# abfffbd8 (v0.208.20 + oas#2484) and picks up the Block of string
# hook_decision variant (oas#2487 / RFC-0321): PreToolUse hard-block
# refusals now produce is_error=true tool results instead of being
# masked as normal results via Override (masc#23542).
# The reachability guard in check-oas-pin.sh tracks main.
readonly OAS_AGENT_SDK_TRACK_REF="main"
readonly OAS_AGENT_SDK_SHA="65c8cfea6a3152b7b8e70bf3adedac431b2b1c70"
readonly OAS_AGENT_SDK_MIN_VERSION="0.208.20"
