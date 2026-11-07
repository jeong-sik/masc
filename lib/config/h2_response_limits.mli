(** Restart-scoped listener resource settings. The server reads them from
    runtime.toml once at boot. *)
val default_max_concurrent_streams : int
val default_max_pending_bytes : int
val default_initial_window_size : int
val default_max_frame_size : int

val min_max_frame_size : int
val max_max_frame_size : int
(** The bounds RFC 9113 §6.5.2 puts on SETTINGS_MAX_FRAME_SIZE. *)

val max_settings_value : int
(** The largest value a stream limit or window setting carries. *)

val max_concurrent_streams : unit -> int
val max_pending_bytes : unit -> int

val initial_window_size : unit -> int
(** The flow-control window each H2 stream starts with, in octets. *)

val max_frame_size : unit -> int
(** The largest frame payload the server announces it accepts, in octets. *)
