(** Observation-only accounting for FD-owning operations.

    This module never delays, serializes, rejects, or retries a callback. It
    records active instrumented scopes and best-effort OS FD facts. Typed
    [EMFILE], [ENFILE], and [ENOSPC] exceptions are reported to the installed
    observer and then re-raised unchanged. *)

type kind =
  | Docker_spawn
  | Provider_http
  | Provider_cli
  | Sandbox_exec
  | Log_writer

type resource_error =
  | Process_fd_exhausted
  | System_fd_exhausted
  | Storage_space_exhausted

val kind_to_string : kind -> string
val kind_of_string : string -> kind option
val all_kinds : kind list
val all_resource_errors : resource_error list
val resource_error_to_string : resource_error -> string
val resource_error_of_exn : exn -> resource_error option

val install_observers :
  nofile_soft_limit:(unit -> int option) ->
  on_resource_error:(kind:kind -> resource_error -> exn -> unit) ->
  unit
(** Replace the process observers. Installation changes observation only;
    callback execution never depends on either observer. The supplied nofile
    observer owns any caching policy. *)

val observe : kind:kind -> (unit -> 'a) -> 'a
(** [observe ~kind f] increments the active-scope count, invokes [f]
    immediately, and decrements the count on every return/exception path. *)

val acquire_lifetime_observation : kind:kind -> unit -> (unit -> unit)
(** Begin an observation whose lifetime outlives its acquiring call. The
    returned release callback is idempotent and never blocks. *)

val active_count : kind:kind -> int

val resource_error_count : kind:kind -> resource_error -> int
(** Monotonic count of typed resource errors observed for [kind]. Counting is
    internal, so an unavailable or faulty external observer cannot erase the
    event from telemetry. *)

val install_dated_jsonl_log_writer_observer : unit -> unit
val install_process_eio_sandbox_exec_observer : unit -> unit
val install_with_process_sandbox_exec_observer : unit -> unit
val install_autonomy_exec_sandbox_exec_observer : unit -> unit
val install_bg_sandbox_exec_observer : unit -> unit

type snapshot =
  { per_kind : (kind * int) list
  ; resource_errors : (kind * resource_error * int) list
  ; fd_open : int option
      (** Process-wide open FD observation when supported. *)
  ; fd_limit : int option
      (** [RLIMIT_NOFILE] soft limit when available. *)
  }

val fd_snapshot : unit -> snapshot
