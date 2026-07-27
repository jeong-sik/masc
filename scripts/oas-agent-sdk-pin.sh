#!/usr/bin/env bash

readonly OAS_AGENT_SDK_URL="https://github.com/jeong-sik/oas.git"
readonly OAS_AGENT_SDK_BASE_VERSION="v0.228.0"
# v0.228.0 follows the runtime's frozen successor after typed pre-generation
# input-capacity refusal while preserving context-window and serialized-request
# causes. It adds no persistence, settlement, commit, lease, or replay layer.
# MASC still consumes only opaque flow, receipt, provenance, and runtime failure
# facts; provider/model resolution, wire parsing, and Pricing remain OAS-owned.
# Previous pin: v0.227.1 (8351a0a8).
# MASC consumes only the public Agent SDK contract; Keeper, Gate, Board, and
# product operation ownership remain MASC concepts.
# The reachability guard in check-oas-pin.sh tracks main; oas-drift-check.sh
# reports the public-surface delta at pin-bump time.
# Pinned to the v0.228.0 release commit.
readonly OAS_AGENT_SDK_DECLARED_VERSION="0.228.0"
# TRACK_REF consumed by check-oas-pin.sh / oas-drift-check.sh /
# sync-oas-pin-docs.sh; removed by #25579 and restored here (#25584).
readonly OAS_AGENT_SDK_TRACK_REF="main"
readonly OAS_AGENT_SDK_SHA="0257262d7dd25ff83113d6ab57cb9b47c2086de2"
readonly OAS_AGENT_SDK_MIN_VERSION="0.228.0"
