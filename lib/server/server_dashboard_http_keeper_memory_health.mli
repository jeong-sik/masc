(** Read-only fleet health over the ordinary and source-bound current snapshots
    recall consumes. *)

val keeper_memory_health_http_json : base_path:string -> Yojson.Safe.t
