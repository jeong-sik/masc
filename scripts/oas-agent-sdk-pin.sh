#!/usr/bin/env bash

readonly OAS_AGENT_SDK_URL="https://github.com/jeong-sik/oas.git"
readonly OAS_AGENT_SDK_BASE_VERSION="v0.223.1"
# v0.223.1 preserves the immutable exact-flow contract from v0.223.0 while
# restoring the supported Eio 1.3 dependency solution. MASC consumes only
# opaque flow, receipt, and provenance facts; provider/model resolution,
# admission, successor choice, and Pricing remain OAS-owned.
# Previous pin: v0.223.0 (e87cc15c).
# MASC consumes only the public Agent SDK contract; Keeper, Gate, Board, and
# product operation ownership remain MASC concepts.
# The reachability guard in check-oas-pin.sh tracks main; oas-drift-check.sh
# reports the public-surface delta at pin-bump time.
# Pinned to the v0.223.1 release commit.
readonly OAS_AGENT_SDK_DECLARED_VERSION="0.223.1"
# TRACK_REF consumed by check-oas-pin.sh / oas-drift-check.sh /
# sync-oas-pin-docs.sh; removed by #25579 and restored here (#25584).
readonly OAS_AGENT_SDK_TRACK_REF="main"
readonly OAS_AGENT_SDK_SHA="3d4ee19a4773cbd8b1b73ed5555c5cdfe82e6d77"
readonly OAS_AGENT_SDK_MIN_VERSION="0.223.1"
