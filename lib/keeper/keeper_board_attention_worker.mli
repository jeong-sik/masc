(** Per-Keeper Board-attention judgment worker.

    MASC owns candidate membership, domain judgment state, and durable exact
    callbacks. AGENT_CORE owns opaque-runtime flow admission, dispatch, and
    advancement. Process-local wakes only request another durable inspection. *)

type contention =
  { keeper_name : string
  ; partition_id : string
  ; generation : Keeper_board_attention_partition.Generation.t
  }

type step =
  | Idle
  | Contended of contention
  | Rescan_later of contention
  | Judgment_completed of
      { candidate_id : string
      ; owner_wake : Keeper_registry.exact_wakeup_outcome
      }
  | Candidate_already_consumed of { candidate_id : string }
  | Partition_blocked of
      { candidate_id : string
      ; reason : Keeper_board_attention_partition.blocked_reason
      }

type retry_reason =
  | Exact_claim_contended
  | Selected_generation_changed

type drain_progress =
  { judgments : int
  ; steps : int
  }
(** What one drain did before it stopped: [judgments] counts candidates that
    produced a judgment, [steps] every loop iteration including visits that
    found the candidate already consumed or its partition blocked. A wake that
    finds an empty partition carries zeroes, which is what separates it from a
    drain that did work — the verdict alone cannot. *)

type drain_outcome =
  | Drained of drain_progress
  | Retry_later of
      { contention : contention
      ; reason : retry_reason
      ; progress : drain_progress
      }
(** [Drained] clears the contention re-arms; [Retry_later] keeps the durable
    partition undrained and re-arms the contention timer, so the same worker
    re-inspects it (see [apply_drain_rearm]). A generation that moved under the
    worker arrives here as [Retry_later { reason = Selected_generation_changed }]
    and is retried, not abandoned. The ledger stays the work authority in both
    cases. Both carry the progress made before the verdict: contention after
    ten judgments is not the same event as contention on the first visit. *)

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

val max_completed_settlements_per_owner_turn : unit -> int
(** Hard ceiling for filesystem-backed completed partitions settled by one
    owner turn. Remaining work is preserved behind a continuation wake.
    Backed by the [keeper.board_attention.settlements_per_turn]
    runtime_params tunable (see [Keeper_config]); read fresh on each call
    since an operator override can change it between turns. *)

val run :
  sw:Eio.Switch.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  net:Eio_context.eio_net option ->
  base_path:string ->
  keeper_name:string ->
  (unit, fatal_error) result
(** Register and run the wake-driven worker until [sw] is cancelled. The clock
    is forwarded to AGENT_CORE execution. MASC owns no execution-target policy.
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
(** Owner-admission boundary. Settle preceding non-admitting judgments only up
    to the fixed per-turn durability bound, cooperatively yielding between
    them; stop after the first admitting judgment and request one continuation
    wake when more completed results remain. A completion that remains
    sync-unconfirmed after one explicit confirmation returns an error without
    delivery or wake. This function never invokes AGENT_CORE. *)

module For_testing : sig
  type rearm_scheduler

  val reconcile_quarantines :
    now:float -> base_path:string -> keeper_name:string -> (unit, string) result
  (** The process-start quarantine reconciliation pass [run] performs.
      Exposed so a test can drive the retired-candidate settlement without
      standing up the full Eio worker lifecycle. *)

  val drain_outcome_label : drain_outcome -> string
  (** The drain verdict as one token, as logged. Retry_later keeps its reason
      so a worker stuck on a moved generation is distinguishable from one
      losing a claim race. *)

  val drain_outcome_progress : drain_outcome -> drain_progress
  (** The work counts the outcome carries, as logged. *)

  val drain_outcome_log_level : drain_outcome -> Log.level
  (** The level the drain line is emitted at, derived from the outcome.
      [Retry_later] leaves the partition undrained, so it is not routine. *)

  val cli_tail_may_answer : _ Keeper_board_attention_exact_flow.execution_error -> bool
  (** Whether an exact-flow terminal is one the lane's official-client tail may
      answer. True only for provider exhaustion: the persistence and provenance
      terminals mean the durable record is in doubt, and a domain-invalid
      answer is a contract failure rather than an unreachable provider.
      Exposed because the production path reaches it only with live providers
      and live clients. *)

  val process_next_exact
    :  clock:_ Eio.Time.clock
    -> net:Eio_context.eio_net option
    -> now:(unit -> float)
    -> worker_epoch:Keeper_board_attention_partition.Worker_epoch.t
    -> base_path:string
    -> keeper_name:string
    -> (step, string) result
  (** Exercise the production prepare/execute/result projection path. *)

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
         (failed:Keeper_board_attention_exact_flow.advance_source ->
          next:Keeper_board_attention_exact_flow.candidate_visit ->
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
         (failed:Keeper_board_attention_exact_flow.advance_source ->
          next:Keeper_board_attention_exact_flow.candidate_visit ->
          (unit, string) result) ->
       'prepared ->
       ( Keeper_board_attention_candidate.judgment
       , string Keeper_board_attention_exact_flow.execution_error )
       result) ->
    (step, string) result
  (** Inject one opaque-runtime exact-flow preparation and execution. The
      next Pending candidate is prepared before it is claimed; setup failure
      returns an error with the candidate still Pending and its partition Ready.
      The execution seam must invoke the supplied callbacks at the same boundaries
      as AGENT_CORE. It exposes no target cause, receipt phase, or dispatch count. *)

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
         (failed:Keeper_board_attention_exact_flow.advance_source ->
          next:Keeper_board_attention_exact_flow.candidate_visit ->
          (unit, string) result) ->
       'prepared ->
       ( Keeper_board_attention_candidate.judgment
       , string Keeper_board_attention_exact_flow.execution_error )
       result) ->
    (drain_outcome, string) result
  (** Drain every currently claimable root. Terminal failures remain Blocked and
      completion durability failures return without re-entering AGENT_CORE. Exact claim
      contention returns [Retry_later] without recursive same-turn retry. *)

  val drain_available_with_process :
    yield:(unit -> unit) ->
    process:(unit -> (step, string) result) ->
    (drain_outcome, string) result

  val make_contention_rearm_scheduler :
    fork:((unit -> unit) -> unit) ->
    sleep:(float -> unit) ->
    request:
      (unit ->
       (Keeper_board_attention_worker_wake.wake_result, string) result) ->
    unit ->
    rearm_scheduler

  val schedule_contention_rearm :
    rearm_scheduler -> contention -> rearm_schedule

  val reset_contention_rearms :
    rearm_scheduler -> keep:contention option -> unit

  val apply_drain_rearm :
    rearm_scheduler -> drain_outcome -> rearm_schedule option
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
