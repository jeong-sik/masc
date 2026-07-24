(** Per-Keeper Board-attention judgment worker.

    MASC owns candidate membership, domain judgment state, and durable exact
    callbacks. OAS owns provider-neutral flow admission, dispatch, and
    advancement. Process-local wakes only request another durable inspection. *)

type contention =
  { keeper_name : string
  ; partition_id : string
  ; generation : Keeper_board_attention_partition.Generation.t
  }

type step =
  | Idle
  | Contended of contention
  | Judgment_completed of
      { candidate_id : string
      ; owner_wake : Keeper_registry.wakeup_outcome
      }
  | Candidate_already_consumed of { candidate_id : string }
  | Partition_blocked of
      { candidate_id : string
      ; reason : Keeper_board_attention_partition.blocked_reason
      }

type drain_outcome =
  | Drained
  | Retry_later of contention

type rearm_schedule =
  | Rearm_scheduled of { delay_s : float }
  | Rearm_deduplicated of { delay_s : float }

type settlement =
  | No_completed_partition
  | Partition_settled of
      { candidate_id : string
      ; continuation_wake : Keeper_registry.wakeup_outcome option
      }

type fatal_stage =
  | Registration
  | Process_start_recovery
  | Durable_drain
  | Control_loop

type fatal_error =
  { stage : fatal_stage
  ; detail : string
  }

val fatal_error_to_string : fatal_error -> string

val run :
  sw:Eio.Switch.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  net:Eio_context.eio_net option ->
  base_path:string ->
  keeper_name:string ->
  (unit, fatal_error) result
(** Register and run the wake-driven worker until [sw] is cancelled. The clock
    is forwarded to OAS execution. MASC owns no Provider execution policy.
    Setup or durability errors end this lifecycle instead of awaiting another
    wake. Exact claim contention schedules one generation-keyed delayed wake on
    the worker switch; it never recursively claims a sibling in the same turn.
    Cancellation performs no partition I/O: process-start recovery releases an
    unbound claim and quarantines every durably bound execution. Process recovery
    ownership is released when the lifecycle ends or is cancelled. *)

val settle_one_completed :
  base_path:string ->
  keeper_name:string ->
  (settlement, string) result
(** Owner-admission boundary. Apply and deliver at most one completed judgment,
    settle its partition, and request one continuation wake when more completed
    results remain. A completion that remains sync-unconfirmed after one explicit
    confirmation returns an error without delivery or wake. This function never
    invokes OAS. *)

module For_testing : sig
  type rearm_scheduler

  val process_next_with_claim_ready_exact :
    claim_ready_exact:
      (now:float ->
       worker_epoch:Keeper_board_attention_partition.Worker_epoch.t ->
       base_path:string ->
       keeper_name:string ->
       partition_id:string ->
       generation:Keeper_board_attention_partition.Generation.t ->
       (Keeper_board_attention_partition.t option, string) result) ->
    now:(unit -> float) ->
    worker_epoch:Keeper_board_attention_partition.Worker_epoch.t ->
    base_path:string ->
    keeper_name:string ->
    prepare:
      (Keeper_board_attention_candidate.candidate ->
       ( 'prepared
       , Keeper_board_attention_exact_flow.setup_error )
       result) ->
    execute:
      (before_dispatch:
         (Keeper_board_attention_exact_flow.attempt_provenance ->
          (unit, string) result) ->
       before_advance:
         (failed:Keeper_board_attention_exact_flow.attempt_provenance ->
          next:Keeper_board_attention_exact_flow.attempt_provenance ->
          (unit, string) result) ->
       'prepared ->
       ( Keeper_board_attention_candidate.judgment
       , string Keeper_board_attention_exact_flow.execution_error )
       result) ->
    (step, string) result
  (** Test seam for deterministic exact-claim conflicts. Production always uses
      [Keeper_board_attention_partition.claim_ready_exact]. *)

  val process_next :
    now:(unit -> float) ->
    worker_epoch:Keeper_board_attention_partition.Worker_epoch.t ->
    base_path:string ->
    keeper_name:string ->
    prepare:
      (Keeper_board_attention_candidate.candidate ->
       ( 'prepared
       , Keeper_board_attention_exact_flow.setup_error )
       result) ->
    execute:
      (before_dispatch:
         (Keeper_board_attention_exact_flow.attempt_provenance ->
          (unit, string) result) ->
       before_advance:
         (failed:Keeper_board_attention_exact_flow.attempt_provenance ->
          next:Keeper_board_attention_exact_flow.attempt_provenance ->
          (unit, string) result) ->
       'prepared ->
       ( Keeper_board_attention_candidate.judgment
       , string Keeper_board_attention_exact_flow.execution_error )
       result) ->
    (step, string) result
  (** Inject one provider-neutral exact-flow preparation and execution. The
      next Pending candidate is prepared before it is claimed; setup failure
      returns an error with the candidate still Pending and its partition Ready.
      The execution seam must invoke the supplied callbacks at the same boundaries
      as OAS. It exposes no Provider cause, receipt phase, or dispatch count. *)

  val drain_available :
    yield:(unit -> unit) ->
    now:(unit -> float) ->
    worker_epoch:Keeper_board_attention_partition.Worker_epoch.t ->
    base_path:string ->
    keeper_name:string ->
    prepare:
      (Keeper_board_attention_candidate.candidate ->
       ( 'prepared
       , Keeper_board_attention_exact_flow.setup_error )
       result) ->
    execute:
      (before_dispatch:
         (Keeper_board_attention_exact_flow.attempt_provenance ->
          (unit, string) result) ->
       before_advance:
         (failed:Keeper_board_attention_exact_flow.attempt_provenance ->
          next:Keeper_board_attention_exact_flow.attempt_provenance ->
          (unit, string) result) ->
       'prepared ->
       ( Keeper_board_attention_candidate.judgment
       , string Keeper_board_attention_exact_flow.execution_error )
       result) ->
    (drain_outcome, string) result
  (** Drain every currently claimable root. Terminal failures remain Blocked and
      completion durability failures return without re-entering OAS. Exact claim
      contention returns [Retry_later] without recursive same-turn retry. *)

  val make_contention_rearm_scheduler :
    fork:((unit -> unit) -> unit) ->
    sleep:(float -> unit) ->
    request:(unit -> string) ->
    unit ->
    rearm_scheduler

  val schedule_contention_rearm :
    rearm_scheduler -> contention -> rearm_schedule

  val reset_contention_rearms :
    rearm_scheduler -> keep:contention option -> unit
  (** Deterministic seam for the run-owner delayed rearm scheduler. Production
      supplies a structured [Eio.Fiber.fork] on the worker switch and its
      monotonic clock. *)

  val replay_completed_owner_wake :
    base_path:string ->
    keeper_name:string ->
    wake_owner:
      (base_path:string -> keeper_name:string -> Keeper_registry.wakeup_outcome) ->
    (Keeper_registry.wakeup_outcome option, string) result

  val with_process_recovery_claim :
    base_path:string -> keeper_name:string -> (bool -> 'a) -> 'a
  (** Run one lifecycle with process-recovery ownership when available, releasing
      that ownership on both normal return and exceptions. *)
end
