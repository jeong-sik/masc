(** The exact-attempt transitions of a summary in [Keeper_approval_queue].

    [exact_attempt_entry_unlocked] finds the entry that an exact-attempt
    candidate names and returns an error when the entry is missing or its
    input hash or sequence differs. [persist_exact_attempt_entry_unlocked]
    writes the snapshot with the updated entry through the writer and the
    write mode it is given and replaces the pending map when the write lands.
    [bind_summary_exact_attempt_with],
    [release_summary_exact_attempt_before_dispatch_with],
    [quarantine_summary_exact_attempt_with] and
    [complete_summary_exact_attempt_with] validate the candidate, apply the
    matching transition of [Keeper_approval_queue_exact_transition] to its
    entry under the store lock, persist the result, and publish it once the
    lock is released. They share one body, [transition_exact_attempt], which
    takes the transition as its first argument. The functions without [_with]
    fix the [Append_rows] write mode and
    [Fs_compat.save_file_atomic_strict_staged].
    [Keeper_approval_queue] includes this module. *)
open Keeper_approval_queue_result
open Keeper_approval_queue_registry
open Keeper_approval_queue_rules

val bind_summary_exact_attempt_with :
  write_mode:write_mode ->
  save_file_atomic_strict_staged:(string ->
                                  string ->
                                  (unit, Fs_compat.atomic_replace_failure)
                                  result) ->
  id:string ->
  input_hash:string ->
  sequence:int ->
  slot_id:string ->
  call_id:string ->
  plan_fingerprint:string ->
  request_body_sha256:string ->
  (exact_attempt_transition,
   exact_attempt_error)
  result

val bind_summary_exact_attempt :
  id:string ->
  input_hash:string ->
  sequence:int ->
  slot_id:string ->
  call_id:string ->
  plan_fingerprint:string ->
  request_body_sha256:string ->
  (exact_attempt_transition, exact_attempt_error) result

val release_summary_exact_attempt_before_dispatch_with :
  write_mode:write_mode ->
  save_file_atomic_strict_staged:(string ->
                                  string ->
                                  (unit, Fs_compat.atomic_replace_failure)
                                  result) ->
  id:string ->
  input_hash:string ->
  sequence:int ->
  slot_id:string ->
  call_id:string ->
  plan_fingerprint:string ->
  request_body_sha256:string ->
  (exact_attempt_transition,
   exact_attempt_error)
  result

val release_summary_exact_attempt_before_dispatch :
  id:string ->
  input_hash:string ->
  sequence:int ->
  slot_id:string ->
  call_id:string ->
  plan_fingerprint:string ->
  request_body_sha256:string ->
  (exact_attempt_transition, exact_attempt_error) result

val quarantine_summary_exact_attempt_with :
  write_mode:write_mode ->
  save_file_atomic_strict_staged:(string ->
                                  string ->
                                  (unit, Fs_compat.atomic_replace_failure)
                                  result) ->
  id:string ->
  input_hash:string ->
  sequence:int ->
  slot_id:string ->
  call_id:string ->
  plan_fingerprint:string ->
  request_body_sha256:string ->
  cause:Keeper_approval_queue_rules_types.exact_attempt_quarantine_cause ->
  (exact_attempt_transition,
   exact_attempt_error)
  result

val quarantine_summary_exact_attempt :
  id:string ->
  input_hash:string ->
  sequence:int ->
  slot_id:string ->
  call_id:string ->
  plan_fingerprint:string ->
  request_body_sha256:string ->
  cause:exact_attempt_quarantine_cause ->
  (exact_attempt_transition, exact_attempt_error) result

val complete_summary_exact_attempt_with :
  write_mode:write_mode ->
  save_file_atomic_strict_staged:(string ->
                                  string ->
                                  (unit, Fs_compat.atomic_replace_failure)
                                  result) ->
  id:string ->
  input_hash:string ->
  sequence:int ->
  slot_id:string ->
  call_id:string ->
  plan_fingerprint:string ->
  request_body_sha256:string ->
  summary:Keeper_approval_queue_rules_types.hitl_context_summary ->
  (exact_attempt_transition,
   exact_attempt_error)
  result

val complete_summary_exact_attempt :
  id:string ->
  input_hash:string ->
  sequence:int ->
  slot_id:string ->
  call_id:string ->
  plan_fingerprint:string ->
  request_body_sha256:string ->
  summary:hitl_context_summary ->
  (exact_attempt_transition, exact_attempt_error) result
