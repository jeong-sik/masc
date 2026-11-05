(** How an exact attempt ends in the approval queue: the exceptions that carry
    a failed or cancelled settlement, the settlement results, quarantining a
    candidate, and the signals raised when the queue cannot record the end.
    [Hitl_summary_worker] includes this module. *)

open Keeper_approval_queue_result
open Keeper_approval_queue_rules_types
open Hitl_summary_exact_queue

exception Exact_terminalization_persistence_failed of string

exception Exact_terminalization_rejected of
            exact_attempt_rejection

exception Cancelled_uncertain of exn * Printexc.raw_backtrace * string

exception Exact_terminalization_identity_unbound of string

exception Cancelled_identity_unbound of exn * Printexc.raw_backtrace

exception Cancelled_exact_rejected of exn * Printexc.raw_backtrace *
            exact_attempt_rejection

type exact_settlement_error =
  | Exact_settlement_identity_unbound of string
  | Exact_settlement_persistence_failed of string
  | Exact_settlement_rejected of exact_attempt_rejection

type cancellation_settlement =
  | Cancellation_settled
  | Cancellation_exact_settlement_failed of exact_settlement_error
  | Cancellation_settlement_raised of string

val mark_persistence_uncertain :
  pending_approval ->
  (bool, exact_attempt_error) result

val persist_identity_unbound :
  pending_approval ->
  (unit,
   [> `Rejected of exact_attempt_rejection
    | `Storage_failed of string
    | `Transition_not_applied ])
  result

val signal_terminalization_persistence_failure :
  pending_approval ->
  string -> string -> 'a

val quarantine_identity :
  queue_ops:exact_queue_ops ->
  pending_approval ->
  exact_identity ->
  exact_attempt_quarantine_cause -> unit

val quarantine_candidate :
  queue_ops:exact_queue_ops ->
  pending_approval ->
  Llm_provider.Exact_output.flow_attempt_receipt ->
  exact_attempt_quarantine_cause -> unit

val settle_current :
  queue_ops:exact_queue_ops ->
  pending_approval ->
  reason:string ->
  cause:exact_attempt_quarantine_cause ->
  (unit, exact_settlement_error) result

val settle_current_or_signal :
  queue_ops:exact_queue_ops ->
  pending_approval ->
  reason:string ->
  cause:exact_attempt_quarantine_cause ->
  unit
