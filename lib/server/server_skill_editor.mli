(** CanAdmin Skill editor authority for existing published SKILL.md files.

    The editor never accepts a host path. An exact published reference is
    resolved back through the frozen source configuration, and writes are
    limited to sources declared [read-write]. The expected content revision is
    a compare-and-swap guard against overwriting an unpublished external edit. *)

type access = Read_only | Read_write

type loaded = private
  { reference : Skill_reference.t
  ; snapshot_revision : Skill_catalog_snapshot.snapshot_revision
  ; source_text : string
  ; access : access
  }

type preview = private
  { reference : Skill_reference.t
  ; profile : Keeper_skill_observability.profile
  ; diagnostics : string list
  }

type save_outcome =
  | Unchanged of
      { preview : preview
      ; snapshot_revision : Skill_catalog_snapshot.snapshot_revision
      }
  | Saved_and_published of
      { preview : preview
      ; snapshot_revision : Skill_catalog_snapshot.snapshot_revision
      }
  | Saved_but_unpublished of
      { preview : preview
      ; reason : string
      }

type error =
  | Invalid_workspace
  | Snapshot_not_registered
  | Snapshot_uninitialized
  | Reference_not_current
  | Source_not_ready
  | Source_file_missing
  | Source_read_failed
  | Source_read_only
  | Revision_conflict of { actual : Skill_reference.content_revision }
  | Source_too_large of { bytes : int; max_bytes : int }
  | Validation_failed of string
  | Write_failed of string

val load : base_path:string -> Skill_reference.t -> (loaded, error) result
val preview : base_path:string -> Skill_reference.t -> source_text:string -> (preview, error) result

val save :
  base_path:string ->
  reference:Skill_reference.t ->
  source_text:string ->
  refresh:(unit -> (Skill_catalog_snapshot_service.publication, string) result) ->
  (save_outcome, error) result

val access_to_string : access -> string
val error_code : error -> string
val error_to_string : error -> string
val loaded_to_yojson : loaded -> Yojson.Safe.t
val preview_to_yojson : preview -> Yojson.Safe.t
val save_outcome_to_yojson : save_outcome -> Yojson.Safe.t
