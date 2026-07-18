#!/usr/bin/env bash

readonly OAS_AGENT_SDK_URL="https://github.com/jeong-sik/oas.git"
readonly OAS_AGENT_SDK_BASE_VERSION="v0.216.2"
# Pinned to the v0.216.2 release (tracks main). On top of 0.216.0:
# - Opaque provider Tool IDs remain correlation evidence through execution
#   events without becoming MASC settlement authority (oas#2648).
# - Exact provider-native completion-request measurement is available for
#   the future source-bound fit contract (oas#2647).
# - Serial Tool batches preserve declared schedule order (oas#2652).
# - Empty successful HTTP completions carrying provider overflow evidence
#   become the typed Context_window_exceeded error (oas#2659).
# The reachability guard in check-oas-pin.sh tracks main; oas-drift-check.sh
# reports the public-surface delta at pin-bump time.
readonly OAS_AGENT_SDK_TRACK_REF="main"
readonly OAS_AGENT_SDK_SHA="fd713eb0cfc4ffa9887a5d4830f497be7263004d"
readonly OAS_AGENT_SDK_MIN_VERSION="0.216.2"
