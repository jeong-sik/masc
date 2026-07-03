#!/usr/bin/env bash

readonly OAS_AGENT_SDK_URL="https://github.com/jeong-sik/oas.git"
readonly OAS_AGENT_SDK_BASE_VERSION="v0.208.13"
# Tagged release v0.208.13 (the pinned commit below IS the tag) includes the
# packaged model catalog surface (oas#2424, oas#2429), call-time provider env
# reads (oas#2436), the single-source Responses builder policy (oas#2437),
# catalog-declared typed task (oas#2438), the vllm-qwen3-mtp namespace rename
# (oas#2432), and the Ollama Cloud structured-output capability correction
# (oas#2440). The reachability guard in check-oas-pin.sh tracks main.
readonly OAS_AGENT_SDK_TRACK_REF="main"
readonly OAS_AGENT_SDK_SHA="8a6e5fede943f3e8d277b54b80018e7615ca3cb4"
readonly OAS_AGENT_SDK_MIN_VERSION="0.208.13"
