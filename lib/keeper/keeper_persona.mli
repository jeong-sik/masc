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

(** Create a keeper from a persona definition. Honors a [dry_run] arg
    that returns a preview without invoking [handle_keeper_up]. Applies
    per-persona shard configuration after successful creation. *)
val handle_keeper_create_from_persona :
  _ Keeper_types.context -> Yojson.Safe.t -> tool_result
