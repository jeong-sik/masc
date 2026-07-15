#!/usr/bin/env bash

readonly OAS_AGENT_SDK_URL="https://github.com/jeong-sik/oas.git"
readonly OAS_AGENT_SDK_BASE_VERSION="v0.212.1"
# Pinned to the v0.212.1 release (tracks main). On top of the 0.212.0
# hard-cut (implicit lifecycle ceilings, approval/governance orchestration,
# ambient catalog bootstrap removed; embedded model catalog; typed
# provider/pricing contracts; cooperative tool-boundary yield), this release
# adds the deployment catalog overlay: Model_catalog.merge +
# set_global_overlay (embedded catalog + deployment delta rows) and
# alias-canonicalized provider lookup (RFC-OAS-036), consumed by masc's
# config-root oas-models-overlay.toml wiring (RFC-0342 D1). It also
# reconciles the GLM reasoning-replay test fixtures with the typed
# provenance contract. The reachability guard in check-oas-pin.sh tracks
# main; oas-drift-check.sh reports the public-surface delta at pin-bump
# time.
readonly OAS_AGENT_SDK_TRACK_REF="main"
readonly OAS_AGENT_SDK_SHA="7e7b1e703a5fa2e8a8e504b5eb8a96d0290ad164"
readonly OAS_AGENT_SDK_MIN_VERSION="0.212.1"
