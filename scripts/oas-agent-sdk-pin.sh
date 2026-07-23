#!/usr/bin/env bash

readonly OAS_AGENT_SDK_URL="https://github.com/jeong-sik/oas.git"
readonly OAS_AGENT_SDK_BASE_VERSION="v0.220.5"
# Pinned to the v0.219.0 release (tracks main). On top of 0.217.4:
# - 0.219.0 (breaking, dead-surface retirement): the legacy
#   Api/Api_openai/Api_anthropic/Api_common/Streaming/Provider_intf dispatch
#   island and the test-only agent_sdk re-export surface (Subagent,
#   Cost_tracker, Guardrail_llm/tripwire, eval/harness family, runtime
#   replay/sync/projection cluster, ...) are deleted (oas#2735/#2738 plus the
#   parallel #2689/#2690/#2737 train). masc impact: exactly two call sites
#   (keeper_context_core_message_json.ml) re-pointed from Agent_sdk.Api to
#   Agent_sdk.Llm_provider.Api_common, same functions. Handoff is exported
#   directly. 0.218.0 carried the eval/runtime purges and TTFT/lifecycle
#   fixes from the 07-20/21 merge train.
# Previous pin (v0.217.4): On top of 0.217.3:
# - 0.217.4 (dangling tool_use prevention): a provider that emits complete
#   tool_use blocks but labels the turn finish_reason=stop/end_turn (EndTurn) is
#   reconciled to StopToolUse so the driver executes the tools instead of ending
#   the turn with dangling tool_uses (tool_use with no tool_result). Fixes both
#   the streaming chain (Stop_reason_wire.reconcile) and the non-streaming
#   OpenAI parser (of_finish); MaxTokens+blocks stays MaxTokens (truncation may
#   be incomplete) (oas#2728). Dangling tool_use is the upstream root of
#   Keeper_compaction_unit.Overlapping_tool_cycle compaction rejection (masc
#   Layer 2), so this pin makes new keeper turns stop producing the structure
#   that blocks compaction. Also: legacy openai body path rejects unencoded
#   explicit thinking (oas#2720, follows oas#2716). refactor! dropped the
#   unused public symbols Pending_input_updated and with_backtrace (oas#2726) —
#   verified inert on masc (0 references in lib/ test/; oas-drift-check surface
#   delta reviewed at pin-bump).
# On top of 0.217.1:
# - 0.217.2: reasoning_replay_dropped logs at Info, not Warn (oas#2721).
# - 0.217.3 (behavioral hard-cut): Ollama native tool-loop replay/correlation
#   is projected through an immutable occurrence-scoped Tool_result_projection;
#   legacy User-role ToolResult and uncorrelated tool messages are rejected
#   typed (AcceptRejected) on Gemini/Ollama-native instead of silently repaired
#   (oas#2710, supersedes oas#2711). Live checkpoint audit 2026-07-20: 24/24
#   primary checkpoints carry zero legacy shapes, so the cut is inert on the
#   current fleet. Durable Error_occurred error_domain is classified from the
#   error, not hardcoded "Api" (oas#2717).
# On top of 0.216.5:
# - 0.216.6/0.216.7: Kimi native token-count admission (oas#2705), projected
#   provider input as the admission SSOT (oas#2707), exact provider turn
#   identity shared with execution (oas#2709).
# - 0.217.0 (breaking): streaming rejects malformed tool-call batches
#   whole-batch instead of executing a partial subset (oas#2702).
# - Resume is total over crash-reachable journal states: a settled turn after
#   a partial-close crash resumes instead of aborting Failed (oas#2713), and
#   resume matches the run's original prompt rather than the latest injected
#   User message (oas#2715, 0.217.1).
# - Overflow wire finish_reason decodes into the typed classifier (oas#2703);
#   non-finite/negative retry_after rejected at the parse boundary (oas#2708);
#   admission-conflict warnings sanitize base_url credentials (oas#2706).
# - Explicit enable_thinking that the provider dialect cannot encode is now
#   AcceptRejected instead of silently dropped (oas#2716). MASC-side prep:
#   ollama_cloud /v1 rows (kimi-k2.6, minimax-m3, deepseek-v4-pro) declare
#   thinking_control_format="none" + supports_reasoning=true in the runtime
#   oas-models-overlay.toml (2026-07-20 flip-risk audit).
# MASC consumes only the public Agent SDK contract; Keeper, Gate, Board, and
# product operation ownership remain MASC concepts.
# The reachability guard in check-oas-pin.sh tracks main; oas-drift-check.sh
# reports the public-surface delta at pin-bump time.
# Pinned to main (5851df2e). Absorbs oas#2773 & oas#2775: release v0.220.5 restoring
# the exact-output public compile (resolver_endpoint_error ml/mli parity, oas#2774).
readonly OAS_AGENT_SDK_DECLARED_VERSION="0.220.5"
# TRACK_REF consumed by check-oas-pin.sh / oas-drift-check.sh /
# sync-oas-pin-docs.sh; removed by #25579 and restored here (#25584).
readonly OAS_AGENT_SDK_TRACK_REF="main"
readonly OAS_AGENT_SDK_SHA="5851df2e276872d640769813f2000642f7bd56d3"
readonly OAS_AGENT_SDK_MIN_VERSION="0.220.5"
