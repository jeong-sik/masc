#!/usr/bin/env bash

readonly OAS_AGENT_SDK_URL="https://github.com/jeong-sik/oas.git"
readonly OAS_AGENT_SDK_BASE_VERSION="v0.214.0"
# Pinned to the v0.214.0 release (tracks main). On top of 0.213.0, this
# release adds:
# - BREAKING (oas#2589): make_http_transport no longer accepts a
#   construction-time ?stream_idle_timeout_s; masc already migrated to
#   Builder.with_stream_idle_timeout (RFC-OAS-026), so no call-site change.
# - Typed input token count: Input_token_count contract (oas#2623) +
#   Anthropic /v1/messages/count_tokens transport Count_tokens_sync
#   (oas#2624) — available for request-time context budgeting.
# - Catalog-gated media generation: Image_generation / Speech_generation
#   with five new [[providers]] rows (zai-image, openai-image, gemini-image,
#   openai-speech, gemini-speech) and task-declared model rows; consuming
#   them requires masc-side dispatch wiring (chat pipeline cannot reach
#   them — generation validates task = image_generation/speech).
# - Latest_user_turn_tool_calls reasoning replay policy
#   (Force_latest_user_turn_tool_calls capability), consumable through the
#   RFC-OAS-036 deployment overlay.
# - All new provider-response parsers decode through Json_util.decode_json_with.
# The reachability guard in check-oas-pin.sh tracks main; oas-drift-check.sh
# reports the public-surface delta at pin-bump time.
readonly OAS_AGENT_SDK_TRACK_REF="main"
readonly OAS_AGENT_SDK_SHA="9b5f0835a1c8d579ae53987c092c889617b7f8ea"
readonly OAS_AGENT_SDK_MIN_VERSION="0.214.0"
