(** Keeper_unified_prompt — Build a single unified prompt from keeper identity
    and world observation.

    Only reactive triggers and resource state are included in the user message.
    Metacognition sections (tool activity, cycle outcome, diversity, behavioral
    stats) removed in #6814; telemetry preserved via decision_audit.

    @since Unified Keeper Loop *)

val state_block_instruction_text : string
(** Generic STATE formatting instruction for normal keeper turns. Turn-level
    output guards can override this when continuity is runtime-managed. *)

(** Build unified system prompt and user message from keeper state.

    Returns [(system_prompt, user_message)] where:
    - [system_prompt] contains keeper identity, instructions, and turn intent
    - [user_message] contains reactive triggers + resource state only

    @param meta Keeper metadata (identity, soul, goals, instructions)
    @param observation Current world snapshot *)
val build_prompt :
  meta:Keeper_meta_contract.keeper_meta ->
  base_path:string ->
  ?profile_defaults:Keeper_types_profile.keeper_profile_defaults ->
  ?turn_decision:Keeper_world_observation.keeper_cycle_decision ->
  ?current_task:Masc_domain.task ->
  ?active_goal_summaries:(string * string) list ->
  ?active_open_loops:Keeper_working_state.loop list ->
  observation:Keeper_world_observation.world_observation ->
  unit ->
  string * string
(** When [?profile_defaults] is omitted, personality fields fall back to
    [meta.{will,needs,desires,instructions}] directly (legacy behavior).
    Production hot path supplies it; tests can keep the bare call.

    RFC-0315 wake-turn self-description:
    - [?turn_decision]: the scheduler's actual cycle decision. When present it
      replaces the internal recompute, so the rendered wake reason matches the
      decision that fired the turn (the recompute cannot see [reactive_wake]
      or drained event-queue triggers). Omitted: legacy recompute.
    - [?current_task]: renders a "Current Task" layer for the task the keeper
      holds ([meta.current_task_id] admits scheduled-autonomous turns, so the
      turn must see the work that admitted it). Omitted: layer absent.
    - [?active_goal_summaries]: renders goal titles next to ids in the Active
      Goals layer. Omitted or empty: bare ids (legacy).
    - [?active_open_loops]: renders an "Open Loops" layer for unresolved
      working-state ledger entries (the keeper's own prior [STATE]
      obligations restored from the sidecar). Omitted or empty: layer
      absent. *)
