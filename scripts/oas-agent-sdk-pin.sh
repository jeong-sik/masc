#!/usr/bin/env bash

readonly OAS_AGENT_SDK_URL="https://github.com/jeong-sik/oas.git"
readonly OAS_AGENT_SDK_BASE_VERSION="v0.226.0"
# v0.226.0 includes evidence-owned exact preference recovery and the
# provider-neutral exact-output single surface. MASC consumes only opaque flow,
# receipt, provenance, and input-capacity facts; provider/model resolution,
# admission, successor choice, and Pricing remain OAS-owned.
# Previous pin: v0.223.1 (3d4ee19a).
# MASC consumes only the public Agent SDK contract; Keeper, Gate, Board, and
# product operation ownership remain MASC concepts.
# The reachability guard in check-oas-pin.sh tracks main; oas-drift-check.sh
# reports the public-surface delta at pin-bump time.
# Pinned to the v0.226.0 release commit.
readonly OAS_AGENT_SDK_DECLARED_VERSION="0.226.0"
# TRACK_REF consumed by check-oas-pin.sh / oas-drift-check.sh /
# sync-oas-pin-docs.sh; removed by #25579 and restored here (#25584).
readonly OAS_AGENT_SDK_TRACK_REF="main"
readonly OAS_AGENT_SDK_SHA="2186dfa5fca2360e4e99fa5e47052ba4c0cc687f"
readonly OAS_AGENT_SDK_MIN_VERSION="0.226.0"
