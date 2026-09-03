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

(** Why a Keeper with durable work has no runnable owner. [Owner_unknown] is a
    lookup that did not answer; [Owner_absent] is a lookup that answered and
    holds no such Keeper. Only the second is an orphan queue directory. *)
type durable_demand_owner_error =
  | Demand_unknown of string
  | Owner_unknown of string
  | Owner_absent
  | Executor_unavailable of Executor_pool_ref.strict_submit_error
  | Demand_execution_failed of exn * Printexc.raw_backtrace

module Recovery_for_testing : sig
  type durable_demand_recovery_action =
    | Wake_executable_owner
    | Supervise_recoverable_owner
    | Report_unknown_owner of string
    | Retain_non_executable_owner of string

  val durable_demand_recovery_action :
    Keeper_activation_readiness.owner_execution_truth ->
    durable_demand_recovery_action
  (** Pure decision used after durable demand and owner readiness have both
      been observed. An already-running owner must receive a fresh wake hint:
      the hint that accompanied the durable write did not survive restart. *)

  val load_durable_demand_meta :
    base_path:string ->
    config:Workspace.config ->
    keeper_name:string ->
    (Keeper_meta_contract.keeper_meta option, durable_demand_owner_error) result
  (** The exact classification the maintenance sweep runs per discovered
      Keeper. [Ok None] means the durable state carries no demand. *)

  val consume_owner_projection_batch :
    commit_cursor:(unit -> unit) ->
    keeper_name:('a -> string) ->
    recover_owner:('a -> unit) ->
    'a list ->
    unit
end

val retention_becomes_warning : int -> bool
(** One recovery pass a minute; the pass landing on a full day (1440)
    warns. Exposed for the suite. *)
