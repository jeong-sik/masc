(** Restart-scoped listener resource settings. The server reads them from
    runtime.toml once at boot. *)
val default_max_concurrent_streams : int
val default_max_pending_bytes : int
val default_initial_window_size : int
(** The h2 library's per-stream window, 2^27 octets. *)

val max_settings_value : int
(** The largest value a stream limit or window setting carries. *)

val max_concurrent_streams : unit -> int
val max_pending_bytes : unit -> int

val initial_window_size : unit -> int
(** The flow-control window each H2 stream starts with, in octets. *)
