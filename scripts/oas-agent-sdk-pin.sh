#!/usr/bin/env bash

readonly OAS_AGENT_SDK_URL="https://github.com/jeong-sik/oas.git"
readonly OAS_AGENT_SDK_BASE_VERSION="v0.231.0"
# v0.231.0 is a hard-cut wave: checkpoint schema is v9 only (v1-v8
# rejected; #2867), provider_config.output_schema is removed in favor of
# response_format = JsonSchema as the single structured-output request state
# (#2858), legacy tool/checkpoint shapes and the typed-compat runtime are
# removed (#2851/#2853), and eval requires explicit metric policies with
# incomplete comparisons rejected (#2854/#2866). MASC already consumes the
# current response_format-only contract; no compatibility or migration code is
# retained. Upgrade blast radius: OAS checkpoint artifacts below v9 are
# rejected and must be reset.
# Previous pin: v0.230.0 (7a3f2af7).
# MASC consumes only the public Agent SDK contract; Keeper, Gate, Board, and
# product operation ownership remain MASC concepts.
# The reachability guards in check-oas-pin.sh and oas-drift-check.sh track
# main; oas-drift-check.sh also reports the public-surface delta at pin-bump
# time.
# Pinned to the v0.231.0 release commit.
readonly OAS_AGENT_SDK_DECLARED_VERSION="0.231.0"
# TRACK_REF consumed by check-oas-pin.sh / oas-drift-check.sh /
# sync-oas-pin-docs.sh; removed by #25579 and restored here (#25584).
readonly OAS_AGENT_SDK_TRACK_REF="main"
readonly OAS_AGENT_SDK_SHA="2cb7d9226a7ba797071cd45733d5b15789f13ff5"
readonly OAS_AGENT_SDK_MIN_VERSION="0.231.0"
