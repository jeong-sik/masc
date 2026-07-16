#!/usr/bin/env bash

readonly OAS_AGENT_SDK_URL="https://github.com/jeong-sik/oas.git"
readonly OAS_AGENT_SDK_BASE_VERSION="v0.213.0"
# Pinned to the v0.213.0 release (tracks main). On top of 0.212.1 (deployment
# catalog overlay + alias-canonicalized provider lookup, RFC-OAS-036), this
# release adds:
# - Json_util.decode_json_with: total JSON decode boundary for provider
#   response parsers (contains Json_error/Type_error/Undefined; oas#2619).
# - Behavioral delta consumers must absorb: an empty completion whose typed
#   stop_reason is ContextWindowExceeded is now classified as
#   Error.Api (Retry.ContextOverflow { limit = None }) instead of
#   Provider/ProviderUnavailable (oas#2621, masc#24838). masc's
#   context_overflow_event_of_error starts matching that path, so overflow
#   turns route to Provider_overflow compaction recovery instead of
#   runtime rotation.
# The reachability guard in check-oas-pin.sh tracks main; oas-drift-check.sh
# reports the public-surface delta at pin-bump time.
readonly OAS_AGENT_SDK_TRACK_REF="main"
readonly OAS_AGENT_SDK_SHA="e43baf8fe2bb8b849845c7493ba170e88918b6b2"
readonly OAS_AGENT_SDK_MIN_VERSION="0.213.0"
