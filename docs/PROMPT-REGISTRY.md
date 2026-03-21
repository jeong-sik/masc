# Prompt Registry

This file is the discoverability index for prompt-bearing code in MASC.

Scope:
- Includes LLM-facing prompt builders and one deterministic compaction summary template that behaves like a prompt surface.
- Does not extract prompts into external files. Most of these builders rely on `Printf.sprintf`/structured OCaml assembly, which preserves compile-time format checking.
- Excludes adjacent helpers that do not construct prompt text directly, such as response parsers, report renderers, and metrics formatters.

## Registry

| Area | File | Function | Lines | Kind | Purpose | Primary inputs |
| --- | --- | --- | --- | --- | --- | --- |
| Keeper identity | `lib/keeper/keeper_prompt.ml` | `build_keeper_system_prompt` | `41-143` | System prompt | Builds the resident keeper identity/worldview prompt with goal horizons and self-model traits. | `goal`, `short_goal`, `mid_goal`, `long_goal`, `soul_profile`, `will`, `needs`, `desires`, `instructions` |
| Keeper proactive | `lib/keeper/keeper_prompt.ml` | `proactive_prompt_for_keeper` | `269-310` | Turn prompt | Drives autonomous proactive turns with continuity state, recent preview avoidance, and strict one-line output formatting. | `meta`, `idle_seconds`, `snapshot`, `continuity_summary` |
| Keeper proactive | `lib/keeper/keeper_prompt.ml` | `proactive_retry_instruction` | `323-330` | Retry suffix | Adds retry-specific steering when proactive generation must be retried. | `attempt`, `reason` |
| Keeper unified | `lib/keeper/keeper_unified_prompt.ml` | `build_prompt` | `29-144` | System + user message pair | Builds the unified keeper prompt pair: identity/system prompt plus structured current-world-state user message. | `meta`, `observation` |
| Keeper deliberation | `lib/keeper/keeper_deliberation.ml` | `build_deliberation_prompt` | `359-408` | Decision prompt | Asks the model to choose exactly one keeper action and emit strict JSON. | `keeper_name`, `soul_profile`, `goal`, `triggers`, `obs` |
| Chain design | `lib/chain/chain_composer.ml` | `build_design_context` | `103-189` | Planning prompt | Requests a chain/graph design from a goal and optional predefined tasks, with Mermaid/JSON output rules. | `goal`, `tasks` |
| Chain verification | `lib/chain/chain_composer.ml` | `build_verification_prompt` | `192-194` | Alias | Thin alias kept in composer for discoverability; delegates to `Chain_evaluator.build_verification_context`. | `goal`, `metrics` |
| Chain replanning | `lib/chain/chain_composer.ml` | `build_replan_context` | `197-260` | Re-plan prompt | Requests a replacement chain after failure, timeout pressure, or context change while preserving successful work. | `goal`, `original_chain`, `reason`, `metrics` |
| Chain verification | `lib/chain/chain_evaluator.ml` | `build_verification_context` | `281-336` | Evaluation prompt | Builds the goal-achievement verification context used by the composer/model verification step. | `goal`, `metrics` |
| Auto responder | `lib/auto_responder.ml` | `build_response_prompt` | `90-104` | Instruction prompt | Instructs lightweight auto-responders how to join, broadcast with the assigned nickname, and leave. | `from_agent`, `content`, `mention` |
| Reflection | `lib/reflection.ml` | `reflect` | `81-104` | Reflection prompt | Builds the self-reflection prompt for concise Korean insight generation. | `agent_name`, `identity`, memory placeholder |
| Context compaction | `lib/context_compact_oas.ml` | `SummarizeOld.summarizer` inside `oas_strategy_of` | `60-94` | Deterministic summary template | Produces extractive summaries for older messages without a model call; still worth indexing because it defines prompt-like summary wording. | `old_msgs` |

## Notes

- `build_verification_prompt` in `chain_composer.ml` is intentionally listed even though it is an alias. People usually grep the composer first when tracing chain orchestration.
- `build_prompt` in `keeper_unified_prompt.ml` returns a tuple: the first string is the system prompt, the second is the structured user/world-state message.
- `context_compact_oas.ml` is not an LLM prompt file, but its `SummarizeOld` closure defines a stable summary surface (`[Compacted N messages into summary]`) that affects model inputs downstream.

## Not Included

These are adjacent but intentionally out of scope for this registry:
- `lib/chain/chain_evaluator.ml:479+` `generate_report` — human-readable report, not model input
- `lib/keeper/keeper_deliberation.ml:415+` response parsing/extraction helpers
- `lib/keeper/keeper_prompt.ml` state snapshot formatting helpers used as prompt ingredients rather than standalone prompt definitions
