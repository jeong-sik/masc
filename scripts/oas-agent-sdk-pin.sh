#!/usr/bin/env bash

readonly OAS_AGENT_SDK_URL="https://github.com/jeong-sik/oas.git"
readonly OAS_AGENT_SDK_BASE_VERSION="v0.215.0"
# Pinned to the v0.215.0 release (tracks main). On top of 0.214.1, the
# 0.215.0 release adds:
# - BREAKING (oas#2631): Tool.handler_kind gains a third constructor
#   [WithExecutionEnv of execution_env_tool_handler]; Tool.execute gains an
#   optional [?invocation] parameter; new [Tool.Invocation] /
#   [Tool.Execution_env] modules carry exact turn/planned_index-scoped
#   tool_use_id occurrence metadata. masc's imported surface is untouched:
#   no masc code matches on [handler_kind] or constructs handlers beyond
#   [create]/[create_with_context] (audited 2026-07-17, zero call sites).
# - oas#2637: execution journal binds recursive work to exact tool attempts
#   (Execution_event_store / Execution_journal API changes). masc consumes
#   neither module (zero references).
# The reachability guard in check-oas-pin.sh tracks main; oas-drift-check.sh
# reports the public-surface delta at pin-bump time.
readonly OAS_AGENT_SDK_TRACK_REF="main"
readonly OAS_AGENT_SDK_SHA="a7ea83fbbfeb8ff0b79b13f911c134be3895270a"
readonly OAS_AGENT_SDK_MIN_VERSION="0.215.0"
