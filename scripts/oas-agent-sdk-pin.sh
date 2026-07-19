#!/usr/bin/env bash

readonly OAS_AGENT_SDK_URL="https://github.com/jeong-sik/oas.git"
readonly OAS_AGENT_SDK_BASE_VERSION="v0.216.5"
# Pinned to the v0.216.5 release (tracks main). On top of 0.216.4:
# - Agent execution reports a typed terminal disposition so consumers can
#   distinguish safe retirement from operator repair without parsing error
#   detail (oas#2694).
# - Agent execution exposes a durable, read-only projection over the canonical
#   journal so consumers do not reconstruct execution history from callbacks
#   or private storage (oas#2701). MASC consumes only the public Agent SDK
#   contract; Keeper, Gate, Board, and product operation ownership remain MASC
#   concepts.
# The reachability guard in check-oas-pin.sh tracks main; oas-drift-check.sh
# reports the public-surface delta at pin-bump time.
readonly OAS_AGENT_SDK_TRACK_REF="main"
readonly OAS_AGENT_SDK_SHA="64525619fc749c310f992bb77190ebade0965783"
readonly OAS_AGENT_SDK_MIN_VERSION="0.216.5"
