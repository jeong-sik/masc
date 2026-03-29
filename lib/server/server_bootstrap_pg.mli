(** Backend initialization functions.
    Initializes PG task backend when available, otherwise JSONL fallback. *)

val init_task_backend : unit -> unit
val inject_shared_pg_pool : unit -> unit
val init_pg_schemas_sequential : unit -> unit
