(** Observation-only process and host file-descriptor facts.

    This module never admits, delays, pauses, serializes, or rejects Keeper
    work. It records actual typed [EMFILE]/[ENFILE] failures and exposes
    best-effort operating-system FD observations. *)

type nofile_cache =
  | Uninitialized
  | In_flight
  | Resolved of int option

val nofile_soft_limit_cache : nofile_cache Atomic.t

type system_fd_snapshot =
  { open_files : int
  ; max_files : int
  ; max_files_per_process : int option
  }

type external_level =
  | External_warn
  | External_crit

val note_exception : ?site:string -> exn -> unit
(** Record and log a typed FD-exhaustion exception. Other exceptions are
    ignored; their callers remain responsible for reporting them. *)

val engage_external : reason:string -> level:external_level -> ts:float -> unit -> unit
(** Record an external host-pressure signal as telemetry. Exact duplicate
    [(level, ts)] observations are idempotent. It never changes Keeper
    execution. *)

val projection_fields : unit -> (string * Yojson.Safe.t) list
val reset_for_tests : unit -> unit

val process_nofile_soft_limit : unit -> int option
val process_open_fd_count : unit -> int option
val system_fd_snapshot : ?now:float -> unit -> system_fd_snapshot option

val runtime_state_json :
  ?soft_limit:int option ->
  ?open_fds:int option ->
  ?system_fds:system_fd_snapshot option ->
  active_keepers:int ->
  unit ->
  Yojson.Safe.t
(** Raw observations for the runtime-health surface. [active_keepers] is an
    observed fleet count; it is never combined with an estimated FD cost. *)
