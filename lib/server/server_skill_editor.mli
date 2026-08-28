(** CanAdmin Skill editor authority for existing published SKILL.md files.

    The editor never accepts a host path. An exact published reference is
    resolved back through the frozen source configuration, and writes are
    limited to sources declared [read-write]. The expected content revision is
    a compare-and-swap guard against overwriting an unpublished external edit. *)

type access = Read_only | Read_write

type path_rejection =
  | Outside_source
  | Non_directory_component
  | Non_regular_file
  | Identity_changed
  | Recovery_directory_not_private

type recovery_disposition =
  | Original_restored
  | Quarantine_retained
  | Original_restored_with_quarantine_retained

type loaded = private
  { reference : Skill_reference.t
  ; snapshot_revision : Skill_catalog_snapshot.snapshot_revision
  ; source_text : string
  ; access : access
  }

type preview = private
  { profile : Keeper_skill_observability.profile
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

type writable_source = private { source_id : Skill_source_config.source_id }

type create_outcome =
  | Created_and_published of
      { preview : preview
      ; snapshot_revision : Skill_catalog_snapshot.snapshot_revision
      }
  | Created_but_unpublished of
      { preview : preview
      ; reason : string
      }

type delete_outcome =
  | Deleted_and_published of
      { reference : Skill_reference.t
      ; snapshot_revision : Skill_catalog_snapshot.snapshot_revision
      ; recovery_id : string
      ; disposition : recovery_disposition
      }
  | Deleted_but_unpublished of
      { reference : Skill_reference.t
      ; reason : string
      ; recovery_id : string
      ; disposition : recovery_disposition
      }

type error =
  | Invalid_workspace
  | Snapshot_not_registered
  | Snapshot_uninitialized
  | Reference_not_current
  | Source_not_ready
  | Source_file_missing
  | Source_read_failed
  | Source_path_rejected of path_rejection
  | Source_read_only
  | Confirmation_required
  | Package_already_exists
  | Invalid_package_id of string
  | Revision_conflict of { actual : Skill_reference.content_revision }
  | Delete_revision_conflict of
      { actual : Skill_reference.content_revision
      ; recovery_id : string
      ; disposition : recovery_disposition
      }
  | Source_too_large of { bytes : int; max_bytes : int }
  | Validation_failed of string
  | Write_failed of string
  | Quarantine_failed of
      { candidate_moved : bool
      ; recovery_id : string option
      ; detail : string
      }
  | Recovery_required of
      { observed : Skill_reference.content_revision option
      ; recovery_id : string
      ; disposition : recovery_disposition
      ; detail : string
      }

val load : base_path:string -> Skill_reference.t -> (loaded, error) result
val preview : base_path:string -> Skill_reference.t -> source_text:string -> (preview, error) result

val save :
  base_path:string ->
  reference:Skill_reference.t ->
  source_text:string ->
  refresh:(unit -> (Skill_catalog_snapshot_service.publication, string) result) ->
  (save_outcome, error) result

(** Writable, ready source identities only. Resolved host paths never leave
    this authority boundary. *)
val writable_sources : base_path:string -> (writable_source list, error) result

(** Create one new package directory and SKILL.md without overwriting. *)
val create :
  base_path:string ->
  source_id:Skill_source_config.source_id ->
  package_id:string ->
  source_text:string ->
  refresh:(unit -> (Skill_catalog_snapshot_service.publication, string) result) ->
  (create_outcome, error) result

(** Logically delete the exact [SKILL.md] selected by [reference]. [confirmed]
    must be [true]. The candidate is atomically moved into a fresh private,
    non-scanned recovery directory and verified there. A matching candidate is
    retained under [recovery_id], never unlinked by this operation. Existing
    turns keep their immutable snapshot; [refresh] only publishes the change
    for later turns. *)
val delete :
  base_path:string ->
  reference:Skill_reference.t ->
  confirmed:bool ->
  refresh:(unit -> (Skill_catalog_snapshot_service.publication, string) result) ->
  (delete_outcome, error) result

val access_to_string : access -> string
val recovery_disposition_to_string : recovery_disposition -> string
val error_code : error -> string
val error_to_string : error -> string
val loaded_to_yojson : loaded -> Yojson.Safe.t
val preview_to_yojson : preview -> Yojson.Safe.t
val save_outcome_to_yojson : save_outcome -> Yojson.Safe.t
val writable_source_to_yojson : writable_source -> Yojson.Safe.t
val create_outcome_to_yojson : create_outcome -> Yojson.Safe.t
val delete_outcome_to_yojson : delete_outcome -> Yojson.Safe.t
val error_to_yojson : error -> Yojson.Safe.t

module For_testing : sig
  val recovery_file_path : source_root:string -> recovery_id:string -> string

  (** Inject an external path replacement after the exact revision precheck
      and immediately before the atomic quarantine rename. *)
  val delete :
    before_quarantine:(unit -> unit) ->
    after_quarantine:(unit -> unit) ->
    after_verification:(unit -> unit) ->
    base_path:string ->
    reference:Skill_reference.t ->
    confirmed:bool ->
    refresh:(unit -> (Skill_catalog_snapshot_service.publication, string) result) ->
    (delete_outcome, error) result
end
