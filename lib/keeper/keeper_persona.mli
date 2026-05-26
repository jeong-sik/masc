(** Keeper_persona — persona list and persona-backed keeper creation handlers. *)

type tool_result = Keeper_types.tool_result

val handle_persona_list :
  _ Keeper_types.context -> Yojson.Safe.t -> tool_result

val handle_persona_schema :
  _ Keeper_types.context -> Yojson.Safe.t -> tool_result

val handle_persona_generate :
  _ Keeper_types.context -> Yojson.Safe.t -> tool_result

val handle_persona_save :
  _ Keeper_types.context -> Yojson.Safe.t -> tool_result

(** RFC-0182 §3.1 — ctx-free entry points for the persona dispatch
    ref.  [Tool_keeper] registers these into [Persona_dispatch_ref]
    at module load so [Agent_tool_in_process_runtime] (compiled
    early) can reach the persona surface without a static import that
    closes a cycle through [Keeper_turn_driver]. *)
val persona_list_handler : Yojson.Safe.t -> tool_result
val persona_schema_handler : Yojson.Safe.t -> tool_result
val persona_save_handler : Yojson.Safe.t -> tool_result

(** Create a keeper from a persona definition. Honors a [dry_run] arg
    that returns a preview without invoking [handle_keeper_up]. Applies
    per-persona shard configuration after successful creation. *)
val handle_keeper_create_from_persona :
  _ Keeper_types.context -> Yojson.Safe.t -> tool_result
