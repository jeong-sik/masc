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

type owner_budget_error = Invalid_owner_budget of int
type owner_budget
type sweep_cursor

type owner_projection =
  { keeper_name : string
  ; outcome : (projection_outcome, projection_error) result
  }

type sweep_report =
  { discovered : int
  ; processed : int
  ; deferred : int
  ; no_pending : int
  ; converged : int
  ; claim_busy : int
  ; projections : owner_projection list
  ; failures : owner_failure list
  ; discovery_error : discovery_error option
  }

type sweep_page =
  { report : sweep_report
  ; next_cursor : sweep_cursor
  }

val projection_error_to_string : projection_error -> string
val discovery_error_to_string : discovery_error -> string
val owner_budget_error_to_string : owner_budget_error -> string
val owner_budget : max_owners:int -> (owner_budget, owner_budget_error) result
val initial_sweep_cursor : sweep_cursor

val project_owner_result :
  base_path:string ->
  keeper_name:string ->
  (projection_outcome, projection_error) result
(** Acquire the process-local owner claim, inspect the durable outbox, and
    invoke the canonical reaction-ledger projector when work is present.
    Durable I/O runs outside the claim-table mutex and without cancellation
    masking. [Transition_converged] does not identify which process performed
    the physical append or retirement. *)

val project_discovered_bounded :
  base_path:string ->
  budget:owner_budget ->
  cursor:sweep_cursor ->
  sweep_page
(** Project one deterministic owner page. The next cursor resumes strictly
    after the last processed canonical keeper name and wraps in lexical order,
    so repeated maintenance ticks cannot starve a durable owner.
    [report.projections] contains exactly one typed outcome per selected owner
    in page order. The cursor is process-local and carries no migration or
    persistence contract. *)

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

  val pending_transition_count_result :
    base_path:string ->
    keeper_name:string ->
    (int, projection_error) result
  (** Read-only observation of the canonical durable outbox. No raw entry or
      transition-retirement capability crosses this testing boundary. *)
end
