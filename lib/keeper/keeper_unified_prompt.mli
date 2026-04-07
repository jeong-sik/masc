(** Keeper_unified_prompt — Build a single unified prompt from keeper identity
    and world observation, replacing the per-path prompt builders.

    Sections are conditionally included based on observation state:
    empty mentions/goals/events produce no section, saving tokens.

    @since Unified Keeper Loop *)

(** Build unified system prompt and user message from keeper state.

    Returns [(system_prompt, user_message)] where:
    - [system_prompt] contains keeper identity, instructions, and tools guidance
    - [user_message] contains the current world observation as structured context

    @param meta Keeper metadata (identity, soul, goals, instructions)
    @param observation Current world snapshot *)
val build_prompt :
  meta:Keeper_types.keeper_meta ->
  base_path:string ->
  observation:Keeper_world_observation.world_observation ->
  ?diversity_hint:string ->
  unit ->
  string * string
