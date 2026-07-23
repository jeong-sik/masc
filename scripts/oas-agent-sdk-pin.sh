#!/usr/bin/env bash

readonly OAS_AGENT_SDK_URL="https://github.com/jeong-sik/oas.git"
readonly OAS_AGENT_SDK_BASE_VERSION="v0.222.0"
# v0.222.0 makes Agent_sdk.Tool_contract the sole public SSOT for terminal-tool
# invocation, schedule, execution-mode, and completion types:
# - Agent_sdk.Tool remains the descriptor/handler value surface only;
# - Terminal_tool_receipt carries the canonical terminal execution evidence;
# - removed Tool and Hooks type aliases are not recreated in MASC;
# - provider/model/tier resolution remains opaque to MASC, and pricing remains
#   observation-only rather than routing, retry, or admission policy.
# Previous pin: v0.221.1 (2b6b7b98).
# MASC consumes only the public Agent SDK contract; Keeper, Gate, Board, and
# product operation ownership remain MASC concepts.
# The reachability guard in check-oas-pin.sh tracks main; oas-drift-check.sh
# reports the public-surface delta at pin-bump time.
# Pinned to the v0.222.0 release commit.
readonly OAS_AGENT_SDK_DECLARED_VERSION="0.222.0"
# TRACK_REF consumed by check-oas-pin.sh / oas-drift-check.sh /
# sync-oas-pin-docs.sh; removed by #25579 and restored here (#25584).
readonly OAS_AGENT_SDK_TRACK_REF="main"
readonly OAS_AGENT_SDK_SHA="f443220428751a266c26308d3e094c1d0fb31680"
readonly OAS_AGENT_SDK_MIN_VERSION="0.222.0"
