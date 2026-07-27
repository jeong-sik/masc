#!/usr/bin/env bash

readonly OAS_AGENT_SDK_URL="https://github.com/jeong-sik/oas.git"
readonly OAS_AGENT_SDK_BASE_VERSION="v0.226.0"
# v0.226.0 replaces the process-local exact-flow settlement surface with
# commit-fenced entry points: recover_flow_preferences ~evidence,
# commit_and_settle_flow_domain ~commit, and
# commit_and_retire_flow_preference_scope ~commit. The callback is the durable
# content-commit fence, so MASC owns a current-schema preference evidence
# journal (#25808) rather than acknowledging evidence it did not persist.
# This pin only lands together with those consumers: #25799 bumped the pin
# alone and left main unable to compile, which #25810 reverted.
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
