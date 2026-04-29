(** Persona authoring tools.

    The existing persona loader is the source of truth for how
    profile.json turns into keeper defaults. This module exposes
    that shape explicitly and keeps writes constrained to the
    resolved personas root.

    Selective .mli surface — internal helpers
    (assoc_*, normalize_*, add_optional_*, ensure_personas_root,
    handle_from_concept, generation_prompt, etc.) stay private. *)

module Archetypes = Keeper_persona_authoring_contract

(** Return value of [save_persona] — points to the persisted
    profile.json on disk plus optional warnings. *)
type save_result =
  { handle : string
  ; personas_root : string
  ; profile_path : string
  ; profile : Yojson.Safe.t
  ; warnings : string list
  }

(** Selected archetype axis values extracted from tool arguments. *)
type archetype_axes =
  { alignment : string option
  ; risk_posture : string option
  }

(** {1 Persona schema (catalog + JSON projection)} *)

(** A single keeper-field entry in the persona schema catalog. *)
type field_catalog_entry =
  { path : string
  ; typ : string
  ; required : bool
  ; default : Yojson.Safe.t option
  ; choices : Yojson.Safe.t option
  ; field_effect : string
  }

(** Full catalog of every keeper field that the persona save
    pipeline accepts. *)
val field_catalog_entries : field_catalog_entry list

(** Render the catalog as a JSON document for the dashboard. *)
val field_catalog_json : unit -> Yojson.Safe.t

(** Catalog-path prefix shared by every keeper field
    ([keeper.<field>]). *)
val keeper_field_prefix : string

(** Strip [keeper_field_prefix] from a catalog path; returns
    [None] when [path] does not start with the prefix. *)
val keeper_field_name_of_catalog_path : string -> string option

(** Set of allowed keeper field names derived from
    [field_catalog_entries]. *)
val allowed_keeper_fields : string list

(** Render the complete persona schema (top-level fields + keeper
    sub-tree + archetype axes). [include_examples] flips whether
    LLM-prompt example payloads are appended. *)
val schema_json : ?include_examples:bool -> unit -> Yojson.Safe.t

(** Tool-handler entry for [keeper_persona_schema]. *)
val handle_persona_schema :
  _ Keeper_types.context -> Yojson.Safe.t -> bool * string

(** {1 Persona save / normalize} *)

(** Normalize a raw profile JSON for [handle]; rejects invalid
    handle names and surfaces structural errors. *)
val normalize_profile :
  handle:string ->
  Yojson.Safe.t ->
  (Yojson.Safe.t, string) result

(** Persist [profile] to the resolved personas root.
    [overwrite=false] (default) errors when the target file
    already exists; [dry_run=true] returns the [save_result]
    without touching disk. *)
val save_persona :
  ?overwrite:bool ->
  ?dry_run:bool ->
  handle:string ->
  Yojson.Safe.t ->
  (save_result, string) result

(** Render a [save_result] as the canonical save-tool JSON
    response, including a follow-up [keeper_create_preview_args]
    hint for the LLM. *)
val save_result_to_json :
  ?dry_run:bool -> save_result -> Yojson.Safe.t

(** Tool-handler entry for [keeper_persona_save]. *)
val handle_persona_save :
  _ Keeper_types.context -> Yojson.Safe.t -> bool * string

(** {1 Persona generation (LLM-assisted)} *)

(** Project archetype-axes args to the [archetype_axes] record;
    rejects unknown choice values. *)
val selected_archetype_axes_from_args :
  Yojson.Safe.t -> (archetype_axes, string) result

val archetype_axes_to_json : archetype_axes -> Yojson.Safe.t

(** Render the per-axis "selected effect" JSON entries for the
    chosen archetype values. *)
val selected_archetype_effects_to_json :
  archetype_axes -> Yojson.Safe.t

(** Tool-handler entry for [keeper_persona_generate]. *)
val handle_persona_generate :
  _ Keeper_types.context -> Yojson.Safe.t -> bool * string
