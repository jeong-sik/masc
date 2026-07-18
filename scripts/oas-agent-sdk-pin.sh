#!/usr/bin/env bash

readonly OAS_AGENT_SDK_URL="https://github.com/jeong-sik/oas.git"
readonly OAS_AGENT_SDK_BASE_VERSION="v0.216.4"
# Pinned to the v0.216.4 release (tracks main). On top of 0.216.3:
# - Provider fit admission measures the exact prepared request later dispatched
#   and returns typed overflow without caller-side request reconstruction
#   (oas#2678).
# - Agent Tool occurrences use one durable execution authority across call,
#   settlement, restart resume, cancellation, and observer projection
#   (oas#2683). MASC consumes only the public Agent SDK contract; Keeper, Gate,
#   Board, and product operation ownership remain MASC concepts.
# The reachability guard in check-oas-pin.sh tracks main; oas-drift-check.sh
# reports the public-surface delta at pin-bump time.
readonly OAS_AGENT_SDK_TRACK_REF="main"
readonly OAS_AGENT_SDK_SHA="9d8c54b665c69b927ac1541bec58891ac3cc93d9"
readonly OAS_AGENT_SDK_MIN_VERSION="0.216.4"
