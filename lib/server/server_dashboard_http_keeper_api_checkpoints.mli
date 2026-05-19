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

val inventory_json : Coord.config -> string -> [ `Not_found | `OK ] * Yojson.Safe.t

val linked_artifact_json : kind:string -> string -> Yojson.Safe.t
