#!/usr/bin/env bash

readonly OAS_AGENT_SDK_URL="https://github.com/jeong-sik/oas.git"
readonly OAS_AGENT_SDK_BASE_VERSION="v0.222.2"
# v0.222.2 adds evidence-backed serving constraints and typed zero-dispatch
# InputCapacity outcomes. MASC consumes only the provider-neutral evidence;
# provider/model resolution and admission remain OAS-owned.
# Previous pin: v0.222.1 (f448e518).
# MASC consumes only the public Agent SDK contract; Keeper, Gate, Board, and
# product operation ownership remain MASC concepts.
# The reachability guard in check-oas-pin.sh tracks main; oas-drift-check.sh
# reports the public-surface delta at pin-bump time.
# Pinned to the v0.222.2 release commit.
readonly OAS_AGENT_SDK_DECLARED_VERSION="0.222.2"
# TRACK_REF consumed by check-oas-pin.sh / oas-drift-check.sh /
# sync-oas-pin-docs.sh; removed by #25579 and restored here (#25584).
readonly OAS_AGENT_SDK_TRACK_REF="main"
readonly OAS_AGENT_SDK_SHA="45473aae840b8c917641811e9fa4006ebc09528f"
readonly OAS_AGENT_SDK_MIN_VERSION="0.222.2"
