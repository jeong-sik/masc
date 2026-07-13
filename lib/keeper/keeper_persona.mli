(** Keeper_persona — persona list and persona-backed keeper creation handlers. *)

type tool_result = Keeper_types_profile.tool_result

val handle_persona_list :
  _ Keeper_types_profile.context -> Yojson.Safe.t -> tool_result

val persona_list_handler : Yojson.Safe.t -> tool_result

(** Create a keeper from a persona definition. Honors a [dry_run] arg
    that returns a preview without invoking [handle_keeper_up]. *)
val handle_keeper_create_from_persona :
  _ Keeper_types_profile.context -> Yojson.Safe.t -> tool_result
