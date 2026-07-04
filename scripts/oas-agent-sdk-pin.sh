#!/usr/bin/env bash

readonly OAS_AGENT_SDK_URL="https://github.com/jeong-sik/oas.git"
readonly OAS_AGENT_SDK_BASE_VERSION="v0.208.17"
# Pinned to the OAS v0.208.17 release commit (oas#2463). Advances from
# 6c6d5ca (v0.208.14 + api.kimi.com coding-plan vendor host, oas#2454) and
# picks up, since that pin: the exact Uri.host ollama classifier replacing the
# fuzzy match (oas#2458), wire-capture I/O offloaded to a background fiber
# (oas#2456) with Eio.Mutex protection (oas#2460), output_schema wire
# serialization pinned for ollama+anthropic (oas#2459), kimi sampling-prompt
# and k2 thinking-dialect alignment (oas#2461/#2465), dropping the dummy local
# provider key (oas#2464), and removal of a stream-idle `assert false` control
# path (oas#2462). The reachability guard in check-oas-pin.sh tracks main.
readonly OAS_AGENT_SDK_TRACK_REF="main"
readonly OAS_AGENT_SDK_SHA="0df6f741b9029b320bafc97d5586a3a53b134238"
readonly OAS_AGENT_SDK_MIN_VERSION="0.208.17"
