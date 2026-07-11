#!/usr/bin/env bash

readonly OAS_AGENT_SDK_URL="https://github.com/jeong-sik/oas.git"
readonly OAS_AGENT_SDK_BASE_VERSION="v0.211.2"
# Pinned to green oas main after v0.211.2. This carries typed tool-failure
# provenance, adjacent-failure episode detection, the closed LLM recovery
# decision boundary, transactional recovery receipts, run-boundary-safe
# checkpoint restore, and public recovery-stage labels. MASC consumes only
# the public judge/error/event surfaces and supplies its runtime catalog at
# the callback boundary; OAS remains independent of MASC. The exact post-tag
# SHA is intentional because the recovery API is not present in the v0.211.2
# tag. The reachability guard in check-oas-pin.sh tracks main.
readonly OAS_AGENT_SDK_TRACK_REF="main"
readonly OAS_AGENT_SDK_SHA="fc405106e62dce43b57d08870ea6fbbff8422c93"
readonly OAS_AGENT_SDK_MIN_VERSION="0.211.2"
