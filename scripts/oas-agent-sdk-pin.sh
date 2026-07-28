#!/usr/bin/env bash

readonly OAS_AGENT_SDK_URL="https://github.com/jeong-sik/oas.git"
readonly OAS_AGENT_SDK_BASE_VERSION="v0.230.0"
# v0.230.0 makes pre-tool approval a typed, fail-closed boundary:
# ElicitToolApproval is distinct from generic ElicitInput, and only an exact
# Approved invocation may execute. The public Exact_output.execute_once
# shortcut is removed; callers freeze candidates with snapshot_flow, create an
# affine flow with start_flow, and consume it through execute_flow_once.
# Previous pin: v0.229.0 (6bf1751a).
# MASC consumes only the public Agent SDK contract; Keeper, Gate, Board, and
# product operation ownership remain MASC concepts.
# The reachability guards in check-oas-pin.sh and oas-drift-check.sh track
# main; oas-drift-check.sh also reports the public-surface delta at pin-bump
# time.
# Pinned to the v0.230.0 release commit.
readonly OAS_AGENT_SDK_DECLARED_VERSION="0.230.0"
# TRACK_REF consumed by check-oas-pin.sh / oas-drift-check.sh /
# sync-oas-pin-docs.sh; removed by #25579 and restored here (#25584).
readonly OAS_AGENT_SDK_TRACK_REF="main"
readonly OAS_AGENT_SDK_SHA="7a3f2af7aed6fdd19968de3e1637dccb4f867461"
readonly OAS_AGENT_SDK_MIN_VERSION="0.230.0"
