(** Restart-scoped listener resource settings. The server reads them from
    runtime.toml once at boot. *)
val default_max_concurrent_streams : int
val default_max_pending_bytes : int
val max_concurrent_streams : unit -> int
val max_pending_bytes : unit -> int
