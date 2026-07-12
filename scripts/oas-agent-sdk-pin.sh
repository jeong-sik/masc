#!/usr/bin/env bash

readonly OAS_AGENT_SDK_URL="https://github.com/jeong-sik/oas.git"
readonly OAS_AGENT_SDK_BASE_VERSION="v0.211.8"
# Pinned to the v0.211.8 release (tracks main). Carries the v0.211.5 baseline
# (authoritative ToolResult outcome, opt-in typed tool-failure recovery, Defer
# host control, redacted external recovery events, hardened recovery-receipt
# provenance, exact Gemini textual thought-signature replay) plus the
# v0.211.6-v0.211.8 delta: exact Gemini replay payload schema validation
# (oas#2569), provider closed-failure attribution and binding identity
# (oas#2572), legacy error projections preserved with typed evidence
# (oas#2576), unclassified status fallback clarified (oas#2577), and idle-guard
# preservation under the recovery judge (oas#2579). MASC consumes only public
# OAS surfaces and supplies its runtime catalog at the callback boundary; OAS
# remains independent of MASC. The reachability guard in check-oas-pin.sh tracks
# main; oas-drift-check.sh reports the public-surface delta at pin-bump time.
readonly OAS_AGENT_SDK_TRACK_REF="main"
readonly OAS_AGENT_SDK_SHA="677a7eed6a8c8529e822d1d8ce95100e920f0b9e"
readonly OAS_AGENT_SDK_MIN_VERSION="0.211.8"
