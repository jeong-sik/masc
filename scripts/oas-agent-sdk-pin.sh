#!/usr/bin/env bash

readonly OAS_AGENT_SDK_URL="https://github.com/jeong-sik/oas.git"
readonly OAS_AGENT_SDK_BASE_VERSION="v0.221.1"
# v0.221.1 extends the exact-output boundary with one affine outer flow:
# - MASC owns ordered logical Runtime candidate IDs and domain I/O contracts;
# - each candidate's executable selected-target/ready materialization remains
#   opaque to MASC and is admitted and frozen by OAS before dispatch;
# - immutable ready flows create non-shared attempts with aggregate evidence;
# - execute_flow_once owns candidate advancement and permits it only for exact
#   Before_dispatch evidence with dispatch_count=0;
# - success, cancellation, callback failure, and any post-dispatch exposure are
#   terminal, while receipts and provenance remain available to MASC;
# - provider/model/tier resolution stays inside OAS, and pricing remains
#   observation-only rather than routing, retry, or admission policy.
# Previous pin: v0.221.0 (0f1df2a4).
# MASC consumes only the public Agent SDK contract; Keeper, Gate, Board, and
# product operation ownership remain MASC concepts.
# The reachability guard in check-oas-pin.sh tracks main; oas-drift-check.sh
# reports the public-surface delta at pin-bump time.
# Pinned to the v0.221.1 release commit (oas#2781, oas#2782).
readonly OAS_AGENT_SDK_DECLARED_VERSION="0.221.1"
# TRACK_REF consumed by check-oas-pin.sh / oas-drift-check.sh /
# sync-oas-pin-docs.sh; removed by #25579 and restored here (#25584).
readonly OAS_AGENT_SDK_TRACK_REF="main"
readonly OAS_AGENT_SDK_SHA="2b6b7b98cb19a4bc6d0cf2dba728ba36c987fbe0"
readonly OAS_AGENT_SDK_MIN_VERSION="0.221.1"
