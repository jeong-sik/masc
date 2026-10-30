val fork_logged_fiber :
  sw:Eio.Switch.t -> on_error:(exn -> unit) -> (unit -> unit) -> unit
val log_server_fiber_crash : string -> exn -> unit

val wake_enqueue_counts_of_dispatches :
  Schedule_runner.dispatch_result list -> Schedule_runner_status.wake_enqueue_counts
(** Derive keeper-wake delivery counts from typed production consumer receipts. *)

type schedule_runner_state
(** Immutable state owned by one production runner loop. Before the first
    successful startup recovery no normal tick or dispatch is admitted. Active
    state retains the last held set and exact pending settlement intents. *)

val initial_schedule_runner_state : schedule_runner_state

val run_schedule_runner_tick :
  clock:(unit -> float) ->
  Workspace.config ->
  state:schedule_runner_state ->
  schedule_runner_state
(** One cadence of the schedule runner loop. Retry failed startup recovery
    before any normal tick; after its first success never recover active
    Running occurrences again, including after a normal tick error or crash.
    Record its start, run it with the
    production consumer, record its outcome (success, error or crash), then
    drop the cached fleet schedule list so the next read of that page carries
    this tick's runner status and holds. The returned immutable state preserves
    the held set on failure and settlement progress from both success and
    error returns. Progress is captured before clock, telemetry, owner-resume
    and cache effects: failures
    in those effects cannot discard new settlement intents. Pending intents
    retry only their original store verdict, never consumer delivery. Startup
    recovery failures use the same error/crash status and cache invalidation.
    Cancellation propagates. *)

val run_periodic_task_gc : Workspace.config -> days:int -> unit
(** One archive-first task-only GC pass (audit 2026-10-07 F-06 / D6-11),
    run from its own 24h maintenance block: first due at startup, then every
    24h of uptime, independent of the JSONL-prune outcome. Terminal tasks
    older than [days] move to [tasks-archive.json]; non-terminal tasks are
    never archived, and old workspace messages and backend pubsub are never
    touched. Failures are logged here and never propagate to the cleanup
    loop. *)

val recover_keeper_msg_requests_on_startup :
  base_path:string -> Keeper_msg_async.recovery_report
(** Settle durable async request rows that cannot have a live owner after a
    process restart. Called synchronously before background server work starts. *)

val recover_keeper_config_journal_on_startup :
  base_path:string -> Keeper_config_journal.report
(** Converge an interrupted keeper manifest + runtime assignment composite
    write (#31180) to its pre-request state and clear the journal. Called
    synchronously before background server work starts. *)

val with_initial_configuration :
  base_path:string -> (runtime_config_path:string -> 'a) -> ('a, string) result
(** Hold the existing configuration lock from the first bootstrap read through
    publication of the initial owner inventory. Recheck journal admission under
    that lock: early recovery's [No_journal] is not a later read permit. The
    callback's own missing/invalid-model result is preserved as its value. *)

val latest_keeper_config_journal_recovery_report :
  unit -> Keeper_config_journal.report option
(** Last config-journal startup recovery observed by this process.
    Read-only process-local projection, not recovery authority. *)

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

