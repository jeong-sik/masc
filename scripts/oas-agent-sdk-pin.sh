#!/usr/bin/env bash

readonly OAS_AGENT_SDK_URL="https://github.com/jeong-sik/oas.git"
readonly OAS_AGENT_SDK_BASE_VERSION="v0.227.0"
# v0.227.0 publishes durable measurement receipt snapshots and hard-cuts the
# retired nested-visit shape. MASC consumes only opaque flow, receipt, and
# provenance facts; provider/model resolution, admission, successor choice,
# and Pricing remain OAS-owned.
# Previous pin: v0.223.1 (3d4ee19a).
# MASC consumes only the public Agent SDK contract; Keeper, Gate, Board, and
# product operation ownership remain MASC concepts.
# The reachability guard in check-oas-pin.sh tracks main; oas-drift-check.sh
# reports the public-surface delta at pin-bump time.
# Pinned to the v0.227.0 release commit.
readonly OAS_AGENT_SDK_DECLARED_VERSION="0.227.0"
# TRACK_REF consumed by check-oas-pin.sh / oas-drift-check.sh /
# sync-oas-pin-docs.sh; removed by #25579 and restored here (#25584).
readonly OAS_AGENT_SDK_TRACK_REF="main"
readonly OAS_AGENT_SDK_SHA="d788df707ab7724687a33326aa2c097902ef71f6"
readonly OAS_AGENT_SDK_MIN_VERSION="0.227.0"
