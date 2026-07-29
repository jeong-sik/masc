#!/usr/bin/env bash

readonly OAS_AGENT_SDK_URL="https://github.com/jeong-sik/oas.git"
readonly OAS_AGENT_SDK_BASE_VERSION="v0.230.0"
# OAS #2858 hard-cuts the duplicate structured-output state. Provider requests
# now carry only response_format = Off | JsonMode | JsonSchema; MASC no longer
# reads or writes the removed output_schema compatibility field.
# Previous pin: v0.230.0 (7a3f2af7).
# MASC consumes only the public Agent SDK contract; Keeper, Gate, Board, and
# product operation ownership remain MASC concepts.
# The reachability guards in check-oas-pin.sh and oas-drift-check.sh track
# main; oas-drift-check.sh also reports the public-surface delta at pin-bump
# time.
# Pinned to OAS main after #2858/#2862 and the adjacent current-head fixes.
readonly OAS_AGENT_SDK_DECLARED_VERSION="0.230.0"
# TRACK_REF consumed by check-oas-pin.sh / oas-drift-check.sh /
# sync-oas-pin-docs.sh; removed by #25579 and restored here (#25584).
readonly OAS_AGENT_SDK_TRACK_REF="main"
readonly OAS_AGENT_SDK_SHA="50e1bf1af1af598729c2482e190f8476ecebc3f1"
readonly OAS_AGENT_SDK_MIN_VERSION="0.230.0"
