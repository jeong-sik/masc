#!/usr/bin/env bash

readonly OAS_AGENT_SDK_URL="https://github.com/jeong-sik/oas.git"
readonly OAS_AGENT_SDK_BASE_VERSION="v0.227.1"
# v0.227.1 preserves exact observed Ollama context-overflow wire errors as
# typed capacity failures so MASC can enter its existing compaction lifecycle.
# MASC still consumes only opaque flow, receipt, provenance, and runtime failure
# facts; provider/model resolution, wire parsing, and Pricing remain OAS-owned.
# Previous pin: v0.223.1 (3d4ee19a).
# MASC consumes only the public Agent SDK contract; Keeper, Gate, Board, and
# product operation ownership remain MASC concepts.
# The reachability guard in check-oas-pin.sh tracks main; oas-drift-check.sh
# reports the public-surface delta at pin-bump time.
# Pinned to the v0.227.1 release commit.
readonly OAS_AGENT_SDK_DECLARED_VERSION="0.227.1"
# TRACK_REF consumed by check-oas-pin.sh / oas-drift-check.sh /
# sync-oas-pin-docs.sh; removed by #25579 and restored here (#25584).
readonly OAS_AGENT_SDK_TRACK_REF="main"
readonly OAS_AGENT_SDK_SHA="8351a0a8fb3daa48ba324fc0959324d890f457f3"
readonly OAS_AGENT_SDK_MIN_VERSION="0.227.1"
