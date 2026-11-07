(** The approval lifecycle rows of a transcript.

    A system-owned row records one phase of an approval, and its delivery key
    is the approval id, so a retry and a restart converge on one row.
    [append_approval_lifecycle_at_slot_once] appends the row at a transcript
    slot that its caller names and answers with an [approval_lifecycle_append]:
    exact, or a conflict with the lifecycle that holds the slot.
    [append_approval_lifecycle_once] picks the slot from the phase and turns a
    conflict into an [Error] that names both phases.
    [reconcile_approval_replay_lifecycle_once] settles a replay outcome against
    the row on disk: an identical row stays, and a conflicting one makes it
    append the outcome once in the correction slot.
    [approval_lifecycle_equal] compares the approval id, the phase and the
    artifact reference, and takes a missing [tool_name] as no conflict.
    [existing_approval_lifecycle_at_slot] reads the lifecycle stored at a slot.
    [approval_lifecycle_phase_present] and [approval_continuation_settled] ask
    whether a phase, or a settlement of the continuation, is on disk, and
    [approval_request_call_summary] returns the call summary of the request
    row. [approval_lifecycle_is_replay] and [approval_lifecycle_is_continuation]
    sort the phases.
    [Keeper_chat_store] includes this module. *)
open Keeper_approval_lifecycle
open Keeper_chat_types

val approval_lifecycle_is_continuation :
  approval_lifecycle_phase -> bool

val append_approval_lifecycle_once :
  base_dir:string ->
  keeper_name:string ->
  lifecycle:approval_lifecycle ->
  (append_once_result, string) result

val reconcile_approval_replay_lifecycle_once :
  base_dir:string ->
  keeper_name:string ->
  lifecycle:approval_lifecycle ->
  (append_once_result, string) result

val approval_lifecycle_phase_present :
  base_dir:string ->
  keeper_name:string ->
  approval_id:string ->
  phase:approval_lifecycle_phase ->
  bool

val approval_continuation_settled :
  base_dir:string ->
  keeper_name:string ->
  approval_id:string ->
  bool

val approval_request_call_summary :
  base_dir:string ->
  keeper_name:string ->
  approval_id:string ->
  string option
