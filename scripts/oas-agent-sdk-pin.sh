#!/usr/bin/env bash

readonly OAS_AGENT_SDK_URL="https://github.com/jeong-sik/oas.git"
readonly OAS_AGENT_SDK_BASE_VERSION="v0.209.1"
# Pinned to the oas 0.209.1 patch release (#2510). It preserves the 0.209
# public boundary while repairing the invalid Option.bind application,
# injected getenv type, and formatter drift introduced by oas#2499. The
# remaining oas#2512 changes are repo-only test contract corrections and do
# not alter the consumer library surface. The reachability guard in
# check-oas-pin.sh tracks main.
readonly OAS_AGENT_SDK_TRACK_REF="main"
readonly OAS_AGENT_SDK_SHA="495a5ba3e76195264cfb5a5a65879fe0c11fc495"
readonly OAS_AGENT_SDK_MIN_VERSION="0.209.1"
