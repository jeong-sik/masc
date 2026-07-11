#!/usr/bin/env bash

readonly OAS_AGENT_SDK_URL="https://github.com/jeong-sik/oas.git"
readonly OAS_AGENT_SDK_BASE_VERSION="v0.210.0"
# Pinned to the oas 0.210.0 release (#2516), which lands oas#2514: request
# builders stop inventing max_tokens=16384 for catalog-silent models and
# omit the field instead (the invented value capped thinking+answer jointly
# and truncated long reasoning mid-thought — masc RFC-0271 §9). Consumer
# surface deltas: Backend_openai_request.effective_max_output_tokens is now
# int option and Backend_anthropic.required_max_output_tokens is new; the
# keeper lane always passes an explicit max_tokens, so its request values
# are unchanged until the flat-fallback purge (masc#24057) starts passing
# None. The reachability guard in check-oas-pin.sh tracks main.
readonly OAS_AGENT_SDK_TRACK_REF="main"
readonly OAS_AGENT_SDK_SHA="c63bbf0175cd60984b8613dcce2950a29c930259"
readonly OAS_AGENT_SDK_MIN_VERSION="0.210.0"
