#!/usr/bin/env bash

readonly OAS_AGENT_SDK_URL="https://github.com/jeong-sik/oas.git"
readonly OAS_AGENT_SDK_BASE_VERSION="v0.208.12"
# Base release 0.208.12 includes the default-unbounded agent turn budget
# contract from oas#2423. The main-branch pin below also includes the packaged
# model catalog surface from oas#2424 and the post-merge test registration
# repair from oas#2429. The reachability guard in check-oas-pin.sh tracks main.
readonly OAS_AGENT_SDK_TRACK_REF="main"
readonly OAS_AGENT_SDK_SHA="97076aa6dae6ee8ac14a1857a9232ea6373118f6"
readonly OAS_AGENT_SDK_MIN_VERSION="0.208.12"
