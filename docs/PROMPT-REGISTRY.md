# Prompt Registry

This file is the discoverability index for prompt-bearing code in MASC.

Scope:
- Includes LLM-facing prompt builders and one deterministic compaction summary template that behaves like a prompt surface.
- Core operator-managed prompts now live in `config/prompts/*.md` and are loaded through `Prompt_registry`.
- OCaml prompt builders remain responsible for assembling structured runtime inputs and placeholder values.
- Excludes adjacent helpers that do not construct prompt text directly, such as response parsers, report renderers, and metrics formatters.

## Registry

| Area | File | Function | Lines | Kind | Purpose | Primary inputs |
| --- | --- | --- | --- | --- | --- | --- |
| Keeper identity | `lib/keeper/keeper_prompt.ml` | `build_keeper_system_prompt` | `41-143` | System prompt | Builds the resident keeper identity/worldview prompt with goal horizons and self-model traits. | `goal`, `short_goal`, `mid_goal`, `long_goal`, `soul_profile`, `will`, `needs`, `desires`, `instructions` |
| Keeper constitution | `config/prompts/keeper.constitution.md` | `Prompt_registry.get_prompt` | n/a | Markdown prompt | Continuity and `[STATE]` block rules for keeper replies. | none |
| Keeper world | `config/prompts/keeper.world.md` | `Prompt_registry.get_prompt` | n/a | Markdown prompt | Shared keeper world context block. | none |
| Keeper capabilities | `config/prompts/keeper.capabilities.md` | `Prompt_registry.get_prompt` | n/a | Markdown prompt | Shared keeper capabilities block. | none |
| Keeper proactive | `config/prompts/keeper.proactive_turn.md` | `lib/keeper/keeper_prompt.ml` `proactive_prompt_for_keeper` | runtime render | Markdown template | Drives autonomous proactive turns with continuity state and output constraints. | `idle_seconds`, `profile`, `goal`, `last_preview`, `continuity_snapshot`, `seed` |
| Keeper proactive | `config/prompts/keeper.proactive_retry.md` | `lib/keeper/keeper_prompt.ml` `proactive_retry_instruction` | runtime render | Markdown template | Adds retry-specific steering when proactive generation must be retried. | `attempt_phrase`, `reason`, `directive` |
| Keeper unified | `config/prompts/keeper.unified.system.md` | `lib/keeper/keeper_unified_prompt.ml` `build_prompt` | runtime render | Markdown template | Builds the unified keeper system prompt around structured world-state input. | `identity_header`, `trait_lines`, `instructions_block`, `goal_lines` |
| Keeper deliberation | `config/prompts/keeper.deliberation.md` | `lib/keeper/keeper_deliberation.ml` `build_deliberation_prompt` | runtime render | Markdown template | Asks the model to choose exactly one keeper action and emit strict JSON. | `keeper_name`, `soul_profile`, `goal`, `triggers`, `world_state`, `multi_step_line`, `multi_step_example` |
| Dashboard operator judge | `config/prompts/dashboard.operator_judge.md` | `lib/dashboard/dashboard_operator_judge.ml` `prompt_for_facts` | runtime render | Markdown template | Produces strict JSON judgments for room/session operator actions. | `facts_json` |
| Dashboard governance judge | `config/prompts/dashboard.governance_judge.md` | `lib/dashboard/dashboard_governance_judge.ml` `prompt_for_facts` | runtime render | Markdown template | Produces strict JSON judgments for governance actions in the dashboard. | `facts_json` |
| Governance deliberation | `config/prompts/governance.deliberation.md` | `Prompt_registry.get_prompt` | n/a | Markdown prompt | Governance deliberation agent system prompt. | none |
| Governance dry run | `config/prompts/governance.dry_run.md` | `Prompt_registry.get_prompt` | n/a | Markdown prompt | Governance dry-run analysis agent system prompt. | none |
| Chain design | `lib/chain/chain_composer.ml` | `build_design_context` | `103-189` | Planning prompt | Requests a chain/graph design from a goal and optional predefined tasks, with Mermaid/JSON output rules. | `goal`, `tasks` |
| Chain verification | `lib/chain/chain_composer.ml` | `build_verification_prompt` | `192-194` | Alias | Thin alias kept in composer for discoverability; delegates to `Chain_evaluator.build_verification_context`. | `goal`, `metrics` |
| Chain replanning | `lib/chain/chain_composer.ml` | `build_replan_context` | `197-260` | Re-plan prompt | Requests a replacement chain after failure, timeout pressure, or context change while preserving successful work. | `goal`, `original_chain`, `reason`, `metrics` |
| Chain verification | `lib/chain/chain_evaluator.ml` | `build_verification_context` | `281-336` | Evaluation prompt | Builds the goal-achievement verification context used by the composer/model verification step. | `goal`, `metrics` |
| Auto responder | `lib/auto_responder.ml` | `build_response_prompt` | `90-104` | Instruction prompt | Instructs lightweight auto-responders how to join, broadcast with the assigned nickname, and leave. | `from_agent`, `content`, `mention` |
| Reflection | `lib/reflection.ml` | `reflect` | `81-104` | Reflection prompt | Builds the self-reflection prompt for concise Korean insight generation. | `agent_name`, `identity`, memory placeholder |
| Context compaction | `lib/context_compact_oas.ml` | `SummarizeOld.summarizer` inside `oas_strategy_of` | `60-94` | Deterministic summary template | Produces extractive summaries for older messages without a model call; still worth indexing because it defines prompt-like summary wording. | `old_msgs` |

## Notes

- Dashboard `Lab > Tools > Prompt Registry` shows effective prompt text, file baseline, and runtime overrides.
- Runtime override persistence lives in `.masc/prompt_overrides.json`.
- `build_verification_prompt` in `chain_composer.ml` is intentionally listed even though it is an alias. People usually grep the composer first when tracing chain orchestration.
- `build_prompt` in `keeper_unified_prompt.ml` returns a tuple: the first string is the system prompt, the second is the structured user/world-state message.
- `context_compact_oas.ml` is not an LLM prompt file, but its `SummarizeOld` closure defines a stable summary surface (`[Compacted N messages into summary]`) that affects model inputs downstream.

## Not Included

These are adjacent but intentionally out of scope for this registry:
- `lib/chain/chain_evaluator.ml:479+` `generate_report` — human-readable report, not model input
- `lib/keeper/keeper_deliberation.ml:415+` response parsing/extraction helpers
- `lib/keeper/keeper_prompt.ml` state snapshot formatting helpers used as prompt ingredients rather than standalone prompt definitions
