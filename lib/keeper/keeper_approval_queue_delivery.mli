(** The delivery of a committed resolution to its keeper in
    [Keeper_approval_queue].

    [commit_keeper_approval_resolution] enqueues the resolution for the
    keeper durably. A keeper that does not exist is returned as
    [Hitl_recipient_absent] without a failure record; any other failure is
    counted and logged by [record_resolution_delivery_failure].
    [deliver_resolution] commits the resolution of an entry through the
    continuation channel of that entry and translates the decision with
    [hitl_resolution_decision_of_approval_decision].
    [signal_resolution_after_commit] asks the registry to wake the keeper,
    counts the outcome, and counts and logs any failure other than a
    cancellation.
    [ensure_resolution_chat_projection], [ensure_replay_chat_projection] and
    [continuation_settled_chat_projection_present] are the functions of the
    same names in [Keeper_approval_queue_projection].
    [settled_continuation_readiness] answers [Continuation_ready None] for a
    rejection and reads the approved delivery for an approval.
    [ensure_settled_continuation_chat_projection] and
    [ensure_failed_continuation_chat_projection] record the settled or the
    failed continuation of a resolution in the chat projection with that
    readiness. [record_native_continuation_delivery] records a settled
    continuation with the tool name of the approved request and refuses a
    request that belongs to another keeper.
    [Keeper_approval_queue] includes this module. *)
open Keeper_approval_queue_result
open Keeper_approval_queue_rules

val record_resolution_delivery_failure :
  keeper_name:string -> approval_id:string -> string -> unit

val signal_resolution_after_commit :
  base_path:string -> keeper_name:string -> approval_id:string -> unit

val hitl_resolution_decision_of_approval_decision :
  Keeper_approval_queue_rules_types.decision ->
  Keeper_event_queue.hitl_resolution_decision

val deliver_resolution :
  base_path:string ->
  Keeper_approval_queue_rules_types.pending_approval ->
  Keeper_approval_queue_rules_types.decision ->
  (unit, Keeper_registry_event_queue.hitl_resolution_enqueue_error) result

val ensure_resolution_chat_projection :
  base_path:string ->
  keeper_name:string ->
  approval_id:string ->
  tool_name:string option ->
  decision:decision ->
  (unit, string) result

val ensure_replay_chat_projection :
  base_path:string ->
  keeper_name:string ->
  approval_id:string ->
  tool_name:string option ->
  outcome:resolution_replay_outcome ->
  (unit, string) result

val continuation_settled_chat_projection_present :
  base_path:string ->
  keeper_name:string ->
  approval_id:string ->
  bool

type continuation_projection_result =
  Keeper_approval_queue_result.continuation_projection_result =
  | Continuation_projection_recorded
  | Continuation_projection_not_ready

val ensure_settled_continuation_chat_projection :
  base_path:string ->
  keeper_name:string ->
  resolution:Keeper_event_queue.hitl_resolution ->
  (continuation_projection_result, string) result

val record_native_continuation_delivery :
  base_path:string -> keeper_name:string ->
  resolution:Keeper_event_queue.hitl_resolution ->
  (continuation_projection_result, string) result

val ensure_failed_continuation_chat_projection :
  base_path:string ->
  keeper_name:string ->
  resolution:Keeper_event_queue.hitl_resolution ->
  route:Keeper_runtime_failure_route.route ->
  (continuation_projection_result, string) result
