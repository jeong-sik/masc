(** Keeper_tool_persona_crud — masc_persona_create and masc_persona_update handlers. *)

(** Build the persona [profile.json] payload from create args, in the shape the
    profile loaders read: identity ([name], [role], [trait]) at the top level
    and keeper-template defaults ([goal], [instructions], [mention_targets],
    [proactive_enabled]) nested under ["keeper"]. Exposed for
    round-trip tests that assert the written shape against the loaders. *)
val profile_from_create_args : Yojson.Safe.t -> Yojson.Safe.t

(** Merge update args into an existing profile object, routing each field to
    the same layer its loader reads (identity at the top level, keeper-template
    fields under ["keeper"]). Returns [Error] when the existing profile is not a
    JSON object. Exposed for round-trip tests. *)
val merge_update_args_into_profile :
  Yojson.Safe.t -> Yojson.Safe.t -> (Yojson.Safe.t, string) result

(** Handle a [masc_persona_create] tool call. Validates the create args,
    rejects an existing persona, then writes the new profile. *)
val handle_persona_create :
  _ Keeper_types_profile.context
  -> Yojson.Safe.t
  -> Keeper_types_profile.tool_result

(** Handle a [masc_persona_update] tool call. Requires [persona_name],
    rejects an unknown persona, then merges the update args into the
    existing profile. *)
val handle_persona_update :
  _ Keeper_types_profile.context
  -> Yojson.Safe.t
  -> Keeper_types_profile.tool_result

(** Handle a [masc_persona_delete] tool call. Requires [persona_name], rejects
    an unknown persona, then removes the persona directory (profile.json plus
    any sibling files) via {!Fs_compat.remove_tree}. *)
val handle_persona_delete :
  _ Keeper_types_profile.context
  -> Yojson.Safe.t
  -> Keeper_types_profile.tool_result

(** [masc_persona_delete] body operating on raw JSON args, resolving the persona
    location from MASC_PERSONAS_DIR. Returns a JSON object carrying an ["error"]
    field on failure. Exposed for round-trip tests. *)
val handle_persona_delete_json : Yojson.Safe.t -> Yojson.Safe.t
