(** SKILL.md-backed catalog of Keeper instruction skills.

    {!Agent_core.Skill_document} is the parse authority for one SKILL.md file.
    This module assembles documents into a duplicate-free, name-sorted catalog
    of instruction skills served through {!Keeper_instruction_skill}. *)

type surface =
  | Instruction

type provenance = private
  { identity : Skill_catalog_snapshot.identity
  ; source : Skill_source_config.source
  ; source_root : string option
  ; resource_read_max_bytes : Skill_source_config.resource_read_max_bytes option
  ; directory : string
  }

type skill = private
  { name : string
  ; description : string
  ; body : string
  ; reference : Skill_reference.t option
  ; provenance : provenance option
  ; surface : surface
  }

type t

type error =
  | Definition_rejected of
      { directory : string
      ; diagnostics : Agent_core.Skill_document.diagnostic list
      }
  | Duplicate_skill of { name : string }
  | Body_blank of { skill : string }

type rejected_document = private
  { directory : string
  ; error : error
  }

type projection_diagnostic = private
  { identity : Skill_catalog_snapshot.identity
  ; error : error
  }

type entry_projection =
  | Projected of skill
  | Entry_unavailable of error

type turn_unavailable =
  | Configured_skill_name_unavailable of { name : string }

type configured_name_unavailable = private Configured_name_unavailable of string

type turn_projection = private
  { catalog : t
  ; unavailable : turn_unavailable list
  }

type exact_surface_availability =
  | Instruction_tool
  | Exact_unavailable of { diagnostic : string }

type exact_surface = private
  { reference : Skill_reference.t
  ; availability : exact_surface_availability
  }

val parse_skill : ?descriptors:Keeper_tool_descriptor.t list -> directory:string -> string -> (skill, error) result

type authored_source_error =
  | Source_too_large of { bytes : int; max_bytes : int }
  | Invalid_document of error

val validate_authored_source :
  descriptors:Keeper_tool_descriptor.t list ->
  directory:string -> string -> (skill, authored_source_error) result

val partition_documents :
  (string * string) list -> t * rejected_document list

type prepared

val prepare_snapshot :
  descriptors:Keeper_tool_descriptor.t list -> Skill_catalog_snapshot.t -> prepared
val prepared_matches :
  prepared -> descriptors:Keeper_tool_descriptor.t list -> Skill_catalog_snapshot.t -> bool
val prepared_snapshot : prepared -> Skill_catalog_snapshot.t
val prepared_descriptor_count : prepared -> int
val prepared_catalog : prepared -> t * projection_diagnostic list
val project_prepared_entry : prepared -> Skill_catalog_snapshot.entry -> entry_projection
val fold_prepared_entries :
  prepared ->
  init:'a ->
  f:('a -> Skill_catalog_snapshot.entry -> entry_projection -> effective:bool -> 'a) ->
  'a

val of_snapshot :
  ?descriptors:Keeper_tool_descriptor.t list -> Skill_catalog_snapshot.t -> t * projection_diagnostic list

val all_entries_of_snapshot :
  ?descriptors:Keeper_tool_descriptor.t list -> Skill_catalog_snapshot.t -> t * projection_diagnostic list

val project_entry_or_fallback :
  ?descriptors:Keeper_tool_descriptor.t list -> Skill_catalog_snapshot.t -> Skill_catalog_snapshot.entry -> entry_projection

val project_turn : names:string list option -> global:t -> task:skill list -> turn_projection

val turn_unavailable_to_string : turn_unavailable -> string
val configured_names_unavailable : turn_projection -> configured_name_unavailable list
val configured_name_unavailable_to_yojson : configured_name_unavailable -> Yojson.Safe.t
val exact_is_executable : turn_projection -> Skill_reference.t -> bool
val exact_surfaces : turn_projection -> task:skill list -> exact_surface list
val exact_surface_to_yojson : exact_surface -> Yojson.Safe.t
val unprojectable_exact_surface : Skill_reference.t -> diagnostic:string -> exact_surface

val empty : t
val skills : t -> skill list
val find : t -> string -> skill option
val instruction_entries : t -> (string * string * string) list
val surface_to_string : surface -> string
val provenance_to_yojson : provenance -> Yojson.Safe.t
val error_code : error -> string
val error_to_string : error -> string
