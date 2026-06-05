(** Persona authoring tools.

    The existing persona loader is the source of truth for how [profile.json]
    turns into keeper defaults. This module exposes that shape explicitly and
    keeps writes constrained to the resolved personas root. *)

type save_result =
  { handle : string
  ; personas_root : string
  ; profile_path : string
  ; profile : Yojson.Safe.t
  ; warnings : string list
  }

type archetype_axes =
  { alignment : string option
  ; risk_posture : string option
  }

type field_catalog_entry =
  { path : string
  ; typ : string
  ; required : bool
  ; default : Yojson.Safe.t option
  ; choices : Yojson.Safe.t option
  ; field_effect : string
  }

val field_catalog_entries : field_catalog_entry list
val field_catalog_json : unit -> Yojson.Safe.t
val keeper_field_prefix : string
val keeper_field_name_of_catalog_path : string -> string option
val allowed_keeper_fields : string list
val schema_json : ?include_examples:bool -> unit -> Yojson.Safe.t

val handle_persona_schema :
  _ Keeper_types_profile.context -> Yojson.Safe.t -> Keeper_types_profile.tool_result

val handle_persona_schema_no_ctx :
  Yojson.Safe.t -> Keeper_types_profile.tool_result

val normalize_profile :
  handle:string -> Yojson.Safe.t -> (Yojson.Safe.t, string) result

val save_persona :
  ?overwrite:bool ->
  ?dry_run:bool ->
  handle:string ->
  Yojson.Safe.t ->
  (save_result, string) result

val save_result_to_json : ?dry_run:bool -> save_result -> Yojson.Safe.t

val handle_persona_save :
  _ Keeper_types_profile.context -> Yojson.Safe.t -> Keeper_types_profile.tool_result

val handle_persona_save_no_ctx : Yojson.Safe.t -> Keeper_types_profile.tool_result
val selected_archetype_axes_from_args :
  Yojson.Safe.t -> (archetype_axes, string) result

val archetype_axes_to_json : archetype_axes -> Yojson.Safe.t
val selected_archetype_effects_to_json : archetype_axes -> Yojson.Safe.t
