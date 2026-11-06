(** The effects of a journaled resolution in [Keeper_approval_queue].

    [resolve_with_policy] resolves an approval for an operator. It finds the
    approval, claims its id, journals the decision with [journal_resolution]
    and completes the delivery. A new journal also notifies the waiting
    inventory and records the decision in the audit ledger
    ([record_journaled_resolution]). An approval that is already journaled
    completes again when the request is the same and fails with
    [Already_resolved] otherwise.
    [complete_delivery] wakes the keeper for a delivery; its
    [delivery_occasion] says why. A delivery whose grant is consumed sends no
    wake. A keeper that does not exist retires the delivery from the store
    ([remove_delivery_from_store]). After the resolution is enqueued it
    remembers the rule the operator asked for ([remember_rule_for_delivery]),
    projects the decision into the chat ([project_resolution_chat]) and
    signals the keeper.
    [remember_rule_for_entry] upserts the always-allow rule of an entry,
    records the audit receipt of a created or renewed rule, and counts and
    logs a failure that is not a cancellation. [approval_decision_equal]
    compares two decisions. [delivery_wake_was_observed] asks the reaction
    ledger whether the wake of a delivery was delivered, and answers [false]
    when it cannot read the ledger.
    [Keeper_approval_queue] includes this module. *)
open Keeper_approval_queue_result
open Keeper_approval_queue_codec
open Keeper_approval_queue_journal
open Keeper_approval_queue_rules

(* Why a delivery is being completed. The operator's decision reaches the
   audit ledger as [Resolved] once, when [journal_resolution] has made it
   durable (see [record_journaled_resolution]); no completion writes that row.
   The occasion only says why the wake is being sent, and a boot replay or a
   same-request resubmission logs it as a redelivery.

   Writing the row on every completion counted one click as many decisions --
   nineteen rows for one approval on 2026-09-22 while its keeper was offline
   across twenty-one boots (#37964). Writing it on the first completion, after
   the wake, lost the decision whenever that wake failed: the operator's second
   press and every boot replay found no pending entry and never wrote it. *)
type delivery_occasion =
  | First_commit
  | Boot_replay
  | Same_request_resubmitted

val complete_delivery :
  occasion:delivery_occasion ->
  persisted_delivery ->
  (resolution_result,
   resolve_error)
  result

val delivery_wake_was_observed :
  persisted_delivery -> bool

val resolve_with_policy :
  base_path:string ->
  id:string ->
  decision:decision ->
  source:decision_source ->
  ?remember_rule:bool ->
  ?rule_expires_at:float ->
  ?created_by:string ->
  unit ->
  (resolution_result, resolve_error) result
