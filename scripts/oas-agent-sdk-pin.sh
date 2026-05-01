#!/usr/bin/env bash

readonly OAS_AGENT_SDK_URL="https://github.com/jeong-sik/oas.git"
readonly OAS_AGENT_SDK_BASE_VERSION="v0.187.5"
# Temporary stacked PR ref for the OAS timeout-containment changes. Keep the
# exact SHA pinned here and retarget this ref to main/tag after OAS #1281 lands.
readonly OAS_AGENT_SDK_TRACK_REF="codex/timeout-containment-oas"
readonly OAS_AGENT_SDK_SHA="21ed9d720ffbbe5f51edff46c7d7d999037495c5"
readonly OAS_AGENT_SDK_MIN_VERSION="0.187.5"
