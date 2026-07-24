(** Shared recovery surface for durable Keeper event-queue transition outboxes.

    The process-local owner claim only suppresses overlapping work in this
    process. It is not a durable lease or a physical exactly-once guarantee.
    Cross-process and crash retries converge through the reaction ledger's
    stable per-source event ids, then retire the matching durable outbox. *)

type projection_outcome =
  | No_pending_transition
  | Transition_converged
  | Claim_busy

type projection_error =
  | Owner_unavailable of Keeper_event_queue_persistence.owner_identity_error
  | Outbox_unavailable of string
  | Ledger_projection_failed of string
  | Unexpected_projection_failure of Eio.Exn.with_bt

type discovery_error = Snapshot_discovery_failed of string

type owner_failure =
  { keeper_name : string
  ; error : projection_error
  }

type sweep_report =
  { discovered : int
  ; no_pending : int
  ; converged : int
  ; claim_busy : int
  ; failures : owner_failure list
  ; discovery_error : discovery_error option
  }

val projection_error_to_string : projection_error -> string
val discovery_error_to_string : discovery_error -> string

val project_owner_result :
  base_path:string ->
  keeper_name:string ->
  (projection_outcome, projection_error) result
(** Acquire the process-local owner claim, inspect the durable outbox, and
    invoke the canonical reaction-ledger projector when work is present.
    Durable I/O runs outside the claim-table mutex and without cancellation
    masking. [Transition_converged] does not identify which process performed
    the physical append or retirement. *)

val project_discovered : base_path:string -> sweep_report
(** Discover current-schema durable queue owners and project each owner through
    {!project_owner_result}. A partial discovery error is retained alongside
    results for every owner that was discovered successfully. *)

module For_testing : sig
  type 'a claim_outcome =
    | Claim_acquired of 'a
    | Claim_already_held

  val with_owner_claim :
    base_path:string ->
    keeper_name:string ->
    (unit -> 'a) ->
    ('a claim_outcome, projection_error) result
  (** Hold the canonical process-local owner claim while running the callback.
      The claim-table mutex is not held while the callback runs. *)
end
