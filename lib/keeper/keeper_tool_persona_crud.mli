(** Keeper_tool_persona_crud — masc_persona_create and masc_persona_update handlers. *)

type tool_result = Keeper_types_profile.tool_result

(** Handle a [masc_persona_create] tool call. Validates the create args,
    rejects an existing persona, then writes the new profile. *)
val handle_persona_create :
  _ Keeper_types_profile.context -> Yojson.Safe.t -> tool_result

(** Handle a [masc_persona_update] tool call. Requires [persona_name],
    rejects an unknown persona, then merges the update args into the
    existing profile. *)
val handle_persona_update :
  _ Keeper_types_profile.context -> Yojson.Safe.t -> tool_result
