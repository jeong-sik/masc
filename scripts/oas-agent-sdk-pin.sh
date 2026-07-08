#!/usr/bin/env bash

readonly OAS_AGENT_SDK_URL="https://github.com/jeong-sik/oas.git"
readonly OAS_AGENT_SDK_BASE_VERSION="v0.208.20"
# Pinned to oas main aad819bb (oas#2488 merge). Advances from
# 65c8cfea (Block of string variant, oas#2487 / RFC-0321) and picks up
# the openai-compat chat-template thinking token injection + empty-
# completion fail-close (oas#2488 / #2483): silent Ok content=[] on
# blank 200 is now a typed Empty_completion error, closing the
# empty-turn storm root.
# The reachability guard in check-oas-pin.sh tracks main.
readonly OAS_AGENT_SDK_TRACK_REF="main"
readonly OAS_AGENT_SDK_SHA="aad819bb1977c9668dbb87ac13b1ab7d50ac9edb"
readonly OAS_AGENT_SDK_MIN_VERSION="0.208.20"
