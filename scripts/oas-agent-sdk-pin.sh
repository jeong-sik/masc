#!/usr/bin/env bash

readonly OAS_AGENT_SDK_URL="https://github.com/jeong-sik/oas.git"
readonly OAS_AGENT_SDK_BASE_VERSION="v0.216.0"
# Pinned to the v0.216.0 release (tracks main). On top of 0.215.0:
# - BREAKING (oas#2642): one immutable Tool.Invocation.t becomes the
#   tool-occurrence SSOT across hooks, event-bus payloads, execution
#   handlers, callbacks, results, and typed failures; canonical scheduler
#   placement moves into Tool.schedule (Hooks.tool_schedule stays as a
#   compatibility alias). MASC reads invocations through the
#   Tool.Invocation accessors (tool_use_id/turn/planned_index), which
#   survive the cut; hook-payload consumers are re-verified by CI.
# - Per-endpoint concurrent dispatch admission (oas#2641): fair FIFO
#   Slot_scheduler gated by Provider_config.max_concurrent_requests
#   (default None = unbounded, opt-in per provider) — the typed
#   backpressure primitive for the ollama.com concurrency contract.
# - Retry-After and rate-limit prose carried through typed provider
#   errors (oas#2644).
# The reachability guard in check-oas-pin.sh tracks main; oas-drift-check.sh
# reports the public-surface delta at pin-bump time.
readonly OAS_AGENT_SDK_TRACK_REF="main"
readonly OAS_AGENT_SDK_SHA="20865f7b3dde870bf322b092854496ee79b2cd78"
readonly OAS_AGENT_SDK_MIN_VERSION="0.216.0"
