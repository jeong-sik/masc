(** Checkpoint inventory JSON helpers for keeper dashboard API. *)

val stat_json_of_path : string -> Yojson.Safe.t

val oas_checkpoint_summary_json :
  source_kind:string ->
  snapshot_id:string ->
  path:string ->
  is_current:bool ->
  fallback_generation:int ->
  Agent_sdk.Checkpoint.t ->
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

val linked_artifact_json : kind:string -> string -> Yojson.Safe.t
