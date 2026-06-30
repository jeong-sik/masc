#!/usr/bin/env bash

readonly OAS_AGENT_SDK_URL="https://github.com/jeong-sik/oas.git"
readonly OAS_AGENT_SDK_BASE_VERSION="v0.208.5"
# 0.208.5 is the latest tagged dependency floor; this main pin consumes
# OAS PR #2361's typed reasoning-details projection after merge.
readonly OAS_AGENT_SDK_TRACK_REF="main"
readonly OAS_AGENT_SDK_SHA="17101f461e3d2873873b796e27c0169b86efa18e"
readonly OAS_AGENT_SDK_MIN_VERSION="0.208.5"
