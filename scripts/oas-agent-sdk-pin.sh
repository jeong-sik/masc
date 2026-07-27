#!/usr/bin/env bash

readonly OAS_AGENT_SDK_URL="https://github.com/jeong-sik/oas.git"
readonly OAS_AGENT_SDK_BASE_VERSION="v0.229.0"
# v0.229.0 freezes caller-declared Runtime order, requires one semantic
# validator, advances after strict JSON/domain rejection, and admits ordinary
# text Runtimes without inventing native schema support. Preference stores and
# domain settlement/recovery surfaces are removed. MASC consumes only accepted
# output or typed exhaustion; provider/model resolution, wire parsing, and
# failover remain OAS-owned.
# Previous pin: v0.228.0 (0257262d).
# MASC consumes only the public Agent SDK contract; Keeper, Gate, Board, and
# product operation ownership remain MASC concepts.
# The reachability guard in check-oas-pin.sh tracks main; oas-drift-check.sh
# reports the public-surface delta at pin-bump time.
# Pinned to the v0.229.0 release commit.
readonly OAS_AGENT_SDK_DECLARED_VERSION="0.229.0"
# TRACK_REF consumed by check-oas-pin.sh / oas-drift-check.sh /
# sync-oas-pin-docs.sh; removed by #25579 and restored here (#25584).
readonly OAS_AGENT_SDK_TRACK_REF="main"
readonly OAS_AGENT_SDK_SHA="6bf1751a56357eecddd088383f0aac65275c6de6"
readonly OAS_AGENT_SDK_MIN_VERSION="0.229.0"
