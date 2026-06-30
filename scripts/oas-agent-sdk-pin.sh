#!/usr/bin/env bash

readonly OAS_AGENT_SDK_URL="https://github.com/jeong-sik/oas.git"
readonly OAS_AGENT_SDK_BASE_VERSION="v0.208.5"
# 0.208.5 is a tagged release on OAS main (commit below); the prior
# codex/oas-tool-call-block-projection branch does not contain it, so the
# reachability guard in check-oas-pin.sh now tracks main.
readonly OAS_AGENT_SDK_TRACK_REF="main"
readonly OAS_AGENT_SDK_SHA="8d9a62020b2e745f9983796290650265be28785d"
readonly OAS_AGENT_SDK_MIN_VERSION="0.208.5"
