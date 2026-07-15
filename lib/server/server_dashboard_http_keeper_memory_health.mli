(** Keeper Memory Health dashboard HTTP JSON helper.

    Produces a read-only snapshot of per-keeper fact-store sizes and GC-dry-run
    statistics for the
    /api/v1/dashboard/keeper-memory-health endpoint. *)

val keeper_memory_health_http_json : base_path:string -> Yojson.Safe.t
