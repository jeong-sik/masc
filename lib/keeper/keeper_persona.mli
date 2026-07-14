(** Keeper_persona — persona list handlers. *)

type tool_result = Keeper_types_profile.tool_result

val handle_persona_list :
  _ Keeper_types_profile.context -> Yojson.Safe.t -> tool_result

val persona_list_handler : Yojson.Safe.t -> tool_result
