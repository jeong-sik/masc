(** The submission of a new approval request in [Keeper_approval_queue].

    [generate_id] makes an approval id. [default_continuation_channel] is the
    unrouted channel of a request without an originating connector.
    [create_entry] builds a pending entry with the fingerprint of the input as
    its input hash, the current time as its request time, and a summary that
    is not requested.
    [submit_pending] returns an error when the store of the workspace is not
    installed or is unavailable. A request that matches a pending entry in
    workspace, keeper, tool, input, origin, task, goal and continuation
    channel is deduplicated, and one that matches an approved delivery with an
    unconsumed grant is folded onto it. Any other request becomes a new entry
    at the next sequence, persisted under the store lock; the call returns an
    error when the sequence is exhausted. After the lock it notifies the
    waiting inventory and records the pending audit event.
    [Keeper_approval_queue] includes this module. *)
open Keeper_approval_queue_result

val generate_id : unit -> string

val submit_pending :
  keeper_name:string ->
  tool_name:string ->
  input:Yojson.Safe.t ->
  call_summary:string option ->
  base_path:string ->
  ?turn_id:int ->
  origin:Keeper_approval_origin.t ->
  ?request_context:Yojson.Safe.t ->
  ?observation:Keeper_approval_queue_rules_types.observed_refusal ->
  ?task_id:string ->
  ?goal_id:string ->
  ?continuation_channel:Keeper_continuation_channel.t ->
  unit ->
  (pending_submission, storage_error) result
