(** The grants of approved resolutions in [Keeper_approval_queue].

    [approved_delivery_unlocked] finds the approved delivery of an approval id
    and says whether its grant is consumed. It returns an error when the store
    of the workspace is unavailable, when the id belongs to another workspace
    ([grant_workspace_mismatch]), when the delivery rejected the request, when
    the entry is still pending, and when no entry has the id.
    [approved_resolution_request] returns the keeper, tool and input of an
    unconsumed grant and [None] for a consumed one,
    [approved_resolution_state] says which of the two it is, and
    [approved_resolution_delivery] returns both with the replay outcome. All
    three read under the store lock.
    [record_consumed_resolution_replay] writes the replay outcome of a
    consumed grant to the replay results file and to the delivery that holds
    the grant. It reports an outcome equal to the stored one
    ([resolution_replay_outcome_equal]) as already recorded and a different
    one as a conflict.
    [consume_approved_resolution] consumes the grant when the keeper, the tool
    and the input hash match the approved entry. It writes the snapshot under
    the lock and records the grant-consumed audit event after releasing it.
    [Keeper_approval_queue] includes this module. *)
open Keeper_approval_queue_result

val approved_resolution_request :
  base_path:string ->
  id:string ->
  (approved_resolution_request option, grant_error) result

val approved_resolution_state :
  base_path:string -> id:string -> (approved_resolution_state, grant_error) result

val approved_resolution_delivery :
  base_path:string ->
  id:string ->
  (approved_resolution_delivery, grant_error) result

val record_consumed_resolution_replay :
  base_path:string ->
  id:string ->
  outcome:resolution_replay_outcome ->
  (replay_recording, grant_error) result

val consume_approved_resolution :
  base_path:string ->
  id:string ->
  keeper_name:string ->
  tool_name:string ->
  input:Yojson.Safe.t ->
  (grant_consumption, grant_error) result
