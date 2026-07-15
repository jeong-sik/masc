(** Keeper_unified_prompt — Build a single unified prompt from keeper identity
    and world observation.

    Only reactive triggers and resource state are included in the user message;
    runtime telemetry remains on the decision-audit path.

    @since Unified Keeper Loop *)

val format_board_event_text : Keeper_world_observation.pending_board_event -> string
(** Render a single pending board event as its prompt line. Exposed for tests:
    RFC-0320 W3(a) verifies that an [External_attention] event steers the woken
    keeper to reply into the originating conversation via keeper_surface_post. *)

(** Build unified system prompt and user message from keeper state.

    Returns [(system_prompt, user_message)] where:
    - [system_prompt] contains keeper identity, instructions, and turn intent
    - [user_message] contains reactive triggers + resource state only

    @param meta Keeper metadata (identity and instructions)
    @param observation Current world snapshot *)
val build_prompt :
  meta:Keeper_meta_contract.keeper_meta ->
  base_path:string ->
  ?profile_defaults:Keeper_types_profile.keeper_profile_defaults ->
  ?turn_decision:Keeper_world_observation.keeper_cycle_decision ->
  ?current_task:Masc_domain.task ->
  observation:Keeper_world_observation.world_observation ->
  unit ->
  string * string
(** When [?profile_defaults] is omitted, [instructions] falls back to
    [meta.instructions]. Production hot path supplies profile defaults;
    tests can keep the bare call.

    RFC-0315 wake-turn self-description:
    - [?turn_decision]: the scheduler's actual cycle decision. When present it
      replaces the internal recompute, so the rendered wake reason matches the
      decision that fired the turn (the recompute cannot see [reactive_wake]
      or drained event-queue triggers). Omitted: legacy recompute.
    - [?current_task]: renders a "Current Task" layer for the task the keeper
      holds ([meta.current_task_id] admits scheduled-autonomous turns, so the
      turn must see the work that admitted it). Omitted: layer absent. *)
