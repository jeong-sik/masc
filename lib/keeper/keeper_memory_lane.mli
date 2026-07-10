(** Restart-durable per-keeper memory execution lane (RFC-0257).

    The lane keeps only worker ownership in process memory. Accepted work is a
    typed {!Keeper_memory_job_store.job} persisted under its BasePath before
    [submit] returns. Each keeper has one drain daemon; different keepers drain
    independently. A process crash leaves pending/inflight jobs replayable and
    never requires retaining an unbounded closure FIFO on the OCaml heap. *)

type retryability =
  | Retryable
  | Terminal

type execution_error =
  { retryability : retryability
  ; kind : string
  ; message : string
  ; detail : Yojson.Safe.t
  }

type execute =
  base_path:string ->
  Keeper_memory_job_store.job ->
  (Yojson.Safe.t, execution_error) result

type worker_deferred_reason =
  | Executor_not_initialized
  | Executor_base_path_mismatch
  | Executor_switch_released
  | Hook_registration_failed
  | Fork_failed

type worker_state =
  | Started
  | Already_running
  | Not_needed
  | Deferred of worker_deferred_reason

type admission =
  | Admitted of
      { job_id : string
      ; activation : Keeper_memory_job_store.activation
      ; worker : worker_state
      }
  | Rejected of Keeper_memory_job_store.error

type staging =
  | Staged of
      { job_id : string
      ; durable : Keeper_memory_job_store.admission
      }
  | Stage_rejected of Keeper_memory_job_store.error

type init_report =
  { discovered_keepers : int
  ; workers_started : int
  ; workers_deferred : int
  ; discovery_error : Keeper_memory_job_store.error option
  ; keeper_discovery_errors : Keeper_memory_job_store.error list
  }

val init :
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  base_path:string ->
  execute:execute ->
  init_report
(** Install the one long-lived executor and start workers for every keeper with
    durable backlog. Repeating with the same switch/BasePath/handler is
    idempotent; replacing any of them is a programming error. A root discovery
    failure is returned in [discovery_error]. Keeper-local malformed backlogs
    are isolated in [keeper_discovery_errors], while healthy keepers still
    start. Every error is logged, never hidden. *)

val stage :
  base_path:string ->
  Keeper_memory_job_store.job ->
  staging
(** Durably admit a non-runnable awaiting-turn-commit job. *)

val activate :
  base_path:string -> Keeper_memory_job_store.job -> admission
(** Activate a staged job only after the owning execution receipt committed,
    then wake its Keeper lane. *)

val abort :
  base_path:string ->
  Keeper_memory_job_store.job ->
  (unit, Keeper_memory_job_store.error) result
(** Remove a staged job after execution-receipt failure. *)

val request_reconciliation :
  base_path:string -> keeper_name:string -> unit
(** Start or retain the self-retrying strict execution-receipt reconciliation
    loop for one Keeper. Used when the caller cannot safely classify an
    awaiting outbox as committed or aborted. Missing/mismatched executor
    ownership is logged explicitly and the durable outbox remains untouched. *)

val worker_deferred_reason_to_string : worker_deferred_reason -> string

module For_testing : sig
  val reset : unit -> unit
  val backlog_count : base_path:string -> keeper_name:string -> (int, Keeper_memory_job_store.error) result
end
