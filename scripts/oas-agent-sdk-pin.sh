#!/usr/bin/env bash

readonly OAS_AGENT_SDK_URL="https://github.com/jeong-sik/oas.git"
readonly OAS_AGENT_SDK_BASE_VERSION="v0.216.5"
# Pinned to the v0.216.5 release (tracks main). On top of 0.216.4:
# - Durable execution completion reports a typed terminal disposition so a
#   consumer can distinguish safe retirement from operator repair after an
#   unknown effect outcome (oas#2694).
# - Durable execution history has a read-only, opaque-cursor projection over
#   the canonical OAS journal without granting consumer write authority
#   (oas#2701). MASC owns product identity and display policy only.
# The reachability guard in check-oas-pin.sh tracks main; oas-drift-check.sh
# reports the public-surface delta at pin-bump time.
readonly OAS_AGENT_SDK_TRACK_REF="main"
readonly OAS_AGENT_SDK_SHA="64525619fc749c310f992bb77190ebade0965783"
readonly OAS_AGENT_SDK_MIN_VERSION="0.216.5"
