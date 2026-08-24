(** Checkpoint inventory JSON helpers for keeper dashboard API. *)

val stat_json_of_path : string -> Yojson.Safe.t

val agent_core_checkpoint_summary_json :
  source_kind:string ->
  snapshot_id:string ->
  path:string ->
  is_current:bool ->
  Agent_core.Checkpoint.t ->
  Yojson.Safe.t

(** Total dashboard projection of a typed checkpoint load failure. [Not_found]
    is a normal missing asset; every other constructor is an unavailable asset
    with its original categorical kind and detail preserved. *)
val checkpoint_load_error_json :
  Keeper_checkpoint_store.checkpoint_load_error -> Yojson.Safe.t

(** Additive checkpoint inventory projection. [current] remains a summary or
    null and [history] remains a summary list. [current_status],
    [current_error], and [history_errors] expose missing or unavailable assets
    without mixing diagnostic rows into the compatibility fields. *)
val inventory_json : Workspace.config -> string -> [ `Not_found | `OK ] * Yojson.Safe.t

type purge_report =
  { messages_before : int
  ; messages_after : int
  ; bytes_before : int
  ; bytes_after : int
  ; duplicates_dropped : int
  ; reasoning_blocks_stripped : int
  ; reasoning_messages_dropped : int
  ; tool_results_cleared : int
  }

type purge_result =
  { keeper : string
  ; trace_id : string
  ; apply_allowed : bool
  ; applied : bool
  ; backup_path : string option
  ; report : purge_report
  ; warnings : string list
  }

type purge_error =
  | Purge_invalid_keeper_name of string
  | Purge_keeper_not_found of string
  | Purge_keeper_active of string
  | Purge_checkpoint_unavailable of string
  | Purge_checkpoint_invalid of string
  | Purge_backup_failed of string
  | Purge_source_changed
  | Purge_install_failed of string

val purge_error_to_string : purge_error -> string

(** Deterministically preview or apply the fixed checkpoint purge policy.
    Preview is read-only and reports whether apply is currently allowed.
    Apply requires the Keeper to be fully absent from the runtime registry and
    serializes that check with same-Keeper boot registration. The canonical
    checkpoint is installed only if its exact source reference is unchanged. *)
val purge_current :
  Workspace.config ->
  keeper_name:string ->
  apply:bool ->
  (purge_result, purge_error) result

val purge_result_json : action:string -> purge_result -> Yojson.Safe.t

val linked_artifact_json : kind:string -> string -> Yojson.Safe.t
