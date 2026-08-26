(** Shared recovery surface for durable Keeper event-queue transition outboxes.

    The process-local owner claim only suppresses overlapping work in this
    process. It is not a durable lease or a physical exactly-once guarantee.
    Cross-process and crash retries converge accepted-transfer target
    projections and the reaction ledger's stable per-source event ids before
    retiring the matching durable outbox. *)

type projection_outcome =
  | No_pending_transition
  | Transition_converged
  | Claim_busy

type projection_error =
  | Owner_unavailable of Keeper_event_queue_persistence.owner_identity_error
  | Owner_shutdown_reserved of Keeper_shutdown_types.Operation_id.t
  | Executor_unavailable of Executor_pool_ref.strict_submit_error
  | Outbox_unavailable of string
  | Target_transfer_projection_failed of
      { target_keeper : string
      ; detail : string
      }
  | Paused_transfer_target_projection_failed of
      { target_keeper : string
      ; cause : Keeper_paused_work_transfer_transaction.failure
      }
  | Ledger_projection_failed of string
  | Unexpected_projection_failure of Eio.Exn.with_bt

type discovery_error =
  | Durable_state_discovery_failed of string
  | Sweep_execution_failed of Eio.Exn.with_bt
  | Sweep_executor_unavailable of Executor_pool_ref.strict_submit_error

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
  ; shutdown_reserved : int
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
(** Acquire the process-local owner claim and the owner's durable-intake fence,
    then inspect the durable outbox. A shutdown that linearizes first returns
    [Owner_shutdown_reserved]; an in-flight projection finishes before the
    shutdown join returns, so it cannot recreate artifacts after purge.

    Accepted transfers first converge the exact target projection; only then
    does the canonical reaction-ledger projector retire the source outbox.
    Durable I/O runs outside the claim-table mutex and without cancellation
    masking, and requires the startup executor pool; it is never run inline.
    [Transition_converged] does not identify which process performed the
    physical append or retirement. *)

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
    persistence contract. Executor unavailability returns an empty page with
    the unchanged cursor and a typed [discovery_error]. *)

module For_testing : sig
  type 'a claim_outcome =
    | Claim_acquired of 'a
    | Claim_already_held


  (** Read-only observation of the canonical durable outbox. No raw entry or
      transition-retirement capability crosses this testing boundary. *)
end
