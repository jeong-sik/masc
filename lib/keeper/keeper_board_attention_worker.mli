(** Per-Keeper Board-attention judgment worker.

    Provider work runs in this worker, never under Keeper turn admission. The
    candidate and partition ledgers are authoritative; process-local wakes only
    request another inspection. *)

type step =
  | Idle
  | Judgment_completed of
      { candidate_id : string
      ; owner_wake : Keeper_registry.wakeup_outcome
      }
  | Judgment_deferred of
      { candidate_id : string
      ; failure : Keeper_board_attention_failure.retryable
      }
  | Candidate_already_consumed of { candidate_id : string }
  | Partition_blocked of
      { candidate_id : string
      ; reason : Keeper_board_attention_partition.blocked_reason
      }

type settlement =
  | No_completed_partition
  | Partition_settled of
      { candidate_id : string
      ; continuation_wake : Keeper_registry.wakeup_outcome option
      }

val run :
  sw:Eio.Switch.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  net:Eio_context.eio_net option ->
  base_path:string ->
  keeper_name:string ->
  unit
(** Register and run the transition-driven worker until [sw] is cancelled.
    The first registration for this exact workspace/Keeper in the process owns
    prior-process recovery and replays one owner wake when durable [Completed]
    work exists. A durable [Deferred] root does not stop unrelated [Ready]
    siblings from draining. There is no timer polling or retry-count policy. *)

val settle_one_completed :
  base_path:string -> keeper_name:string -> (settlement, string) result
(** Owner-admission boundary. Apply and deliver at most one completed judgment,
    settle its partition, and request one continuation wake when more completed
    results remain. This function never invokes a Provider. *)

module For_testing : sig
  val process_next :
    now:(unit -> float) ->
    worker_epoch:Keeper_board_attention_partition.Worker_epoch.t ->
    base_path:string ->
    keeper_name:string ->
    judge:
      (Keeper_board_attention_candidate.candidate ->
       ( Keeper_board_attention_candidate.judgment
       , Keeper_board_attention_failure.attempt_failure )
       result) ->
    (step, string) result

  val drain_available :
    yield:(unit -> unit) ->
    now:(unit -> float) ->
    worker_epoch:Keeper_board_attention_partition.Worker_epoch.t ->
    base_path:string ->
    keeper_name:string ->
    judge:
      (Keeper_board_attention_candidate.candidate ->
       ( Keeper_board_attention_candidate.judgment
       , Keeper_board_attention_failure.attempt_failure )
       result) ->
    (unit, string) result
  (** Drain every currently claimable root. Each iteration releases due
      Provider-authored retries before claiming, keeps the deferred/blocked
      observability labels of the production loop, and continues past a durable
      [Deferred] so unrelated [Ready] siblings keep progressing. *)

  val replay_completed_owner_wake :
    base_path:string ->
    keeper_name:string ->
    wake_owner:
      (base_path:string -> keeper_name:string -> Keeper_registry.wakeup_outcome) ->
    (Keeper_registry.wakeup_outcome option, string) result
end
