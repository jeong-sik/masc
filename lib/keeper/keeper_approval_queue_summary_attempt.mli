(** The transitions of the summary and of its attempt in
    [Keeper_approval_queue].

    [mark_summary_pending] moves an entry whose summary was not requested to
    pending and refuses an entry with a bound exact attempt.
    [transition_summary_attempt] applies an update to the entry that a
    workspace, id, input hash and sequence name, under the store lock,
    persists the result, and publishes it; the update returns [None] to leave
    the entry as it is. [publish_summary_attempt_transition] publishes the
    summary update after a transition that wrote the entry.
    [mark_summary_attempt_identity_unbound],
    [mark_summary_attempt_persistence_uncertain] and
    [mark_summary_attempt_pre_worker_unavailable] set the matching
    disposition; the last one rejects an operator detail that is empty or has
    leading or trailing whitespace. [release_orphaned_start_reservation]
    returns a start reservation that a process restart orphaned to the ready
    disposition. [reserve_summary_attempt_retry] reserves a new start for an
    operator when the entry still has the disposition and the exact-attempt
    state the operator saw, and rejects a blank [requested_by].
    [retire_summary_owner] fails every pending summary of a keeper in a
    workspace and publishes each; it returns an error and fails none when one
    of them has a bound exact attempt.
    [Keeper_approval_queue] includes this module. *)
open Keeper_approval_queue_rules
open Keeper_approval_queue_result

val mark_summary_pending : id:string -> (bool, summary_transition_error) result

val mark_summary_attempt_identity_unbound :
  base_path:string ->
  id:string ->
  input_hash:string ->
  sequence:int ->
  (bool, exact_attempt_error) result

val mark_summary_attempt_persistence_uncertain :
  base_path:string ->
  id:string ->
  input_hash:string ->
  sequence:int ->
  (bool, exact_attempt_error) result

val mark_summary_attempt_pre_worker_unavailable :
  base_path:string ->
  id:string ->
  input_hash:string ->
  sequence:int ->
  reason_code:summary_attempt_pre_worker_unavailable_code ->
  operator_detail:string ->
  (bool, exact_attempt_error) result

val release_orphaned_start_reservation :
  base_path:string ->
  id:string ->
  input_hash:string ->
  sequence:int ->
  (bool, exact_attempt_error) result

val reserve_summary_attempt_retry :
  base_path:string ->
  id:string ->
  input_hash:string ->
  sequence:int ->
  expected_exact_attempt:exact_attempt_state ->
  expected_disposition:summary_attempt_disposition ->
  requested_by:string ->
  (bool, exact_attempt_error) result

val retire_summary_owner :
  base_path:string ->
  keeper_name:string ->
  reason:string ->
  (string list, summary_owner_retirement_error) result
