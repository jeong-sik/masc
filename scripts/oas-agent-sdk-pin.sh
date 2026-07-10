#!/usr/bin/env bash

readonly OAS_AGENT_SDK_URL="https://github.com/jeong-sik/oas.git"
readonly OAS_AGENT_SDK_BASE_VERSION="v0.209.0"
# Pinned to oas release 0.209.0 (tag v0.209.0, #2504). Advances from
# a44267d6 (release 0.208.22) and picks up: catalog-driven provider
# capability + Anthropic thinking policy (oas#2499), typed empty-completion
# boundary convergence (oas#2498), Hooks.Block + 0.209 breaking release
# floor (oas#2495 / #2497). 0.209 declares the public API break
# (exhaustive-match migration guidance). The reachability guard in
# check-oas-pin.sh tracks main.
readonly OAS_AGENT_SDK_TRACK_REF="main"
readonly OAS_AGENT_SDK_SHA="9fff304f9d906dbb453612ac6e113894ce54eccd"
readonly OAS_AGENT_SDK_MIN_VERSION="0.209.0"
