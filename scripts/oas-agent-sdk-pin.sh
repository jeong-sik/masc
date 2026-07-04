#!/usr/bin/env bash

readonly OAS_AGENT_SDK_URL="https://github.com/jeong-sik/oas.git"
readonly OAS_AGENT_SDK_BASE_VERSION="v0.208.18"
# Pinned to the OAS v0.208.18 release commit (oas#2468). Advances from
# 0df6f741 (v0.208.17, oas#2463) and picks up, since that pin: the Xiaomi
# MiMo v2.5 capability catalog (oas#2466) and a fix for type-suppressed
# sampling parameters (oas#2467). The reachability guard in check-oas-pin.sh
# tracks main.
readonly OAS_AGENT_SDK_TRACK_REF="main"
readonly OAS_AGENT_SDK_SHA="18680a61fea5f6332202496b91ed737970a23f30"
readonly OAS_AGENT_SDK_MIN_VERSION="0.208.18"
