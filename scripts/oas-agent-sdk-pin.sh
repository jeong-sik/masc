#!/usr/bin/env bash

readonly OAS_AGENT_SDK_URL="https://github.com/jeong-sik/oas.git"
readonly OAS_AGENT_SDK_BASE_VERSION="v0.231.13"
# v0.231.0 is a hard-cut wave: checkpoint schema is v9 only (v1-v8
# rejected; #2867), provider_config.output_schema is removed in favor of
# response_format = JsonSchema as the single structured-output request state
# (#2858), legacy tool/checkpoint shapes and the typed-compat runtime are
# removed (#2851/#2853), and eval requires explicit metric policies with
# incomplete comparisons rejected (#2854/#2866). MASC already consumes the
# current response_format-only contract; no compatibility or migration code is
# retained. Upgrade blast radius: OAS checkpoint artifacts below v9 are
# rejected and must be reset.
# v0.231.1 is a patch release on the same hard-cut wave: corrected 0.231.0
# release-note contracts (#2869) and keeps Exact_output.Json_syntax prompt-only
# (#2870), appending the JSON instruction and validating locally rather than
# selecting a provider-native response format. Provider_schema remains
# explicit. It also removes the public Llm_provider.Complete.gemini_url
# helper; MASC has no caller.
# The pinned post-v0.231.1 head carries the #2873 provider hard-cut:
# Agent.options.provider_config is the single exact carrier, including resume;
# the legacy Provider.config island and separate resume argument are removed.
# The #2877 follow-up derives the effective turn provider config once, threads
# that exact value through dispatch and pricing, and removes duplicate Provider
# auth/pricing facades. MASC consumes the canonical public modules directly.
# Previous pin: v0.231.1 (c3bb4daa7); before that v0.231.0 (2cb7d922).
# MASC consumes only the public Agent SDK contract; Keeper, Gate, Board, and
# product operation ownership remain MASC concepts.
# The reachability guards in check-oas-pin.sh and oas-drift-check.sh track
# main; oas-drift-check.sh also reports the public-surface delta at pin-bump
# time.
# v0.231.2 is a patch on the hard-cut wave: adds GLM-5-Turbo
# reasoning_streaming_format (#2880) — recovers streaming reasoning that was
# falling back to batch (No_streaming_reasoning, ~60s/turn). Also carries the
# #2875 agent-card current-interface contract hard-cut. MASC consumes the same
# public Agent SDK contract; no compatibility or migration code retained.
# Pinned to the 0.231.2 release commit (1ea60e7a1).
# v0.231.3..v0.231.13 are patch releases on the same hard-cut wave: streaming
# fixes (fail closed on malformed Gemini SSE parts #2930, classify malformed
# SSE discriminators #2926, quarantine streaming connections after transport
# EOF #2919), OS-entropy ID reuse for artifacts/traces/session (#2928/#2929),
# and terminal stop-semantics preservation (#2927). MASC consumes the same
# public Agent SDK contract; no compatibility or migration code retained.
# Pinned to the 0.231.13 release commit (59ccced68).
readonly OAS_AGENT_SDK_DECLARED_VERSION="0.231.13"
# TRACK_REF consumed by check-oas-pin.sh / oas-drift-check.sh /
# sync-oas-pin-docs.sh; removed by #25579 and restored here (#25584).
readonly OAS_AGENT_SDK_TRACK_REF="main"
readonly OAS_AGENT_SDK_SHA="59ccced68c2dc96389a91eee24d0b2c6bd5c53a6"
readonly OAS_AGENT_SDK_MIN_VERSION="0.231.13"
