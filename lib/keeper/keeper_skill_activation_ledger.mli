(** Durable, session-scoped evidence of exact Skill activations. *)

type ledger_revision = private string

type origin =
  | Task_instruction of { task_id : Keeper_id.Task_id.t }
  | Session_instruction
  | Task_composition of
      { task_id : Keeper_id.Task_id.t
      ; tool_name : string
      }
  | Session_composition of { tool_name : string }

type activation = private
  { identity : Skill_reference.identity
  ; content_revision : Skill_reference.content_revision
  ; snapshot_revision : Skill_catalog_snapshot.snapshot_revision
  ; turn_ref : Ids.Turn_ref.t
  ; activated_at : string
  ; origin : origin
  }

type t

type record_outcome =
  | Recorded of activation
  | Already_recorded of activation

type decode_error =
  | Expected_object of { field : string }
  | Missing_string of { field : string }
  | Duplicate_field of
      { object_name : string
      ; field : string
      }
  | Unexpected_field of
      { object_name : string
      ; field : string
      }
  | Unsupported_schema of string
  | Invalid_source_id of string
  | Invalid_skill_name of string
  | Invalid_package_id of Skill_reference.package_id_error
  | Invalid_content_revision of Skill_reference.revision_error
  | Invalid_snapshot_revision of Skill_catalog_snapshot.revision_error
  | Invalid_origin_kind of string
  | Invalid_task_id of string
  | Invalid_tool_name of string
  | Invalid_turn_ref of string
  | Turn_ref_session_mismatch
  | Invalid_activated_at of string
  | Duplicate_exact_activation
  | Session_id_mismatch
  | Workspace_key_mismatch
  | Invalid_ledger_revision of Skill_catalog_snapshot.revision_error
  | Ledger_revision_mismatch

type store_error =
  | Lock_failed of string
  | Read_failed of Fs_compat.owned_regular_file_read_error
  | Decode_failed of decode_error
  | Write_failed of Keeper_fs.durable_write_error
  | Readback_mismatch

val store_error_to_string : store_error -> string

val empty : workspace_root:string -> trace_id:Keeper_id.Trace_id.t -> t
val activations : t -> activation list
val revision : t -> ledger_revision
val ledger_revision_to_string : ledger_revision -> string

val make_activation :
  identity:Skill_reference.identity ->
  content_revision:Skill_reference.content_revision ->
  snapshot_revision:Skill_catalog_snapshot.snapshot_revision ->
  turn_ref:Ids.Turn_ref.t ->
  activated_at:string ->
  origin:origin ->
  (activation, decode_error) result

val to_yojson : t -> Yojson.Safe.t
val of_yojson :
  expected_workspace_root:string ->
  expected_trace_id:Keeper_id.Trace_id.t ->
  Yojson.Safe.t ->
  (t, decode_error) result

val load :
  config:Workspace.config ->
  trace_id:Keeper_id.Trace_id.t ->
  (t, store_error) result

val record :
  config:Workspace.config ->
  trace_id:Keeper_id.Trace_id.t ->
  activation ->
  (t * record_outcome, store_error) result
(** Record by exact [(identity, content_revision)] key. Repeating the same
    activation is idempotent; same-name Skills from another source/package or
    revision remain distinct. *)
