(** Restart-scoped listener resource settings. Process environment overrides
    runtime.toml via the existing validated boot-overlay registry. *)
val default_max_concurrent_streams : int
val default_max_pending_bytes : int
val max_concurrent_streams : unit -> int
val max_pending_bytes : unit -> int
