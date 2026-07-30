(** Read-only fleet health over the same current snapshots recall consumes. *)

val keeper_memory_health_http_json : base_path:string -> Yojson.Safe.t
