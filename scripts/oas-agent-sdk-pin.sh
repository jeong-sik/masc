#!/usr/bin/env bash

readonly OAS_AGENT_SDK_URL="https://github.com/jeong-sik/oas.git"
readonly OAS_AGENT_SDK_BASE_VERSION="v0.221.0"
# v0.221.0 hard-cuts the exact-output boundary:
# - catalog admission returns an opaque snapshot-bound admitted target;
# - credential outcomes are frozen per target and materialized only on resolve;
# - immutable ready plans create affine attempts that own call ID and receipt;
# - execute_once accepts an attempt only and rejects duplicate dispatch;
# - provider bytes are not repaired from fenced pseudo-JSON;
# - pricing remains observation-only and cannot drive functional policy.
# Previous pin: v0.220.5 (5851df2e).
# MASC consumes only the public Agent SDK contract; Keeper, Gate, Board, and
# product operation ownership remain MASC concepts.
# The reachability guard in check-oas-pin.sh tracks main; oas-drift-check.sh
# reports the public-surface delta at pin-bump time.
# Pinned to the v0.221.0 release commit (oas#2778, oas#2777, oas#2776, oas#2780).
readonly OAS_AGENT_SDK_DECLARED_VERSION="0.221.0"
# TRACK_REF consumed by check-oas-pin.sh / oas-drift-check.sh /
# sync-oas-pin-docs.sh; removed by #25579 and restored here (#25584).
readonly OAS_AGENT_SDK_TRACK_REF="main"
readonly OAS_AGENT_SDK_SHA="0f1df2a423d487e854af5b8559c6d1e2daec6de9"
readonly OAS_AGENT_SDK_MIN_VERSION="0.221.0"
