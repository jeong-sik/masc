#!/usr/bin/env bash

readonly OAS_AGENT_SDK_URL="https://github.com/jeong-sik/oas.git"
readonly OAS_AGENT_SDK_BASE_VERSION="v0.208.14"
# Pinned to origin/main at v0.208.14 plus the PRs merged after the tag. The tag
# itself includes parse-time base preset validation replacing the silent default
# collapse (oas#2433), removal of the last model-id GLM string classifier
# (oas#2446), per-model catalog rows honored on the Custom_registered path
# (oas#2447), Eio.Mutex wire capture so capture I/O stops blocking fiber
# scheduling (oas#2449) plus its bounded file growth cap (oas#2448), redaction
# hardening for large media payloads (oas#2444), the non-local default fallback
# provider (oas#2442), the Kimi structured-output path-dependence correction
# (oas#2451), RFC-OAS-033 (oas#2336), and the OCaml 5.5 canary lane (oas#2445).
# Post-tag: hardening baseline rebalance (oas#2453) and the api.kimi.com
# coding-plan vendor-host mapping so a kimi_code runtime resolves kimi_capabilities
# instead of failing the capability gate (oas#2452 via #2454). The reachability
# guard in check-oas-pin.sh tracks main.
readonly OAS_AGENT_SDK_TRACK_REF="main"
readonly OAS_AGENT_SDK_SHA="6c6d5ca3971b82e3de746e70b1dac6f15842385d"
readonly OAS_AGENT_SDK_MIN_VERSION="0.208.14"
