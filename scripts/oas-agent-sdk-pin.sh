#!/usr/bin/env bash

readonly OAS_AGENT_SDK_URL="https://github.com/jeong-sik/oas.git"
readonly OAS_AGENT_SDK_BASE_VERSION="v0.211.10"
# Staged cross-repo pin to oas#2589, based on v0.211.10. The pinned commit
# makes stream-idle deadlines explicit request data, removes provider-kind and
# transport-constructor fallback deadlines, exports the named unbounded-turn
# sentinel, and deletes no-op provider turn/attempt limit surfaces. MASC
# consumes only public OAS APIs; OAS remains independent of MASC. Track the PR
# branch until the commit lands on main, then move this ref without changing
# the reviewed SHA.
readonly OAS_AGENT_SDK_TRACK_REF="codex/stream-idle-opt-in-20260714"
readonly OAS_AGENT_SDK_SHA="eed7ce6f1d0f8f9aa9d8c8dc847b3a52efc9fdaf"
readonly OAS_AGENT_SDK_MIN_VERSION="0.211.10"
