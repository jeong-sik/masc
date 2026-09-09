val fork_logged_fiber :
  sw:Eio.Switch.t -> on_error:(exn -> unit) -> (unit -> unit) -> unit
val log_server_fiber_crash : string -> exn -> unit

val wake_enqueue_counts_of_dispatches :
  Schedule_runner.dispatch_result list -> Schedule_runner_status.wake_enqueue_counts
(** Derive keeper-wake delivery counts from typed production consumer receipts. *)

val recover_keeper_msg_requests_on_startup :
  base_path:string -> Keeper_msg_async.recovery_report
(** Settle durable async request rows that cannot have a live owner after a
    process restart. Called synchronously before background server work starts. *)

val latest_keeper_msg_recovery_observation :
  unit -> Keeper_msg_async.recovery_report option
(** Last startup recovery report observed by this process. This is a read-only
    process-local projection; it is not recovery authority or durable state. *)

val start_background_maintenance :
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  env:Eio_unix.Stdenv.base ->
  Mcp_server.server_state -> string * string

module Otel_for_testing : sig
  val start_exporter_background : sw:Eio.Switch.t -> (unit -> unit) -> unit
  (** Fork [setup] under [sw] and return without waiting for it. *)
end

