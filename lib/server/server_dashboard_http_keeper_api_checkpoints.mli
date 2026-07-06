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

val inventory_json : Workspace.config -> string -> [ `Not_found | `OK ] * Yojson.Safe.t
(** Inventory JSON for [GET /checkpoints].

    The payload includes [current_status], [read_error_count], and
    [read_errors].  A missing current checkpoint is reported as
    [current_status = "missing"]; parse/store/I/O/SDK failures are reported as
    [current_status = "read_error"] and/or entries in [read_errors] instead of
    being projected as an ordinary empty inventory. *)

val linked_artifact_json : kind:string -> string -> Yojson.Safe.t
