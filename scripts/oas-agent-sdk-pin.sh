#!/usr/bin/env bash

readonly OAS_AGENT_SDK_URL="https://github.com/jeong-sik/oas.git"
readonly OAS_AGENT_SDK_BASE_VERSION="v0.217.1"
# Pinned to the v0.217.1 release (tracks main). On top of 0.216.5:
# - 0.216.6/0.216.7: Kimi native token-count admission (oas#2705), projected
#   provider input as the admission SSOT (oas#2707), exact provider turn
#   identity shared with execution (oas#2709).
# - 0.217.0 (breaking): streaming rejects malformed tool-call batches
#   whole-batch instead of executing a partial subset (oas#2702).
# - Resume is total over crash-reachable journal states: a settled turn after
#   a partial-close crash resumes instead of aborting Failed (oas#2713), and
#   resume matches the run's original prompt rather than the latest injected
#   User message (oas#2715, 0.217.1).
# - Overflow wire finish_reason decodes into the typed classifier (oas#2703);
#   non-finite/negative retry_after rejected at the parse boundary (oas#2708);
#   admission-conflict warnings sanitize base_url credentials (oas#2706).
# - Explicit enable_thinking that the provider dialect cannot encode is now
#   AcceptRejected instead of silently dropped (oas#2716). MASC-side prep:
#   ollama_cloud /v1 rows (kimi-k2.6, minimax-m3, deepseek-v4-pro) declare
#   thinking_control_format="none" + supports_reasoning=true in the runtime
#   oas-models-overlay.toml (2026-07-20 flip-risk audit).
# MASC consumes only the public Agent SDK contract; Keeper, Gate, Board, and
# product operation ownership remain MASC concepts.
# The reachability guard in check-oas-pin.sh tracks main; oas-drift-check.sh
# reports the public-surface delta at pin-bump time.
readonly OAS_AGENT_SDK_TRACK_REF="main"
readonly OAS_AGENT_SDK_SHA="9fef71dedf1280e5f0daf083bccc06d53b2c065c"
readonly OAS_AGENT_SDK_MIN_VERSION="0.217.1"
