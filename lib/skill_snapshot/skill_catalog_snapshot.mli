(** Immutable catalog snapshot built from ordered Agent Skills sources. *)

type package_id = private string

type package_id_error =
  | Empty_package_id
  | Current_directory_package_id
  | Parent_directory_package_id
  | Package_id_contains_separator
  | Package_id_contains_nul

type content_revision = private string
type config_source_revision = private string
type config_revision = private string
type catalog_revision = private string
type snapshot_revision = private string

type identity = private
  { source_id : Skill_source_config.source_id
  ; package_id : package_id
  ; name : string
  }

type source_operation =
  | Inspect_source
  | Read_source_directory

type source_observation =
  | Source_ready of
      { resolved_path : string
      ; candidates : int
      }
  | Source_missing of { resolved_path : string }
  | Source_not_directory of
      { resolved_path : string
      ; kind : Unix.file_kind
      }
  | Source_unavailable of
      { resolved_path : string
      ; operation : source_operation
      ; detail : string
      }
  | Source_unresolved of Skill_source_config.resolution

type candidate =
  | Candidate_document of
      { directory : string
      ; source_text : string
      }
  | Candidate_unreadable of
      { directory : string
      ; path : string
      ; detail : string
      }

type source_scan =
  { source : Skill_source_config.resolved_source
  ; observation : source_observation
  ; candidates : candidate list
  }

type entry = private
  { identity : identity
  ; source_index : int
  ; directory : string
  ; document : Agent_core.Skill_document.t
  ; conformance : Agent_core.Skill_document.conformance
  ; source_text : string
  ; content_revision : content_revision
        (** SHA-256 identity of the exact [SKILL.md] bytes. Resource files are
            intentionally outside this revision until resource snapshots are
            introduced. *)
  }

type rejection_reason =
  | Document_rejected of Agent_core.Skill_document.diagnostic list
  | Document_unreadable of
      { path : string
      ; detail : string
      }
  | Exact_identity_duplicate of { first_directory : string }
  | Invalid_package_id of package_id_error

type rejection = private
  { source_index : int
  ; source_id : Skill_source_config.source_id
  ; package_id : package_id option
  ; directory : string
  ; reason : rejection_reason
  }

type shadow = private
  { winner : identity
  ; shadowed : identity
  }

type config_state =
  | Configured of
      { config : Skill_source_config.t
      ; revision : config_revision
      }
  | Config_rejected of
      { source_revision : config_source_revision
      ; diagnostics : Skill_source_config.diagnostic list
      }
  | Config_unreadable of { detail : string }

type t

type build_error =
  | Missing_source_scan of Skill_source_config.source_id
  | Duplicate_source_scan of Skill_source_config.source_id
  | Unexpected_source_scan of Skill_source_config.source_id
  | Source_scan_config_mismatch of Skill_source_config.source_id

val package_id_of_directory : string -> (package_id, package_id_error) result
val package_id_to_string : package_id -> string
val make_identity :
  source_id:Skill_source_config.source_id ->
  package_id:package_id ->
  name:string ->
  identity

val configured :
  config:Skill_source_config.t -> source_scan list -> (t, build_error list) result

val config_rejected :
  source_text:string ->
  diagnostics:Skill_source_config.diagnostic list ->
  t

val config_unreadable : detail:string -> t

val config_state : t -> config_state
val sources : t -> source_scan list
val entries : t -> entry list
val effective_entries : t -> entry list
val rejections : t -> rejection list
val shadows : t -> shadow list
val config_revision : t -> config_revision option
val catalog_revision : t -> catalog_revision
val snapshot_revision : t -> snapshot_revision

val find_exact : t -> identity -> entry option
val find_effective_by_name : t -> string -> entry option

val content_revision_to_string : content_revision -> string
val config_source_revision_to_string : config_source_revision -> string
val config_revision_to_string : config_revision -> string
val catalog_revision_to_string : catalog_revision -> string
val snapshot_revision_to_string : snapshot_revision -> string
val identity_to_yojson : identity -> Yojson.Safe.t
val to_public_yojson : t -> Yojson.Safe.t
(** Public projection omits Skill bodies, source text, resolved host paths, and
    raw filesystem error details. *)
