#!/usr/bin/env bash

readonly OAS_AGENT_SDK_URL="https://github.com/jeong-sik/oas.git"
readonly OAS_AGENT_SDK_BASE_VERSION="v0.231.4"
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
# v0.231.2 is a patch on the hard-cut wave: the base catalog declares
# GLM-5-Turbo reasoning_streaming_format (#2880). Deployment exact overlays
# must declare the same capability explicitly, and parser wiring/runtime proof
# remain separate concerns. It also carries the #2875 agent-card
# current-interface contract hard-cut. MASC consumes the same public Agent SDK
# contract; no compatibility or migration code retained.
# v0.231.3 resolves the catalog-declared streaming reasoning dialect once and
# passes that typed value to the GLM stream parser (#2883). This removes the
# backend's hardcoded reasoning_content field without adding model-name or
# provider heuristics. MASC's exact overlay declares the corresponding
# delta:reasoning_content capability.
# Previous pin: v0.231.2 (1ea60e7a1).
# v0.231.4 exposes typed origins for the final provider-bound prepared
# messages and preserves those origins through caller projections. The same
# request is observed after provider serialization through the existing
# metadata-only pre-dispatch observer. MASC consumes both contracts directly;
# it does not infer the current user from list position or reconstruct the
# provider body from partial byte counts.
# Previous pin: v0.231.3 (e01940b14).
readonly OAS_AGENT_SDK_DECLARED_VERSION="0.231.4"
# TRACK_REF consumed by check-oas-pin.sh / oas-drift-check.sh /
# sync-oas-pin-docs.sh; removed by #25579 and restored here (#25584).
readonly OAS_AGENT_SDK_TRACK_REF="main"
readonly OAS_AGENT_SDK_SHA="7d4bac917b9897dd347bbe8ff1edb9fc8c35e2ca"
readonly OAS_AGENT_SDK_MIN_VERSION="0.231.4"
