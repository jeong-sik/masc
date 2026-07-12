#!/usr/bin/env bash

readonly OAS_AGENT_SDK_URL="https://github.com/jeong-sik/oas.git"
readonly OAS_AGENT_SDK_BASE_VERSION="v0.211.3"
# Pinned to the green post-v0.211.3 fix commit. This carries the authoritative
# ToolResult outcome, opt-in typed tool-failure recovery, Defer host control,
# and exact Gemini textual thought-signature replay. The tag itself contains
# a broken Gemini assertion; a317895 fixes that test and is green on OCaml
# 5.4.1 and 5.5.0. MASC consumes only public OAS surfaces and supplies its
# runtime catalog at the callback boundary; OAS remains independent of MASC.
# The reachability guard in check-oas-pin.sh tracks main.
readonly OAS_AGENT_SDK_TRACK_REF="main"
readonly OAS_AGENT_SDK_SHA="a317895d5112ed7d5bc1066a91c7424ca7989294"
readonly OAS_AGENT_SDK_MIN_VERSION="0.211.3"
