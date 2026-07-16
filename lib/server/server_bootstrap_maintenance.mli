val fork_logged_fiber :
  sw:Eio.Switch.t -> on_error:(exn -> unit) -> (unit -> unit) -> unit
val log_server_fiber_crash : string -> exn -> unit

val runtime_for_memory_os_consolidation : unit -> Runtime.t option
(** Resolve the selected consolidation runtime without discarding its identity;
    an unknown explicit selection is logged before falling back to the default. *)

val run_memory_os_consolidation_tick :
  ?complete:Keeper_memory_os_consolidation_runtime.complete_fn ->
  base_path:string ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  ?clock:float Eio.Time.clock_ty Eio.Resource.t ->
  runtime_id:string ->
  provider_cfg:Llm_provider.Provider_config.t ->
  now:float ->
  unit ->
  unit

val wake_enqueue_counts_of_dispatches :
  Schedule_runner.dispatch_result list -> Schedule_runner_status.wake_enqueue_counts
(** Derive keeper-wake delivery counts from typed production consumer receipts. *)

val start_background_maintenance :
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  env:Eio_unix.Stdenv.base ->
  Mcp_server.server_state -> string * string
