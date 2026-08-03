(** Keeper_unified_prompt — Build a single unified prompt from keeper identity
    and world observation.

    Only reactive triggers and resource state are included in the user message;
    runtime telemetry remains on the decision-audit path.

    @since Unified Keeper Loop *)

(** Three-channel turn prompt. The observation frame is separated from the
    persisted user message so it can be injected per-turn (via
    [dynamic_context]) instead of accumulating in the OAS conversation.

    Feedback-loop invariant (#25193, RFC PR #25246, operator decision
    2026-07-20): [world_state] must never be persisted as a conversation
    message. A live audit found 943/945 user messages in one keeper's
    checkpoint were byte-identical world-state frames (59% of payload),
    which starved compaction and re-fed the model its own observations. *)
type turn_prompt_parts = {
  system_prompt : string;
      (** Keeper identity, instructions, and turn intent. Stable across
          turns of a generation. *)
  world_state : string;
      (** The "## Current World State" observation frame, rebuilt fresh
          every turn. Inject as per-turn [dynamic_context]; never append
          to the persisted message history. *)
  user_message : string;
      (** Persisted user-turn content: genuine utterances only. For
          autonomous wake turns this is {!autonomous_wake_marker}; HITL
          resolutions are appended by the turn driver. *)
}

val autonomous_wake_marker : string
(** Persisted user-turn content for autonomous wake turns. Constant and
    tiny by design: the observation frame lives in
    {!turn_prompt_parts.world_state}, not in the message history. *)

val format_current_task : Masc_domain.task -> string
(** Render one held task as per-turn observation context. The direct-message
    lane reuses this renderer so it sees the same task identity, status, and
    handoff as an autonomous wake without persisting that context. *)

val effective_instructions :
  meta:Keeper_meta_contract.keeper_meta ->
  ?profile_defaults:Keeper_types_profile.keeper_profile_defaults ->
  unit ->
  string
(** Resolve the single instructions value used by every system-prompt
    entrypoint and its dashboard projection. *)

val active_goal_summaries :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  (string * string) list
(** Resolve every active goal id for the stable prompt contract. Unknown ids
    remain present with an empty title so every entrypoint renders the same
    bare-id fallback. *)

val build_system_prompt :
  meta:Keeper_meta_contract.keeper_meta ->
  config:Workspace.config ->
  ?profile_defaults:Keeper_types_profile.keeper_profile_defaults ->
  ?active_goal_summaries:(string * string) list ->
  unit ->
  string
(** Build the model-facing stable Keeper contract shared by direct and
    autonomous turns. Channel-specific input belongs in dynamic context or the
    persisted user message, not in a second system-prompt implementation. *)

(** Build the three-channel unified prompt from keeper state.

    @param meta Keeper metadata (identity, soul, goals, instructions)
    @param observation Current world snapshot *)
val build_prompt :
  meta:Keeper_meta_contract.keeper_meta ->
  config:Workspace.config ->
  ?profile_defaults:Keeper_types_profile.keeper_profile_defaults ->
  turn_decision:Keeper_world_observation.keeper_cycle_decision ->
  ?current_task:Masc_domain.task ->
  ?active_goal_summaries:(string * string) list ->
  observation:Keeper_world_observation.world_observation ->
  unit ->
  turn_prompt_parts
(** When [?profile_defaults] is omitted, [instructions] falls back to
    [meta.instructions]. Production hot path supplies profile defaults;
    tests can keep the bare call.

    RFC-0315 wake-turn self-description:
    - [turn_decision]: the scheduler's actual cycle decision, required so the
      rendered wake reason matches the decision that fired the turn.
    - [?current_task]: renders a "Current Task" layer for the task the keeper
      holds ([meta.current_task_id] admits scheduled-autonomous turns, so the
      turn must see the work that admitted it). Omitted: layer absent.
    - [?active_goal_summaries]: renders goal titles next to ids in the Active
      Goals layer. Omitted or empty: bare ids. *)

val build_prompt_preview :
  meta:Keeper_meta_contract.keeper_meta ->
  config:Workspace.config ->
  ?profile_defaults:Keeper_types_profile.keeper_profile_defaults ->
  ?current_task:Masc_domain.task ->
  ?active_goal_summaries:(string * string) list ->
  observation:Keeper_world_observation.world_observation ->
  unit ->
  turn_prompt_parts
(** Build a dashboard preview from current state without inventing a scheduler
    decision. Scheduler wake reasons are absent because no turn fired. *)
