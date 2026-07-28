#!/usr/bin/env bash

readonly OAS_AGENT_SDK_URL="https://github.com/jeong-sik/oas.git"
readonly OAS_AGENT_SDK_BASE_VERSION="v0.229.1"
# v0.229.1 freezes the exact serialized request body before admission and
# dispatch, exposes a metadata-only pre-dispatch serialization observer, and
# guarantees that token measurement and transport consume those same bytes.
# This lets MASC enforce Runtime-specific byte bounds without reconstructing
# provider wire formats or claiming that observation means transport started.
# Previous pin: v0.229.0 (6bf1751a).
# MASC consumes only the public Agent SDK contract; Keeper, Gate, Board, and
# product operation ownership remain MASC concepts.
# The reachability guard in check-oas-pin.sh tracks main; oas-drift-check.sh
# reports the public-surface delta at pin-bump time.
# Pinned to the v0.229.1 release commit.
readonly OAS_AGENT_SDK_DECLARED_VERSION="0.229.1"
# TRACK_REF consumed by check-oas-pin.sh / oas-drift-check.sh /
# sync-oas-pin-docs.sh; removed by #25579 and restored here (#25584).
readonly OAS_AGENT_SDK_TRACK_REF="main"
readonly OAS_AGENT_SDK_SHA="48909eb7ba2a0c05989b92cfd9b796b1eabbdfdd"
readonly OAS_AGENT_SDK_MIN_VERSION="0.229.1"
