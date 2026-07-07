#!/usr/bin/env bash

readonly OAS_AGENT_SDK_URL="https://github.com/jeong-sik/oas.git"
readonly OAS_AGENT_SDK_BASE_VERSION="v0.208.20"
# Pinned to oas main abfffbd8 (one commit past the v0.208.20 release,
# oas#2478). Advances from 64dd43c6 (v0.208.19, oas#2474) and picks up,
# since that pin: the typed Chat_template_token catalog contract
# (oas#2484 / oas#2482) — tokenless chat_template_token rows now fail
# closed at catalog load instead of raising per request, closing the
# 2026-07-06 internal_unhandled_exception storm class (masc#23443).
# The reachability guard in check-oas-pin.sh tracks main.
readonly OAS_AGENT_SDK_TRACK_REF="main"
readonly OAS_AGENT_SDK_SHA="abfffbd88d8810519bee9415c54d55f3e186493d"
readonly OAS_AGENT_SDK_MIN_VERSION="0.208.20"
