#!/usr/bin/env bash

readonly OAS_AGENT_SDK_URL="https://github.com/jeong-sik/oas.git"
readonly OAS_AGENT_SDK_BASE_VERSION="v0.211.0"
# Pinned to the oas 0.211.0 release (#2519), which lands oas#2518 (#2517):
# the catalog max_output_tokens is a validation ceiling, not a request
# default. Optional envelopes (Chat Completions / Responses / Ollama /
# Gemini) omit max_tokens whenever the caller passes None — the ceiling is
# never injected as a request value (on providers whose context window
# bounds input+reasoning+output jointly, ceiling injection can overflow
# the contract). Caller Some n is still clamped to the ceiling with a
# one-shot WARN; the required Anthropic envelope resolves through
# required_max_output_tokens (explicit default = declared model maximum,
# loud failure when nothing is declared). This pin is the prerequisite for
# masc#24067 (#24098): keeper turns pass None absent an explicit operator
# override, activating the omission path on the wire. The reachability
# guard in check-oas-pin.sh tracks main.
readonly OAS_AGENT_SDK_TRACK_REF="main"
readonly OAS_AGENT_SDK_SHA="ca4dbb1995b39feb9b0ffb15352d64cce1840391"
readonly OAS_AGENT_SDK_MIN_VERSION="0.211.0"
