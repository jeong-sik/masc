#!/usr/bin/env bash

readonly OAS_AGENT_SDK_URL="https://github.com/jeong-sik/oas.git"
readonly OAS_AGENT_SDK_BASE_VERSION="v0.222.1"
# v0.222.1 anchors the opaque provider trace in the exact-output contract.
# MASC consumes the trace only through Agent_sdk.Exact_output; provider/model
# resolution and the trace representation remain OAS-owned.
# Previous pin: v0.222.0 (f4432204).
# MASC consumes only the public Agent SDK contract; Keeper, Gate, Board, and
# product operation ownership remain MASC concepts.
# The reachability guard in check-oas-pin.sh tracks main; oas-drift-check.sh
# reports the public-surface delta at pin-bump time.
# Pinned to the v0.222.1 release commit.
readonly OAS_AGENT_SDK_DECLARED_VERSION="0.222.1"
# TRACK_REF consumed by check-oas-pin.sh / oas-drift-check.sh /
# sync-oas-pin-docs.sh; removed by #25579 and restored here (#25584).
readonly OAS_AGENT_SDK_TRACK_REF="main"
readonly OAS_AGENT_SDK_SHA="f448e5185ebd07ef7e0b3d8fb4a30b134b681c28"
readonly OAS_AGENT_SDK_MIN_VERSION="0.222.1"
