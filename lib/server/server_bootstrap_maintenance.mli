val fork_logged_fiber :
  sw:Eio.Switch.t -> on_error:(exn -> unit) -> (unit -> unit) -> unit
val log_server_fiber_crash : string -> exn -> unit

val schedule_runner_interval_sec : float
val schedule_runner_stale_after_sec : float

val provider_cfg_for_memory_os_consolidation :
  unit -> Llm_provider.Provider_config.t option

val run_memory_os_consolidation_tick :
  ?complete:Keeper_memory_os_consolidation_runtime.complete_fn ->
  ?timeout_sec:float ->
  sw:Eio.Switch.t ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  ?clock:float Eio.Time.clock_ty Eio.Resource.t ->
  provider_cfg:Llm_provider.Provider_config.t ->
  now:float ->
  unit ->
  unit

module For_testing : sig
  val record_schedule_runner_due_lag_metrics :
    Schedule_runner.wake_signal list -> unit

  val record_schedule_runner_dispatch_metrics :
    Schedule_runner.dispatch_result list -> unit

  val enqueue_schedule_signal_keeper_wakes :
    config:Workspace.config ->
    Schedule_runner.wake_signal list ->
    Schedule_runner_status.wake_enqueue_counts

  val schedule_dispatch_wrapper : Schedule_runner.dispatch_wrapper

  val memory_os_fact_store_keeper_ids_for_tick :
    site:string -> (string list, string) result
end

val start_background_maintenance :
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  env:Eio_unix.Stdenv.base ->
  Mcp_server.server_state -> string * string
