#!/usr/bin/env bash

readonly OAS_AGENT_SDK_URL="https://github.com/jeong-sik/oas.git"
readonly OAS_AGENT_SDK_BASE_VERSION="v0.212.0"
# Pinned to the v0.212.0 release (tracks main). This breaking release removes
# implicit lifecycle ceilings, approval/governance orchestration, automatic
# retry and context rewriting, tool filtering/disclosure aliases, runtime
# control messages, and ambient catalog bootstrap. It embeds the model catalog,
# preserves exact typed provider/pricing contracts, and adds cooperative
# tool-boundary yield. MASC owns compaction, recovery, gates, and scheduling;
# OAS remains independent of MASC. The reachability guard in check-oas-pin.sh
# tracks main; oas-drift-check.sh reports the public-surface delta at pin-bump
# time.
readonly OAS_AGENT_SDK_TRACK_REF="main"
readonly OAS_AGENT_SDK_SHA="b02bc16f57b18542abae17023e1a2b886cda7347"
readonly OAS_AGENT_SDK_MIN_VERSION="0.212.0"
