(** Keeper_unified_prompt — Build a single unified prompt from keeper identity
    and world observation.

    Only reactive triggers and resource state are included in the user message.
    Metacognition sections (tool activity, cycle outcome, diversity, behavioral
    stats) removed in #6814; telemetry preserved via decision_audit.

    @since Unified Keeper Loop *)

(** Build unified system prompt and user message from keeper state.

    Returns [(system_prompt, user_message)] where:
    - [system_prompt] contains keeper identity, instructions, and turn intent
    - [user_message] contains reactive triggers + resource state only

    @param meta Keeper metadata (identity, soul, goals, instructions)
    @param observation Current world snapshot *)
val build_prompt
  :  meta:Keeper_types.keeper_meta
  -> base_path:string
  -> observation:Keeper_world_observation.world_observation
  -> unit
  -> string * string
