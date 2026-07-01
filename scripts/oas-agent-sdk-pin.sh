#!/usr/bin/env bash

readonly OAS_AGENT_SDK_URL="https://github.com/jeong-sik/oas.git"
readonly OAS_AGENT_SDK_BASE_VERSION="v0.208.10"
# 0.208.10 is a tagged release on OAS main (commit below). It includes the
# resume-time thinking-policy precedence fix from oas#2412, so explicit runtime
# config can override stale checkpointed thinking settings during Agent.resume.
# The reachability guard in check-oas-pin.sh tracks main.
readonly OAS_AGENT_SDK_TRACK_REF="main"
readonly OAS_AGENT_SDK_SHA="72296aa77a888f957204cc9000cbc5f62d24919d"
readonly OAS_AGENT_SDK_MIN_VERSION="0.208.10"
