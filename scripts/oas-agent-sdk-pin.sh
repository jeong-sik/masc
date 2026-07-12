#!/usr/bin/env bash

readonly OAS_AGENT_SDK_URL="https://github.com/jeong-sik/oas.git"
readonly OAS_AGENT_SDK_BASE_VERSION="v0.211.5"
# Pinned to the green v0.211.5 release. This carries the authoritative
# ToolResult outcome, opt-in typed tool-failure recovery, Defer host control,
# redacted external recovery events, hardened recovery-receipt provenance,
# and exact Gemini textual thought-signature replay. The release is green on
# OCaml 5.4.1 and 5.5.0. MASC consumes only public OAS surfaces and supplies
# its runtime catalog at the callback boundary; OAS remains independent of
# MASC. The reachability guard in check-oas-pin.sh tracks main.
readonly OAS_AGENT_SDK_TRACK_REF="main"
readonly OAS_AGENT_SDK_SHA="492de3248908a4a9701ad239cea3f55e8af16bab"
readonly OAS_AGENT_SDK_MIN_VERSION="0.211.5"
